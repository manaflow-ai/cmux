#!/usr/bin/env bash
# Runs on the fleet runner from the snapshot checkout's root.
# 1. The loss simulation on the fix (the snapshot).
# 2. The same simulation on bddc2eb (the branch base) and on its parent (feat-cmux-next).
# 3. The regression tests at bc9d239 (tests only, expected to fail).
set -u
sim() {
  (cd cmux-tui && cargo test --manifest-path crates/cmux-app-ffi/Cargo.toml -p cmux-rd-ffi \
    --test loss_sim -- --nocapture --test-threads 1 2>&1 \
    | grep -E '^\{"scenario|^test |test result|panicked at|^error' | head -30)
}
add_sim() {
  git show "$SNAP":cmux-tui/crates/cmux-rd-ffi/tests/loss_sim.rs > cmux-tui/crates/cmux-rd-ffi/tests/loss_sim.rs
  grep -q '^cmux-rd-engine = ' cmux-tui/crates/cmux-rd-ffi/Cargo.toml || printf '\n[dev-dependencies]\ncmux-rd-engine = { path = "../cmux-rd-engine" }\n' >> cmux-tui/crates/cmux-rd-ffi/Cargo.toml
}
SNAP=$(git rev-parse HEAD)
git fetch -q --deepen=2 origin || echo "DEEPEN FAILED"
# The snapshot is my HEAD plus my edits; my HEAD is the tests-only commit.
TESTS=$(git rev-parse HEAD~1)
# The runner clone is shallow: fetch the commits compared below by full sha.
git fetch -q --depth=1 origin bddc2eb58d87fcd350892a57d355907c14fbe14d 2a9cba423c03bfc6dc0b9f371ac5e253232ebe64 || echo "FETCH FAILED"
git cat-file -e bddc2eb58d87fcd350892a57d355907c14fbe14d && echo have-bddc2eb; git cat-file -e 2a9cba423c03bfc6dc0b9f371ac5e253232ebe64 && echo have-2a9cba4; git log --oneline -4 | cat
echo "== AFTER (fix, snapshot $SNAP)"
sim
for base in bddc2eb58d87fcd350892a57d355907c14fbe14d 2a9cba423c03bfc6dc0b9f371ac5e253232ebe64; do
  git checkout -q "$base" -- cmux-tui ||  { echo "CHECKOUT FAILED $base"; continue; };  git clean -fdq cmux-tui/crates/cmux-rd-ffi cmux-tui/crates/cmux-rd-core cmux-tui/crates/cmux-rd-engine
  add_sim
  echo "== BEFORE ($(git log -1 --format='%h %s' "$base"))"
  sim
done
git checkout -q $TESTS -- cmux-tui && git clean -fdq cmux-tui/crates/cmux-rd-ffi cmux-tui/crates/cmux-rd-core cmux-tui/crates/cmux-rd-engine
echo "== RED (regression tests only, $(git log -1 --format="%h %s" $TESTS))"
(cd cmux-tui && cargo test --manifest-path crates/cmux-app-ffi/Cargo.toml -p cmux-rd-ffi --lib receiver_tests 2>&1 \
  | grep -E '^test |test result|panicked at|left:|right:|^error' | head -60)
(cd cmux-tui && cargo test -p cmux-rd-engine --test engine forced_recovery 2>&1 \
  | grep -E '^test |test result|panicked at|left:|right:|^error' | head -20)

git checkout -q "$SNAP" -- cmux-tui && git clean -fdq cmux-tui/crates/cmux-rd-ffi cmux-tui/crates/cmux-rd-core cmux-tui/crates/cmux-rd-engine
echo "== SUITES (fix)"
cd cmux-tui; st=0
cargo test -p cmux-rd-core -p cmux-rd-engine > /tmp/t1.log 2>&1 || { st=1; echo T1; grep -E "FAILED|panicked|left:|right:|^error" -A3 /tmp/t1.log | head -40; }
cargo test --manifest-path crates/cmux-app-ffi/Cargo.toml -p cmux-rd-ffi > /tmp/t2.log 2>&1 || { st=1; echo T2; grep -E "FAILED|panicked|left:|right:|^error" -A3 /tmp/t2.log | head -40; }
cargo clippy -p cmux-rd-core -p cmux-rd-engine --all-targets -- -D warnings > /tmp/c1.log 2>&1 || { st=1; echo C1; tail -40 /tmp/c1.log; }
cargo clippy --manifest-path crates/cmux-app-ffi/Cargo.toml -p cmux-rd-ffi --all-targets -- -D warnings > /tmp/c2.log 2>&1 || { st=1; echo C2; tail -40 /tmp/c2.log; }
cargo check --manifest-path crates/cmux-rd-host/Cargo.toml --all-targets --no-default-features --features bench,link > /tmp/h.log 2>&1 || { st=1; echo H; tail -40 /tmp/h.log; }
echo STATUS=$st; exit $st
