#!/usr/bin/env bash
# Embed the Chromium Embedded Framework + helper .app bundles into cmux.app/Contents/Frameworks/.
# Invoked as a "Run Script" build phase on the GhosttyTabs target.
#
# Expected env vars: SRCROOT, BUILT_PRODUCTS_DIR, EXECUTABLE_FOLDER_PATH, CONFIGURATION,
# EXPANDED_CODE_SIGN_IDENTITY (Xcode sets these for build phases).

set -euo pipefail

CEF_ROOT="${SRCROOT}/CEF"
FRAMEWORK_SRC="${CEF_ROOT}/Frameworks/Chromium Embedded Framework.framework"
FW_DIR="${BUILT_PRODUCTS_DIR}/${EXECUTABLE_FOLDER_PATH}/../Frameworks"

if [[ ! -d "${FRAMEWORK_SRC}" ]]; then
  echo "warning: CEF framework not provisioned at ${FRAMEWORK_SRC}; running fetch_cef.sh"
  "${CEF_ROOT}/vendor/fetch_cef.sh"
fi

mkdir -p "${FW_DIR}"

# 1. Rsync the Chromium Embedded Framework into Frameworks/.
rsync -a --delete \
  "${FRAMEWORK_SRC}" \
  "${FW_DIR}/"

# 2. Build the helper executables.
SWIFT_CFG=$(echo "${CONFIGURATION:-Debug}" | tr '[:upper:]' '[:lower:]')
case "${SWIFT_CFG}" in
  debug|release) ;;
  *) SWIFT_CFG="debug" ;;
esac

(cd "${CEF_ROOT}" && xcrun swift build -c "${SWIFT_CFG}" --product CMUXCEFHelper)
(cd "${CEF_ROOT}" && xcrun swift build -c "${SWIFT_CFG}" --product CMUXCEFHelperRenderer)

ARCH="$(uname -m)"
BUILD_BIN="${CEF_ROOT}/.build/${ARCH}-apple-macosx/${SWIFT_CFG}"
HELPER_BIN="${BUILD_BIN}/CMUXCEFHelper"
RENDERER_BIN="${BUILD_BIN}/CMUXCEFHelperRenderer"

if [[ ! -x "${HELPER_BIN}" ]] || [[ ! -x "${RENDERER_BIN}" ]]; then
  echo "error: missing helper binaries (${HELPER_BIN} / ${RENDERER_BIN}); swift build failed?"
  exit 1
fi

# 3. Write helper entitlements (JIT + library validation off + get-task-allow).
ENT="$(mktemp -t cmux_cef_helper_ent).plist"
cat > "${ENT}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
  <key>com.apple.security.get-task-allow</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
  <!-- Matches Chrome's Helper (Renderer)/Helper (GPU) entitlement set.
       V8 / Skia rely on W^X relaxation that fails silently under hardened
       runtime without these, manifesting as a renderer that parses HTML
       but never ships a compositor frame back to the browser process. -->
  <key>com.apple.security.cs.disable-executable-page-protection</key><true/>
  <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
</dict>
</plist>
EOF

write_plist() {
  local plist="$1" bid="$2" name="$3" exe="$4"
  cat > "${plist}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>${exe}</string>
  <key>CFBundleIdentifier</key><string>${bid}</string>
  <key>CFBundleName</key><string>${name}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
</dict>
</plist>
EOF
}

install_helper() {
  local folder="$1" exe_src="$2" exe_name="$3" bid="$4" name="$5"
  local app="${FW_DIR}/${folder}.app"
  rm -rf "${app}"
  mkdir -p "${app}/Contents/MacOS"
  cp -f "${exe_src}" "${app}/Contents/MacOS/${exe_name}"
  chmod +x "${app}/Contents/MacOS/${exe_name}"
  write_plist "${app}/Contents/Info.plist" "${bid}" "${name}" "${exe_name}"

  local identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  codesign --remove-signature "${app}/Contents/MacOS/${exe_name}" 2>/dev/null || true
  codesign --remove-signature "${app}" 2>/dev/null || true
  codesign --force --sign "${identity}" --entitlements "${ENT}" \
    --timestamp=none --options runtime "${app}/Contents/MacOS/${exe_name}"
  codesign --force --sign "${identity}" --entitlements "${ENT}" \
    --timestamp=none --options runtime "${app}"
}

# Helper bundle IDs must be <app-bundle-id>.helper[.gpu|.renderer|.plugin] for
# Chromium / Chrome runtime on macOS. The OS uses this exact-prefix lookup to
# route helper-to-app Mach IPC; with a mismatched prefix
# (e.g. com.cmux.helper.renderer when the app is com.cmuxterm.app.debug)
# the renderer launches but never establishes its GPU / compositor channel,
# so navigation begins, the renderer parses HTML, but no IOSurface frames
# ever ship — the pane stays transparent.
APP_BID="${PRODUCT_BUNDLE_IDENTIFIER:-com.cmuxterm.app.debug}"

install_helper "cmux Helper"            "${HELPER_BIN}"   "cmux Helper"            "${APP_BID}.helper"          "cmux Helper"
install_helper "cmux Helper (GPU)"      "${HELPER_BIN}"   "cmux Helper (GPU)"      "${APP_BID}.helper.gpu"      "cmux Helper GPU"
install_helper "cmux Helper (Renderer)" "${RENDERER_BIN}" "cmux Helper (Renderer)" "${APP_BID}.helper.renderer" "cmux Helper Renderer"

rm -f "${ENT}"
echo "embed_cef_into_cmux: done."
