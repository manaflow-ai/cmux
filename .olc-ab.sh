#!/bin/bash
# Scratch (not committed): interleaved head/base A/B of the piece-4 benches in one job.
cd webviews
run() {
  echo "##### $1 round $2"
  (REPEAT=3 RESIZE=0 bun bench/chat-100k-flat.bench.ts 100000 1 2>&1 | grep -E "^chat-100k-flat:|_x1 \|")
  (bun bench/transcript-replay.bench.ts --only long 2>&1 | grep -E "long\.(token|thought|tool_output|tool_call)_ms\"")
}
for round in 1 2; do
  run head $round
  (cd .. && git apply -R .olc-src.patch)
  run base $round
  (cd .. && git apply .olc-src.patch)
done
