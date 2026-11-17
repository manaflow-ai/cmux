#!/bin/bash
# Scratch (not committed): follow-up on #44439: failing tests head vs base, React Doctor detail, typing A/B, full profiles.
cd webviews
bun install --frozen-lockfile >/dev/null 2>&1
swap() { (cd .. && git apply $1 .olc-fu.patch) || echo "SWAP FAILED $1"; }
T="test/transcript-jump-momentum.test.tsx test/transcript-collapsed-tool-runs.test.tsx"
echo "##### two fails head"; bun test $(ls $T 2>/dev/null) 2>&1 | grep -E "\(fail\)| pass$| fail$"
grep -rlE "Jump to latest mid-fling|Find highlights an edit step" test src 2>/dev/null | head -3
(cd .. && python3 scripts/ci/react_doctor_gate.py --project webviews 2>&1 | grep -vE "^##\[error\]" | grep -A12 "gained" | head -20)
ct() { echo "##### typing $1 $2"; bun bench/composer-typing.bench.ts --lengths 60,1500,6000 --keys 60 --modes idle,stream 2>&1 | grep -E "COMPOSER-TYPING"; }
pr() { echo "##### profile $1"; bun bench/composer-typing.bench.ts --lengths 1500 --keys 60 --modes stream --profile 2>&1 | grep -E "COMPOSER-TYPING|PROFILE|ms/key" | head -140; }
swap -R
echo "##### two fails base"; bun test $(ls $T 2>/dev/null) 2>&1 | grep -E "\(fail\)| pass$| fail$"
ct base 1; swap ""; ct head 1; ct head 2; swap -R; ct base 2
pr base; swap ""; pr head
