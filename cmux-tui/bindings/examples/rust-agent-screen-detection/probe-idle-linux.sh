#!/usr/bin/env bash
# PROBE ONLY (removed before merge): headless daemon + this plugin at rest on
# Linux; prints the plugin's CPU and context switches over an idle window and
# the wake log the probe build writes.
# Run from cmux-tui/: bash bindings/examples/rust-agent-screen-detection/probe-idle-linux.sh [terminals]
set -uo pipefail
count="${1:-1}"
cargo build -q -p cmux-tui --bin cmux-tui || exit 1
cargo build -q --manifest-path bindings/examples/rust-agent-screen-detection/Cargo.toml || exit 1
target="${CARGO_TARGET_DIR:-target}"
plugin_target="bindings/examples/rust-agent-screen-detection/target"
[ -x "$target/debug/cmux-agent-screen-detection" ] || cp "$plugin_target/debug/cmux-agent-screen-detection" "$target/debug/"
cp "$plugin_target/debug/cmux-agent-screen-detection" "$target/debug/cmux-agent-screen-detection"
rm -f /tmp/cmux-sd-wakes-*.log
root="$(mktemp -d)"
python3 scripts/bench-scale.py --bin "$target/debug/cmux-tui" --counts "$count" --busy-fraction 0 \
  --per-workspace 1 --fill sequential --idle-seconds 45 --settle-seconds-min 10 \
  --latency-samples 2 --latency-terminals 1 --topology-samples 2 \
  --root-dir "$root" --out "$root/out.json" > "$root/log" 2>&1 &
bench=$!
sleep 30
sample() { for p in $(pgrep -f 'debug/cmux-agent-screen-detection$'); do
  read -r ut st < <(awk '{print $14, $15}' "/proc/$p/stat")
  cs=$(awk '/voluntary_ctxt_switches/ {s+=$2} END {print s}' /proc/$p/status)
  echo "$p $ut $st $cs"; done; }
before="$(sample)"; echo "PROBE before: $before"
sleep 20
after="$(sample)"; echo "PROBE after: $after"
echo "PROBE ticks/s=$(getconf CLK_TCK)"
wait "$bench"; echo "PROBE bench rc=$?"
tail -n 5 "$root/log"
grep -h "screen-detection" "$root"/*/daemon.log "$root"/daemon.log 2>/dev/null | tail -n 30 | sed 's/^/PROBE stderr /'
for f in /tmp/cmux-sd-wakes-*.log; do
  [ -f "$f" ] || continue
  echo "PROBE log $f lines=$(wc -l < "$f")"
  awk '{print $2, $3}' "$f" | sed 's/rev=[0-9]*//; s/prev=[0-9]*//' | sort | uniq -c | sort -rn | head -20
  tail -n 40 "$f" | cut -c1-300
done
rm -rf "$root"
