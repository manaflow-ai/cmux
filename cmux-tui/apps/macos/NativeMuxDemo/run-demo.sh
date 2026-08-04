#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TUI_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
REPO_ROOT="$(cd "$TUI_ROOT/.." && pwd -P)"
REUSE_BUILD=0
LAUNCH_GHOSTTY=1
GHOSTTY_APP="${GHOSTTY_APP:-/Applications/Ghostty.app}"

usage() {
  cat <<'USAGE'
Usage: run-demo.sh [--reuse-build] [--swift-only]

  --reuse-build  Launch the existing cmux-tui binary and NativeMuxDemo.app
                 without running Cargo or Swift build commands.
  --swift-only   Launch only NativeMuxDemo instead of the side-by-side
                 Ghostty cmux-tui client.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reuse-build|--no-build)
      REUSE_BUILD=1
      shift
      ;;
    --swift-only)
      LAUNCH_GHOSTTY=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$LAUNCH_GHOSTTY" == "1" && ! -x "$GHOSTTY_APP/Contents/MacOS/ghostty" ]]; then
  echo "The side-by-side demo needs Ghostty.app at $GHOSTTY_APP." >&2
  echo "Set GHOSTTY_APP to another app bundle or pass --swift-only." >&2
  exit 1
fi

for command in jq open openssl pgrep; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "NativeMuxDemo needs $command on PATH." >&2
    exit 1
  fi
done

if [[ "$REUSE_BUILD" != "1" ]]; then
  for command in cargo codesign swift; do
    if ! command -v "$command" >/dev/null 2>&1; then
      echo "NativeMuxDemo needs $command on PATH." >&2
      exit 1
    fi
  done

  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/ghostty-zig-version.sh"
  ZIG_REQUIRED="$(ghostty_minimum_zig_version "$REPO_ROOT")"
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
fi

TEMP_PARENT="${TMPDIR:-/tmp}"
TEMP_PARENT="${TEMP_PARENT%/}"
DEMO_ROOT="$(mktemp -d "$TEMP_PARENT/cmux-native-mux-demo.XXXXXX")"
DEMO_BUILD_ROOT="$TUI_ROOT/target/native-mux-demo"
RUST_BUILD_ROOT="$DEMO_BUILD_ROOT/rust-build"
SWIFT_BUILD_ROOT="$DEMO_BUILD_ROOT/swift-build"
APP_BUNDLE="$DEMO_BUILD_ROOT/NativeMuxDemo.app"
CMUX_TUI="$RUST_BUILD_ROOT/debug/cmux-tui"
STATIC_LIBRARY="$RUST_BUILD_ROOT/debug/libcmux_terminal_client.a"
SESSION="native-mux-$$"
MUX_SOCKET="$DEMO_ROOT/mux.sock"
MUX_STATE="$DEMO_ROOT/mux-state"
ADMIN_SOCKET="$DEMO_ROOT/admin.sock"
LINK_SOCKET="$DEMO_ROOT/link.sock"
REMOTE_STATE="$DEMO_ROOT/remote-state"
SWIFT_INVITATION_FILE="$DEMO_ROOT/swift-invitation.txt"
GHOSTTY_INVITATION_FILE="$DEMO_ROOT/ghostty-invitation.txt"
GHOSTTY_CLIENT_STATE="$DEMO_ROOT/ghostty-client-state"
GHOSTTY_LOCAL_SOCKET="$DEMO_ROOT/ghostty-client.sock"
WINDOW_LAYOUT_FILE="$DEMO_ROOT/window-layout.json"
DAEMON_LOG="$DEMO_ROOT/daemon.log"
DAEMON_PID=""
APP_PID=""
OPEN_PID=""
GHOSTTY_PID=""
GHOSTTY_OPEN_PID=""

cleanup() {
  set +e
  if [[ -n "$GHOSTTY_PID" ]] && kill -0 "$GHOSTTY_PID" 2>/dev/null; then
    kill "$GHOSTTY_PID" 2>/dev/null
    wait "$GHOSTTY_PID" 2>/dev/null
  fi
  if [[ -n "$GHOSTTY_OPEN_PID" ]] && kill -0 "$GHOSTTY_OPEN_PID" 2>/dev/null; then
    kill "$GHOSTTY_OPEN_PID" 2>/dev/null
    wait "$GHOSTTY_OPEN_PID" 2>/dev/null
  fi
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
  fi
  if [[ -n "$OPEN_PID" ]] && kill -0 "$OPEN_PID" 2>/dev/null; then
    kill "$OPEN_PID" 2>/dev/null
    wait "$OPEN_PID" 2>/dev/null
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

if [[ "$APP_BUNDLE" != "$TUI_ROOT/target/native-mux-demo/NativeMuxDemo.app" ]]; then
  echo "Refusing unsafe NativeMuxDemo app path: $APP_BUNDLE" >&2
  exit 1
fi

if [[ "$REUSE_BUILD" == "1" ]]; then
  echo "Reusing existing cmux-tui and NativeMuxDemo.app artifacts..."
  for artifact in "$CMUX_TUI" "$APP_BUNDLE/Contents/MacOS/NativeMuxDemo"; do
    if [[ ! -x "$artifact" ]]; then
      echo "Reusable build artifact is missing: $artifact" >&2
      echo "Run this launcher without --reuse-build once after freeing build space." >&2
      exit 1
    fi
  done
else
  echo "Building cmux-tui and the shared native frontend library..."
  (cd "$TUI_ROOT" && cargo +1.97.1 build --target-dir "$RUST_BUILD_ROOT" -p cmux-tui)
  (cd "$TUI_ROOT" && cargo +1.97.1 build --target-dir "$RUST_BUILD_ROOT" \
    -p cmux-terminal-client \
    --no-default-features --features native-renderer)

  echo "Building NativeMuxDemo in its worktree-local SwiftPM directory..."
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
  for artifact in "$CMUX_TUI" "$STATIC_LIBRARY" "$APP_BINARY"; do
    if [[ ! -e "$artifact" ]]; then
      echo "Expected build artifact is missing: $artifact" >&2
      exit 1
    fi
  done

  rm -rf -- "$APP_BUNDLE"
  mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/en.lproj" \
    "$APP_BUNDLE/Contents/Resources/ja.lproj"
  cp "$SCRIPT_DIR/Support/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
  cp "$SCRIPT_DIR/Support/en.lproj/InfoPlist.strings" \
    "$APP_BUNDLE/Contents/Resources/en.lproj/InfoPlist.strings"
  cp "$SCRIPT_DIR/Support/ja.lproj/InfoPlist.strings" \
    "$APP_BUNDLE/Contents/Resources/ja.lproj/InfoPlist.strings"
  cp "$SCRIPT_DIR/Sources/NativeMuxDemo/Resources/en.lproj/Localizable.strings" \
    "$APP_BUNDLE/Contents/Resources/en.lproj/Localizable.strings"
  cp "$SCRIPT_DIR/Sources/NativeMuxDemo/Resources/ja.lproj/Localizable.strings" \
    "$APP_BUNDLE/Contents/Resources/ja.lproj/Localizable.strings"
  cp "$APP_BINARY" "$APP_BUNDLE/Contents/MacOS/NativeMuxDemo"
  codesign --force --sign - --timestamp=none "$APP_BUNDLE" >/dev/null
fi
APP_PROCESS_TOKEN="target/native-mux-demo/NativeMuxDemo.app/Contents/MacOS/NativeMuxDemo"

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
    --params-json "$params" --mutation --idempotency-key "$key" --json
}

result_id() {
  local json="$1"
  local key="$2"
  printf '%s' "$json" | jq -er --arg key "$key" \
    '.value[$key] // .result.value[$key] // .[$key]'
}

invitation_id() {
  local invitation="$1"
  local encoded="${invitation#cmux://enroll/}"
  local standard
  standard="$(printf '%s' "$encoded" | sed 'y#_-#/+#')"
  while (( ${#standard} % 4 != 0 )); do standard="${standard}="; done
  printf '%s' "$standard" | openssl base64 -d -A | jq -er '.id'
}

find_new_pid() {
  local process_token="$1"
  local previous="$2"
  local pid
  for pid in $(pgrep -f "$process_token" || true); do
    if [[ " $previous " != *" $pid "* ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 1
}

wait_for_invitation_claim() {
  local invitation_id="$1"
  local owner_pid="$2"
  local owner_name="$3"
  local pending
  for _ in $(seq 1 900); do
    if ! kill -0 "$owner_pid" 2>/dev/null; then
      echo "$owner_name exited before claiming its invitation." >&2
      return 1
    fi
    pending="$("$CMUX_TUI" enroll pending --admin-socket "$ADMIN_SOCKET" --json)"
    if printf '%s' "$pending" \
      | jq -e --arg id "$invitation_id" 'any(.[]; .invitation_id == $id)' >/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo "$owner_name did not claim its invitation within 90 seconds." >&2
  return 1
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
TERM_C="$(result_id "$SPLIT_C" terminal_id)"

TAB_TWO="$(raw_mutation tab.create_terminal native-seed-tab-two \
  "{$BASE_PARAMS,\"pane\":\"$PANE_A\",\"name\":\"logs\"}")"
TERM_TAB="$(result_id "$TAB_TWO" terminal_id)"

raw_mutation tab.create_browser native-seed-browser \
  "{$BASE_PARAMS,\"pane\":\"$PANE_B\",\"url\":\"https://example.com\",\"name\":\"web\"}" \
  >/dev/null

COLUMN="$(raw_mutation pane.split native-seed-column \
  "{$BASE_PARAMS,\"pane\":\"$PANE_B\",\"direction\":\"right\",\"viewport_width\":0.55}")"
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
    "printf '\\033[2J\\033[H\\033[1;36m$label\\033[0m\\nTwo clients · one daemon · synchronized PTY\\nSwift/GhosttyKit ↔ Ghostty/cmux-tui over Iroh\\nType in either window; output appears in both.\\n\\n\\033[31mred \\033[32mgreen \\033[33myellow \\033[34mblue \\033[35mmagenta \\033[36mcyan\\033[0m\\n\\033[1mbold\\033[0m  \\033[4munderline\\033[0m  UTF-8: λ 日本語\\n\\n'"
  "$CMUX_TUI" --socket "$MUX_SOCKET" terminal "$terminal" keys enter
}
seed_terminal "$TERM_A" "agents / editor"
seed_terminal "$TERM_B" "agents / browser host"
seed_terminal "$TERM_C" "agents / tests"
seed_terminal "$TERM_TAB" "agents / logs tab"
seed_terminal "$TERM_D" "niri column"

SWIFT_INVITATION="$("$CMUX_TUI" enroll create --admin-socket "$ADMIN_SOCKET" --ttl 300)"
printf '%s\n' "$SWIFT_INVITATION" >"$SWIFT_INVITATION_FILE"
chmod 600 "$SWIFT_INVITATION_FILE"
SWIFT_INVITATION_ID="$(invitation_id "$SWIFT_INVITATION")"

APP_PIDS_BEFORE="$(pgrep -f "$APP_PROCESS_TOKEN" | tr '\n' ' ' || true)"
echo "Launching NativeMuxDemo and claiming invitation $SWIFT_INVITATION_ID..."
open -n -W \
  --env "CMUX_NATIVE_INVITATION_FILE=$SWIFT_INVITATION_FILE" \
  --env CMUX_NATIVE_AUTOCONNECT=1 \
  --env "CMUX_NATIVE_WINDOW_LAYOUT_FILE=$WINDOW_LAYOUT_FILE" \
  "$APP_BUNDLE" &
OPEN_PID=$!

for _ in $(seq 1 900); do
  if [[ -z "$APP_PID" ]]; then
    APP_PID="$(find_new_pid "$APP_PROCESS_TOKEN" "$APP_PIDS_BEFORE" || true)"
  fi
  if ! kill -0 "$OPEN_PID" 2>/dev/null; then
    echo "NativeMuxDemo exited before claiming its invitation." >&2
    exit 1
  fi
  [[ -n "$APP_PID" ]] && break
  sleep 0.1
done
if [[ -z "$APP_PID" ]]; then
  echo "Could not identify the new NativeMuxDemo process." >&2
  exit 1
fi
if ! wait_for_invitation_claim "$SWIFT_INVITATION_ID" "$APP_PID" "NativeMuxDemo"; then
  sed -n '1,180p' "$DAEMON_LOG" >&2
  exit 1
fi
"$CMUX_TUI" enroll approve "$SWIFT_INVITATION_ID" --admin-socket "$ADMIN_SOCKET" >/dev/null

if [[ "$LAUNCH_GHOSTTY" == "1" ]]; then
  GHOSTTY_INVITATION="$("$CMUX_TUI" enroll create --admin-socket "$ADMIN_SOCKET" --ttl 300)"
  printf '%s\n' "$GHOSTTY_INVITATION" >"$GHOSTTY_INVITATION_FILE"
  chmod 600 "$GHOSTTY_INVITATION_FILE"
  GHOSTTY_INVITATION_ID="$(invitation_id "$GHOSTTY_INVITATION")"

  layout_ready=0
  for _ in $(seq 1 100); do
    if jq -e '.x and .y != null and .columns and .rows' "$WINDOW_LAYOUT_FILE" \
      >/dev/null 2>&1; then
      layout_ready=1
      break
    fi
    sleep 0.1
  done
  if [[ "$layout_ready" != "1" ]]; then
    echo "NativeMuxDemo did not publish its side-by-side window layout." >&2
    exit 1
  fi

  GHOSTTY_X="$(jq -er '.x' "$WINDOW_LAYOUT_FILE")"
  GHOSTTY_Y="$(jq -er '.y' "$WINDOW_LAYOUT_FILE")"
  GHOSTTY_COLUMNS="$(jq -er '.columns' "$WINDOW_LAYOUT_FILE")"
  GHOSTTY_ROWS="$(jq -er '.rows' "$WINDOW_LAYOUT_FILE")"
  GHOSTTY_PROCESS_TOKEN="$GHOSTTY_APP/Contents/MacOS/ghostty"
  GHOSTTY_PIDS_BEFORE="$(pgrep -f "$GHOSTTY_PROCESS_TOKEN" | tr '\n' ' ' || true)"

  echo "Launching Ghostty with a second cmux-tui client over Iroh..."
  open -n -W "$GHOSTTY_APP" --args \
    --title="Ghostty · cmux-tui shared session" \
    --window-save-state=never \
    --window-position-x="$GHOSTTY_X" \
    --window-position-y="$GHOSTTY_Y" \
    --window-width="$GHOSTTY_COLUMNS" \
    --window-height="$GHOSTTY_ROWS" \
    --font-size=12 \
    -e "$CMUX_TUI" connect \
      --invite-file "$GHOSTTY_INVITATION_FILE" \
      --device-name "Ghostty cmux-tui demo" \
      --state-dir "$GHOSTTY_CLIENT_STATE" \
      --local-socket "$GHOSTTY_LOCAL_SOCKET" \
      --lanes isolated &
  GHOSTTY_OPEN_PID=$!

  for _ in $(seq 1 900); do
    if [[ -z "$GHOSTTY_PID" ]]; then
      GHOSTTY_PID="$(find_new_pid "$GHOSTTY_PROCESS_TOKEN" "$GHOSTTY_PIDS_BEFORE" || true)"
    fi
    if ! kill -0 "$GHOSTTY_OPEN_PID" 2>/dev/null; then
      echo "Ghostty exited before connecting to cmux-tui." >&2
      exit 1
    fi
    [[ -n "$GHOSTTY_PID" ]] && break
    sleep 0.1
  done
  if [[ -z "$GHOSTTY_PID" ]]; then
    echo "Could not identify the new Ghostty process." >&2
    exit 1
  fi
  if ! wait_for_invitation_claim \
    "$GHOSTTY_INVITATION_ID" "$GHOSTTY_PID" "Ghostty cmux-tui"; then
    sed -n '1,180p' "$DAEMON_LOG" >&2
    exit 1
  fi
  "$CMUX_TUI" enroll approve \
    "$GHOSTTY_INVITATION_ID" --admin-socket "$ADMIN_SOCKET" >/dev/null

  connected=0
  for _ in $(seq 1 300); do
    CONNECTED_CLIENTS="$("$CMUX_TUI" enroll status \
      --admin-socket "$ADMIN_SOCKET" --json | jq -er '.connected_clients')"
    if (( CONNECTED_CLIENTS >= 2 )); then
      connected=1
      break
    fi
    sleep 0.1
  done
  if [[ "$connected" != "1" ]]; then
    echo "The daemon did not observe both demo clients." >&2
    exit 1
  fi
fi

if [[ "$LAUNCH_GHOSTTY" == "1" ]]; then
  echo "Ready. Swift/GhosttyKit is on the left; Ghostty/cmux-tui is on the right."
  echo "Both are independently enrolled Iroh clients for session $SESSION."
  echo "Type in either frontend and verify the same PTY output appears in both."
  echo "Close either client to detach it. The daemon stops after both clients close."
else
  echo "Ready. Exercise workspaces, spaces, splits, vertical tabs, browser tabs, and niri columns."
  echo "Close NativeMuxDemo to stop the isolated daemon and remove its state."
fi

while true; do
  app_alive=0
  ghostty_alive=0
  kill -0 "$APP_PID" 2>/dev/null && app_alive=1
  if [[ "$LAUNCH_GHOSTTY" == "1" ]]; then
    kill -0 "$GHOSTTY_PID" 2>/dev/null && ghostty_alive=1
  fi
  if [[ "$app_alive" == "0" && "$ghostty_alive" == "0" ]]; then
    break
  fi
  sleep 0.2
done

wait "$OPEN_PID" 2>/dev/null || true
OPEN_PID=""
APP_PID=""
if [[ -n "$GHOSTTY_OPEN_PID" ]]; then
  wait "$GHOSTTY_OPEN_PID" 2>/dev/null || true
  GHOSTTY_OPEN_PID=""
fi
GHOSTTY_PID=""
