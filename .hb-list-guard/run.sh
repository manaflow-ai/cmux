#!/bin/bash
# Scratch (never committed): checks for the list guard, then the same CPU test on base.
set -uo pipefail
ROOT=$PWD
B=$ROOT/.hb-list-guard
cd "$ROOT/cmux-tui"
A=crates/acpmux/src
FILES="hub/mod.rs hub/seen.rs hub/session_pages.rs hub/lifecycle.rs hub/remote_rows.rs server/mod.rs server/requests.rs"
rc=0
echo "== fmt"; cargo fmt -p acpmux -- --check 2>&1 | head -80 || true
echo "== clippy"; cargo clippy --locked -p acpmux --all-targets -- -D warnings 2>&1 | grep -v '^ *\(Compiling\|Checking\)' | tail -80; [ ${PIPESTATUS[0]} -eq 0 ] || rc=1
echo "== lib tests"; cargo test --locked -p acpmux --lib 2>&1 | grep -E '^test result|FAILED|panicked|failed|left:|right:' | head -40; [ ${PIPESTATUS[0]} -eq 0 ] || rc=1
echo "== list tests"; for t in daemon_list_guard daemon_memory daemon_idle hub_integration peer_integration; do
  echo "-- $t"; cargo test --locked -p acpmux --test $t -- --nocapture 2>&1 | grep -E '^test .*FAILED|test result|daemon CPU|  [a-z].*core|panicked|left:|right:|acpmux-memory|holds' | head -60; [ ${PIPESTATUS[0]} -eq 0 ] || rc=1
done
echo "-- memory x3"; for i in 1 2 3; do cargo test --locked -p acpmux --test daemon_memory a_chief_home -- --nocapture 2>&1 | grep -E 'acpmux-memory'; done
echo "== base: the same test"
for f in $FILES; do cp "$B/base/$f" "$A/$f"; done
rm -f $A/hub/list_guard.rs $A/server/list_reply.rs
cargo test --locked -p acpmux --test daemon_list_guard -- --nocapture 2>&1 | grep -E '^test |test result|daemon CPU|  [a-z].*core|panicked' | head -30
echo "base exit ${PIPESTATUS[0]}"
echo "-- base agent_tools + memory"
cargo test --locked -p acpmux --lib agent_tools::tests::own_servers_run_under_the_daemon_prefix 2>&1 | grep -E 'test result|panicked|left:|right:' | head
for i in 1 2 3; do cargo test --locked -p acpmux --test daemon_memory a_chief_home -- --nocapture 2>&1 | grep -E 'acpmux-memory'; done
echo "after rc=$rc"
exit $rc
