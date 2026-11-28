#!/usr/bin/env bash
# Base (off: the thread's will-change rule overridden) vs fix (none), default key script as the nightly runs it.
cd webviews || exit 1
for v in "$@"; do
  echo "== $v load $(cut -d' ' -f1 /proc/loadavg)"
  bun bench/composer-typing.bench.ts --engines webkit --mode L0 --lengths 60 --repeat 3 --probe ../.ct-probe/$v.js 2>&1 | grep -E "^COMPOSER-TYPING" | python3 -c '
import json,sys
for l in sys.stdin:
  r=json.loads(l[len("COMPOSER-TYPING "):])[0]; print("  ROW p95", r.get("to_paint_p95"), "p99", r.get("to_paint_p99"), "attempts", r.get("attempt_to_paint_p99"), r.get("attempt_to_paint_p95"))'
done
echo "end load $(cut -d' ' -f1 /proc/loadavg)"
