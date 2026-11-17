#!/bin/bash
# Scratch (not committed): profile transcript-replay long, head then base, plus a repeat of the A/B.
cd webviews
prof() {
  echo "##### $1 profile"
  PROFILE=1 bun bench/transcript-replay.bench.ts --only long 2>&1 | grep -vE "^\s*$" | tail -80
}
ab() {
  echo "##### $1 round $2"
  bun bench/transcript-replay.bench.ts --only long 2>&1 | grep -E "long\.(token|thought|tool_output|tool_call)_ms\""
}
prof head
(cd .. && git apply -R .olc-src.patch)
prof base
ab base 1
(cd .. && git apply .olc-src.patch)
ab head 1
(cd .. && git apply -R .olc-src.patch)
ab base 2
(cd .. && git apply .olc-src.patch)
ab head 2
