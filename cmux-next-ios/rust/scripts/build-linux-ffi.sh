#!/usr/bin/env bash
# RFD 0051 route 2: build the Linux static library of cmux-mobile-link-ffi, generate its uniffi C
# header, and run CmuxMobileLinkFFILinuxTests, which call Rust through the checked-in Swift binding
# (CmuxMobileKit/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift) with no Apple framework.
#
# It also checks that bindgen on this library reproduces the checked-in Swift, so the Linux receipt
# is for the same binding the app ships.
#
# Needs cargo (rust-toolchain.toml's pin) and Swift 6.2 on Linux. Environment: PROFILE (default
# dev; release for an optimized library), SKIP_TEST=1 builds and checks without running Swift.
set -euo pipefail

rust_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ios_dir="$(cd "$rust_dir/.." && pwd)"
kit_dir="$ios_dir/CmuxMobileKit"
module_dir="$kit_dir/Sources/CmuxMobileLinkFFIFFILinux"
profile="${PROFILE:-dev}"
case "$profile" in
  dev) out=debug ;;
  *) out="$profile" ;;
esac
target_dir="${CARGO_TARGET_DIR:-$rust_dir/target}"

if [ "$(uname -s)" != Linux ]; then
  echo "build-linux-ffi.sh: Linux only (Apple platforms use build-xcframework.sh)" >&2
  exit 2
fi

cd "$rust_dir"
cargo build --profile "$profile" -p cmux-mobile-link-ffi --lib
lib_out="$target_dir/$out"

gen="$(mktemp -d)"
lib_only="$(mktemp -d)"
trap 'rm -rf -- "$gen" "$lib_only"' EXIT
cargo run --profile "$profile" -p cmux-mobile-link-ffi --features bindgen --bin uniffi-bindgen -- \
  generate --library "$lib_out/libcmux_mobile_link_ffi.so" --language swift --out-dir "$gen"

if ! cmp -s "$gen/CmuxMobileLinkFFI.swift" "$kit_dir/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift"; then
  echo "build-linux-ffi.sh: the checked-in CmuxMobileLinkFFI.swift differs from this library's binding:" >&2
  diff -u "$kit_dir/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift" "$gen/CmuxMobileLinkFFI.swift" | head -40 >&2 || true
  exit 1
fi
cp "$gen/CmuxMobileLinkFFIFFI.h" "$module_dir/CmuxMobileLinkFFIFFI.h"
# Only the archive in the search path: the linker must not pick the shared object.
cp "$lib_out/libcmux_mobile_link_ffi.a" "$lib_only/"

if [ "${SKIP_TEST:-}" = 1 ]; then
  echo "build-linux-ffi.sh: header and library built; tests skipped"
  exit 0
fi

# The connection contract's Rust half (cmux-next-ios/contract/README.md): the fixture the Swift
# suite below reads must say what this library does.
cargo test --profile "$profile" -p cmux-mobile-link-ffi --test connection_contract
export CMUX_SWIFTPM_TARGET_LINUX=1 CMUX_MOBILE_LINK_FFI_LINUX=1
swift test --package-path "$kit_dir" --filter CmuxMobileLinkFFILinuxTests -Xlinker -L"$lib_only"
