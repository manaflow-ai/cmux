#!/bin/bash
# Scratch (not committed): base/head A/B in ABBA order, transcript-replay long and chat-100k-flat (main cases).
cd webviews
swap() { (cd .. && git apply ${1:-} .olc-src.patch); }
rep() { echo "##### replay $1 $2"; bun bench/transcript-replay.bench.ts --only long 2>&1 | grep -E "long\.(token|thought|tool_output|tool_call)_ms\""; }
flat() { echo "##### flat $1"; CASES=main RESIZE=0 bun bench/chat-100k-flat.bench.ts 100000 2 2>&1 | grep -E "^chat-100k-flat:|_x[12] \|"; }
swap -R; rep base 1; swap ""; rep head 1; rep head 2; swap -R; rep base 2
flat base; swap ""; flat head
