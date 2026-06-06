#!/usr/bin/env bash
#
# codesign_dev.sh — apply the CEF-required entitlements to the SwiftPM
# build products of this package (CMUXCEFHelper, CMUXCEFHelperRenderer,
# CMUXCEFDemoApp). SwiftPM's auto-generated entitlement plist for
# executable targets only ships `get-task-allow`, which is insufficient
# for CEF Chrome runtime: helpers need V8 JIT, V8 unsigned executable
# memory, and (because the bundled CEF framework is ad-hoc-signed with an
# empty team id) library validation must be disabled.
#
# This script is a **development** convenience for `swift run`. When the
# cmux Xcode project consumes this package, it sets these entitlements
# from its own .entitlements file and re-signs the helpers with the
# cmux Developer ID; this script is no longer in the loop.
#
# Usage:
#   ./Scripts/codesign_dev.sh            # signs the most-recent debug build
#   ./Scripts/codesign_dev.sh release    # signs the release build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG="${1:-debug}"

case "${CONFIG}" in
  debug|release) ;;
  *)
    echo "codesign_dev: config must be 'debug' or 'release'" >&2
    exit 2
    ;;
esac

ARCH="$(uname -m)"
BUILD_DIR="${PKG_DIR}/.build/${ARCH}-apple-macosx/${CONFIG}"

if [[ ! -d "${BUILD_DIR}" ]]; then
  echo "codesign_dev: ${BUILD_DIR} not found. Run 'swift build' first." >&2
  exit 3
fi

ENTITLEMENTS="$(mktemp -t cmux-cef-entitlements)"
cat > "${ENTITLEMENTS}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.get-task-allow</key>
    <true/>
</dict>
</plist>
PLIST

sign_one() {
  local target="$1"
  local path="${BUILD_DIR}/${target}"
  if [[ ! -f "${path}" ]]; then
    echo "codesign_dev: skip ${target} (not built)"
    return 0
  fi
  echo "codesign_dev: signing ${target}"
  codesign --force --sign - \
    --entitlements "${ENTITLEMENTS}" \
    --options runtime \
    --timestamp=none \
    "${path}"
}

sign_one CMUXCEFHelper
sign_one CMUXCEFHelperRenderer
sign_one CMUXCEFDemoApp

rm -f "${ENTITLEMENTS}"

echo "codesign_dev: done"
