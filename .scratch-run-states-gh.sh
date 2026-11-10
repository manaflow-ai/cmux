#!/usr/bin/env bash
# Render chosen gallery states with the CI checker, ROUNDS times, in the checkout this runs in.
# Usage (inside cmux-ci test): STATES="entry#variant,..." ROUNDS=3 bash run-states.sh
# Writes $FAST_CHECKS_OUT/round-N/health.json and a per-state tally to $FAST_CHECKS_OUT/tally.txt.
set -uo pipefail
out="${FAST_CHECKS_OUT:-/tmp/gh-out}"
mkdir -p "$out"
root=$(git rev-parse --show-toplevel)
states="${STATES:?}"
rounds="${ROUNDS:-3}"
retries="${RETRIES:-0}"
entries=$(echo "$states" | tr ',' '\n' | sed 's/#.*//' | sort -u | paste -sd, -)
cd "$root/webviews"
bun install --frozen-lockfile >/dev/null 2>&1 || bun install --frozen-lockfile
bun scripts/gallery/manifest.ts --frame component --entries "$entries" --out /tmp/entries.json
jq --arg states "$states" '($states | split(",")) as $red
  | map(select(((.params.entry // "") + "#" + (.params.variant // "")) as $s | any($red[]; . == $s)))' \
  /tmp/entries.json > /tmp/manifest.json
echo "cases: $(jq length /tmp/manifest.json)"
CMUX_GALLERY_OUT_DIR=/tmp/gallery bun run gallery:build > /tmp/build.log 2>&1 || { tail -50 /tmp/build.log; exit 3; }
cd "$root/scripts/gallery-matrix"
bun install --frozen-lockfile >/dev/null 2>&1
eval "$("$root/scripts/ci/ensure-system-chrome.sh" | grep '^CMUX_CHROME_HEADLESS_SHELL=' | sed 's/^/export /')"
export CMUX_GALLERY_IN_VM=1
for n in $(seq 1 "$rounds"); do
  CMUX_GALLERY_IN_VM=1 bun health.ts --manifest /tmp/manifest.json --gallery-dir /tmp/gallery \
    --retries "$retries" --output-dir "$out/round-$n" > "$out/round-$n.log" 2>&1
  echo "round $n exit $?"
done
python3 - "$out" "$rounds" "$states" <<'EOF' | tee "$out/tally.txt"
import json, sys, os
out, rounds, states = sys.argv[1], int(sys.argv[2]), sys.argv[3].split(",")
red = {s: 0 for s in states}
why = {}
for n in range(1, rounds + 1):
    p = os.path.join(out, f"round-{n}", "health.json")
    if not os.path.exists(p):
        print(f"round {n}: no health.json"); continue
    d = json.load(open(p))
    for item in d.get("fresh", []) + d.get("known", []):
        red[item["state"]] = red.get(item["state"], 0) + 1; why[item["state"]] = item["reason"]
    for item in d.get("slow", []):
        red[item["state"]] = red.get(item["state"], 0) + 1; why[item["state"]] = f"slow {item['ms']} ms (budget {item['budget']})"
for s, c in sorted(red.items()):
    print(f"{c}/{rounds} red  {s}  {why.get(s, '')}")
EOF
