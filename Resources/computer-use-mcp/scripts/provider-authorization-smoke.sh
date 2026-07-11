#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cmux-cu-provider-auth.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

APP="$TMP/cmux Test.app"
RESOURCES="$APP/Contents/Resources"
PROVIDER="$RESOURCES/libexec/cmux-computer-use-provider"
LAUNCHER="$RESOURCES/bin/cmux-computer-use-mcp"
APP_HOST="$APP/Contents/MacOS/cmux-test-host"
mkdir -p "$(dirname "$PROVIDER")" "$(dirname "$LAUNCHER")" "$(dirname "$APP_HOST")"

"$ROOT/scripts/build-computer-use-provider.sh" \
  --require-mcp-parent \
  --output "$PROVIDER"

cat > "$TMP/launcher.swift" <<'SWIFT'
import Foundation

let process = Process()
process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
process.standardInput = FileHandle.standardInput
process.standardOutput = FileHandle.standardOutput
process.standardError = FileHandle.standardError
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
SWIFT
/usr/bin/xcrun swiftc "$TMP/launcher.swift" -o "$LAUNCHER"
cat > "$TMP/app-host.swift" <<'SWIFT'
import Foundation

let process = Process()
process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
process.arguments = Array(CommandLine.arguments.dropFirst(2))
process.standardInput = FileHandle.standardInput
process.standardOutput = FileHandle.standardOutput
process.standardError = FileHandle.standardError
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
SWIFT
/usr/bin/xcrun swiftc "$TMP/app-host.swift" -o "$APP_HOST"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>cmux-test-host</string>
<key>CFBundleIdentifier</key><string>com.cmux.provider-authorization-smoke</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - --timestamp=none "$LAUNCHER"
/usr/bin/codesign --force --deep --sign - --timestamp=none "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"

DIRECT_OUTPUT="$(printf '%s\n' '{"op":"list_apps"}' | "$PROVIDER" || true)"
node -e '
const result = JSON.parse(process.argv[1]);
if (result.ok !== false || result.code !== "provider.authorizationRequired") process.exit(1);
' "$DIRECT_OUTPUT"

STANDALONE_OUTPUT="$(printf '%s\n' '{"op":"list_apps"}' | "$LAUNCHER" "$PROVIDER" || true)"
node -e '
const result = JSON.parse(process.argv[1]);
if (result.ok !== false || result.code !== "provider.authorizationRequired") process.exit(1);
' "$STANDALONE_OUTPUT"

AUTHORIZED_OUTPUT="$(printf '%s\n' '{"op":"list_apps"}' | "$APP_HOST" "$LAUNCHER" "$PROVIDER")"
node -e '
const result = JSON.parse(process.argv[1]);
if (result.ok !== true || !Array.isArray(result.apps)) process.exit(1);
' "$AUTHORIZED_OUTPUT"

FORGED_RESOURCES="$TMP/Forged.app/Contents/Resources"
FORGED_PROVIDER="$FORGED_RESOURCES/libexec/cmux-computer-use-provider"
FORGED_LAUNCHER="$FORGED_RESOURCES/bin/cmux-computer-use-mcp"
mkdir -p "$(dirname "$FORGED_PROVIDER")" "$(dirname "$FORGED_LAUNCHER")"
cp "$PROVIDER" "$FORGED_PROVIDER"
cp "$LAUNCHER" "$FORGED_LAUNCHER"
FORGED_OUTPUT="$(printf '%s\n' '{"op":"list_apps"}' | "$FORGED_LAUNCHER" "$FORGED_PROVIDER" || true)"
node -e '
const result = JSON.parse(process.argv[1]);
if (result.ok !== false || result.code !== "provider.authorizationRequired") process.exit(1);
' "$FORGED_OUTPUT"

echo "provider authorization boundary=PASS"
