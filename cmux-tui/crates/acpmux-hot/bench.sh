#!/usr/bin/env bash
# Builds the guest's four variants, the host bench, and runs it: per-call cost against native,
# swap and rollback times (plans/cmux-next/acpmux-hot-modules-DESIGN.md). A fleet step, never the
# person's Mac:  cmux-ci test --setup rust -- bash cmux-tui/crates/acpmux-hot/bench.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${FAST_CHECKS_OUT:-$here/guest/target/bench-out}"
mkdir -p "$out"
(cd "$here" && rustup target add wasm32-wasip2 >/dev/null)

build_guest() { # NAME [FEATURE]
  local name=$1 feature=${2:-}
  local t0=$(date +%s.%N)
  (cd "$here/guest" && cargo build --locked --release --target wasm32-wasip2 --target-dir "target/$name" \
      ${feature:+--features "$feature"} 2>&1 | tail -3)
  local t1=$(date +%s.%N)
  cp "$here/guest/target/$name/wasm32-wasip2/release/acpmux_hot_guest.wasm" "$here/guest/target/$name.wasm"
  echo "guest $name built in $(python3 -c "print(round($t1 - $t0, 2))") s"
}
build_guest good
build_guest v2 v2
build_guest trap trap
build_guest spin spin
build_guest no-offer no-offer
# A second edit-and-rebuild of the warm good guest: the dev loop's compile step.
touch "$here/../acpmux/src/agent_login/parse.rs"
t0=$(date +%s.%N)
(cd "$here/guest" && cargo build --release --target wasm32-wasip2 --target-dir target/good 2>&1 | tail -1)
t1=$(date +%s.%N)
echo "guest_incremental_rebuild_s=$(python3 -c "print(round($t1 - $t0, 2))")" | tee "$out/guest-rebuild.txt"

ls -l "$here"/guest/target/*.wasm | tee "$out/guest-sizes.txt"
if command -v wasm-tools >/dev/null; then wasm-tools component wit "$here/guest/target/good.wasm" > "$out/good.wit" || true; fi

live_dir="$here/guest/target/live"
mkdir -p "$live_dir" && chmod 700 "$live_dir"
cd "$here/../.."
# The lockfile is committed: nothing here may change it.
cargo metadata --locked --format-version 1 >/dev/null
cargo test --locked -p acpmux-hot --features wasm 2>&1 | tail -15
cargo run --locked --release -p acpmux-hot --features wasm --example hot_bench -- \
  "$here/guest/target/good.wasm" "$here/guest/target/v2.wasm" \
  "$here/guest/target/trap.wasm" "$here/guest/target/spin.wasm" \
  "$live_dir/acpmux_hot.wasm" "$out/hot-bench.json" 2>&1 | tee "$out/hot-bench.log"
cat "$out/hot-bench.json"
# The daemon side compiles with the feature on (the default build is unchanged: the dep is optional).
cargo check --locked -p acpmux --features hot-modules 2>&1 | tail -3
# A debug daemon's sign-in end to end (tests/agent_login.rs: stand-in claude and codex CLIs over a
# connection), with the parser from the module: passes with the good module, and fails with the
# `no-offer` one, which proves the daemon asked the module and not its native parser.
run_login() { # MODULE
  ACPMUX_HOT_MODULE="$live_dir/acpmux_hot.wasm" cargo test --locked -p acpmux --features hot-modules \
    --test agent_login 2>&1 | tee "$out/daemon-login-$1.log" | grep -E '^test |test result|acpmux-hot:'
}
cp "$here/guest/target/good.wasm" "$live_dir/acpmux_hot.wasm"
run_login good
cp "$here/guest/target/no-offer.wasm" "$live_dir/acpmux_hot.wasm"
if run_login no-offer; then echo "daemon login passed with the no-offer module: the module was not asked" >&2; exit 1; fi
echo "daemon login failed with the no-offer module, as it must"
cp Cargo.lock "$out/Cargo.lock"
cp "$here/guest/Cargo.lock" "$out/guest-Cargo.lock"
