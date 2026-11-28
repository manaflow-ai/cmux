set -euo pipefail
export CI_TOOLS="$PWD/.default-speed-tools"
export PATH="$CI_TOOLS/bin:$PATH"
export VALGRIND_INCLUDE="$CI_TOOLS/valgrind-root/usr/include"
export CMUX_GHOSTTY_VT_ZIG_CPU=baseline
export CARGO_TARGET_DIR="$PWD/scripts/bench/phone-default-speed/target"
test -x "$CI_TOOLS/bin/zig"
timeout 1800 cargo +1.95.0 build --locked --release --manifest-path scripts/bench/phone-default-speed/Cargo.toml
python3 scripts/bench/phone-default-speed/check_lock.py
