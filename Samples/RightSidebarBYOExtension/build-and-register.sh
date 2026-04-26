#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$HOME/Library/Application Support/cmux/ExtensionSamples/RightSidebarBYOExtension}"
APP_NAME="cmux BYO Sidebar Sample"
EXT_NAME="CmuxBYOSidebarSampleExtension"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.cmuxterm.samples.byo-sidebar}"
EXT_BUNDLE_ID="${EXT_BUNDLE_ID:-${APP_BUNDLE_ID}.extension}"
EXTENSION_POINT_ID="com.cmuxterm.app.debug.extkit.right-sidebar-panel"
SCENE_ID="cmux-right-sidebar-demo"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
if [ -z "$TARGET_TRIPLE" ]; then
  HOST_ARCH="$(uname -m)"
  case "$HOST_ARCH" in
    arm64)
      TARGET_TRIPLE="arm64-apple-macos26.0"
      ;;
    x86_64)
      TARGET_TRIPLE="x86_64-apple-macos26.0"
      ;;
    *)
      echo "Unsupported host architecture: $HOST_ARCH. Set TARGET_TRIPLE explicitly." >&2
      exit 1
      ;;
  esac
fi
APP_PATH="${BUILD_ROOT}/${APP_NAME}.app"
EXT_PATH="${APP_PATH}/Contents/Extensions/${EXT_NAME}.appex"

if [ -e "/tmp/cmux-byo-sidebar-sample/cmux BYO Sidebar Sample.app/Contents/Extensions/CmuxBYOSidebarSampleExtension.appex" ]; then
  pluginkit -r "/tmp/cmux-byo-sidebar-sample/cmux BYO Sidebar Sample.app/Contents/Extensions/CmuxBYOSidebarSampleExtension.appex" 2>/dev/null || true
fi
if [ -e "/tmp/cmux-byo-sidebar-sample/cmux BYO Sidebar Sample.app" ]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u -f "/tmp/cmux-byo-sidebar-sample/cmux BYO Sidebar Sample.app" 2>/dev/null || true
fi
if [ -e "$EXT_PATH" ]; then
  pluginkit -r "$EXT_PATH" 2>/dev/null || true
fi
if [ -e "$APP_PATH" ]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u -f "$APP_PATH" 2>/dev/null || true
fi
rm -rf "$BUILD_ROOT"
mkdir -p \
  "$APP_PATH/Contents/MacOS" \
  "$APP_PATH/Contents/Resources" \
  "$APP_PATH/Contents/Extensions" \
  "$EXT_PATH/Contents/MacOS" \
  "$EXT_PATH/Contents/Resources"

xcrun swiftc \
  -sdk "$SDK_PATH" \
  -target "$TARGET_TRIPLE" \
  -parse-as-library \
  "$ROOT/Sources/ContainerApp/RightSidebarSampleContainerApp.swift" \
  -o "$APP_PATH/Contents/MacOS/$APP_NAME"

xcrun swiftc \
  -sdk "$SDK_PATH" \
  -target "$TARGET_TRIPLE" \
  -parse-as-library \
  "$ROOT/Sources/Extension/RightSidebarSampleExtension.swift" \
  -o "$EXT_PATH/Contents/MacOS/$EXT_NAME"

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${APP_BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

cat > "$EXT_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${EXT_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${EXT_BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${EXT_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>XPC!</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>EXAppExtensionAttributes</key>
  <dict>
    <key>EXExtensionPointIdentifier</key>
    <string>${EXTENSION_POINT_ID}</string>
  </dict>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
</dict>
</plist>
PLIST

cat > "$BUILD_ROOT/Extension.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>
  <true/>
  <key>com.apple.security.get-task-allow</key>
  <true/>
</dict>
</plist>
PLIST

xcrun xcstringstool installloc "$ROOT/Resources" --output-directory "$APP_PATH/Contents/Resources" --languages "en ja"
xcrun xcstringstool installloc "$ROOT/Resources" --output-directory "$EXT_PATH/Contents/Resources" --languages "en ja"

codesign --force --sign - --timestamp=none --entitlements "$BUILD_ROOT/Extension.entitlements" "$EXT_PATH"
codesign --force --sign - --timestamp=none "$APP_PATH"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_PATH"
pluginkit -a "$EXT_PATH"
pluginkit -e use -i "$EXT_BUNDLE_ID" -p "$EXTENSION_POINT_ID" >/dev/null 2>&1 || true

echo "Sample app:"
echo "  $APP_PATH"
echo
echo "Sample extension:"
echo "  $EXT_PATH"
echo
echo "Extension point:"
echo "  $EXTENSION_POINT_ID"
echo
echo "Scene id:"
echo "  $SCENE_ID"
echo
pluginkit -m -A -D -v -p "$EXTENSION_POINT_ID"
