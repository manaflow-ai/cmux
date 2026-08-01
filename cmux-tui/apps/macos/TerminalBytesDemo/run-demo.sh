#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TUI_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
REPO_ROOT="$(cd "$TUI_ROOT/.." && pwd -P)"

# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/ghostty-zig-version.sh"
ZIG_REQUIRED="$(ghostty_minimum_zig_version "$REPO_ROOT")"

for command in cargo codesign jq openssl xcodebuildmcp; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "TerminalBytes demo needs $command on PATH." >&2
    exit 1
  fi
done

if [[ -z "${ZIG:-}" ]]; then
  ZIG="$(command -v zig || true)"
fi
if [[ -z "${ZIG:-}" || ! -x "$ZIG" ]]; then
  echo "Set ZIG to a Zig $ZIG_REQUIRED-compatible executable." >&2
  exit 1
fi
if ! ZIG_ACTUAL="$("$ZIG" version 2>/dev/null)" \
  || ! ghostty_zig_version_is_compatible "$ZIG_ACTUAL" "$ZIG_REQUIRED"; then
  echo "TerminalBytes demo needs Zig $ZIG_REQUIRED-compatible; $ZIG reports ${ZIG_ACTUAL:-unknown}." >&2
  exit 1
fi
export ZIG
export MACOSX_DEPLOYMENT_TARGET=14.0

echo "Building the exact cmux-tui daemon and Rust terminal-client static library..."
(cd "$TUI_ROOT" && cargo +1.97.1 build -p cmux-tui -p cmux-terminal-client)

echo "Building the standalone macOS app through XcodeBuildMCP..."
xcodebuildmcp swift-package clean --package-path "$SCRIPT_DIR"
xcodebuildmcp swift-package build \
  --package-path "$SCRIPT_DIR" \
  --configuration debug

CMUX_TUI="$TUI_ROOT/target/debug/cmux-tui"
STATIC_LIBRARY="$TUI_ROOT/target/debug/libcmux_terminal_client.a"
APP_BINARY="$SCRIPT_DIR/.build/debug/TerminalBytesDemo"
RESOURCE_BUNDLE="$SCRIPT_DIR/.build/debug/TerminalBytesDemo_TerminalBytesDemo.bundle"
for artifact in "$CMUX_TUI" "$STATIC_LIBRARY" "$APP_BINARY" "$RESOURCE_BUNDLE"; do
  if [[ ! -e "$artifact" ]]; then
    echo "Expected build artifact is missing: $artifact" >&2
    exit 1
  fi
done

TEMP_PARENT="${TMPDIR:-/tmp}"
TEMP_PARENT="${TEMP_PARENT%/}"
DEMO_ROOT="$(mktemp -d "$TEMP_PARENT/cmux-terminal-bytes-demo.XXXXXX")"
SESSION="terminal-bytes-$$"
MUX_SOCKET="$DEMO_ROOT/mux.sock"
MUX_STATE="$DEMO_ROOT/mux-state"
ADMIN_SOCKET="$DEMO_ROOT/admin.sock"
LINK_SOCKET="$DEMO_ROOT/link.sock"
REMOTE_STATE="$DEMO_ROOT/remote-state"
INVITATION_FILE="$DEMO_ROOT/invitation.txt"
DAEMON_LOG="$DEMO_ROOT/daemon.log"
DAEMON_PID=""
APP_PID=""
SURFACE=""

cleanup() {
  set +e
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
  fi
  if [[ "$SURFACE" =~ ^[0-9]+$ && -S "$MUX_SOCKET" ]]; then
    "$CMUX_TUI" --socket "$MUX_SOCKET" close-surface --surface "$SURFACE" \
      >/dev/null 2>&1
    sleep 0.2
  fi
  if [[ -n "$DAEMON_PID" ]] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    kill "$DAEMON_PID" 2>/dev/null
    wait "$DAEMON_PID" 2>/dev/null
  fi
  if [[ -n "$DEMO_ROOT" && "$DEMO_ROOT" == "$TEMP_PARENT"/cmux-terminal-bytes-demo.* ]]; then
    rm -rf -- "$DEMO_ROOT"
  fi
}
trap cleanup EXIT INT TERM

APP_BUNDLE="$DEMO_ROOT/TerminalBytesDemo.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/en.lproj" \
  "$APP_BUNDLE/Contents/Resources/ja.lproj"
cp "$SCRIPT_DIR/Support/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$SCRIPT_DIR/Support/en.lproj/InfoPlist.strings" \
  "$APP_BUNDLE/Contents/Resources/en.lproj/InfoPlist.strings"
cp "$SCRIPT_DIR/Support/ja.lproj/InfoPlist.strings" \
  "$APP_BUNDLE/Contents/Resources/ja.lproj/InfoPlist.strings"
cp "$APP_BINARY" "$APP_BUNDLE/Contents/MacOS/TerminalBytesDemo"
cp -R "$RESOURCE_BUNDLE" \
  "$APP_BUNDLE/Contents/Resources/TerminalBytesDemo_TerminalBytesDemo.bundle"
codesign --force --sign - --timestamp=none "$APP_BUNDLE" >/dev/null
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/TerminalBytesDemo"

echo "Starting isolated ephemeral Iroh daemon in $DEMO_ROOT"
"$CMUX_TUI" daemon \
  --session "$SESSION" \
  --socket "$MUX_SOCKET" \
  --state "$MUX_STATE" \
  --iroh \
  --remote-state-dir "$REMOTE_STATE" \
  --remote-link-socket "$LINK_SOCKET" \
  --remote-admin-socket "$ADMIN_SOCKET" \
  >"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!

ready=0
for _ in $(seq 1 300); do
  if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    echo "The demo daemon exited during startup:" >&2
    sed -n '1,160p' "$DAEMON_LOG" >&2
    exit 1
  fi
  if [[ -S "$MUX_SOCKET" && -S "$ADMIN_SOCKET" ]] \
    && "$CMUX_TUI" --socket "$MUX_SOCKET" ping >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
if [[ "$ready" != "1" ]]; then
  echo "The demo daemon did not become ready:" >&2
  sed -n '1,160p' "$DAEMON_LOG" >&2
  exit 1
fi

SURFACE="$("$CMUX_TUI" --socket "$MUX_SOCKET" new-workspace \
  --name TerminalBytesDemo --cols 100 --rows 30)"
if [[ ! "$SURFACE" =~ ^[0-9]+$ ]]; then
  echo "Could not create the isolated terminal surface: $SURFACE" >&2
  exit 1
fi
"$CMUX_TUI" --socket "$MUX_SOCKET" send --surface "$SURFACE" \
  --text "printf '\\033[2J\\033[H\\033[1;36mTerminalBytes over Iroh\\033[0m\\nSwift UI, Rust transport, local libghostty parser.\\n日本語 input and ANSI control bytes are parsed locally.\\n\\nType a command below to verify input and resize:\\n'"
"$CMUX_TUI" --socket "$MUX_SOCKET" send-key --surface "$SURFACE" enter

INVITATION="$("$CMUX_TUI" enroll create \
  --admin-socket "$ADMIN_SOCKET" --ttl 300)"
printf '%s\n' "$INVITATION" >"$INVITATION_FILE"
chmod 600 "$INVITATION_FILE"

ENCODED="${INVITATION#cmux://enroll/}"
if [[ "$ENCODED" == "$INVITATION" ]]; then
  echo "Daemon returned an invalid invitation URI." >&2
  exit 1
fi
STANDARD="$(printf '%s' "$ENCODED" | sed 'y#_-#/+#')"
while (( ${#STANDARD} % 4 != 0 )); do
  STANDARD="${STANDARD}="
done
INVITATION_ID="$(printf '%s' "$STANDARD" \
  | openssl base64 -d -A \
  | jq -er '.id')"

echo "Launching surface $SURFACE. The app will claim invitation $INVITATION_ID."
CMUX_TERMINAL_INVITATION_FILE="$INVITATION_FILE" \
CMUX_TERMINAL_SURFACE="$SURFACE" \
CMUX_TERMINAL_AUTOCONNECT=1 \
  "$APP_EXECUTABLE" &
APP_PID=$!

claimed=0
for _ in $(seq 1 900); do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "The app exited before claiming its invitation." >&2
    exit 1
  fi
  PENDING="$("$CMUX_TUI" enroll pending --admin-socket "$ADMIN_SOCKET" --json)"
  if printf '%s' "$PENDING" \
    | jq -e --arg id "$INVITATION_ID" 'any(.[]; .invitation_id == $id)' \
      >/dev/null; then
    claimed=1
    break
  fi
  sleep 0.1
done
if [[ "$claimed" != "1" ]]; then
  echo "The app did not claim the fresh demo invitation within 90 seconds." >&2
  sed -n '1,160p' "$DAEMON_LOG" >&2
  exit 1
fi

"$CMUX_TUI" enroll approve "$INVITATION_ID" \
  --admin-socket "$ADMIN_SOCKET" >/dev/null
echo "Approved only fresh invitation $INVITATION_ID. Close the app to stop and clean up."
echo "Expected diagnostics: carrier=iroh, service=terminal-bytes-v1, ready=true, resync_count=0."

wait "$APP_PID"
APP_PID=""
