#!/usr/bin/env bash
# Build libcmux_remote_mobile.a for whichever iOS SDK Xcode is targeting.
#
# The client half of cmux-remote needs no Zig, so this is a plain cargo build
# with no toolchain beyond rustup and the iOS SDK.
set -euo pipefail

cd "$(dirname "$0")/../../.."

case "${PLATFORM_NAME:-iphoneos}" in
  iphonesimulator) target=aarch64-apple-ios-sim ;;
  *) target=aarch64-apple-ios ;;
esac

profile_flag=()
if [ "${CONFIGURATION:-Debug}" != "Debug" ]; then
  profile_flag=(--release)
fi

rustup target add "$target" >/dev/null 2>&1 || true
exec cargo build -p cmux-remote-mobile --target "$target" "${profile_flag[@]}"
