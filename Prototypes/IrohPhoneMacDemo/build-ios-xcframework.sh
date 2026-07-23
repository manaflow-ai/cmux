#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_DIR="$SCRIPT_DIR/rust"
PACKAGE_DIR="$SCRIPT_DIR/iOS/IrohPhoneDemoPackage"
OUT_DIR="$PACKAGE_DIR/Binaries"
FRAMEWORK_NAME="IrohPhoneMacFFI"
FRAMEWORK_PATH="$OUT_DIR/$FRAMEWORK_NAME.xcframework"

rustup target add aarch64-apple-ios aarch64-apple-ios-sim >/dev/null

export IPHONEOS_DEPLOYMENT_TARGET=17.0
export CFLAGS_aarch64_apple_ios="-miphoneos-version-min=17.0"
export CFLAGS_aarch64_apple_ios_sim="-mios-simulator-version-min=17.0"
export CARGO_TARGET_AARCH64_APPLE_IOS_RUSTFLAGS="-C link-arg=-miphoneos-version-min=17.0"
export CARGO_TARGET_AARCH64_APPLE_IOS_SIM_RUSTFLAGS="-C link-arg=-mios-simulator-version-min=17.0"

cargo build \
  --manifest-path "$RUST_DIR/Cargo.toml" \
  --release \
  --lib \
  --target aarch64-apple-ios

cargo build \
  --manifest-path "$RUST_DIR/Cargo.toml" \
  --release \
  --lib \
  --target aarch64-apple-ios-sim

rm -rf "$FRAMEWORK_PATH"
mkdir -p "$OUT_DIR"

xcodebuild -create-xcframework \
  -library "$RUST_DIR/target/aarch64-apple-ios/release/libiroh_phone_mac_demo_ffi.a" \
  -headers "$RUST_DIR/include" \
  -library "$RUST_DIR/target/aarch64-apple-ios-sim/release/libiroh_phone_mac_demo_ffi.a" \
  -headers "$RUST_DIR/include" \
  -output "$FRAMEWORK_PATH"

echo "XCFramework:"
echo "  $FRAMEWORK_PATH"
