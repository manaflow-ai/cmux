#!/usr/bin/env bash
# The end-of-task hand-off of the cmux-next iPhone app (new and under verification, see
# cmux-next-ios/AGENTS.md; the root "Finishing a task" rules are unchanged until it has run end
# to end): one command, run by an agent at a pushed head, that leaves the task's build on every connected
# iPhone signed in and paired with the same-tag cmux NEXT Mac build, and proves it.
#
#   cmux-next-ios/scripts/review.sh --tag <task-slug> [--device-id <udid>] [--target-worker <worker>]
#       [--workspace <PR URL>]   (default: the branch's PR, else cmux-next-ios-review/<task-slug>)
#       [--manual-pairing | --no-auth]
#
# The default is the hand-off every dev build must reach: signed in (personal account) and paired
# with the same-tag Mac at once, and still both after the person relaunches the app or the Mac.
#   --manual-pairing  signed in as usual, but the Mac's pairing code is not handed to the phone
#                     (and not marked used): the person pairs by hand, to dogfood pairing. The
#                     proof keeps the sign-in checks (and the credential-free relaunch) and drops
#                     the paired ones and the Mac relaunch. "pairing left to you (--manual-pairing)".
#   --no-auth         no credentials and no code; the first launch carries the DEBUG-only
#                     CMUX_MOBILE_CLEAR_AUTH=1, which drops the tag's stored session, so the app
#                     opens at the welcome screen as on a fresh install. The proof: the receipt
#                     says signed out, and a plain relaunch is still signed out. Implies no
#                     pairing. "installed, not signed in (--no-auth)".
#
# In order (each phone's failure is its own blocker; the others go on):
#  1. Fleet, at the pushed HEAD: the tagged Mac dev build (`cmux-ci build cmux`, then
#     `cmux-ci publish-hq`, Tag Opener http://127.0.0.1:17320/<tag>) and, in one simulator step,
#     the iPhone app (scripts/ci/cmux-next-ios-sim.sh handoff: Demo configuration with the DEBUG
#     developer surface, bundle dev.cmux.mobile.<tag>, display name "cmux <tag>", an unsigned
#     device app) plus the fleet simulator check: signed in with the worker's agent account, then
#     relaunched with no credentials and signed in from its own Keychain, with screenshots and a
#     recording. The step carries --label ios-agent-signin, so only a simulator worker holding
#     the agent account file takes it; --target-worker pins it further. Job ids are saved:
#     rerunning the same command resumes them. With no connected phone the fleet legs still run,
#     and the phone is the reported blocker.
#  2. This Mac: installs the tagged Mac app where ios-reload.py and verify-iphone-auth.sh look for
#     it (a new head of the same tag replaces this tool's earlier install, quitting it first;
#     another workflow's install of the tag is never touched), launches it in the background
#     (`open -g` with an empty environment, never taking focus) and waits until it is signed in
#     to the `personal` account and its Mobile Pairing page offers a code. iPhone connections
#     (`mobile.allowIPhoneConnections`) live in the shared ~/.config/cmux/cmux-next.json that every
#     build reads, so a fresh tag has the person's choice; when it is off this reports it and
#     never turns it on.
#  3. Every connected, paired iPhone (scripts/lib/iphone-review-targets.sh; a new phone is
#     registered in ~/.config/cmux/iphone-device-ids; a --device-id phone that is missing is a
#     blocker, a missing default a notice): signs a copy of the app with this Mac's Apple
#     Development identity and, per bundle, a development profile naming the phone
#     (sign_device_app.py), installs it through the sanctioned install
#     (CMUX_SANCTIONED_IPHONE_INSTALL), and launches it with the personal account
#     (DEVICECTL_CHILD_CMUX_MOBILE_STACK_*) and the Mac's single-use pairing code
#     (DEVICECTL_CHILD_CMUX_MOBILE_PAIR_URL: the code a scan would open; no Allow prompt, no seed).
#     A code is recorded as used only after a phone paired with it.
#  4. Proves each phone, from the app's DEBUG readiness receipt (handoff_receipt.py; a fresh nonce
#     per launch, so an old receipt never passes; the build's commit and tag must be this run's):
#     signed in and paired and linked with this tag's Mac (the `mac=` id of its own pairing link);
#     the Mac lists this phone (one of its device ids) as paired and connected; then a
#     credential-free relaunch (no account, no code, as the person's own cold launch) comes back
#     signed in from its own session and linked again; then the tagged Mac app quits as the person
#     quits it and starts again (`open -g`), and one more credential-free relaunch of each phone is
#     linked to it again.
#  5. Prints the report (AGENTS.md format). Exit 0 only when every phone passed every check;
#     no connected phone is a failure too.
#
# The credential-free relaunches run the app's production persistence path: with no
# CMUX_MOBILE_STACK_* in the launch there are no auto-login credentials, so AuthCoordinator restores
# from the Keychain token store (KeychainStackTokenStore, the same code in Release), and the
# pairing keys, device ids and Mac pins are the app's own Keychain and Application Support state.
# The DEBUG receipt only observes that state.
#
# Never builds, boots a simulator or compiles on this Mac. Credentials stay in
# ~/.secrets/cmuxterm-dev.env (personal profile) and are never printed.
#
# Tests: python3 ios/tests/test_cnx_review.py
set -euo pipefail

usage() { sed -n '2,70p' "$0"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEAM=7WLXT3NR37
TAG="" SLUG="" DEVICE_ID="" TARGET_WORKER="" WORKSPACE=""
# What the phone gets (default `paired`, the hand-off every dev build must reach):
#   paired   signed in with the personal account and paired with the same-tag Mac by its code
#   manual   --manual-pairing: signed in, no pairing code; the person pairs by hand
#   none     --no-auth: no credentials, no code, and the tag's stored session cleared first
PHONE_MODE=paired

# shellcheck source=scripts/lib/mobile-attach.sh
source "$REPO_ROOT/scripts/lib/mobile-attach.sh"
# shellcheck source=scripts/lib/dev-secrets.sh
source "$REPO_ROOT/scripts/lib/dev-secrets.sh"
# shellcheck source=scripts/lib/iphone-review-targets.sh
source "$REPO_ROOT/scripts/lib/iphone-review-targets.sh"
# shellcheck source=../../scripts/cmux-next/lib/origin-net.sh
source "$REPO_ROOT/scripts/cmux-next/lib/origin-net.sh"

REVIEW_CALLER="cmux-next-ios/scripts/review.sh"
# The cmux-next app talks to the public dev mobile service: no tailnet note for a new phone.
REVIEW_TAILNET_NOTE=0
REVIEW_PHONES_FILE="${CMUX_CONFIG_DIR:-$HOME/.config/cmux}/iphone-device-ids"
REVIEW_TARGETS=()
REVIEW_FAILED=0
REVIEW_PHONE_STATUS=""
DEFAULT_DEVICE_ID=""
# A phone asked for with --device-id (missing, it is a blocker); the configured default only
# gets a notice (scripts/lib/iphone-review-targets.sh).
REQUESTED_DEVICE_ID=""
NO_PHONE=0
REPORT_MAC="not built"
REPORT_SIM="not run"
MAC_JOB="" SIM_STEP="" SHA=""
STATE="" TAG_STATE="" MAC_APP="" MAC_SOCKET="" MAC_DEVICE_ID=""
# The phones that passed, as " udid udid " (a string, so an empty set needs no array expansion,
# which aborts under set -u on macOS's bash 3.2).
PASSED_PHONES=" "

die() { echo "review.sh: $*" >&2; exit 2; }

# --- the report ---------------------------------------------------------------
review_report() {
  local link="http://127.0.0.1:17320/$SLUG"
  printf '==> Review ready (tag: %s)\n' "$SLUG"
  printf 'Dev build:  %s   (%s, head %s)\n' "$link" "$REPORT_MAC" "${SHA:-unknown}"
  printf 'Simulator:  %s\n' "$REPORT_SIM"
  local first=1 line
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$line" ]] || continue
    if [[ $first -eq 1 ]]; then printf 'iPhone:     %s\n' "$line"; first=0; else printf '            %s\n' "$line"; fi
  done <<<"$REVIEW_PHONE_STATUS"
  if [[ $NO_PHONE -eq 1 || $first -eq 1 ]]; then
    local lead='iPhone:    '
    [[ $first -eq 1 ]] || lead='           '
    printf '%s BLOCKED: no connected iPhone; connect and unlock one, then rerun: %s\n' "$lead" "$(retry_command)"
  fi
}

retry_command() {
  printf 'cmux-next-ios/scripts/review.sh --tag %s' "$SLUG"
  [[ -z "$REQUESTED_DEVICE_ID" ]] || printf ' --device-id %s' "$REQUESTED_DEVICE_ID"
  case "$PHONE_MODE" in manual) printf ' --manual-pairing' ;; none) printf ' --no-auth' ;; esac
  [[ -z "$TARGET_WORKER" ]] || printf ' --target-worker %s' "$TARGET_WORKER"
}

passed() { [[ "$PASSED_PHONES" == *" $1 "* ]]; }

finish() {
  review_report
  [[ "$REVIEW_FAILED" -eq 0 && "$PASSED_PHONES" != " " ]]
}

# --- fleet --------------------------------------------------------------------
cmux_ci() {
  local ci="${CMUX_CI:-}"
  [[ -n "$ci" ]] || ci="$(command -v cmux-ci 2>/dev/null || true)"
  [[ -n "$ci" ]] || ci="$HOME/.local/bin/cmux-ci"
  "$ci" "$@"
}

# The Mac build's job, submitted once per tag and head (its id saved in $STATE/cmux-job).
fleet_submit_mac() {
  if [[ -s "$STATE/cmux-job" ]]; then
    MAC_JOB="$(cat "$STATE/cmux-job")"
    if [[ -f "$STATE/cmux-terminal.json" ]] && grep -Eq '"state": *"(failed|cancelled)"' "$STATE/cmux-terminal.json"; then
      mv "$STATE/cmux-job" "$STATE/cmux-job.$MAC_JOB.failed"
      mv "$STATE/cmux-terminal.json" "$STATE/cmux-terminal.$MAC_JOB.json"
      MAC_JOB=""
    else
      echo "==> Mac build: resuming fleet job $MAC_JOB"
      return 0
    fi
  fi
  local out
  # cmux-next needs no shared dev backend (AGENTS.md): the tag's own local mode.
  out="$(cmux_ci build cmux --ref "$SHA" --tag "$SLUG" --workspace "$WORKSPACE" --backend-mode local)" || { REPORT_MAC="BLOCKED: cmux-ci build cmux was refused"; return 1; }
  MAC_JOB="$(printf '%s' "$out" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')" ||
    { REPORT_MAC="BLOCKED: cmux-ci build cmux printed no job id"; return 1; }
  printf '%s\n' "$MAC_JOB" >"$STATE/cmux-job"
  echo "==> Mac build: fleet job $MAC_JOB"
}

# The iPhone app's simulator step, in the background; the same --key re-attaches to it. It is
# `handoff tag=<tag>`, sent as `shots handoff=<tag>` until the fleet controller lists handoff.
fleet_start_sim() {
  # ios-agent-signin: only a simulator worker holding the agent account file (hq build-fleet README,
  # "Sign-in placement") takes it; the step reads that file itself (cmux-next-ios-sim.sh handoff).
  local args=(run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref "$SHA"
    --arg shots --arg "handoff=$SLUG" --label ios-agent-signin --artifact artifacts/ios-sim/evidence.zip
    --key "cnx-ios-handoff-$SLUG-${SHA:0:12}")
  [[ -z "$TARGET_WORKER" ]] || args+=(--target-worker "$TARGET_WORKER")
  echo "==> iPhone app: fleet step cmux-next-ios-sim.sh handoff tag=$SLUG${TARGET_WORKER:+ on $TARGET_WORKER} (log: $STATE/sim-step.log)"
  cmux_ci "${args[@]}" >"$STATE/sim-step.log" 2>"$STATE/sim-step.err" &
  SIM_PID=$!
}

fleet_finish_mac() {
  if ! cmux_ci wait "$MAC_JOB" --receipt "$STATE/cmux-terminal.json"; then
    REPORT_MAC="BLOCKED: fleet job $MAC_JOB failed (cmux-ci log $MAC_JOB); retry: $(retry_command)"
    return 1
  fi
  rm -f "$STATE/cmux.zip"
  cmux_ci artifact "$MAC_JOB" "$STATE/cmux.zip" >/dev/null ||
    { REPORT_MAC="BLOCKED: fleet job $MAC_JOB passed but its artifact did not download; retry: $(retry_command)"; return 1; }
  if ! cmux_ci publish-hq "$MAC_JOB" >/dev/null; then
    REPORT_MAC="BLOCKED: fleet job $MAC_JOB built, but cmux-ci publish-hq failed; retry: cmux-ci publish-hq $MAC_JOB"
    return 1
  fi
  REPORT_MAC="fleet job $MAC_JOB, published to HQ"
}

fleet_finish_sim() {
  local rc=0
  wait "$SIM_PID" || rc=$?
  SIM_STEP="$(sed -n 's/^cmux-ci: step \([0-9a-f]\{24\}\).*/\1/p' "$STATE/sim-step.err" | tail -n 1)"
  if grep -q "is not the reviewed version" "$STATE/sim-step.err" "$STATE/sim-step.log" 2>/dev/null; then
    # The fleet runs an allowlisted step script only as it is on feat-cmux-next.
    REPORT_SIM="BLOCKED: the fleet refused scripts/ci/cmux-next-ios-sim.sh at $SHA: its handoff mode is not on feat-cmux-next yet (the fleet runs only the reviewed script); rerun after it lands: $(retry_command)"
    return 1
  fi
  if [[ $rc -ne 0 || -z "$SIM_STEP" ]]; then
    REPORT_SIM="BLOCKED: the fleet iPhone build failed (step ${SIM_STEP:-not created}, exit $rc; $STATE/sim-step.log); retry: $(retry_command)"
    return 1
  fi
  rm -f "$STATE/ios.zip"
  cmux_ci artifact "$SIM_STEP" "$STATE/ios.zip" >/dev/null ||
    { REPORT_SIM="BLOCKED: step $SIM_STEP passed but its artifact did not download; retry: $(retry_command)"; return 1; }
}

# Unzip an archive into a fresh directory, refusing absolute paths, `..`, and symlinks that point
# outside it (absolute, or climbing out). Links inside it stay: a Mac app's frameworks need them.
safe_unzip() {
  local zip="$1" dest="$2"
  rm -rf "$dest"
  /usr/bin/python3 -I "$SCRIPT_DIR/handoff_receipt.py" check-zip "$zip" || return 1
  ditto -x -k "$zip" "$dest"
}

# The simulator verdict and the device app from the step's artifact.
read_ios_artifact() {
  local why
  why="$(safe_unzip "$STATE/ios.zip" "$STATE/ios" 2>&1)" ||
    { REPORT_SIM="BLOCKED: the iPhone artifact of step $SIM_STEP is not a safe zip (${why##*$'\n'})"; return 1; }
  local check
  # One field per line (a tab split loses empty fields); the reason for a mismatch goes in the report.
  check="$(/usr/bin/python3 -I "$SCRIPT_DIR/handoff_receipt.py" read-manifest "$STATE/ios/handoff.json" \
    --tag "$SLUG" --sha "$SHA" --bundle-id "dev.cmux.mobile.$SLUG" 2>&1)" ||
    { REPORT_SIM="BLOCKED: step $SIM_STEP: ${check##*$'\n'}; retry: $(retry_command)"; return 1; }
  local status host device reason dir
  { IFS= read -r status; IFS= read -r host; IFS= read -r device; IFS= read -r reason; } <<<"$check"
  dir="$STATE/ios"
  if [[ "$status" == pass ]]; then
    REPORT_SIM="fleet simulator ($host, $device), signed in (agent account), restored after a credential-free relaunch: $dir (screens/signed-in-auto_login.png, screens/signed-in-restored.png, recording.mp4; step $SIM_STEP)"
  else
    REPORT_SIM="BLOCKED: fleet simulator check on $host failed: ${reason:-unknown}; evidence $dir; retry: $(retry_command)"
    REVIEW_FAILED=1
  fi
  why="$(safe_unzip "$STATE/ios/CmuxMobileApp-Demo-device-unsigned.app.zip" "$STATE/device" 2>&1)" ||
    { REPORT_SIM="$REPORT_SIM; BLOCKED: the device app is not a safe zip (${why##*$'\n'})"; REVIEW_FAILED=1; return 1; }
  [[ -d "$STATE/device/CmuxMobileApp.app" ]] ||
    { REPORT_SIM="$REPORT_SIM; BLOCKED: the artifact has no device app"; REVIEW_FAILED=1; return 1; }
}

# --- the tagged Mac -----------------------------------------------------------
mac_py() { /usr/bin/python3 -I "$SCRIPT_DIR/review_mac.py" "$@"; }

# Install the fleet Mac app at the tag's path (ios-reload.py's install_mac, verify-iphone-auth.sh).
# The tag's install record ($TAG_STATE/mac-installed: "<head> <job>") says this tool put the app
# there. The same head reuses it; an earlier head of this tool is quit and replaced; an app this tool
# did not install (another workflow's build of the tag) is never touched.
mac_install() {
  local why
  why="$(safe_unzip "$STATE/cmux.zip" "$STATE/mac" 2>&1)" ||
    { REPORT_MAC="BLOCKED: the Mac artifact of job $MAC_JOB is not a safe zip (${why##*$'\n'})"; return 1; }
  local built record recorded_sha=""
  built="$(find "$STATE/mac" -maxdepth 3 -name 'cmux DEV *.app' -type d | head -n 1)"
  [[ -n "$built" ]] || { REPORT_MAC="BLOCKED: fleet job $MAC_JOB has no cmux DEV app"; return 1; }
  MAC_APP="$(cmux_attach_mac_app_path "$SLUG")"
  record="$TAG_STATE/mac-installed"
  [[ -f "$record" ]] && recorded_sha="$(awk '{ print $1; exit }' "$record")"
  if [[ -d "$MAC_APP" ]]; then
    if [[ -z "$recorded_sha" ]]; then
      REPORT_MAC="BLOCKED: $SLUG already has a build this tool did not install; choose a new tag"
      return 1
    fi
    if [[ "$recorded_sha" == "$SHA" ]]; then
      MAC_SOCKET="$(mac_py socket "$MAC_APP")" || MAC_SOCKET="$(cmux_attach_socket_path "$SLUG")"
      return 0
    fi
    echo "==> replacing this tool's install of $SLUG at ${recorded_sha:0:12} with $SHA"
    mac_quit_installed || { REPORT_MAC="BLOCKED: the tag's earlier build (${recorded_sha:0:12}) did not quit"; return 1; }
    rm -rf "$MAC_APP"
  fi
  mkdir -p "$(dirname "$MAC_APP")"
  ditto "$built" "$MAC_APP"
  printf '%s %s\n' "$SHA" "$MAC_JOB" >"$record"
  MAC_SOCKET="$(mac_py socket "$MAC_APP")" || MAC_SOCKET="$(cmux_attach_socket_path "$SLUG")"
}

# Quit the tag's installed Mac app if it runs: over its control socket, else an Apple Event to its
# bundle id. Neither brings it to the front; an app that is not running is never launched.
mac_quit_installed() {
  pgrep -f "$MAC_APP/Contents/MacOS/" >/dev/null 2>&1 || return 0
  local socket bundle i
  socket="$(mac_py socket "$MAC_APP" 2>/dev/null || cmux_attach_socket_path "$SLUG")"
  if ! mac_py quit "$socket" 2>/dev/null; then
    bundle="$(mac_py bundle "$MAC_APP")"
    [[ -n "$bundle" ]] && osascript -e "if application id \"$bundle\" is running then tell application id \"$bundle\" to quit" >/dev/null 2>&1
  fi
  for i in $(seq 1 60); do
    pgrep -f "$MAC_APP/Contents/MacOS/" >/dev/null 2>&1 || return 0
    sleep 1
  done
  return 1
}

# `open -g` hands the launching shell's environment to the app. An agent's shell inside the person's
# cmux carries that app's CMUX_NEXT_CLOUD_ENV=prod (and the rest of its CMUX_* values), which the
# tagged build takes as its Cloud environment: it then never signs in to the dev account
# (seen 2026-11-14). The tag's own LSEnvironment is all it needs, so it starts from an empty one.
mac_open() {
  env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    TMPDIR="${TMPDIR:-/tmp}" "${MAC_OPEN:-/usr/bin/open}" -g --env CMUX_NEXT_NO_ACTIVATE=1 "$MAC_APP"
}

# Launch it in the background (never frontmost) unless it runs, and wait for the personal account.
mac_start() {
  if ! mac_py wait-socket "$MAC_SOCKET" --timeout 2; then
    echo "==> launching the tagged Mac app in the background"
    mac_open ||
      { REPORT_MAC="$REPORT_MAC; BLOCKED: the tagged Mac app did not launch"; return 1; }
    mac_py wait-socket "$MAC_SOCKET" --timeout 120 ||
      { REPORT_MAC="$REPORT_MAC; BLOCKED: the tagged Mac app never answered on its control socket"; return 1; }
  fi
  local account
  account="$(mac_py account "$MAC_SOCKET" --timeout 120)" ||
    { REPORT_MAC="$REPORT_MAC; BLOCKED: the tagged Mac app is not signed in (it signs in from ~/.secrets/cmuxterm-dev.env as ~/.config/cmux/dev-account)"; return 1; }
  if [[ "$account" != "$PERSONAL_ACCOUNT" ]]; then
    REPORT_MAC="$REPORT_MAC; BLOCKED: the tagged Mac app is signed in as $account, not the personal account $PERSONAL_ACCOUNT"
    return 1
  fi
  # --manual-pairing / --no-auth: no code is handed to a phone, so none is required here.
  [[ "$PHONE_MODE" == paired ]] || return 0
  local why
  # The id phones pair with, from the Mac's own pairing link: also shows the page can offer a code.
  MAC_DEVICE_ID="$(mac_py mac-id "$MAC_SOCKET" --timeout 90 2>&1)" ||
    { why="$MAC_DEVICE_ID"; MAC_DEVICE_ID=""
      REPORT_MAC="$REPORT_MAC; BLOCKED: the tagged Mac app offers no pairing code (${why##*$'\n'}; iPhone connections on in Settings > Mobile?)"; return 1; }
}

# Quit the tagged Mac app as the person does and start it again (the Tag Opener's relaunch).
mac_restart() {
  mac_py quit "$MAC_SOCKET" || return 1
  local i
  for i in $(seq 1 60); do
    pgrep -f "$MAC_APP/Contents/MacOS/" >/dev/null 2>&1 || break
    sleep 1
  done
  ! pgrep -f "$MAC_APP/Contents/MacOS/" >/dev/null 2>&1 || return 1
  local before="$MAC_DEVICE_ID"
  mac_start || return 1
  [[ "$MAC_DEVICE_ID" == "$before" ]]
}

# --- the phones ---------------------------------------------------------------
# One launch of the app on PHONE and its receipt. Args: udid client launch [pair-url], where launch is
#   auto_login   the personal account's credentials (and the pairing code, when given)
#   restored     nothing: the app's own stored session, as the person's own cold launch
#   clear        CMUX_MOBILE_CLEAR_AUTH=1 (DEBUG only: drops the tag's stored session), then signed out
#   signed_out   nothing, and the app must still be signed out
# Credentials go in the environment of this one call only; every other launch carries none, and
# the ambient DEVICECTL_CHILD_ credential, code and clear variables are dropped first.
phone_launch_and_check() {
  local udid="$1" client="$2" launch="$3" pair_url="${4:-}" nonce rc=0 session mac_id=""
  session="$launch"
  [[ "$launch" != clear ]] || session=signed_out
  # Only the paired hand-off checks the Mac; --manual-pairing and --no-auth prove sign-in state only.
  [[ "$PHONE_MODE" != paired ]] || mac_id="$MAC_DEVICE_ID"
  nonce="$(cmux_attach_readiness_nonce)"
  # In a subshell's environment, never on a command line (ps would show it).
  if ! (
    unset DEVICECTL_CHILD_CMUX_MOBILE_STACK_EMAIL DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD DEVICECTL_CHILD_CMUX_MOBILE_PAIR_URL \
      DEVICECTL_CHILD_CMUX_MOBILE_CLEAR_AUTH
    export DEVICECTL_CHILD_CMUX_DOGFOOD_READINESS_NONCE="$nonce" DEVICECTL_CHILD_CMUX_DOGFOOD_CLIENT_ID="$client"
    if [[ "$launch" == auto_login ]]; then
      export DEVICECTL_CHILD_CMUX_MOBILE_STACK_EMAIL="$PERSONAL_EMAIL" DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD="$PERSONAL_PASSWORD"
      [[ -z "$pair_url" ]] || export DEVICECTL_CHILD_CMUX_MOBILE_PAIR_URL="$pair_url"
    elif [[ "$launch" == clear ]]; then
      export DEVICECTL_CHILD_CMUX_MOBILE_CLEAR_AUTH=1
    fi
    exec xcrun devicectl device process launch --terminate-existing --device "$udid" "$BUNDLE_ID" >/dev/null 2>&1
  ); then
    PHONE_REASON="could not launch the app ($launch; is the phone locked? unlock it)"
    return 1
  fi
  local deadline=$((SECONDS + ${CNX_REVIEW_RECEIPT_TIMEOUT:-180})) verdict="" receipt
  receipt="$(mktemp "${TMPDIR:-/tmp}/cnx-review-receipt.XXXXXX")"
  while :; do
    rm -f "$receipt"
    if cmux_attach_fetch_app_receipt physical_device "$udid" "$BUNDLE_ID" "$receipt" 2>/dev/null; then
      rc=0
      verdict="$(/usr/bin/python3 -I "$SCRIPT_DIR/handoff_receipt.py" check "$receipt" --nonce "$nonce" \
        --client-id "$client" --bundle-id "$BUNDLE_ID" --account "$PERSONAL_ACCOUNT" --session "$session" \
        --mac-id "$mac_id" --git-sha "$SHA" --dev-tag "$SLUG")" || rc=$?
      [[ $rc -eq 1 ]] || break
    else
      rc=1 verdict="no readiness receipt yet"
    fi
    (( SECONDS < deadline )) || break
    sleep 3
  done
  # The last receipt this launch wrote: mac_sees_phone reads the phone's device ids from it.
  mkdir -p "$STATE/phone-$udid"
  if [[ -f "$receipt" ]]; then mv "$receipt" "$STATE/phone-$udid/receipt.json"; else rm -f "$receipt"; fi
  if [[ $rc -ne 0 ]]; then
    PHONE_REASON="$launch launch: $verdict (after ${CNX_REVIEW_RECEIPT_TIMEOUT:-180} s)"
    return 1
  fi
  PHONE_VERDICT="$verdict"
}

# The Mac lists THIS phone as paired and connected: hostd's row id is one of the phone's own device
# ids (the receipt's phone_device_ids), never just any connected phone.
mac_sees_phone() {
  local udid="$1" i ids
  ids="$(/usr/bin/python3 -I "$SCRIPT_DIR/handoff_receipt.py" phone-ids "$STATE/phone-$udid/receipt.json" 2>/dev/null)" ||
    return 1
  for i in $(seq 1 20); do
    if mac_py phones "$MAC_SOCKET" | /usr/bin/python3 -I -c '
import json, sys
ids = {line.strip().lower() for line in sys.argv[1].splitlines() if line.strip()}
rows = json.load(sys.stdin).get("phones") or []
sys.exit(0 if any(r.get("paired") and r.get("connected") and str(r.get("id", "")).lower() in ids for r in rows) else 1)
' "$ids" 2>/dev/null; then
      return 0
    fi
    sleep 3
  done
  return 1
}

sign_app() { /usr/bin/python3 -I "$SCRIPT_DIR/sign_device_app.py" "$@"; }

# Sign, install, launch signed in with the pairing code, prove it, relaunch credential-free, prove it.
phone_review() {
  local udid="$1" label="$2" client app pair_url
  PHONE_REASON=""
  client="$(cmux_attach_dogfood_client_id "$BUNDLE_ID" "$udid")"
  app="$STATE/phone-$udid/CmuxMobileApp.app"
  rm -rf "$STATE/phone-$udid"
  mkdir -p "$STATE/phone-$udid"
  ditto "$STATE/device/CmuxMobileApp.app" "$app"
  local signed
  if ! signed="$(sign_app --app "$app" --checkout "$REPO_ROOT" --team "$TEAM" --device "$udid" \
      2>"$STATE/phone-$udid/sign.err")"; then
    PHONE_REASON="signing failed: $(sed 's/^sign_device_app: //' "$STATE/phone-$udid/sign.err" | tail -n 1)"
    return 1
  fi
  printf '%s\n' "$signed" >"$STATE/phone-$udid/signed.json"
  "$REPO_ROOT/scripts/ios-device-process.sh" terminate-installed --device-id "$udid" --bundle-id "$BUNDLE_ID" >/dev/null 2>&1 || true
  # The sanctioned install (ios/AGENTS.md iPhone auth gate): it ends in the auth gate below, and the
  # marker lets the local-build-guards devicectl interceptor tell it from a raw install.
  if ! CMUX_SANCTIONED_IPHONE_INSTALL=1 xcrun devicectl device install app --device "$udid" "$app" \
      >"$STATE/phone-$udid/install.log" 2>&1; then
    PHONE_REASON="install failed ($(tail -n 1 "$STATE/phone-$udid/install.log"); locked, or Developer Mode off?)"
    return 1
  fi
  case "$PHONE_MODE" in
    manual)
      # Signed in like every dev build; the Mac's code is never fetched, so it stays unused.
      phone_launch_and_check "$udid" "$client" auto_login || return 1
      local signed_in="$PHONE_VERDICT"
      phone_launch_and_check "$udid" "$client" restored || return 1
      PHONE_LINE="$label: installed, $signed_in; credential-free relaunch: $PHONE_VERDICT; pairing left to you (--manual-pairing)"
      return 0 ;;
    none)
      phone_launch_and_check "$udid" "$client" clear || return 1
      phone_launch_and_check "$udid" "$client" signed_out || return 1
      PHONE_LINE="$label: installed, not signed in (--no-auth): the tag's stored session cleared, at the welcome screen; relaunch: still signed out"
      return 0 ;;
  esac
  local pair_err="$STATE/phone-$udid/pair-url.err"
  # A code is recorded as used only once a phone paired with it (its receipt says so), so a launch
  # that failed, or a rerun, takes the same live code again instead of waiting for the next one.
  pair_url="$(mac_py pair-url "$MAC_SOCKET" --timeout 90 --used "$TAG_STATE/used-codes" 2>"$pair_err")" ||
    { PHONE_REASON="no pairing code from the tagged Mac: $(tail -n 1 "$pair_err")"; return 1; }
  if ! phone_launch_and_check "$udid" "$client" auto_login "$pair_url"; then
    pair_url=""
    return 1
  fi
  printf '%s' "$pair_url" | mac_py mark-used "$TAG_STATE/used-codes" || true
  pair_url=""
  local first="$PHONE_VERDICT"
  mac_sees_phone "$udid" || { PHONE_REASON="the tagged Mac does not list this phone as paired and connected"; return 1; }
  phone_launch_and_check "$udid" "$client" restored || return 1
  PHONE_LINE="$label: installed, $first; Mac sees it paired and connected; credential-free relaunch: $PHONE_VERDICT"
}

phone_after_mac_restart() {
  local udid="$1" client
  client="$(cmux_attach_dogfood_client_id "$BUNDLE_ID" "$udid")"
  phone_launch_and_check "$udid" "$client" restored || return 1
  mac_sees_phone "$udid" || { PHONE_REASON="after the Mac relaunch, the tagged Mac does not list this phone as paired and connected"; return 1; }
}

# --- main ---------------------------------------------------------------------
# HEAD is the head of its branch on origin, or on a remote-tracking branch already fetched.
# Returns 0 pushed, 1 not pushed, 2 when origin did not answer (never read as "not pushed").
head_pushed() {
  local branch refs remote_head
  branch="$(git branch --show-current 2>/dev/null || true)"
  if [[ -n "$branch" ]]; then
    refs="$(remote_refs "$REPO_ROOT" origin "refs/heads/$branch")" || return 2
    remote_head="$(printf '%s\n' "$refs" | awk 'NF { print $1; exit }')"
    if [[ "$remote_head" == "$SHA" ]]; then
      # cmux-ci checks the head against remote-tracking branches; a clone that fetches only its base has none.
      [[ -n "$(git branch -r --contains "$SHA" 2>/dev/null)" ]] ||
        git fetch -q origin "refs/heads/$branch:refs/remotes/origin/$branch" 2>/dev/null || true
      return 0
    fi
  fi
  [[ -n "$(git branch -r --contains "$SHA" 2>/dev/null)" ]]
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag) TAG="${2:-}"; shift 2 ;;
      --device-id) REQUESTED_DEVICE_ID="${2:-}"; shift 2 ;;
      --target-worker) TARGET_WORKER="${2:-}"; shift 2 ;;
      --workspace) WORKSPACE="${2:-}"; shift 2 ;;
      --manual-pairing) [[ "$PHONE_MODE" == none ]] || PHONE_MODE=manual; shift ;;
      # --no-auth implies no pairing, whatever order the flags come in.
      --no-auth) PHONE_MODE=none; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "review.sh: unknown argument $1" >&2; usage >&2; exit 2 ;;
    esac
  done
  [[ -n "$TAG" ]] || { usage >&2; die "--tag is required"; }
  cmux_attach_validate_dev_tag "$TAG" || exit 2
  SLUG="$(cmux_attach__slug "$TAG")"
  BUNDLE_ID="dev.cmux.mobile.$SLUG"
  if ! xcrun --find devicectl >/dev/null 2>&1 && [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
  cd "$REPO_ROOT"
  SHA="$(git rev-parse HEAD)"
  # The Mac build's stream (cmux-ci build --workspace): the branch's PR, else this task's own name.
  [[ -n "$WORKSPACE" ]] || WORKSPACE="$(gh pr view --json url --jq .url 2>/dev/null || true)"
  [[ -n "$WORKSPACE" ]] || WORKSPACE="cmux-next-ios-review/$SLUG"
  [[ -z "$(git status --porcelain --ignore-submodules=untracked)" ]] || die "commit every change first: the fleet builds the pushed HEAD"
  local pushed_rc=0
  head_pushed || pushed_rc=$?
  case "$pushed_rc" in
    0) ;;
    2) die "origin did not answer whether HEAD ($SHA) is pushed; check the network and rerun" ;;
    *) die "push HEAD ($SHA) first: the fleet builds the pushed commit" ;;
  esac

  # The personal profile (physical iPhones); never the agent one, never printed.
  cmux_dev_secrets_load --profile personal >/dev/null || die "the personal sign-in profile is incomplete (scripts/setup-team-dev.sh)"
  PERSONAL_EMAIL="$CMUX_UITEST_STACK_EMAIL" PERSONAL_PASSWORD="$CMUX_UITEST_STACK_PASSWORD" PERSONAL_ACCOUNT="$CMUX_DEV_AUTH_ACCOUNT"
  unset CMUX_UITEST_STACK_EMAIL CMUX_UITEST_STACK_PASSWORD
  TAG_STATE="$HOME/Library/Application Support/cmux-dev/cnx-ios-builds/$SLUG"
  STATE="$TAG_STATE/$SHA"
  review_run
}

# Everything after the preflight (main): phones, fleet, Mac, each phone, the Mac relaunch, the report.
# Exits 1 when anything failed. Needs SLUG, SHA, STATE, BUNDLE_ID and the PERSONAL_* values.
review_run() {
  local default_file
  default_file="$(dirname "$REVIEW_PHONES_FILE")/iphone-device-id"
  DEFAULT_DEVICE_ID="$(head -n 1 "$default_file" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$TAG_STATE" ]] || TAG_STATE="$(dirname "$STATE")"
  # No connected phone is a blocker, but the Mac build, its publish and the fleet simulator check
  # still run, so the report has everything but the phone.
  if ! review_resolve_phones; then
    REVIEW_FAILED=1
    NO_PHONE=1
  else
    echo "==> installing on ${#REVIEW_TARGETS[@]} connected iPhone(s)"
  fi

  mkdir -p "$STATE"
  fleet_start_sim
  local mac_ok=1 ios_ok=1 target
  { fleet_submit_mac && fleet_finish_mac; } || mac_ok=0
  fleet_finish_sim || ios_ok=0
  [[ $ios_ok -eq 0 ]] || read_ios_artifact || ios_ok=0
  if [[ $NO_PHONE -eq 1 ]]; then
    finish || exit 1
  fi
  [[ $mac_ok -eq 0 ]] || { mac_install && mac_start; } || mac_ok=0
  if [[ $mac_ok -eq 0 || $ios_ok -eq 0 ]]; then
    REVIEW_FAILED=1
    for target in ${REVIEW_TARGETS[@]+"${REVIEW_TARGETS[@]}"}; do
      review_phone_result "${target#*$'\t'}: BLOCKED: nothing installed, the $([[ $ios_ok -eq 0 ]] && echo 'iPhone build' || echo 'tagged Mac') is not ready (see Dev build / Simulator); retry: $(retry_command)"
    done
    finish || exit 1
  fi

  local udid label lines=()
  for target in ${REVIEW_TARGETS[@]+"${REVIEW_TARGETS[@]}"}; do
    udid="${target%%$'\t'*}" label="${target#*$'\t'}"
    echo "==> iPhone $label"
    if phone_review "$udid" "$label"; then
      PASSED_PHONES+="$udid "
      lines+=("$udid"$'\t'"$PHONE_LINE")
    else
      REVIEW_FAILED=1
      lines+=("$udid"$'\t'"$label: BLOCKED: $PHONE_REASON; retry: $(retry_command)")
    fi
  done

  # The person's own Mac relaunch: quit the tagged app and start it again; every phone links again.
  # Only the paired hand-off has a link to prove across it.
  local restarted=1
  if [[ "$PASSED_PHONES" != " " && "$PHONE_MODE" == paired ]]; then
    echo "==> relaunching the tagged Mac app (quit as the person quits it, then open -g)"
    mac_restart || restarted=0
  fi
  local line
  for line in ${lines[@]+"${lines[@]}"}; do
    udid="${line%%$'\t'*}" line="${line#*$'\t'}"
    if passed "$udid" && [[ "$PHONE_MODE" == paired ]]; then
      if [[ $restarted -eq 0 ]]; then
        REVIEW_FAILED=1
        line="$line; BLOCKED: the tagged Mac app did not quit and start again; retry: $(retry_command)"
      elif phone_after_mac_restart "$udid"; then
        line="$line; after the Mac app relaunched: $PHONE_VERDICT"
      else
        REVIEW_FAILED=1
        line="$line; BLOCKED after the Mac app relaunched: $PHONE_REASON; retry: $(retry_command)"
      fi
    fi
    review_phone_result "$line"
  done
  finish || exit 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
