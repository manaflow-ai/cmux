#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TUI_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
REPO_ROOT="$(cd "$TUI_ROOT/.." && pwd -P)"

# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/ghostty-zig-version.sh"
ZIG_REQUIRED="$(ghostty_minimum_zig_version "$REPO_ROOT")"

for command in cargo codesign jq openssl swift; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "NativeMuxDemo needs $command on PATH." >&2
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
  echo "NativeMuxDemo needs Zig $ZIG_REQUIRED-compatible; $ZIG reports ${ZIG_ACTUAL:-unknown}." >&2
  exit 1
fi
export ZIG
export MACOSX_DEPLOYMENT_TARGET=14.0
export CMUX_ALLOW_LOW_SPACE_BUILD=1

CMUX_TUI="$TUI_ROOT/target/debug/cmux-tui"
STATIC_LIBRARY="$TUI_ROOT/target/debug/libcmux_terminal_client.a"
TEMP_PARENT="${TMPDIR:-/tmp}"
TEMP_PARENT="${TEMP_PARENT%/}"
DEMO_ROOT="$(mktemp -d "$TEMP_PARENT/cmux-native-mux-demo.XXXXXX")"
SWIFT_BUILD_ROOT="$DEMO_ROOT/swift-build"
SESSION="native-mux-$$"
MUX_SOCKET="$DEMO_ROOT/mux.sock"
MUX_STATE="$DEMO_ROOT/mux-state"
ADMIN_SOCKET="$DEMO_ROOT/admin.sock"
LINK_SOCKET="$DEMO_ROOT/link.sock"
REMOTE_STATE="$DEMO_ROOT/remote-state"
INVITATION_FILE="$DEMO_ROOT/invitation.txt"
DAEMON_LOG="$DEMO_ROOT/daemon.log"
DAEMON_PID=""
APP_PID=""

cleanup() {
  set +e
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
  fi
  if [[ -n "$DAEMON_PID" ]] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    kill "$DAEMON_PID" 2>/dev/null
    wait "$DAEMON_PID" 2>/dev/null
  fi
  if [[ -n "$DEMO_ROOT" && "$DEMO_ROOT" == "$TEMP_PARENT"/cmux-native-mux-demo.* ]]; then
    rm -rf -- "$DEMO_ROOT"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Building cmux-tui and the shared native frontend library..."
(cd "$TUI_ROOT" && cargo +1.97.1 build -p cmux-tui -p cmux-terminal-client)

echo "Building NativeMuxDemo in an invocation-owned SwiftPM directory..."
swift build \
  --package-path "$SCRIPT_DIR" \
  --scratch-path "$SWIFT_BUILD_ROOT" \
  --configuration debug
SWIFT_BIN_PATH="$(swift build \
  --package-path "$SCRIPT_DIR" \
  --scratch-path "$SWIFT_BUILD_ROOT" \
  --configuration debug \
  --show-bin-path)"

APP_BINARY="$SWIFT_BIN_PATH/NativeMuxDemo"
RESOURCE_BUNDLE="$SWIFT_BIN_PATH/NativeMuxDemo_NativeMuxDemo.bundle"
for artifact in "$CMUX_TUI" "$STATIC_LIBRARY" "$APP_BINARY" "$RESOURCE_BUNDLE"; do
  if [[ ! -e "$artifact" ]]; then
    echo "Expected build artifact is missing: $artifact" >&2
    exit 1
  fi
done

APP_BUNDLE="$DEMO_ROOT/NativeMuxDemo.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/en.lproj" \
  "$APP_BUNDLE/Contents/Resources/ja.lproj"
cp "$SCRIPT_DIR/Support/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$SCRIPT_DIR/Support/en.lproj/InfoPlist.strings" \
  "$APP_BUNDLE/Contents/Resources/en.lproj/InfoPlist.strings"
cp "$SCRIPT_DIR/Support/ja.lproj/InfoPlist.strings" \
  "$APP_BUNDLE/Contents/Resources/ja.lproj/InfoPlist.strings"
cp "$APP_BINARY" "$APP_BUNDLE/Contents/MacOS/NativeMuxDemo"
cp -R "$RESOURCE_BUNDLE" \
  "$APP_BUNDLE/Contents/Resources/NativeMuxDemo_NativeMuxDemo.bundle"
codesign --force --sign - --timestamp=none "$APP_BUNDLE" >/dev/null
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/NativeMuxDemo"

echo "Starting an isolated ephemeral Iroh daemon..."
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
    sed -n '1,180p' "$DAEMON_LOG" >&2
    exit 1
  fi
  if [[ -S "$MUX_SOCKET" && -S "$ADMIN_SOCKET" ]] \
    && "$CMUX_TUI" --socket "$MUX_SOCKET" session current ping >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
if [[ "$ready" != "1" ]]; then
  echo "The demo daemon did not become ready:" >&2
  sed -n '1,180p' "$DAEMON_LOG" >&2
  exit 1
fi

raw_mutation() {
  local operation="$1"
  local key="$2"
  local params="$3"
  "$CMUX_TUI" --socket "$MUX_SOCKET" raw operation "$operation" \
    --params-json "$params" --mutation --idempotency-key "$key"
}

result_id() {
  local json="$1"
  local key="$2"
  printf '%s' "$json" | jq -er --arg key "$key" \
    '.value[$key] // .result.value[$key] // .[$key]'
}

echo "Seeding workspaces, spaces, splits, a stack, vertical tabs, and niri columns..."
CREATED="$("$CMUX_TUI" --socket "$MUX_SOCKET" workspace create \
  --name agents --json)"
WORKSPACE="$(result_id "$CREATED" workspace_id)"
SCREEN="$(result_id "$CREATED" screen_id)"
PANE_A="$(result_id "$CREATED" pane_id)"
TERM_A="$(result_id "$CREATED" terminal_id)"

BASE_PARAMS="\"machine\":\"current\",\"session\":\"current\",\"workspace\":\"$WORKSPACE\",\"screen\":\"$SCREEN\""
SPLIT_B="$(raw_mutation pane.split native-seed-split-b \
  "{$BASE_PARAMS,\"pane\":\"$PANE_A\",\"direction\":\"right\",\"ratio\":0.55}")"
PANE_B="$(result_id "$SPLIT_B" pane_id)"
TERM_B="$(result_id "$SPLIT_B" terminal_id)"

SPLIT_C="$(raw_mutation pane.split native-seed-split-c \
  "{$BASE_PARAMS,\"pane\":\"$PANE_A\",\"direction\":\"down\",\"ratio\":0.58}")"
PANE_C="$(result_id "$SPLIT_C" pane_id)"
TERM_C="$(result_id "$SPLIT_C" terminal_id)"

TAB_TWO="$(raw_mutation tab.create_terminal native-seed-tab-two \
  "{$BASE_PARAMS,\"pane\":\"$PANE_A\",\"name\":\"logs\"}")"
TERM_TAB="$(result_id "$TAB_TWO" terminal_id)"

raw_mutation tab.create_browser native-seed-browser \
  "{$BASE_PARAMS,\"pane\":\"$PANE_B\",\"url\":\"https://example.com\",\"name\":\"web\"}" \
  >/dev/null

COLUMN="$(raw_mutation pane.split native-seed-column \
  "{$BASE_PARAMS,\"pane\":\"$PANE_B\",\"direction\":\"right\",\"viewport_width\":0.55}")"
PANE_D="$(result_id "$COLUMN" pane_id)"
TERM_D="$(result_id "$COLUMN" terminal_id)"

raw_mutation pane.create native-seed-stack \
  "{$BASE_PARAMS}" >/dev/null
raw_mutation screen.create native-seed-space-two \
  "{\"machine\":\"current\",\"session\":\"current\",\"workspace\":\"$WORKSPACE\",\"name\":\"review\"}" \
  >/dev/null
"$CMUX_TUI" --socket "$MUX_SOCKET" workspace create --name servers --json >/dev/null
raw_mutation workspace.focus native-seed-focus-workspace \
  "{\"machine\":\"current\",\"session\":\"current\",\"workspace\":\"$WORKSPACE\"}" \
  >/dev/null
raw_mutation screen.focus native-seed-focus-screen \
  "{$BASE_PARAMS}" >/dev/null

seed_terminal() {
  local terminal="$1"
  local label="$2"
  "$CMUX_TUI" --socket "$MUX_SOCKET" terminal "$terminal" write --text \
    "printf '\\033[2J\\033[H\\033[1;36m$label\\033[0m\\nNative Swift UI · Iroh transport · local libghostty parser\\n\\n'"
  "$CMUX_TUI" --socket "$MUX_SOCKET" terminal "$terminal" keys enter
}
seed_terminal "$TERM_A" "agents / editor"
seed_terminal "$TERM_B" "agents / browser host"
seed_terminal "$TERM_C" "agents / tests"
seed_terminal "$TERM_TAB" "agents / logs tab"
seed_terminal "$TERM_D" "niri column"

INVITATION="$("$CMUX_TUI" enroll create --admin-socket "$ADMIN_SOCKET" --ttl 300)"
printf '%s\n' "$INVITATION" >"$INVITATION_FILE"
chmod 600 "$INVITATION_FILE"

ENCODED="${INVITATION#cmux://enroll/}"
STANDARD="$(printf '%s' "$ENCODED" | sed 'y#_-#/+#')"
while (( ${#STANDARD} % 4 != 0 )); do STANDARD="${STANDARD}="; done
INVITATION_ID="$(printf '%s' "$STANDARD" | openssl base64 -d -A | jq -er '.id')"

echo "Launching NativeMuxDemo and claiming invitation $INVITATION_ID..."
CMUX_NATIVE_INVITATION_FILE="$INVITATION_FILE" \
CMUX_NATIVE_AUTOCONNECT=1 \
  "$APP_EXECUTABLE" &
APP_PID=$!

claimed=0
for _ in $(seq 1 900); do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "NativeMuxDemo exited before claiming its invitation." >&2
    exit 1
  fi
  PENDING="$("$CMUX_TUI" enroll pending --admin-socket "$ADMIN_SOCKET" --json)"
  if printf '%s' "$PENDING" \
    | jq -e --arg id "$INVITATION_ID" 'any(.[]; .invitation_id == $id)' >/dev/null; then
    claimed=1
    break
  fi
  sleep 0.1
done
if [[ "$claimed" != "1" ]]; then
  echo "NativeMuxDemo did not claim its invitation within 90 seconds." >&2
  sed -n '1,180p' "$DAEMON_LOG" >&2
  exit 1
fi

"$CMUX_TUI" enroll approve "$INVITATION_ID" --admin-socket "$ADMIN_SOCKET" >/dev/null
echo "Ready. Exercise workspaces, spaces, splits, vertical tabs, browser tabs, and niri columns."
echo "Close NativeMuxDemo to stop the isolated daemon and remove its state."

wait "$APP_PID"
APP_PID=""
