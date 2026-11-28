#!/usr/bin/env bash
# Pool A/B of probe variants: base, rows-anim-off, field-anim-off, thread will-change.
cd webviews || exit 1
for v in "$@"; do
  echo "== $v load $(cut -d' ' -f1 /proc/loadavg)"
  bun bench/composer-typing.bench.ts --engines webkit --mode L0 --lengths 60 --keys 500 --gap 20 --repeat 3 --probe ../.ct-probe/$v.js 2>&1 | grep -E "^PROBE|^COMPOSER-TYPING" | python3 -c '
import json,sys
for l in sys.stdin:
  if l.startswith("PROBE"):
    p=json.loads(l[6:])["probe"]; print("  grew", p.get("grew_keys"), "skipped", p.get("skipped"), "slow", len(p["slow_keys"]), "gap_p95", p["gap_p95"])
  else:
    r=json.loads(l[len("COMPOSER-TYPING "):])[0]; print("  ROW p95", r.get("to_paint_p95"), "p99", r.get("to_paint_p99"), "attempts", r.get("attempt_to_paint_p99"), r.get("attempt_to_paint_p95"))'
done
echo "end load $(cut -d' ' -f1 /proc/loadavg)"
