#!/bin/bash
# mount-stress.sh — generate mount traffic and measure PID 1 overhead
#
# Usage: mount-stress.sh [background_mounts] [churn_count] [parallel_workers] [max_delay_ms]
#
# parallel_workers  — number of concurrent mount/umount workers (default: 1)
# max_delay_ms      — max random delay in ms between mount and umount (default: 100)
#
# If perf is available, automatically captures PID 1 syscall profile during
# the churn phase. Syscalls traced: read, openat, statx, newfstatat, fstatfs,
# listmount, statmount, close, sendmsg.

set -eu

BACKGROUND=${1:-500}
CHURN=${2:-200}
PARALLEL=${3:-1}
MAX_DELAY_MS=${4:-100}
BASE=/tmp/mnt-stress
PERF_OUTPUT=/tmp/perf-stress.txt
PERF_PID=""
SYSCALLS="read,openat,statx,newfstatat,fstatfs,listmount,statmount,close,sendmsg"
SYSTEMD_PID=1

cleanup() {
    if [ -n "$PERF_PID" ] && kill -0 "$PERF_PID" 2>/dev/null; then
        kill -INT "$PERF_PID" 2>/dev/null
        wait "$PERF_PID" 2>/dev/null || true
    fi
    for i in $(seq 1 $BACKGROUND); do
        umount "$BASE/bg-$i" 2>/dev/null || true
    done
    rm -rf "$BASE"
}
trap cleanup EXIT

mkdir -p "$BASE"

random_delay_ms() {
    local max=$1
    if [ "$max" -gt 0 ]; then
        local ms=$(( RANDOM % (max + 1) ))
        sleep "0.$(printf '%03d' $ms)"
    fi
}

echo "=== Phase 1: creating $BACKGROUND background mounts ==="
for i in $(seq 1 $BACKGROUND); do
    dir="$BASE/bg-$i"
    mkdir -p "$dir"
    mount -t tmpfs "stress-bg-$i" "$dir" 2>/dev/null
done

echo "Background done: $(wc -l < /proc/self/mountinfo) entries in mountinfo"

# Start perf trace after background mounts to avoid buffer overflow
if command -v perf >/dev/null 2>&1; then
    echo "=== Starting perf trace on PID $SYSTEMD_PID ==="
    rm -f "$PERF_OUTPUT"
    perf trace -s -e "$SYSCALLS" -p "$SYSTEMD_PID" -- sleep 600 2>"$PERF_OUTPUT" &
    PERF_PID=$!
    sleep 0.5
fi

echo "=== Phase 2: $CHURN mount/umount cycles ($PARALLEL workers, max delay ${MAX_DELAY_MS}ms) ==="

JOURNAL_CURSOR=$(journalctl -n 0 --show-cursor 2>/dev/null | grep -o 's=.*' || true)

CPU_BEFORE=$(awk '{print $14+$15}' /proc/$SYSTEMD_PID/stat)
TIME_BEFORE=$(date +%s%N)

churn_worker() {
    local worker_id=$1
    local start=$2
    local end=$3

    for i in $(seq $start $end); do
        dir="$BASE/churn-w${worker_id}-${i}"
        mkdir -p "$dir"
        mount -t tmpfs "stress-churn-w${worker_id}-${i}" "$dir"
        random_delay_ms "$MAX_DELAY_MS"
        umount "$dir"
        random_delay_ms "$MAX_DELAY_MS"
    done
}

if [ "$PARALLEL" -le 1 ]; then
    churn_worker 0 1 "$CHURN"
else
    per_worker=$(( CHURN / PARALLEL ))
    remainder=$(( CHURN % PARALLEL ))
    pids=()

    for w in $(seq 0 $((PARALLEL - 1))); do
        start=$(( w * per_worker + 1 ))
        end=$(( (w + 1) * per_worker ))
        if [ "$w" -eq $((PARALLEL - 1)) ]; then
            end=$(( end + remainder ))
        fi
        churn_worker "$w" "$start" "$end" &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait "$pid"
    done
fi

TIME_AFTER=$(date +%s%N)
CPU_AFTER=$(awk '{print $14+$15}' /proc/$SYSTEMD_PID/stat)

# Stop perf and let it write the summary
if [ -n "$PERF_PID" ] && kill -0 "$PERF_PID" 2>/dev/null; then
    kill -INT "$PERF_PID"
    wait "$PERF_PID" 2>/dev/null || true
    PERF_PID=""
    sleep 0.5
fi

WALL_MS=$(( (TIME_AFTER - TIME_BEFORE) / 1000000 ))
CPU_TICKS=$(( CPU_AFTER - CPU_BEFORE ))

echo "=== Results ==="
echo "Wall time: ${WALL_MS}ms"
echo "PID 1 CPU ticks: ${CPU_TICKS}"
echo "Mountinfo lines: $(wc -l < /proc/self/mountinfo)"

if [ -s "$PERF_OUTPUT" ]; then
    echo "=== PID 1 syscall profile (perf trace) ==="
    cat "$PERF_OUTPUT"
    rm -f "$PERF_OUTPUT"
fi

if [ -n "$JOURNAL_CURSOR" ]; then
    sleep 1
    echo "=== Mount monitor stats (journal) ==="
    journalctl --after-cursor="$JOURNAL_CURSOR" --no-pager 2>/dev/null \
        | grep "Mount monitor" || echo "(no mount monitor messages)"
fi

echo "=== Timing systemctl list-units --type=mount ==="
time systemctl list-units --type=mount --no-pager 2>/dev/null | wc -l

echo "=== Cleanup ==="
# cleanup handled by trap
