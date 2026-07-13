#!/bin/zsh
# Builds CEFDemo.app into Demo/DerivedData.
#
# CMUX_ALLOW_LOCAL_XCODEBUILD: the hq xcodebuild guard blocks by checkout path
# and cannot see that CEFDemo is not the cmux app. CEFDemo has its own bundle
# id, product name, and DerivedData; it never touches cmux debug sockets or
# launches a cmux DEV test host, so the guard's concerns don't apply here.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -d "../third_party/cef/current" ]]; then
  echo "CEF distribution missing; run ../scripts/fetch-cef.sh first." >&2
  exit 1
fi

xcodegen generate
CMUX_ALLOW_LOCAL_XCODEBUILD=1 xcodebuild \
  -project CEFDemo.xcodeproj \
  -scheme CEFDemo \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  build "$@"

echo
echo "App: $ROOT_DIR/DerivedData/Build/Products/Debug/CEFDemo.app"
