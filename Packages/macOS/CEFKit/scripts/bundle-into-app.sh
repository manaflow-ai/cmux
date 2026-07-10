#!/bin/zsh
# Bundles the CEF runtime into an already-built cmux app and re-seals the
# ad-hoc signature. Used after cloud reloads: fleet builders have no CEF
# distribution (the "Copy CEF Runtime (dev only)" phase skips there), so the
# runtime is injected locally into the downloaded tagged app.
#
# Usage: bundle-into-app.sh "/path/to/cmux DEV <tag>.app"
set -euo pipefail

APP_PATH="${1:?usage: bundle-into-app.sh <app-path>}"
PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$PKG_DIR/../../.." && pwd)"

if [[ ! -d "$APP_PATH/Contents" ]]; then
  echo "not an app bundle: $APP_PATH" >&2
  exit 1
fi

PLIST="$APP_PATH/Contents/Info.plist"
export SRCROOT="$REPO_ROOT"
export TARGET_BUILD_DIR="$(dirname "$APP_PATH")"
export FULL_PRODUCT_NAME="$(basename "$APP_PATH")"
export CONFIGURATION="Debug"
export PRODUCT_NAME="${FULL_PRODUCT_NAME%.app}"
export PRODUCT_BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"

"$REPO_ROOT/scripts/copy-cef-runtime-dev.sh"

# Adding frameworks invalidated the app seal; re-sign shallow ad-hoc, same
# as scripts/reload.sh does.
xattr -cr "$APP_PATH" 2>/dev/null || true
/usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der "$APP_PATH"
echo "CEF runtime bundled into $APP_PATH"
