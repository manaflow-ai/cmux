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
cp Cargo.lock "$out/Cargo.lock"
cp "$here/guest/Cargo.lock" "$out/guest-Cargo.lock"
