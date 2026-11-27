#!/usr/bin/env bash
# Put any pull request, branch or commit of the cmux-next iPhone app on your phone as "cmux Dev":
# the iPhone twin of `cmux app try PR` (cmuxterm-hq docs/design/ios-dev-channels.md).
#
#   cmux-next-ios/scripts/try.sh <PR number|PR URL|branch|sha|.> [--device-id UDID] [--target-worker W]
#       [--backend ORIGIN] [--sign-in] [--urgent] [--dry-run]
#   cmux-next-ios/scripts/try.sh status      what cmux Dev runs on each phone, and the last tries' times
#
# Leo, 2026-11-21: "what is a dev build of iPhone? ... if I want to just have a bunch of fucking YOLO
# patches in to my fucking app? Like how do I get them in?"
#
# cmux Dev is one app, bundle dev.cmux.mobile.dev, beside the INTERNAL TestFlight app and every tagged
# dev build. Every try installs over the last one, so its sign-in and its pairing with your NIGHTLY
# Mac stay: it has no dev tag (no X-Cmux-Build-Space), so it shows your real data, as the shared Demo
# build does. It is the Demo configuration (optimized, with Settings > Developer). No production push:
# that needs a TestFlight build (the INTERNAL app keeps it).
#
# In order, from a Mac with the phone attached (USB, or the same network once paired in Xcode):
#  1. Resolves the target to one pushed commit (a PR's head, a branch's tip; `.` is this checkout's
#     HEAD, which must be pushed).
#  2. Gets that commit's cmux Dev device app: from this Mac's cache, else one fleet simulator step
#     (scripts/ci/cmux-next-ios-sim.sh try: the unsigned device app alone, no simulator), keyed by
#     the commit, so a rerun or a second Mac reattaches to the same step. Nothing builds here.
#     A commit whose cmux-next-ios-sim.sh predates the try mode (read before sending) builds through
#     the older handoff mode with tag dev instead (same bundle id; it carries the dev:dev build space until the PR
#     takes feat-cmux-next with the try mode) and the report says so. A cold build waits in the
#     simulator queue (13+ min behind 30 steps on 2026-11-21); --urgent puts it first (cmux-ci run
#     --urgent, logged with a reason): only for the person waiting on their phone.
#  3. On every connected iPhone (scripts/lib/iphone-review-targets.sh; --device-id for one): signs a
#     copy with this Mac's Apple Development identity (sign_device_app.py: the team wildcard
#     profile covers dev.cmux.mobile.dev), installs it through the sanctioned install and launches
#     it. --sign-in launches it signed in with the `personal` profile (the first install needs it
#     once; later tries keep the session). --backend ORIGIN points it at another Cloud backend on
#     launch (a `preview-N`, a tailnet stack), as review.sh --backend does; the app keeps it.
#  4. Prints one line per phone with each phase's seconds, and appends the run to
#     ~/Library/Application Support/cmux-dev/cnx-ios-try/history.jsonl (`try.sh status` reads it).
#
# Exits 0 when every phone has the commit, 1 when a phone or the build failed, 2 on a usage error.
# Its Linux tests: python3 ios/tests/test_cnx_review.py (TryScriptTests).
set -euo pipefail

TRY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# review.sh's helpers (fleet, safe unzip, signing, the phones); its main does not run when sourced.
# shellcheck source=cmux-next-ios/scripts/review.sh
source "$TRY_SCRIPT_DIR/review.sh"

TRY_BUNDLE_ID=dev.cmux.mobile.dev
TRY_REPO="${CNX_TRY_REPO:-manaflow-ai/cmux}"
TRY_HOME="${CNX_TRY_HOME:-$HOME/Library/Application Support/cmux-dev/cnx-ios-try}"
TRY_URGENT=0 TRY_TARGET="" TRY_SIGN_IN=0 TRY_DRY_RUN=0 TRY_HOW="" TRY_NOTE=""

try_usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1' "$0"; }
try_die() { echo "try.sh: $*" >&2; exit 2; }
now_s() { /usr/bin/python3 -c 'import time; print(f"{time.time():.1f}")'; }
since() { /usr/bin/python3 -c "import sys,time; print(f'{time.time()-float(sys.argv[1]):.0f}')" "$1"; }

# The target as one full commit id, and words for the report (TRY_LABEL).
try_resolve() {
  local target="$1" n=""
  case "$target" in
    .)
      cd "$REPO_ROOT"
      [[ -z "$(git status --porcelain --ignore-submodules=untracked)" ]] || try_die "commit every change first: the fleet builds the pushed HEAD"
      SHA="$(git rev-parse HEAD)"
      head_pushed || try_die "push HEAD ($SHA) first: the fleet builds the pushed commit"
      TRY_LABEL="this checkout (${SHA:0:12})" ;;
    https://github.com/*/pull/*) n="${target##*/pull/}"; n="${n%%[/#?]*}" ;;
    \#[0-9]*|[0-9]|[0-9][0-9]|[0-9][0-9][0-9]|[0-9][0-9][0-9][0-9]|[0-9][0-9][0-9][0-9][0-9]|[0-9][0-9][0-9][0-9][0-9][0-9]) n="${target#\#}" ;;
    *)
      if [[ "$target" =~ ^[0-9a-f]{40}$ ]]; then
        SHA="$target" TRY_LABEL="commit ${SHA:0:12}"
      else
        SHA="$(git -C "$REPO_ROOT" ls-remote origin "refs/heads/$target" | awk 'NF { print $1; exit }')"
        [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || try_die "no branch '$target' on origin (give a PR number, a branch or a full commit id)"
        TRY_LABEL="branch $target (${SHA:0:12})"
      fi ;;
  esac
  if [[ -n "$n" ]]; then
    [[ "$n" =~ ^[0-9]+$ ]] || try_die "not a pull request number: $target"
    SHA="$(gh pr view "$n" -R "$TRY_REPO" --json headRefOid --jq .headRefOid 2>/dev/null)" ||
      try_die "could not read PR #$n's head (gh pr view $n -R $TRY_REPO)"
    [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || try_die "PR #$n has no head commit"
    TRY_LABEL="PR #$n (${SHA:0:12})"
  fi
}

# The fleet step for SHA: try (cmux Dev, device only), else handoff tag=dev for an older script.
try_fleet() {
  local mode="$1" args
  # The fallback's phone sits in dev:dev. That is no tagged build's space only while every tag entry point
  # (scripts/lib/mobile-attach.sh cmux_attach_validate_dev_tag: reload.sh, review.sh, the simulator handoff)
  # refuses the tag dev; were it a usable tag, a Mac tagged dev would take this phone for its own.
  [[ "$mode" != handoff ]] || cmux_attach_tag_reserved dev ||
    try_die "the handoff fallback builds cmux Dev in build space dev:dev, which only stays apart while tag dev is reserved (CMUX_ATTACH_RESERVED_TAGS in scripts/lib/mobile-attach.sh)"
  args=(run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref "$SHA" --artifact artifacts/ios-sim/evidence.zip
    --no-supersede --key "cnx-ios-try-$mode-${SHA:0:12}$(try_attempt_suffix "$mode")")
  # Through the controller's shots form until it lists the modes (cmux-next-ios-sim.sh header).
  if [[ "$mode" == try ]]; then args+=(--arg shots --arg try=dev); else args+=(--arg shots --arg handoff=dev); fi
  [[ -z "$TARGET_WORKER" ]] || args+=(--target-worker "$TARGET_WORKER")
  [[ $TRY_URGENT -eq 0 ]] || args+=(--urgent --reason "try.sh: $TRY_LABEL on the person's iPhone as cmux Dev; they are waiting")
  echo "==> cmux Dev for $TRY_LABEL: fleet step cmux-next-ios-sim.sh $mode (log: $STATE/fleet-$mode.log)"
  cmux_ci "${args[@]}" >"$STATE/fleet-$mode.log" 2>"$STATE/fleet-$mode.err"
}

# A failed step's key would hand back that failure on every rerun: each failure bumps the attempt.
try_attempt_suffix() {
  local n
  n="$(cat "$STATE/attempt-$1" 2>/dev/null || true)"
  [[ ! "$n" =~ ^[1-9][0-9]*$ ]] || printf -- '-r%s' "$n"
}
try_bump_attempt() {
  local n
  n="$(cat "$STATE/attempt-$1" 2>/dev/null || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s\n' "$((n + 1))" >"$STATE/attempt-$1"
}

# Which fleet mode SHA's cmux-next-ios-sim.sh has: try, or handoff for a commit from before it. An older
# script would read `shots try=dev` as a screenshot scene and build no device app, so it is read first:
# from this clone when it has the commit, else GitHub's contents API. Neither read: unknown, which fails clearly
# (guessing try would queue a step an older script turns into screenshots).
try_script_mode() {
  local text=""
  text="$(git -C "$REPO_ROOT" show "$SHA:scripts/ci/cmux-next-ios-sim.sh" 2>/dev/null)" ||
    text="$(gh api -H 'Accept: application/vnd.github.raw' \
      "repos/$TRY_REPO/contents/scripts/ci/cmux-next-ios-sim.sh?ref=$SHA" 2>/dev/null)" || text=""
  if [[ -z "$text" ]]; then echo unknown
  elif [[ "$text" != *'try=dev'* ]]; then echo handoff
  else echo try; fi
}

# One run per commit on this Mac: \$STATE (device.part, ios.zip, phone-*) is shared, so a second run for the
# same commit waits up to TRY_LOCK_WAIT seconds, then stops with the holder's pid. A holder that died is taken over.
try_lock() {
  local lock="$STATE.lock" waited=0 holder
  while ! mkdir "$lock" 2>/dev/null; do
    holder="$(cat "$lock/pid" 2>/dev/null || true)"
    if [[ "$holder" =~ ^[0-9]+$ ]] && ! kill -0 "$holder" 2>/dev/null; then
      rm -rf "$lock"; continue
    fi
    if (( waited >= ${TRY_LOCK_WAIT:-900} )); then
      try_die "another try.sh for $SHA is running on this Mac (pid ${holder:-unknown}, $lock); rerun when it ends"
    fi
    (( waited == 0 )) && echo "try.sh: another try.sh for $SHA is running (pid ${holder:-unknown}); waiting for it" >&2
    sleep 5; waited=$((waited + 5))
  done
  printf '%s\n' "$$" >"$lock/pid"
  trap 'rm -rf "$STATE.lock"' EXIT
}

# The unsigned cmux Dev app for SHA at $STATE/device/CmuxMobileApp.app (cached per commit).
try_get_app() {
  if [[ -d "$STATE/device/CmuxMobileApp.app" ]]; then
    TRY_HOW="cached on this Mac ($(cat "$STATE/how" 2>/dev/null || echo fleet))"
    return 0
  fi
  local mode step zip
  mode="$(try_script_mode)"
  if [[ "$mode" == unknown ]]; then
    TRY_FAIL="could not read $SHA's scripts/ci/cmux-next-ios-sim.sh (not in this clone, and GitHub's contents API did not answer), so its fleet mode is unknown; git fetch origin, or check gh auth, then rerun"
    return 1
  fi
  if [[ "$mode" == handoff ]]; then
    TRY_NOTE="built by the handoff mode (this commit's cmux-next-ios-sim.sh predates the try mode): cloud build space dev:dev, not your real data, until the PR takes feat-cmux-next"
  fi
  if ! try_fleet "$mode"; then
    try_bump_attempt "$mode"
    if grep -q "is not the reviewed version" "$STATE/fleet-$mode.err" "$STATE/fleet-$mode.log" 2>/dev/null; then
      TRY_FAIL="the fleet runs only a reviewed cmux-next-ios-sim.sh, and this commit's is not one (it changes the script); merge feat-cmux-next into the PR or try a commit whose script is on feat-cmux-next"
    else
      TRY_FAIL="the fleet build failed ($(tail -n 1 "$STATE/fleet-$mode.err" 2>/dev/null); $STATE/fleet-$mode.err)"
    fi
    return 1
  fi
  step="$(sed -n 's/^cmux-ci: step \([0-9a-f]\{24\}\).*/\1/p' "$STATE/fleet-$mode.err" | tail -n 1)"
  [[ -n "$step" ]] || { TRY_FAIL="the fleet printed no step id ($STATE/fleet-$mode.err)"; return 1; }
  rm -f "$STATE/ios.zip"
  cmux_ci artifact "$step" "$STATE/ios.zip" >/dev/null || { TRY_FAIL="step $step passed but its artifact did not download"; return 1; }
  safe_unzip "$STATE/ios.zip" "$STATE/ios" >/dev/null 2>&1 || { TRY_FAIL="step $step's artifact is not a safe zip"; return 1; }
  zip="$STATE/ios/CmuxMobileApp-Dev-device-unsigned.app.zip"
  [[ -f "$zip" ]] || zip="$STATE/ios/CmuxMobileApp-Demo-device-unsigned.app.zip"
  [[ -f "$zip" ]] || { TRY_FAIL="step $step's artifact has no device app ($mode mode)"; return 1; }
  # Unzip beside the cache and move it in only once the bundle id checks, so a run that dies midway never
  # leaves a partial or wrong app that the next run's cache check (a directory test) would install.
  rm -rf "$STATE/device.part"
  safe_unzip "$zip" "$STATE/device.part" >/dev/null 2>&1 || { rm -rf "$STATE/device.part"; TRY_FAIL="step $step's device app is not a safe zip"; return 1; }
  local bid
  bid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STATE/device.part/CmuxMobileApp.app/Info.plist" 2>/dev/null ||
    /usr/bin/python3 -I -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["CFBundleIdentifier"])' \
      "$STATE/device.part/CmuxMobileApp.app/Info.plist" 2>/dev/null || true)"
  [[ "$bid" == "$TRY_BUNDLE_ID" ]] || { rm -rf "$STATE/device.part"; TRY_FAIL="step $step built $bid, not $TRY_BUNDLE_ID"; return 1; }
  rm -rf "$STATE/device" && mv "$STATE/device.part" "$STATE/device"
  printf 'fleet step %s, %s mode\n' "$step" "$mode" >"$STATE/how"
  [[ -z "$TRY_NOTE" ]] || printf '%s\n' "$TRY_NOTE" >"$STATE/note"
  TRY_HOW="fleet step $step ($mode mode)"
}

# Sign, install and launch on one phone; TRY_LINE or TRY_REASON.
try_phone() {
  local udid="$1" label="$2" app t sign_s install_s launch_s
  TRY_REASON=""
  app="$STATE/phone-$udid/CmuxMobileApp.app"
  rm -rf "$STATE/phone-$udid"
  mkdir -p "$STATE/phone-$udid"
  ditto "$STATE/device/CmuxMobileApp.app" "$app"
  t="$(now_s)"
  if ! sign_app --app "$app" --checkout "$REPO_ROOT" --team "$TEAM" --device "$udid" \
      >"$STATE/phone-$udid/signed.json" 2>"$STATE/phone-$udid/sign.err"; then
    TRY_REASON="signing failed: $(sed 's/^sign_device_app: //' "$STATE/phone-$udid/sign.err" | tail -n 1)"
    return 1
  fi
  sign_s="$(since "$t")"; t="$(now_s)"
  "$REPO_ROOT/scripts/ios-device-process.sh" terminate-installed --device-id "$udid" --bundle-id "$TRY_BUNDLE_ID" >/dev/null 2>&1 || true
  # The sanctioned install: the marker lets the local-build-guards devicectl interceptor tell it from a raw install.
  if ! CMUX_SANCTIONED_IPHONE_INSTALL=1 xcrun devicectl device install app --device "$udid" "$app" \
      >"$STATE/phone-$udid/install.log" 2>&1; then
    TRY_REASON="install failed ($(tail -n 1 "$STATE/phone-$udid/install.log"); locked, or Developer Mode off?)"
    return 1
  fi
  install_s="$(since "$t")"; t="$(now_s)"
  if ! (
    unset DEVICECTL_CHILD_CMUX_MOBILE_STACK_EMAIL DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD DEVICECTL_CHILD_CMUX_NEXT_CLOUD_BACKEND
    [[ -z "$BACKEND_URL" ]] || export DEVICECTL_CHILD_CMUX_NEXT_CLOUD_BACKEND="$BACKEND_URL"
    # In the environment, never on a command line (ps would show it).
    if [[ $TRY_SIGN_IN -eq 1 ]]; then
      export DEVICECTL_CHILD_CMUX_MOBILE_STACK_EMAIL="$PERSONAL_EMAIL" DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD="$PERSONAL_PASSWORD"
    fi
    exec xcrun devicectl device process launch --terminate-existing --device "$udid" "$TRY_BUNDLE_ID" >/dev/null 2>&1
  ); then
    TRY_REASON="installed, but it did not launch (is the phone locked? unlock it and open cmux Dev)"
    return 1
  fi
  launch_s="$(since "$t")"
  TRY_LINE="$label: cmux Dev at $TRY_LABEL, installed and launched (sign ${sign_s} s, install ${install_s} s, launch ${launch_s} s)"
}

try_record() {
  local result="$1" total="$2" build="$3" phones="$4"
  mkdir -p "$TRY_HOME"
  /usr/bin/python3 -I - "$TRY_HOME/history.jsonl" "$result" "$total" "$build" "$phones" "$SHA" "$TRY_LABEL" "$TRY_HOW" <<'PY'
import json, sys, time
path, result, total, build, phones, sha, label, how = sys.argv[1:]
row = {"schema": "cmux.ios-try.run.v1", "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "result": result,
       "sha": sha, "target": label, "how": how, "total_s": float(total), "build_s": float(build), "phones": int(phones)}
with open(path, "a") as f:
    f.write(json.dumps(row) + "\n")
PY
}

try_status() {
  local hist="$TRY_HOME/history.jsonl"
  [[ -f "$hist" ]] || { echo "no tries yet on this Mac ($hist)"; return 0; }
  /usr/bin/python3 -I - "$hist" <<'PY'
import json, statistics, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
for r in rows[-10:]:
    print(f"{r['at']}  {r['result']:4}  {r['total_s']:>6.0f} s total, {r['build_s']:>6.0f} s build  {r['target']}  ({r['how']})")
ok = [r for r in rows if r["result"] == "ok"]
for name, sel in (("built ahead or cached", [r for r in ok if r["how"].startswith("cached")]),
                  ("cold (fleet build)", [r for r in ok if not r["how"].startswith("cached")])):
    if sel:
        t = sorted(r["total_s"] for r in sel)
        print(f"{name}: n={len(t)} p50={statistics.median(t):.0f} s max={t[-1]:.0f} s")
PY
}

try_main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device-id) REQUESTED_DEVICE_ID="${2:-}"; shift 2 ;;
      --target-worker) TARGET_WORKER="${2:-}"; shift 2 ;;
      --backend) BACKEND_ARG="${2:-}"; [[ -n "$BACKEND_ARG" ]] || try_die "--backend needs a value"; shift 2 ;;
      --sign-in) TRY_SIGN_IN=1; shift ;;
      --urgent) TRY_URGENT=1; shift ;;
      --dry-run) TRY_DRY_RUN=1; shift ;;
      -h|--help|help) try_usage; exit 0 ;;
      status) try_status; exit 0 ;;
      -*) echo "try.sh: unknown flag $1" >&2; try_usage >&2; exit 2 ;;
      *) [[ -z "$TRY_TARGET" ]] || try_die "one target at a time (got '$TRY_TARGET' and '$1')"; TRY_TARGET="$1"; shift ;;
    esac
  done
  [[ -n "$TRY_TARGET" ]] || { try_usage >&2; try_die "name a PR, branch or commit"; }
  SLUG=dev
  if ! xcrun --find devicectl >/dev/null 2>&1 && [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
  local t0 tb build_s
  t0="$(now_s)"
  try_resolve "$TRY_TARGET"
  review_resolve_backend
  STATE="$TRY_HOME/$SHA"
  if [[ $TRY_DRY_RUN -eq 1 ]]; then
    echo "try.sh: would put $TRY_LABEL on every connected iPhone as cmux Dev ($TRY_BUNDLE_ID); cache $STATE"
    exit 0
  fi
  if [[ $TRY_SIGN_IN -eq 1 ]]; then
    cmux_dev_secrets_load --profile personal >/dev/null || try_die "--sign-in: the personal sign-in profile is incomplete (scripts/setup-team-dev.sh)"
    PERSONAL_EMAIL="$CMUX_UITEST_STACK_EMAIL" PERSONAL_PASSWORD="$CMUX_UITEST_STACK_PASSWORD"
    unset CMUX_UITEST_STACK_EMAIL CMUX_UITEST_STACK_PASSWORD
  fi
  mkdir -p "$STATE"
  try_lock
  local default_file
  default_file="$(dirname "$REVIEW_PHONES_FILE")/iphone-device-id"
  DEFAULT_DEVICE_ID="$(head -n 1 "$default_file" 2>/dev/null | tr -d '[:space:]' || true)"
  REVIEW_CALLER="cmux-next-ios/scripts/try.sh"
  # The phones first: no phone is reported at once, but the build still runs (built ahead for later).
  local have_phones=1
  review_resolve_phones || have_phones=0
  tb="$(now_s)"
  TRY_FAIL=""
  if ! try_get_app; then
    echo "cmux Dev: BLOCKED: $TRY_FAIL; retry: cmux-next-ios/scripts/try.sh $TRY_TARGET"
    try_record fail "$(since "$t0")" "$(since "$tb")" 0
    exit 1
  fi
  build_s="$(since "$tb")"
  [[ -n "$TRY_NOTE" ]] || TRY_NOTE="$(cat "$STATE/note" 2>/dev/null || true)"
  echo "==> cmux Dev for $TRY_LABEL: $TRY_HOW, ${build_s} s"
  if [[ $have_phones -eq 0 || ${#REVIEW_TARGETS[@]} -eq 0 ]]; then
    echo "cmux Dev: built ($TRY_HOW), but BLOCKED: no connected iPhone; connect and unlock one, then rerun: cmux-next-ios/scripts/try.sh $TRY_TARGET"
    try_record nophone "$(since "$t0")" "$build_s" 0
    exit 1
  fi
  local target udid label failed=0 n=0 lines=()
  for target in "${REVIEW_TARGETS[@]}"; do
    udid="${target%%$'\t'*}" label="${target#*$'\t'}"
    if try_phone "$udid" "$label"; then
      lines+=("$TRY_LINE"); n=$((n + 1))
    else
      lines+=("$label: BLOCKED: $TRY_REASON; retry: cmux-next-ios/scripts/try.sh $TRY_TARGET --device-id $udid"); failed=1
    fi
  done
  local total
  total="$(since "$t0")"
  echo "==> cmux Dev: $TRY_LABEL in ${total} s (build ${build_s} s: $TRY_HOW)"
  [[ -z "$TRY_NOTE" ]] || echo "    note: $TRY_NOTE"
  [[ -z "$BACKEND_URL" ]] || echo "    backend: $BACKEND_REPORT"
  for label in "${lines[@]}"; do echo "iPhone: $label"; done
  try_record "$([[ $failed -eq 0 ]] && echo ok || echo fail)" "$total" "$build_s" "$n"
  [[ $failed -eq 0 ]]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  try_main "$@"
fi
