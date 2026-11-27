set -euo pipefail
export CARGO_TARGET_DIR="$PWD/scripts/bench/phone-speed/target"
if [ -d "$CI_TOOLS/valgrind-root/usr/include" ]; then
  export VALGRIND_INCLUDE="$CI_TOOLS/valgrind-root/usr/include"
fi
channel="$(sed -n 's/^channel *= *"\([^"]*\)".*/\1/p' cmux-tui/rust-toolchain.toml)"
cargo +"$channel" test --locked --manifest-path scripts/bench/phone-speed/Cargo.toml
cargo +"$channel" run --release --locked --manifest-path scripts/bench/phone-speed/Cargo.toml -- check
python3 scripts/bench/tests/test_phone_speed.py
