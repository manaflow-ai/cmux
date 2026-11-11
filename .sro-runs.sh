#!/bin/bash
# Runner-only: a copy of the overlap test with live-turn-work pinned to its `runs` arm (finished calls
# stay in sight until the turn folds). Never committed. Usage: .sro-runs.sh LABEL N
set -u
label="$1"; n="$2"
cd webviews
src=test/agent-pane-stream-row-overlap.test.ts
dst=test/agent-pane-stream-row-overlap-runsarm.test.ts
python3 - "$src" "$dst" <<'PY'
import sys
s=open(sys.argv[1]).read()
needle="    await page.goto("
assert needle in s
s=s.replace(needle,"    await page.addInitScript(() => localStorage.setItem(\"cmux.experiments\", '{\"live-turn-work\":\"runs\"}'));\n"+needle,1)
open(sys.argv[2],"w").write(s)
PY
for i in $(seq 1 "$n"); do
  for load in 0 1; do
    pids=()
    if [ "$load" = 1 ]; then for k in 1 2 3; do (yes > /dev/null) & pids+=($!); done; fi
    echo "### $label runs-arm run $i load=$load"
    bun test "$dst" 2>&1 | grep -E "OVERLAP_REPORT|^\(pass\)|^\(fail\)| pass$| fail$"
    for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  done
done
rm -f "$dst"
