#!/usr/bin/env bash
# The end-of-task hand-off of the cmux-next iPhone app (AGENTS.md "Finishing a task"): one
# command, run by an agent at a pushed head, that leaves the task's build on every connected
# iPhone signed in and paired with the same-tag cmux NEXT Mac build, and proves it.
#
#   cmux-next-ios/scripts/review.sh --tag <task-slug> [--device-id <udid>] [--target-worker <worker>]
#       [--workspace <PR URL>]   (default: the branch's PR, else cmux-next-ios-review/<task-slug>)
#
# In order (each phone's failure is its own blocker; the others go on):
#  1. Fleet, at the pushed HEAD: the tagged Mac dev build (`cmux-ci build cmux`, then
#     `cmux-ci publish-hq`, Tag Opener http://127.0.0.1:17320/<tag>) and, in one simulator step,
#     the iPhone app (scripts/ci/cmux-next-ios-sim.sh handoff: Demo configuration with the DEBUG
#     developer surface, bundle dev.cmux.mobile.<tag>, display name "cmux <tag>", an unsigned
#     device app) plus the fleet simulator check: signed in with the worker's agent account, then
#     relaunched with no credentials and signed in from its own Keychain, with screenshots and a
#     recording. --target-worker pins that step (a worker with the agent account file).
#     Job ids are saved: rerunning the same command resumes them.
#  2. This Mac: installs the tagged Mac app where ios-reload.py and verify-iphone-auth.sh look for
#     it, launches it in the background (`open -g`, never taking focus) and waits until it is
#     signed in to the `personal` account. iPhone connections must already be on (Settings >
#     Mobile); this never turns them on.
#  3. Every connected, paired iPhone (scripts/lib/iphone-review-targets.sh; a new phone is
#     registered in ~/.config/cmux/iphone-device-ids): signs a copy of the app with this Mac's
#     Apple Development identity and a development profile naming the phone
#     (sign_device_app.py), installs it through the sanctioned install
#     (CMUX_SANCTIONED_IPHONE_INSTALL), and launches it with the personal account
#     (DEVICECTL_CHILD_CMUX_MOBILE_STACK_*) and the Mac's single-use pairing code
#     (DEVICECTL_CHILD_CMUX_MOBILE_PAIR_URL: the code a scan would open; no Allow prompt, no seed).
#  4. Proves each phone, from the app's DEBUG readiness receipt (handoff_receipt.py; a fresh nonce
#     per launch, so an old receipt never passes): signed in and paired and linked with this tag's
#     Mac (its cmux-mobile-host device id); the Mac lists a paired, connected phone; then a
#     credential-free relaunch (no account, no code, as the person's own cold launch) comes back
#     signed in from its own session and linked again; then the tagged Mac app quits as the person
#     quits it and starts again (`open -g`), and one more credential-free relaunch of each phone is
#     linked to it again.
#  5. Prints the report (AGENTS.md format). Exit 0 only when every phone passed every check;
#     no connected phone is a failure too.
#
# Never builds, boots a simulator or compiles on this Mac. Credentials stay in
# ~/.secrets/cmuxterm-dev.env (personal profile) and are never printed.
#
# Tests: python3 ios/tests/test_cnx_review.py
set -euo pipefail

usage() { sed -n '2,43p' "$0"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEAM=7WLXT3NR37
TAG="" SLUG="" DEVICE_ID="" TARGET_WORKER="" WORKSPACE=""

# shellcheck source=scripts/lib/mobile-attach.sh
source "$REPO_ROOT/scripts/lib/mobile-attach.sh"
# shellcheck source=scripts/lib/dev-secrets.sh
source "$REPO_ROOT/scripts/lib/dev-secrets.sh"
# shellcheck source=scripts/lib/iphone-review-targets.sh
source "$REPO_ROOT/scripts/lib/iphone-review-targets.sh"

REVIEW_CALLER="cmux-next-ios/scripts/review.sh"
REVIEW_PHONES_FILE="${CMUX_CONFIG_DIR:-$HOME/.config/cmux}/iphone-device-ids"
REVIEW_TARGETS=()
REVIEW_FAILED=0
REVIEW_PHONE_STATUS=""
DEFAULT_DEVICE_ID=""
REPORT_MAC="not built"
REPORT_SIM="not run"
MAC_JOB="" SIM_STEP="" SHA=""
STATE="" MAC_APP="" MAC_SOCKET="" MAC_DEVICE_ID=""
PASSED_PHONES=()

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
  [[ $first -eq 0 ]] || printf 'iPhone:     BLOCKED: no connected iPhone; connect and unlock one, then rerun: %s\n' "$(retry_command)"
}

retry_command() {
  printf 'cmux-next-ios/scripts/review.sh --tag %s' "$SLUG"
  [[ -z "$TARGET_WORKER" ]] || printf ' --target-worker %s' "$TARGET_WORKER"
}

finish() {
  review_report
  [[ "$REVIEW_FAILED" -eq 0 && "${#PASSED_PHONES[@]}" -gt 0 ]]
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
  local args=(run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref "$SHA"
    --arg shots --arg "handoff=$SLUG" --artifact artifacts/ios-sim/evidence.zip
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

# Unzip DIR's archive into a fresh directory, refusing absolute paths, `..` and links out of it.
safe_unzip() {
  local zip="$1" dest="$2"
  rm -rf "$dest"
  /usr/bin/python3 -I - "$zip" <<'PY' || return 1
import stat, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    for i in z.infolist():
        parts = i.filename.split("/")
        if i.filename.startswith("/") or ".." in parts:
            raise SystemExit(f"unsafe path in {sys.argv[1]}: {i.filename}")
PY
  ditto -x -k "$zip" "$dest"
}

# The simulator verdict and the device app from the step's artifact.
read_ios_artifact() {
  safe_unzip "$STATE/ios.zip" "$STATE/ios" || { REPORT_SIM="BLOCKED: the iPhone artifact is not a safe zip"; return 1; }
  local manifest="$STATE/ios/handoff.json" check
  check="$(/usr/bin/python3 -I - "$manifest" "$SLUG" "$SHA" "dev.cmux.mobile.$SLUG" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
want = {"kind": "cmux-next-ios-handoff", "tag": sys.argv[2], "source_sha": sys.argv[3], "bundle_id": sys.argv[4]}
bad = [k for k, v in want.items() if m.get(k) != v]
if bad:
    raise SystemExit("handoff.json does not match this run: " + ", ".join(bad))
s = m.get("simulator") or {}
print("\t".join([s.get("status", ""), m.get("host", ""), s.get("device", ""), s.get("reason", "")]))
PY
)" || { REPORT_SIM="BLOCKED: $check"; return 1; }
  local status host device reason dir
  IFS=$'\t' read -r status host device reason <<<"$check"
  dir="$STATE/ios"
  if [[ "$status" == pass ]]; then
    REPORT_SIM="fleet simulator ($host, $device), signed in (agent account), restored after a credential-free relaunch: $dir (screens/signed-in-auto_login.png, screens/signed-in-restored.png, recording.mp4; step $SIM_STEP)"
  else
    REPORT_SIM="BLOCKED: fleet simulator check on $host failed: ${reason:-unknown}; evidence $dir; retry: $(retry_command)"
    REVIEW_FAILED=1
  fi
  safe_unzip "$STATE/ios/CmuxMobileApp-Demo-device-unsigned.app.zip" "$STATE/device" ||
    { REVIEW_FAILED=1; return 1; }
  [[ -d "$STATE/device/CmuxMobileApp.app" ]]
}

# --- the tagged Mac -----------------------------------------------------------
mac_py() { /usr/bin/python3 -I "$SCRIPT_DIR/review_mac.py" "$@"; }

# Install the fleet Mac app at the tag's path (ios-reload.py's install_mac, verify-iphone-auth.sh).
mac_install() {
  safe_unzip "$STATE/cmux.zip" "$STATE/mac" || { REPORT_MAC="BLOCKED: the Mac artifact is not a safe zip"; return 1; }
  local built
  built="$(find "$STATE/mac" -maxdepth 3 -name 'cmux DEV *.app' -type d | head -n 1)"
  [[ -n "$built" ]] || { REPORT_MAC="BLOCKED: fleet job $MAC_JOB has no cmux DEV app"; return 1; }
  MAC_APP="$(cmux_attach_mac_app_path "$SLUG")"
  if [[ -d "$MAC_APP" ]]; then
    if [[ "$(cat "$STATE/mac-installed" 2>/dev/null)" != "$MAC_JOB" ]]; then
      REPORT_MAC="BLOCKED: $SLUG already has another build installed for this tag; choose a new tag"
      return 1
    fi
  else
    mkdir -p "$(dirname "$MAC_APP")"
    ditto "$built" "$MAC_APP"
    printf '%s\n' "$MAC_JOB" >"$STATE/mac-installed"
  fi
  MAC_SOCKET="$(mac_py socket "$MAC_APP")" || MAC_SOCKET="$(cmux_attach_socket_path "$SLUG")"
}

# Launch it in the background (never frontmost) unless it runs, and wait for the personal account.
mac_start() {
  if ! mac_py wait-socket "$MAC_SOCKET" --timeout 2; then
    echo "==> launching the tagged Mac app in the background"
    open -g --env CMUX_NEXT_NO_ACTIVATE=1 "$MAC_APP" ||
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
  MAC_DEVICE_ID="$(mac_py device-id "$(mac_py bundle "$MAC_APP")")" ||
    { REPORT_MAC="$REPORT_MAC; BLOCKED: the tagged Mac app has no cmux-mobile-host device id (iPhone host not running)"; return 1; }
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
# One launch of the app on PHONE and its receipt. Args: udid client session(auto_login|restored) [pair-url].
# Credentials go in the environment of this one call only; a restored launch carries none.
phone_launch_and_check() {
  local udid="$1" client="$2" session="$3" pair_url="${4:-}" nonce rc=0
  nonce="$(cmux_attach_readiness_nonce)"
  # In a subshell's environment, never on a command line (ps would show it).
  if ! (
    unset DEVICECTL_CHILD_CMUX_MOBILE_STACK_EMAIL DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD DEVICECTL_CHILD_CMUX_MOBILE_PAIR_URL
    export DEVICECTL_CHILD_CMUX_DOGFOOD_READINESS_NONCE="$nonce" DEVICECTL_CHILD_CMUX_DOGFOOD_CLIENT_ID="$client"
    if [[ "$session" == auto_login ]]; then
      export DEVICECTL_CHILD_CMUX_MOBILE_STACK_EMAIL="$PERSONAL_EMAIL" DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD="$PERSONAL_PASSWORD"
      [[ -z "$pair_url" ]] || export DEVICECTL_CHILD_CMUX_MOBILE_PAIR_URL="$pair_url"
    fi
    exec xcrun devicectl device process launch --terminate-existing --device "$udid" "$BUNDLE_ID" >/dev/null 2>&1
  ); then
    PHONE_REASON="could not launch the app ($session; is the phone locked? unlock it)"
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
        --mac-id "$MAC_DEVICE_ID")" || rc=$?
      [[ $rc -eq 1 ]] || break
    else
      rc=1 verdict="no readiness receipt yet"
    fi
    (( SECONDS < deadline )) || break
    sleep 3
  done
  rm -f "$receipt"
  if [[ $rc -ne 0 ]]; then
    PHONE_REASON="$session launch: $verdict (after ${CNX_REVIEW_RECEIPT_TIMEOUT:-180} s)"
    return 1
  fi
  PHONE_VERDICT="$verdict"
}

# The Mac sees a paired, connected phone (hostd's own list).
mac_sees_phone() {
  local i count
  for i in $(seq 1 20); do
    count="$(mac_py phones "$MAC_SOCKET" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["paired_connected"])' 2>/dev/null || echo 0)"
    [[ "$count" -ge 1 ]] && return 0
    sleep 3
  done
  return 1
}

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
  if ! signed="$(/usr/bin/python3 -I "$SCRIPT_DIR/sign_device_app.py" --app "$app" --checkout "$REPO_ROOT" \
      --team "$TEAM" --device "$udid" 2>"$STATE/phone-$udid/sign.err")"; then
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
  local pair_err="$STATE/phone-$udid/pair-url.err"
  pair_url="$(mac_py pair-url "$MAC_SOCKET" --timeout 90 --used "$STATE/used-codes" 2>"$pair_err")" ||
    { PHONE_REASON="no pairing code from the tagged Mac: $(tail -n 1 "$pair_err")"; return 1; }
  phone_launch_and_check "$udid" "$client" auto_login "$pair_url" || return 1
  pair_url=""
  local first="$PHONE_VERDICT"
  mac_sees_phone || { PHONE_REASON="the tagged Mac lists no paired, connected phone"; return 1; }
  phone_launch_and_check "$udid" "$client" restored || return 1
  PHONE_LINE="$label: installed, $first; Mac sees it paired and connected; credential-free relaunch: $PHONE_VERDICT"
}

phone_after_mac_restart() {
  local udid="$1" client
  client="$(cmux_attach_dogfood_client_id "$BUNDLE_ID" "$udid")"
  phone_launch_and_check "$udid" "$client" restored || return 1
  mac_sees_phone || { PHONE_REASON="after the Mac relaunch, the tagged Mac lists no paired, connected phone"; return 1; }
}

# --- main ---------------------------------------------------------------------
# HEAD is the head of its branch on origin, or on a remote-tracking branch already fetched.
head_pushed() {
  local branch remote_head
  branch="$(git branch --show-current 2>/dev/null || true)"
  if [[ -n "$branch" ]]; then
    remote_head="$(git ls-remote origin "refs/heads/$branch" 2>/dev/null | awk '{ print $1 }')"
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
      --device-id) DEVICE_ID="${2:-}"; shift 2 ;;
      --target-worker) TARGET_WORKER="${2:-}"; shift 2 ;;
      --workspace) WORKSPACE="${2:-}"; shift 2 ;;
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
  head_pushed || die "push HEAD ($SHA) first: the fleet builds the pushed commit"

  # The personal profile (physical iPhones); never the agent one, never printed.
  cmux_dev_secrets_load --profile personal >/dev/null || die "the personal sign-in profile is incomplete (scripts/setup-team-dev.sh)"
  PERSONAL_EMAIL="$CMUX_UITEST_STACK_EMAIL" PERSONAL_PASSWORD="$CMUX_UITEST_STACK_PASSWORD" PERSONAL_ACCOUNT="$CMUX_DEV_AUTH_ACCOUNT"
  unset CMUX_UITEST_STACK_EMAIL CMUX_UITEST_STACK_PASSWORD
  STATE="$HOME/Library/Application Support/cmux-dev/cnx-ios-builds/$SLUG/$SHA"
  review_run
}

# Everything after the preflight (main): phones, fleet, Mac, each phone, the Mac relaunch, the report.
# Exits 1 when anything failed. Needs SLUG, SHA, STATE, BUNDLE_ID and the PERSONAL_* values.
review_run() {
  local default_file
  default_file="$(dirname "$REVIEW_PHONES_FILE")/iphone-device-id"
  DEFAULT_DEVICE_ID="$(head -n 1 "$default_file" 2>/dev/null | tr -d '[:space:]' || true)"
  if ! review_resolve_phones; then
    REVIEW_FAILED=1
    finish || exit 1
  fi
  echo "==> installing on ${#REVIEW_TARGETS[@]} connected iPhone(s)"

  mkdir -p "$STATE"
  fleet_start_sim
  local mac_ok=1 ios_ok=1
  { fleet_submit_mac && fleet_finish_mac; } || mac_ok=0
  fleet_finish_sim || ios_ok=0
  [[ $ios_ok -eq 0 ]] || read_ios_artifact || ios_ok=0
  [[ $mac_ok -eq 0 ]] || { mac_install && mac_start; } || mac_ok=0
  if [[ $mac_ok -eq 0 || $ios_ok -eq 0 ]]; then
    REVIEW_FAILED=1
    local target
    for target in "${REVIEW_TARGETS[@]}"; do
      review_phone_result "${target#*$'\t'}: BLOCKED: nothing installed, the $([[ $ios_ok -eq 0 ]] && echo 'iPhone build' || echo 'tagged Mac') is not ready (see Dev build / Simulator); retry: $(retry_command)"
    done
    finish || exit 1
  fi

  local target udid label lines=()
  for target in "${REVIEW_TARGETS[@]}"; do
    udid="${target%%$'\t'*}" label="${target#*$'\t'}"
    echo "==> iPhone $label"
    if phone_review "$udid" "$label"; then
      PASSED_PHONES+=("$udid")
      lines+=("$udid"$'\t'"$PHONE_LINE")
    else
      REVIEW_FAILED=1
      lines+=("$udid"$'\t'"$label: BLOCKED: $PHONE_REASON; retry: $(retry_command)")
    fi
  done

  # The person's own Mac relaunch: quit the tagged app and start it again; every phone links again.
  local restarted=1
  if [[ ${#PASSED_PHONES[@]} -gt 0 ]]; then
    echo "==> relaunching the tagged Mac app (quit as the person quits it, then open -g)"
    mac_restart || restarted=0
  fi
  local line
  for line in "${lines[@]}"; do
    udid="${line%%$'\t'*}" line="${line#*$'\t'}"
    if [[ " ${PASSED_PHONES[*]} " == *" $udid "* ]]; then
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
