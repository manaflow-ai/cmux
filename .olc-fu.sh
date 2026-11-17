#!/bin/bash
# Scratch (not committed): follow-up checks on head, then composer-typing stream A/B (base, head, head, base) and profiles.
cd webviews
bun install --frozen-lockfile >/dev/null 2>&1
swap() { (cd .. && git apply $1 .olc-fu.patch) || echo "SWAP FAILED $1"; }
echo "##### tests head"
bun test src/agent-session/acpmux/conversation/ src/agent-session/acpmux/chips/ test/transcript-pin-pass-no-forced-read.test.tsx test/thread-minimap-token-renders.test.tsx test/transcript-row-height-input-pending.test.tsx test/transcript-stream-no-commit-height-read.test.tsx test/thread-minimap*.test.tsx test/thread-rail*.test.tsx test/chat-minimap*.test.tsx test/transcript-*.test.tsx test/drawn-height*.test.tsx 2>&1 | grep -E "\(fail\)| pass$| fail$"
bun run typecheck 2>&1 | tail -2
(cd .. && python3 scripts/ci/react_doctor_gate.py --project webviews 2>&1 | grep -E "react-doctor: webviews|gained|new " | head -5)
echo "##### shift head"; bun bench/transcript-turn-end-shift.bench.ts 3 --engines chromium 2>&1 | grep -E "^[0-9] \|"
ct() { echo "##### typing $1 $2"; bun bench/composer-typing.bench.ts --lengths 60,1500,6000 --keys 60 --modes idle,stream 2>&1 | grep -E "COMPOSER-TYPING|rows:|rror"; }
pr() { echo "##### profile $1"; bun bench/composer-typing.bench.ts --lengths 1500 --keys 60 --modes stream --profile 2>&1 | grep -E "COMPOSER-TYPING|PROFILE|layoutScrollTop|getBoundingClientRect|drawnHeightOf|Layout|Recalc|offset|clientHeight|scrollTop|flushSync|performWorkOnRoot|\(garbage" | head -60; }
swap -R; ct base 1; swap ""; ct head 1; ct head 2; swap -R; ct base 2
pr base; swap ""; pr head
echo "##### red tests on base"
swap -R; (cd .. && git apply --include='webviews/test/*' --include='webviews/src/*test*' .olc-fu.patch); bun test test/transcript-pin-pass-no-forced-read.test.tsx test/thread-minimap-token-renders.test.tsx test/transcript-row-height-input-pending.test.tsx test/transcript-stream-no-commit-height-read.test.tsx src/agent-session/acpmux/conversation/Thinking.layoutReads.test.tsx 2>&1 | grep -E "\(fail\)|\(pass\)| pass$| fail$"
