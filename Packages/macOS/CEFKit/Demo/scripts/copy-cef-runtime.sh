#!/bin/zsh
# Xcode post-build step: assemble the CEF runtime inside CEFDemo.app.
# - Copies the Chromium Embedded Framework into Contents/Frameworks
# - Clones the single built helper into the five variants CEF spawns
# - Copies demo extensions into Contents/Resources/Extensions
set -euo pipefail

if [[ -z "${SRCROOT:-}" || -z "${TARGET_BUILD_DIR:-}" || -z "${FULL_PRODUCT_NAME:-}" ]]; then
  echo "copy-cef-runtime.sh must run from Xcode build settings" >&2
  exit 1
fi

APP_BUNDLE="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}"
CEF_ROOT="${SRCROOT}/../third_party/cef/current"
HELPER_NAME="CEFDemo Helper"
HELPER_APP="${BUILT_PRODUCTS_DIR}/${HELPER_NAME}.app"
APP_FRAMEWORKS="${APP_BUNDLE}/Contents/Frameworks"
APP_RESOURCES="${APP_BUNDLE}/Contents/Resources"
CEF_FRAMEWORK_DIR="${APP_FRAMEWORKS}/Chromium Embedded Framework.framework"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

CEF_BINARIES="${CEF_ROOT}/${CONFIGURATION}"
if [[ ! -d "${CEF_BINARIES}/Chromium Embedded Framework.framework" ]]; then
  CEF_BINARIES="${CEF_ROOT}/Release"
fi
if [[ ! -d "${CEF_BINARIES}/Chromium Embedded Framework.framework" ]]; then
  echo "CEF runtime missing. Run ../scripts/fetch-cef.sh first." >&2
  exit 1
fi

mkdir -p "$APP_FRAMEWORKS" "$APP_RESOURCES"

rm -rf "$CEF_FRAMEWORK_DIR"
mkdir -p "${CEF_FRAMEWORK_DIR}/Versions"
ditto "${CEF_BINARIES}/Chromium Embedded Framework.framework" "${CEF_FRAMEWORK_DIR}/Versions/A"
ln -sfn "Versions/A/Chromium Embedded Framework" "${CEF_FRAMEWORK_DIR}/Chromium Embedded Framework"
ln -sfn "Versions/A/Libraries" "${CEF_FRAMEWORK_DIR}/Libraries"
ln -sfn "Versions/A/Resources" "${CEF_FRAMEWORK_DIR}/Resources"
ln -sfn "A" "${CEF_FRAMEWORK_DIR}/Versions/Current"

copy_helper_variant() {
  local name_suffix="$1"
  local bundle_suffix="$2"
  local helper_title="${HELPER_NAME}${name_suffix}"
  local helper_bundle="${APP_FRAMEWORKS}/${helper_title}.app"
  local helper_binary_dir="${helper_bundle}/Contents/MacOS"
  local helper_binary="${helper_binary_dir}/${helper_title}"
  local helper_plist="${helper_bundle}/Contents/Info.plist"

  rm -rf "$helper_bundle"
  ditto "$HELPER_APP" "$helper_bundle"

  if [[ "$name_suffix" != "" ]]; then
    mv "${helper_binary_dir}/${HELPER_NAME}" "$helper_binary"
  fi

  "$PLIST_BUDDY" -c "Set :CFBundleDisplayName ${helper_title}" "$helper_plist"
  "$PLIST_BUDDY" -c "Set :CFBundleExecutable ${helper_title}" "$helper_plist"
  "$PLIST_BUDDY" -c "Set :CFBundleIdentifier local.cefkit.demo.helper${bundle_suffix}" "$helper_plist"
  "$PLIST_BUDDY" -c "Set :CFBundleName ${helper_title}" "$helper_plist"
  codesign --force --sign - "$helper_bundle" 2>/dev/null || true
}

copy_helper_variant "" ""
copy_helper_variant " (Alerts)" ".alerts"
copy_helper_variant " (GPU)" ".gpu"
copy_helper_variant " (Plugin)" ".plugin"
copy_helper_variant " (Renderer)" ".renderer"

rm -rf "${APP_RESOURCES}/Extensions"
mkdir -p "${APP_RESOURCES}/Extensions"
ditto "${SRCROOT}/TestExtension" "${APP_RESOURCES}/Extensions/cefkit-test-extension"
if [[ -d "${SRCROOT}/Extensions" ]]; then
  for ext in "${SRCROOT}/Extensions"/*(N/); do
    ditto "$ext" "${APP_RESOURCES}/Extensions/${ext:t}"
  done
fi
# Preinstalled extensions fetched by ../scripts/fetch-extensions.sh, if any.
if [[ -d "${SRCROOT}/../third_party/extensions" ]]; then
  for ext in "${SRCROOT}/../third_party/extensions"/*(N/); do
    [[ -f "${ext}/manifest.json" ]] || continue
    ditto "$ext" "${APP_RESOURCES}/Extensions/${ext:t}"
  done
fi
