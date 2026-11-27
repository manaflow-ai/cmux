#!/usr/bin/env bash
# Generate, build for the simulator (ad-hoc signed so the keychain works),
# and install on the given simulators.
# usage: verify/build.sh <udid>...
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/.."
xcodegen generate -q
xcodebuild -project CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/dd \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
app=build/dd/Build/Products/Debug-iphonesimulator/CmuxMobileApp.app
for udid in "$@"; do xcrun simctl install "$udid" "$app"; done
