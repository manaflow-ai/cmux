#!/usr/bin/env bash
# Measurement only (cmux#51052 before/after on the duress bench of cmux#51033): one worker, one
# test binary, two acpmux daemons. "after" is this tree (bench + #51052); "before" is the same tree
# with fix.patch reversed (= the bench head alone). Runs in ABBA order.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tui="$(cd "$here/../../.." && pwd)"
out="${FAST_CHECKS_OUT:-$(mktemp -d)}"
bins="$(mktemp -d)"
cd "$tui"

host() {
  echo "host=$(hostname) cores=$(nproc) uid=$(id -u) rlimit_nice=$(ulimit -e) load='$(cut -d' ' -f1-3 /proc/loadavg)' procs=$(ls /proc | grep -c '^[0-9]')"
  if nice -n -5 true 2>/dev/null; then echo "nice -5: allowed"; else echo "nice -5: refused"; fi
}
echo "== host before build"; host

cargo build --release -p acpmux --bin acpmux
exe="$(cargo test -p acpmux --release --test duress_daemon --no-run --message-format=json \
  | grep '"executable":"[^"]*duress_daemon' | sed 's/.*"executable":"\([^"]*\)".*/\1/' | tail -1)"
tgt="$(dirname "$(dirname "$exe")")"
bin="$tgt/acpmux"
echo "test binary: $exe; daemon binary: $bin"
cp "$bin" "$bins/after"
(cd "$tui/.." && git apply -R "$here/fix.patch")
cargo build --release -p acpmux --bin acpmux
cp "$bin" "$bins/before"
(cd "$tui/.." && git apply "$here/fix.patch")
sha256sum "$bins/before" "$bins/after"

run() {
  local label="$1" which="$2"
  cp "$bins/$which" "$bin"
  mkdir -p "$out/$label"
  echo "== $label ($which)"; host | tee "$out/$label/host.txt"
  # The daemon's nice, sampled every 5 s while the bench runs.
  ( while sleep 5; do ps -eo ni=,args= | grep -E 'acpmux daemon run' | grep -v grep | awk -v t="$(date +%s)" '{print t, "ni=" $1}'; done ) \
    > "$out/$label/daemon-nice.txt" 2>/dev/null &
  local sampler=$!
  ACPMUX_DURESS=1 ACPMUX_DURESS_LEGS="${LEGS:-baseline,cpu}" FAST_CHECKS_OUT="$out/$label" \
    "$exe" --ignored --nocapture 2>&1 || echo "run $label exited $?"
  kill "$sampler" 2>/dev/null || true
  echo "-- $label daemon nice samples:"; awk '{print $2}' "$out/$label/daemon-nice.txt" | sort | uniq -c
  echo "-- $label host after"; host
  echo "-- $label duress-bench.md:"; cat "$out/$label/duress-bench.md" 2>/dev/null || echo "(no md)"
}
run r1-before before
run r2-after after
run r3-after after
run r4-before before
echo "outputs in $out"
