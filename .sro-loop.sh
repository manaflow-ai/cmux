#!/bin/bash
# Runs the overlap test N times per mode; prints only the report lines and pass/fail.
set -u
mode="$1"; n="$2"
cd webviews
for i in $(seq 1 "$n"); do
  for load in 0 1; do
    pids=()
    if [ "$load" = 1 ]; then for k in 1 2 3; do (yes > /dev/null) & pids+=($!); done; fi
    echo "### $mode run $i load=$load"
    bun test test/agent-pane-stream-row-overlap.test.ts 2>&1 | grep -E "OVERLAP_REPORT|^\(pass\)|^\(fail\)| pass$| fail$"
    for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  done
done
