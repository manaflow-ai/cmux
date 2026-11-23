#!/usr/bin/env bash
# Scratch (not committed): before/after of a relaunch's expiry ends over Leo's three chats.
set -u
cd "$(dirname "$0")/../../.."
F=crates/acpmux/expiry-fixtures
measure() {
  for f in coord inbox revive; do
    ACPMUX_EXPIRY_FIXTURE="$PWD/$F/$f.ndjson.gz" ACPMUX_EXPIRY_ROOT="$(cat $F/$f.ndjson.roots)" \
      cargo test -q -p acpmux --lib -- --ignored --nocapture measure_relaunch_expiry_ends 2>&1 | grep -E "EXPIRY_MEASURE|panicked|error"
  done
}
echo "== AFTER"
cargo test -q -p acpmux --lib -- subagent expiry work_below 2>&1 | grep -E "test result|FAILED|panicked"
measure
echo "== BEFORE (base $1)"
for p in subagent_expiry.rs subagent_expiry_tests.rs subagents.rs hub/subagent_expiry.rs hub/tap.rs hub/work_below.rs; do
  git show "$1:cmux-tui/crates/acpmux/src/$p" > "crates/acpmux/src/$p"
done
cargo test -q -p acpmux --lib -- a_rebuild_ends_a_notified_helper 2>&1 | grep -E "test result|FAILED|panicked|assert" | head -8
measure
