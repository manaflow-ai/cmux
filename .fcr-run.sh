#!/bin/bash
set -u
cd webviews
echo "### unit"
bun test src/agent-session/acpmux/conversation/turnFold.test.ts src/agent-session/acpmux/conversation/turnEndFold.test.ts src/agent-session/acpmux/conversation/turnFoldStyle.test.ts src/agent-session/acpmux/conversation/followChase.test.ts 2>&1 | grep -vE "^\s*$" | tail -25
echo "### typecheck"; bun run typecheck 2>&1 | tail -2
echo "### lint"; bunx eslint src/agent-session/acpmux/conversation/turnFold.ts src/agent-session/acpmux/conversation/turnFold.test.ts 2>&1 | tail -5
for i in 1 2 3; do
  for load in 0 1; do
    pids=()
    if [ "$load" = 1 ]; then for k in 1 2 3; do (yes > /dev/null) & pids+=($!); done; fi
    echo "### overlap run $i load=$load"
    bun test test/agent-pane-stream-row-overlap.test.ts 2>&1 | grep -E "OVERLAP_REPORT.*\"overlapFrames\":[1-9]|^\(pass\)|^\(fail\)| pass$| fail$"
    for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  done
done
