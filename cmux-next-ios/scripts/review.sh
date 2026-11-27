#!/usr/bin/env bash
# The end-of-task hand-off of the cmux-next iPhone app (the root CLAUDE.md "Finishing a task"
# rule; details in cmux-next-ios/CLAUDE.md): one command, run by an agent at a pushed head, that leaves the task's build on every connected
# iPhone signed in and paired with the same-tag cmux NEXT Mac build, and proves it.
#
#   cmux-next-ios/scripts/review.sh --tag <task-slug> [--device-id <udid>] [--target-worker <worker>]
#       [--workspace <PR URL>]   (default: the branch's PR, else cmux-next-ios-review/<task-slug>)
#       [--manual-pairing | --approve-first | --no-auth] [--backend <origin|tag-stack|dev>] [--forbid-tailnet] [--urgent]
#
# --urgent: a person waits on the phone now. The iPhone step goes ahead of the simulator queue
#   (cmux-ci run --urgent) and the Mac build moves up the Mac queue (cmux-ci promote), each logged with
#   the reason "review.sh --urgent: a person waits ...". Not for an agent's own end-of-task run.
#
# --backend: the Cloud backend this tag's Mac and iPhone builds talk to, chosen at launch, no rebuild.
#   (none)        this tag's own stack (the default): `cloud-dev-stack.sh up --tag <tag>` brings it up
#                 or re-ups it with this checkout's backend code, beside the fleet builds, then both
#                 apps point at it as with tag-stack. An up that fails falls back to the shared dev
#                 Workers, and the Backend line says why (the hand-off still finishes).
#   dev           the shared dev Workers deployment: a backend.json an earlier run left is removed, and
#                 the phone's kept override cleared; no stack is touched
#   tag-stack     this tag's stack as it is now (no up; it must exist): its origin from
#                 scripts/cmux-next/cloud-dev-stack.sh url --tag <tag> (CNX_CLOUD_DEV_STACK names
#                 another command). The stack runs the tag's API, mobile Worker and device hub; both
#                 apps use all three from the one origin (the Mac from its client-config, the phone
#                 from the next two ports, or its public origin's slot hosts), and the phone's receipt
#                 must name the stack's mobile Worker. The Mac takes the tailnet origin; the phone the
#                 public one (https://api.s<N>.wdev.cmux.dev, off the tailnet too) when the stack has it.
#   <origin>      https://<machine>.tail137216.ts.net[:port], https://api.s<N>.wdev.cmux.dev,
#                 `preview-N`, or the dev Workers API origin.
#                 Anything else is refused before any build (review_mac.py backend-check; the apps
#                 refuse it too, and Release builds ignore every override).
#   The Mac gets ~/Library/Application Support/cmux-next/<bundle id>/backend.json, which every launch
#   of that tag reads (the Tag Opener's too: one link for both); the phone gets
#   CMUX_NEXT_CLOUD_BACKEND on its first launch and keeps it. The report's Backend line says which
#   backend each app reports it uses (the Mac's `auth.status`, the phone's readiness receipt).
#
# The default is the hand-off every dev build must reach: signed in (personal account) and paired
# with the same-tag Mac at once, and still both after the person relaunches the app or the Mac.
#   --manual-pairing  signed in as usual, but the phone is not told which Mac to focus: the person
#                     picks and pairs by hand, to dogfood pairing. The
#                     proof keeps the sign-in checks (and the credential-free relaunch) and drops
#                     the paired ones and the Mac relaunch. "pairing left to you (--manual-pairing)".
#   --approve-first   signed in as usual, and the tagged Mac launched with
#                     CMUX_NEXT_IPHONE_APPROVE_FIRST=1 (its dev auto-approve off; a Mac of the tag
#                     that already runs is quit first): the phone picks the tagged Mac and asks, and
#                     the Mac shows "Allow “<phone>” (<key>) to connect to this Mac?". The proof: the
#                     receipt names the tagged Mac; the Mac itself shows the request and the prompt
#                     (review_mac.py allow-state); the report says so, with the Mac's name and app,
#                     before it waits for the person's Allow (CNX_REVIEW_ALLOW_TIMEOUT, default 600 s);
#                     once the Mac lists the phone as paired, a credential-free relaunch is linked
#                     and the Mac lists it paired and connected (no Mac relaunch). Unattended, the
#                     phone's line says where the prompt waits and what to do next. A phone the
#                     tag's Mac paired before is not asked again: that is reported, not passed
#                     (remove it in the Mac's Settings > Mobile first).
#   --no-auth         no credentials and no Mac named; the first launch carries the DEBUG-only
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
#     device app) plus the fleet simulator check: signed in with the agent account's session, then
#     relaunched with no credentials and signed in from its own Keychain, with screenshots and a
#     recording. The step is sent with --sign-in agent: the session comes from this Mac (it signs
#     the shared agent account in for this step alone, seals it to the worker, and revokes it when
#     the step ends), not from a worker account file, so any simulator worker can take it;
#     --target-worker pins it. cmux-ci run follows the step, which is how the session is delivered. Job ids are saved:
#     rerunning the same command resumes them. With no connected phone the fleet legs still run,
#     and the phone is the reported blocker.
#  2. This Mac: installs the tagged Mac app where ios-reload.py and verify-iphone-auth.sh look for
#     it (a new head of the same tag replaces this tool's earlier install, quitting it first;
#     another workflow's install of the tag is never touched), launches it in the background
#     (`open -g` with an empty environment, never taking focus) and waits until it is signed in
#     to the `personal` account and its iPhone host is up (Settings' `iphone` card names its device
#     id). iPhone connections (`mobile.allowIPhoneConnections`, on by default) live in the shared
#     ~/.config/cmux/cmux-next.json that every build reads, so a fresh tag has the person's choice;
#     when they turned it off this reports it and never turns it on.
#  3. Every connected, paired iPhone of this Mac's person (scripts/lib/iphone-review-targets.sh: a
#     phone this Mac does not know that it reaches only over Wi-Fi, such as a teammate's test phone
#     in the room, is skipped; a new phone plugged in by USB is registered in
#     ~/.config/cmux/iphone-device-ids; a --device-id phone that is missing is a
#     blocker, a missing default a notice): signs a copy of the app with this Mac's Apple
#     Development identity and, per bundle, a development profile naming the phone
#     (sign_device_app.py), installs it through the sanctioned install
#     (CMUX_SANCTIONED_IPHONE_INSTALL), and launches it with the personal account
#     (DEVICECTL_CHILD_CMUX_MOBILE_STACK_*) and the tagged Mac to focus (DEVICECTL_CHILD_CMUX_MOBILE_FOCUS_MAC,
#     its iPhone-host device id: no secret, and it picks a Mac only, as a tap in the Macs list does). The
#     phone pairs on its own; the tagged Mac's DEBUG dev auto-approve allows its own tag's phone
#     (SECURITY.md "Dev auto-approve"): no Allow prompt, no seed, no code.
#  4. Proves each phone, from the app's DEBUG readiness receipt (handoff_receipt.py; a fresh nonce
#     per launch, so an old receipt never passes; the build's commit and tag must be this run's):
#     signed in and paired and linked with this tag's Mac (its iPhone-host device id, `review_mac.py mac-id`);
#     the Mac lists this phone (one of its device ids) as paired and connected; then a
#     credential-free relaunch (no account, no Mac named, as the person's own cold launch) comes back
#     signed in from its own session and linked again; then the tagged Mac app quits as the person
#     quits it and starts again (`open -g`), and one more credential-free relaunch of each phone is
#     linked to it again. Between the two, the relay-only relaunch: credential-free with only
#     DEVICECTL_CHILD_CMUX_MOBILE_DEV_RELAY_ONLY=1 (the Rust link skips every direct path), which must
#     link via TURN, the path a phone away from home takes.
#     Every verdict names the link's transport and path (the receipt's DogfoodReadiness.Route):
#     "over WireGuard, direct LAN", "direct over the tailnet", "direct over the internet", "via TURN".
#     The person's iPhone and Mac may both run Tailscale, so a link at home can ride the tailnet,
#     which no user without Tailscale gets; --forbid-tailnet makes a tailnet path a failure.
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

usage() { awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEAM=7WLXT3NR37
TAG="" SLUG="" DEVICE_ID="" TARGET_WORKER="" WORKSPACE="" URGENT=0 SIM_SIGNIN_RETRIED=0
# --backend: what was asked for, the origin it names ("" = the shared dev Workers, no override) and the
# report's words for it; the Mac app's own answer lands in REPORT_BACKEND_MAC.
BACKEND_ARG="" BACKEND_URL="" BACKEND_REPORT="shared dev Workers (no override)" REPORT_BACKEND_MAC="not checked"
# The default (no --backend): this tag's stack, brought up beside the fleet builds (review_start_stack), then
# read (review_await_backend). STACK_UP_PID is that up; STACK_UP_LOG its output.
BACKEND_DEFAULT=0 STACK_UP_PID="" STACK_UP_LOG=""
# A tag stack's own mobile Worker (cloud-dev-stack.sh url --service mobile): the phone's receipt must name it.
BACKEND_MOBILE_URL=""
# The phone's origins when the stack has a public one (cloud-dev-stack.sh url --public): the same stack behind the
# authenticating gateway, which a phone reaches off the tailnet too. The Mac keeps the tailnet origin.
BACKEND_PHONE_URL="" BACKEND_PHONE_MOBILE_URL=""
# What the phone gets (default `paired`, the hand-off every dev build must reach):
#   paired   signed in with the personal account and paired with the same-tag Mac (its dev auto-approve)
#   manual   --manual-pairing: signed in, no Mac named; the person pairs by hand
#   approve  --approve-first: signed in, the Mac's dev auto-approve off; the
#            person presses Allow on the Mac
#   none     --no-auth: no credentials, no Mac named, and the tag's stored session cleared first
PHONE_MODE=paired
# --forbid-tailnet: a link whose peer is a tailnet or CGNAT address fails (handoff_receipt.py --forbid-tailnet).
FORBID_TAILNET=0

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
STATE="" TAG_STATE="" MAC_APP="" MAC_SOCKET="" MAC_DEVICE_ID="" MAC_BUILD_SPACE=""
# The phones that passed, as " udid udid " (a string, so an empty set needs no array expansion,
# which aborts under set -u on macOS's bash 3.2).
PASSED_PHONES=" "

die() { echo "review.sh: $*" >&2; exit 2; }

# --- the report ---------------------------------------------------------------
review_report() {
  local link="http://127.0.0.1:17320/$SLUG"
  printf '==> Review ready (tag: %s)\n' "$SLUG"
  printf 'Dev build:  %s   (%s, head %s)\n' "$link" "$REPORT_MAC" "${SHA:-unknown}"
  printf 'Backend:    %s; Mac app: %s\n' "$BACKEND_REPORT" "$REPORT_BACKEND_MAC"
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
  case "$PHONE_MODE" in
    manual) printf ' --manual-pairing' ;; approve) printf ' --approve-first' ;; none) printf ' --no-auth' ;;
  esac
  [[ "$FORBID_TAILNET" -eq 0 ]] || printf ' --forbid-tailnet'
  [[ -z "$TARGET_WORKER" ]] || printf ' --target-worker %s' "$TARGET_WORKER"
  [[ -z "$BACKEND_ARG" ]] || printf ' --backend %s' "$BACKEND_ARG"
  [[ "${URGENT:-0}" -eq 0 ]] || printf ' --urgent'
}

# --urgent: the reason the fleet logs for raising this hand-off's steps (cmux-ci run --urgent, cmux-ci promote).
urgent_reason() { printf 'review.sh --urgent: a person waits on the phone for the hand-off of tag %s at %s' "$SLUG" "${SHA:0:12}"; }

# --backend to an origin (BACKEND_URL) and the report's words for it (BACKEND_REPORT), before any build. The
# default only marks the stack to bring up (review_start_stack), whose origins review_await_backend reads.
review_resolve_backend() {
  case "$BACKEND_ARG" in
    "")
      BACKEND_DEFAULT=1 BACKEND_URL="" BACKEND_REPORT="this tag's stack (not up yet)" ;;
    dev|default)
      BACKEND_URL="" BACKEND_REPORT="shared dev Workers (--backend dev, no override)" ;;
    tag-stack)
      review_stack_backend "" || exit 2 ;;
    *)
      BACKEND_URL="$(mac_py backend-check "$BACKEND_ARG")" || exit 2
      BACKEND_REPORT="$BACKEND_URL (--backend)" ;;
  esac
}

review_stack_cmd() { printf '%s' "${CNX_CLOUD_DEV_STACK:-$REPO_ROOT/scripts/cmux-next/cloud-dev-stack.sh}"; }

# The tag stack's origins (BACKEND_URL, BACKEND_MOBILE_URL, BACKEND_PHONE_URL, BACKEND_PHONE_MOBILE_URL) and the
# report's words; $1 is appended to them ("" or ", default"). Returns 1 with the reason on stderr.
review_stack_backend() {
  local stack out pub
  stack="$(review_stack_cmd)"
  [[ -x "$stack" ]] || { echo "review.sh: --backend tag-stack needs $stack , which this checkout does not have; pass --backend <origin> instead" >&2; return 1; }
  out="$("$stack" url --tag "$SLUG" 2>&1)" || { echo "review.sh: --backend tag-stack: $stack url --tag $SLUG failed: ${out##*$'\n'}" >&2; return 1; }
  out="$(printf '%s\n' "$out" | awk 'NF { line = $0 } END { print line }')"
  BACKEND_URL="$(mac_py backend-check "$out")" || { echo "review.sh: --backend tag-stack: the stack's URL $out is not a tailnet origin" >&2; return 1; }
  # The stack's mobile Worker and device hub: its client-config names them for the Mac, and the phone
  # derives them from BACKEND_URL; the receipt must show the phone's mobile service is the stack's.
  BACKEND_MOBILE_URL="$("$stack" url --tag "$SLUG" --service mobile 2>/dev/null | awk 'NF { line = $0 } END { print line }')" || BACKEND_MOBILE_URL=""
  BACKEND_REPORT="$BACKEND_URL (this tag's stack: API, mobile Worker and device hub$1)"
  # Its public origin, when it has one, is the phone's: it works away from the tailnet too. With none (every public
  # slot is held), the phone takes the tailnet origin too, and the report says so.
  pub="$("$stack" url --tag "$SLUG" --public 2>/dev/null | awk 'NF { line = $0 } END { print line }')" || pub=""
  if [[ -n "$pub" ]]; then
    BACKEND_PHONE_URL="$(mac_py backend-check "$pub")" || { echo "review.sh: --backend tag-stack: the stack's public URL $pub is not a tag stack origin" >&2; return 1; }
    BACKEND_PHONE_MOBILE_URL="$("$stack" url --tag "$SLUG" --public --service mobile 2>/dev/null | awk 'NF { line = $0 } END { print line }')" || BACKEND_PHONE_MOBILE_URL=""
    BACKEND_REPORT="$BACKEND_REPORT; the phone: $BACKEND_PHONE_URL (its public origin)"
  else
    BACKEND_REPORT="$BACKEND_REPORT; the phone: tailnet only (no free public slot: off the tailnet it cannot reach the stack)"
  fi
}

# The default: bring this tag's stack up (or re-up it with this checkout) in the background, beside the fleet
# builds; its output goes to STACK_UP_LOG. Nothing for an explicit --backend.
review_start_stack() {
  [[ $BACKEND_DEFAULT -eq 1 ]] || return 0
  local stack
  stack="$(review_stack_cmd)"
  STACK_UP_LOG="${TAG_STATE:-${TMPDIR:-/tmp}}/stack-up.$$.log"  # this run's own: another run of the tag has its own
  mkdir -p "$(dirname "$STACK_UP_LOG")"
  if [[ ! -x "$stack" ]]; then
    echo "no $stack in this checkout" >"$STACK_UP_LOG"
    return 0
  fi
  echo "==> this tag's backend stack: $stack up --tag $SLUG (beside the builds; --backend dev skips it)"
  # Another up of this tag (a second hand-off, or the leftover up of an interrupted one) holds the VM's lock for
  # the tag: wait for it (up to about 10 min), then up again with this checkout.
  (
    local tries=0
    while :; do
      "$stack" up --tag "$SLUG" </dev/null >"$STACK_UP_LOG" 2>&1 && exit 0
      grep -q "another up of this tag" "$STACK_UP_LOG" 2>/dev/null && [[ $tries -lt 20 ]] || exit 1
      tries=$((tries + 1))
      sleep 30
    done
  ) </dev/null >/dev/null 2>&1 &  # never holds review.sh's output open (a `| tee` of a run that died early)
  STACK_UP_PID=$!
}

# The default: wait for the stack's up and point both apps at it. An up that failed (the VM unreachable, no
# PlanetScale login, a build error in the backend) leaves the shared dev Workers, with the reason on the
# Backend line: the hand-off still finishes, on the backend every build had before.
review_await_backend() {
  [[ $BACKEND_DEFAULT -eq 1 ]] || return 0
  BACKEND_DEFAULT=2  # once
  local rc=0 why=""
  if [[ -n "$STACK_UP_PID" ]]; then
    wait "$STACK_UP_PID" || rc=$?
  else
    rc=127
  fi
  if [[ $rc -eq 0 ]]; then
    # In this shell (its origins are this run's), its refusal kept beside the up's log.
    if review_stack_backend ", default" 2>"$STACK_UP_LOG.why"; then
      echo "==> backend: $BACKEND_URL (this tag's stack)"
      return 0
    fi
    why="$(tail -n 1 "$STACK_UP_LOG.why" 2>/dev/null)"
  fi
  # An up that printed nothing leaves no reason in its log: never an error of its own under set -e (pipefail).
  [[ -n "$why" ]] || why="$({ grep -v '^[[:space:]]*$' "$STACK_UP_LOG" 2>/dev/null || true; } | tail -n 1)"
  why="${why#review.sh: }"
  BACKEND_URL="" BACKEND_MOBILE_URL="" BACKEND_PHONE_URL="" BACKEND_PHONE_MOBILE_URL=""
  BACKEND_REPORT="shared dev Workers (FALLBACK: this tag's stack did not come up: ${why:-up exited $rc}; log $STACK_UP_LOG; --backend dev skips the stack)"
  echo "==> backend: $BACKEND_REPORT" >&2
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
      mac_promote
      return 0
    fi
  fi
  local out
  # The default builder at any pin. A head whose app FFI sources are ahead of app-ffi-pin.json builds
  # on the Linux pool like any other (hq#16145, #16334, #16431): the build links the newest published
  # release with the head's FFI inputs, or cross-builds the library, or the whole xcframework when the
  # headers changed. Until 2026-11-23 such a head went to `--builder mac`, queued for hours for the few
  # Macs, and failed there when its headers changed (job cb3e5fa3159ea9806ae980fe); with FFI commits
  # every half hour the pin is behind nearly always. cmux-next needs no shared dev backend (AGENTS.md):
  # the tag's own local mode.
  local ref reuse=()
  ref="$(mac_build_ref)"
  # --build always: the hand-off pairs the phone with a tagged Mac app, which a swap into a copy of the
  # NIGHTLY is not. Since the fleet client's swap-first default (an agent's submission of a change it can
  # swap queues nothing), a head that changes only Rust the app links queued no Mac build, and every such
  # hand-off ended "printed no job id" (vfix1125, 2026-11-25). The base's build: any tag's equal build
  # answers at once (--any-tag).
  if [[ "$ref" == "$SHA" ]]; then reuse=(--build); else reuse=(--any-tag --build); fi
  out="$(cmux_ci build cmux --ref "$ref" "${reuse[@]}" --tag "$SLUG" --workspace "$WORKSPACE" --backend-mode local)" ||
    { REPORT_MAC="BLOCKED: cmux-ci build cmux was refused"; return 1; }
  MAC_JOB="$(printf '%s' "$out" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' 2>/dev/null)" ||
    { REPORT_MAC="BLOCKED: cmux-ci build cmux queued no job: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"; return 1; }
  printf '%s\n' "$MAC_JOB" >"$STATE/cmux-job"
  echo "==> Mac build: fleet job $MAC_JOB"
  mac_promote
}

# The commit the Mac build is made from: this head, or its feat-cmux-next merge base when
# scripts/cmux-next/build_select.py says the head changes nothing the Mac app builds or bundles (an
# iPhone-only change, review.sh's own scripts): the base's Mac app is this head's, and a build of it the fleet
# already made (build-ahead, another tag) answers with no Mac minutes. Before 2026-11-24 every hand-off built
# the head, so an iPhone-only PR queued a full Mac build (#53007: 3+ h queued for 7 CmuxMobileKit files).
# CNX_REVIEW_MAC_BUILD=head builds the head anyway. Saved per head in $STATE/mac-ref, so a rerun resumes it.
mac_build_ref() {
  if [[ -s "$STATE/mac-ref" ]]; then
    cat "$STATE/mac-ref"
    return 0
  fi
  local ref="$SHA" base="" mac=""
  if [[ "${CNX_REVIEW_MAC_BUILD:-auto}" != head ]]; then
    base="$(git -C "$REPO_ROOT" merge-base "$SHA" origin/feat-cmux-next 2>/dev/null || true)"
    if [[ -n "$base" && "$base" != "$SHA" ]]; then
      mac="$(python3 "${CNX_REVIEW_BUILD_SELECT:-$REPO_ROOT/scripts/cmux-next/build_select.py}" --repo "$REPO_ROOT" --json "$base" "$SHA" 2>/dev/null |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["mac"])' 2>/dev/null || true)"
    fi
  fi
  if [[ "$mac" == none ]]; then
    ref="$base"
    echo "==> Mac build: this head changes nothing in the Mac app (build_select.py); the tag gets the build of its base ${base:0:12}" >&2
  fi
  printf '%s\n' "$ref" >"$STATE/mac-ref"
  printf '%s\n' "$ref"
}

# --urgent: the Mac build moves up the Mac queue (cmux-ci promote; a build has no --urgent). A refusal
# (the job already started or finished) changes nothing, so it is only noted.
mac_promote() {
  [[ "${URGENT:-0}" -ne 0 && -n "${MAC_JOB:-}" ]] || return 0
  if cmux_ci promote "$MAC_JOB" --reason "$(urgent_reason)" >/dev/null 2>&1; then
    echo "==> Mac build: promoted (--urgent)"
  else
    echo "==> Mac build: promote refused (--urgent); it keeps its place"
  fi
}

# The simulator step's key for this head. The controller answers a key with the step it already
# names, finished or not, so a key whose step failed or was cancelled would hand back that failure on
# every rerun: each such step bumps $STATE/sim-attempt (sim_step_ended) and the next run gets a new key.
sim_key() {
  local attempt
  attempt="$(cat "$STATE/sim-attempt" 2>/dev/null || true)"
  printf 'cnx-ios-handoff-%s-%s' "$SLUG" "${SHA:0:12}"
  [[ ! "$attempt" =~ ^[1-9][0-9]*$ ]] || printf -- '-r%s' "$attempt"
}

# The step failed or was cancelled on the fleet (its own state, not only this client's exit: a
# follow that was interrupted while the step still runs keeps its key, so a rerun re-attaches).
sim_step_ended() {
  local step="$1" attempt
  [[ -n "$step" ]] || return 1
  cmux_ci status "$step" 2>/dev/null | grep -Eq '"state": *"(failed|cancelled|timeout|timed_out)"' || return 1
  sim_next_attempt
}

# The next head's step gets a new key (sim_key's -rN).
sim_next_attempt() {
  local attempt
  attempt="$(cat "$STATE/sim-attempt" 2>/dev/null || true)"
  [[ "$attempt" =~ ^[0-9]+$ ]] || attempt=0
  printf '%s\n' "$((attempt + 1))" >"$STATE/sim-attempt"
}

# The iPhone app's simulator step, in the background; the same --key re-attaches to it. It is
# `handoff tag=<tag>`, sent as `shots handoff=<tag>` until the fleet controller lists handoff.
fleet_start_sim() {
  # --sign-in agent: this Mac seals the step a session of its own (hq build-fleet `sign_in`), delivered
  # while cmux-ci run follows the step, so it is never detached; cmux-next-ios-sim.sh handoff reads it.
  local args=(run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref "$SHA"
    --arg shots --arg "handoff=$SLUG" --sign-in agent --artifact artifacts/ios-sim/evidence.zip
    --key "$(sim_key)")
  [[ -z "$TARGET_WORKER" ]] || args+=(--target-worker "$TARGET_WORKER")
  [[ "${URGENT:-0}" -eq 0 ]] || args+=(--urgent --reason "$(urgent_reason)")
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
  local ref
  ref="$(cat "$STATE/mac-ref" 2>/dev/null || true)"
  [[ -z "$ref" || "$ref" == "$SHA" ]] || REPORT_MAC="$REPORT_MAC (built from the base ${ref:0:12}: this head changes nothing in the Mac app)"
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
  # The controller cancels a tag's still-queued step when a newer head of the same tag sends one ("superseded by
  # <step> (a newer head of this lane)"): nothing failed, this head is just no longer the tag's. It was
  # reported as "the fleet iPhone build failed (exit 76)" (step f06392e4d16521e2f9762f4b, 2026-11-19).
  if [[ $rc -ne 0 ]] && grep -q "superseded by" "$STATE/sim-step.err" 2>/dev/null; then
    local newer
    # A rerun of this head sends a new step instead of this superseded one again.
    sim_step_ended "$SIM_STEP" || true
    newer="$(sed -n 's/.*superseded by \([0-9a-f]\{24\}\).*/\1/p' "$STATE/sim-step.err" | tail -n 1)"
    REPORT_SIM="BLOCKED: not a failure: step ${SIM_STEP:-not created} was superseded by ${newer:-a newer step}, sent for a newer head of tag $SLUG; a newer review.sh run of this tag owns it; review.sh builds the checkout's HEAD, so to review ${SHA:0:12} again, check it out and rerun: $(retry_command)"
    return 1
  fi
  # The step's sign-in session comes from this Mac while cmux-ci run follows it (hq build-fleet sign_in). A
  # delivery the controller dropped ("no session was delivered within 10m0s", step 1e1c4a5c2700774f73411917 while
  # the controller timed out, 2026-11-24) says nothing about the build: send one new step, once.
  # A controller restart under the step loses it the same way: "the controller no longer lists this run as the
  # step's (409 Conflict)" (step df827ca8f4eb26596c17942e, hq#22711, 2026-11-24). So does a worker that stops
  # mid-step: "lease lost: cmux23 stopped renewing the step's lease" (step c50f2a91d132270d466e64d8, 2026-11-24).
  local lost
  lost="$(grep -ohE "no session was delivered|no longer lists this run as the step|lease lost" \
    "$STATE/sim-step.log" "$STATE/sim-step.err" 2>/dev/null | head -n 1 || true)"
  if [[ $rc -ne 0 && -n "$lost" ]]; then
    # The step's own log says it ended; a status read that fails (the controller timing out, as when the
    # delivery was lost) must not resend under the dead step's key, which answers with that step again.
    sim_step_ended "$SIM_STEP" || sim_next_attempt
    if [[ "${SIM_SIGNIN_RETRIED:-0}" -eq 0 ]]; then
      SIM_SIGNIN_RETRIED=1
      if [[ "$lost" == "lease lost" ]]; then
        echo "==> iPhone app: step ${SIM_STEP:-?} ended because its fleet worker stopped mid-step (lease lost); sending it once more"
      else
        echo "==> iPhone app: step ${SIM_STEP:-?} ended because no sign-in session reached it from this Mac; sending it once more"
      fi
      fleet_start_sim
      fleet_finish_sim
      return
    fi
    if [[ "$lost" == "lease lost" ]]; then
      REPORT_SIM="BLOCKED: the fleet iPhone build lost its worker mid-step twice (last step ${SIM_STEP:-?}; $STATE/sim-step.log): the simulator workers are failing (cmux-ci status), retry later: $(retry_command)"
    else
      REPORT_SIM="BLOCKED: the fleet iPhone build got no sign-in session from this Mac twice (steps ended: last ${SIM_STEP:-?}; $STATE/sim-step.log): check that cmux-ci reaches the controller (cmux-ci status), then retry: $(retry_command)"
    fi
    return 1
  fi
  if [[ $rc -ne 0 || -z "$SIM_STEP" ]]; then
    local next=""
    # A rerun at this head sends a new step, not this one's failure again.
    ! sim_step_ended "$SIM_STEP" || next=" (a rerun sends a new step)"
    REPORT_SIM="BLOCKED: the fleet iPhone build failed (step ${SIM_STEP:-not created}, exit $rc; $STATE/sim-step.log)$next; retry: $(retry_command)"
    return 1
  fi
  # Saved before the download: a rerun fetches this step's artifact again (sim_reusable) instead of sending a new
  # step, which the controller refuses ("409: step_key already names a different step"; vcorp1125d, 2026-11-25).
  printf '%s\n' "$SIM_STEP" >"$STATE/sim-passed"
  sim_download
}

# The passed step's artifact into $STATE/ios.zip.
sim_download() {
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
  # The head is reusable only once this read passes (below): an unsafe zip, a manifest of another head or a failed
  # check must never leave an older mark that a rerun would reuse.
  rm -f "$STATE/ios-passed"
  why="$(safe_unzip "$STATE/ios.zip" "$STATE/ios" 2>&1)" ||
    { REPORT_SIM="BLOCKED: the iPhone artifact of step $SIM_STEP is not a safe zip (${why##*$'\n'})"; sim_forget; return 1; }
  local check
  # One field per line (a tab split loses empty fields); the reason for a mismatch goes in the report.
  check="$(/usr/bin/python3 -I "$SCRIPT_DIR/handoff_receipt.py" read-manifest "$STATE/ios/handoff.json" \
    --tag "$SLUG" --sha "$SHA" --bundle-id "dev.cmux.mobile.$SLUG" 2>&1)" ||
    { REPORT_SIM="BLOCKED: step $SIM_STEP: ${check##*$'\n'}; retry: $(retry_command)"; sim_forget; return 1; }
  local status host device reason dir
  { IFS= read -r status; IFS= read -r host; IFS= read -r device; IFS= read -r reason; } <<<"$check"
  dir="$STATE/ios"
  if [[ "$status" == pass ]]; then
    REPORT_SIM="fleet simulator ($host, $device), signed in (agent account), restored after a credential-free relaunch: $dir (screens/signed-in-auto_login.png, screens/signed-in-restored.png, recording.mp4; step $SIM_STEP)"
  else
    REPORT_SIM="BLOCKED: fleet simulator check on $host failed: ${reason:-unknown}; evidence $dir; retry: $(retry_command)"
    REVIEW_FAILED=1
    sim_forget
  fi
  why="$(safe_unzip "$STATE/ios/CmuxMobileApp-Demo-device-unsigned.app.zip" "$STATE/device" 2>&1)" ||
    { REPORT_SIM="$REPORT_SIM; BLOCKED: the device app is not a safe zip (${why##*$'\n'})"; REVIEW_FAILED=1; return 1; }
  [[ -d "$STATE/device/CmuxMobileApp.app" ]] ||
    { REPORT_SIM="$REPORT_SIM; BLOCKED: the artifact has no device app"; REVIEW_FAILED=1; return 1; }
  # This head's iPhone build passed: a rerun (the Mac build failed, a phone was locked) reuses it (sim_reusable).
  [[ "$status" != pass ]] || printf '%s\n' "${SIM_STEP:-}" >"$STATE/ios-passed"
}

# A rerun at this head reuses the iPhone build whose step passed here before, instead of sending the step again: the
# controller answers that step's key only to the run that sent it (a new run seals a new sign-in key), so the
# rerun of 0e728c2b25 got "409: step_key already names a different step" and nothing for the phone (2026-11-24).
# The state is per tag and head, and read_ios_artifact checks the manifest's tag and commit again.
sim_reusable() {
  if [[ -s "$STATE/ios-passed" && -s "$STATE/ios.zip" ]]; then
    SIM_STEP="$(head -n 1 "$STATE/ios-passed")"
    echo "==> iPhone app: reusing this head's build from step ${SIM_STEP:-?} (its simulator check passed)"
    return 0
  fi
  # A step that passed but whose artifact did not download: fetch it again; read_ios_artifact checks it as always.
  [[ -s "$STATE/sim-passed" ]] || return 1
  SIM_STEP="$(head -n 1 "$STATE/sim-passed")"
  [[ "$SIM_STEP" =~ ^[0-9a-f]{24}$ ]] || return 1
  echo "==> iPhone app: step $SIM_STEP passed before; downloading its artifact again"
  sim_download || { echo "==> iPhone app: its artifact did not download again; sending a new step" >&2; REPORT_SIM=""; sim_forget; return 1; }
}

# Give up the passed step: a rerun sends a new one, under a new key (sim_key's -rN), since the controller answers the
# old key only with the old step ("409: step_key already names a different step").
sim_forget() {
  rm -f "$STATE/sim-passed"
  sim_next_attempt
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
  fi
  # The new app is copied beside the old one and swapped in by renames. macOS App Management may refuse
  # every change inside an installed app's bundle ("Operation not permitted") while the bundle itself
  # can still be renamed: emptying it in place left half an app with no Info.plist, recorded as
  # installed (2026-11-18). The old bundle goes to the tag's state folder (same volume), then is removed
  # as far as macOS lets it; what stays there never runs.
  local staged="$MAC_APP.installing" aside="$TAG_STATE/replaced/${recorded_sha:-none}-$$.app"
  mkdir -p "$(dirname "$MAC_APP")"
  rm -rf "$staged" 2>/dev/null || true
  ditto "$built" "$staged" ||
    { rm -rf "$staged" 2>/dev/null; REPORT_MAC="BLOCKED: the Mac app of job $MAC_JOB did not copy into place (ditto failed)"; return 1; }
  if [[ -d "$MAC_APP" ]]; then
    mkdir -p "$(dirname "$aside")"
    mv "$MAC_APP" "$aside" ||
      { rm -rf "$staged" 2>/dev/null; REPORT_MAC="BLOCKED: the tag's earlier app could not be moved aside"; return 1; }
    rm -rf "$aside" 2>/dev/null || true
  fi
  mv "$staged" "$MAC_APP" || { REPORT_MAC="BLOCKED: the new Mac app could not be moved into place"; return 1; }
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
# --approve-first adds CMUX_NEXT_IPHONE_APPROVE_FIRST=1: the dev build's auto-approve of its own
# tag's phone is off, so the Mac shows its Allow prompt (IPhoneDevAutoApprove).
mac_open() {
  local extra=()
  [[ "$PHONE_MODE" != approve ]] || extra=(--env CMUX_NEXT_IPHONE_APPROVE_FIRST=1)
  env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    TMPDIR="${TMPDIR:-/tmp}" "${MAC_OPEN:-/usr/bin/open}" -g --env CMUX_NEXT_NO_ACTIVATE=1 ${extra[@]+"${extra[@]}"} "$MAC_APP"
}

# Quit the tagged Mac app as the person does and wait until it is gone.
mac_quit_and_wait() {
  mac_py quit "$MAC_SOCKET" || return 1
  local i
  for i in $(seq 1 60); do
    pgrep -f "$MAC_APP/Contents/MacOS/" >/dev/null 2>&1 || break
    sleep 1
  done
  ! pgrep -f "$MAC_APP/Contents/MacOS/" >/dev/null 2>&1
}

# The tag's backend.json (review_mac.py backend-write): the app reads it at launch, so a running app
# whose file changed is quit first and started again below.
mac_apply_backend() {
  local bundle changed
  bundle="$(mac_py bundle "$MAC_APP")"
  [[ -n "$bundle" ]] || { REPORT_MAC="$REPORT_MAC; BLOCKED: the tagged Mac app has no bundle id"; return 1; }
  changed="$(mac_py backend-write "$HOME/Library/Application Support/cmux-next/$bundle" "$BACKEND_URL")" ||
    { REPORT_MAC="$REPORT_MAC; BLOCKED: could not write the tag's backend.json"; return 1; }
  if [[ "$changed" == changed ]] && pgrep -f "$MAC_APP/Contents/MacOS/" >/dev/null 2>&1; then
    echo "==> the tag's Cloud backend changed: quitting the tagged Mac app so it starts on it"
    mac_quit_installed || { REPORT_MAC="$REPORT_MAC; BLOCKED: the tagged Mac app did not quit to take its new backend"; return 1; }
  fi
}

# The backend the running Mac app says it uses (`auth.status`), which must be the asked-for one.
mac_check_backend() {
  local json backend label
  json="$(mac_py backend "$MAC_SOCKET" --timeout 60)" ||
    { REPORT_BACKEND_MAC="BLOCKED: the tagged Mac app does not say which Cloud backend it uses"; return 1; }
  backend="$(printf '%s' "$json" | /usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("backend") or "")')"
  label="$(printf '%s' "$json" | /usr/bin/python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("backend_label") or d.get("backend") or "")')"
  if [[ -n "$BACKEND_URL" && "${backend%/}" != "${BACKEND_URL%/}" ]]; then
    REPORT_BACKEND_MAC="BLOCKED: it uses $backend, not $BACKEND_URL"
    return 1
  fi
  REPORT_BACKEND_MAC="$label"
}

# Launch it in the background (never frontmost) unless it runs, and wait for the personal account.
mac_start() {
  mac_apply_backend || return 1
  # --approve-first: a running copy may have its auto-approve on, so it starts again with it off.
  if [[ "$PHONE_MODE" == approve ]] && mac_py wait-socket "$MAC_SOCKET" --timeout 2; then
    echo "==> --approve-first: quitting the running tagged Mac app to start it with its auto-approve off"
    mac_quit_and_wait ||
      { REPORT_MAC="$REPORT_MAC; BLOCKED: the running tagged Mac app did not quit for --approve-first"; return 1; }
  fi
  if ! mac_py wait-socket "$MAC_SOCKET" --timeout 2; then
    echo "==> launching the tagged Mac app in the background"
    mac_open ||
      { REPORT_MAC="$REPORT_MAC; BLOCKED: the tagged Mac app did not launch"; return 1; }
    mac_py wait-socket "$MAC_SOCKET" --timeout 120 ||
      { REPORT_MAC="$REPORT_MAC; BLOCKED: the tagged Mac app never answered on its control socket"; return 1; }
  fi
  # The cloud data space the tagged Mac's requests and hostd carry: every phone receipt must name it, or
  # the phone lists none of this Mac's devices (and another space's Macs instead).
  MAC_BUILD_SPACE="$(mac_py space "$MAC_APP")" ||
    { REPORT_MAC="$REPORT_MAC; BLOCKED: could not read the tagged Mac app's build space"; return 1; }
  [[ "$MAC_BUILD_SPACE" == dev:* ]] ||
    { REPORT_MAC="$REPORT_MAC; BLOCKED: the tagged Mac app has no build space of its own (${MAC_BUILD_SPACE:-the default space})"; return 1; }
  local account
  account="$(mac_py account "$MAC_SOCKET" --timeout 120)" ||
    { REPORT_MAC="$REPORT_MAC; BLOCKED: the tagged Mac app is not signed in (it signs in from ~/.secrets/cmuxterm-dev.env as ~/.config/cmux-next/dev-account)"; return 1; }
  mac_check_backend || { REPORT_MAC="$REPORT_MAC; BLOCKED: Cloud backend ($REPORT_BACKEND_MAC)"; return 1; }
  if [[ "$account" != "$PERSONAL_ACCOUNT" ]]; then
    REPORT_MAC="$REPORT_MAC; BLOCKED: the tagged Mac app is signed in as $account, not the personal account $PERSONAL_ACCOUNT"
    return 1
  fi
  # --manual-pairing / --no-auth: no Mac is named to a phone and no link is proven, so none is
  # required here. The default and --approve-first prove the link, so they need the Mac's id.
  [[ "$PHONE_MODE" == paired || "$PHONE_MODE" == approve ]] || return 0
  local why
  # The id phones pair with, from the Mac's iPhone host: also shows the host is up for the account.
  MAC_DEVICE_ID="$(mac_py mac-id "$MAC_SOCKET" --timeout 90 2>&1)" ||
    { why="$MAC_DEVICE_ID"; MAC_DEVICE_ID=""
      REPORT_MAC="$REPORT_MAC; BLOCKED: the tagged Mac app's iPhone host is not ready (${why##*$'\n'}; iPhone connections on in Settings > Mobile?)"; return 1; }
}

# Quit the tagged Mac app as the person does and start it again (the Tag Opener's relaunch).
mac_restart() {
  mac_quit_and_wait || return 1
  local before="$MAC_DEVICE_ID"
  mac_start || return 1
  [[ "$MAC_DEVICE_ID" == "$before" ]]
}

# --- the phones ---------------------------------------------------------------
# One launch of the app on PHONE and its receipt. Args: udid client launch [focus-mac], where launch is
#   auto_login   the personal account's credentials (and the Mac to focus, when given)
#   restored     nothing: the app's own stored session, as the person's own cold launch
#   clear        CMUX_MOBILE_CLEAR_AUTH=1 (DEBUG only: drops the tag's stored session), then signed out
#   signed_out   nothing, and the app must still be signed out
#   relay-only   nothing but CMUX_MOBILE_DEV_RELAY_ONLY=1 (TURN only, as a phone away from home): restored,
#                and linked via TURN
# Credentials go in the environment of this one call only; every other launch carries none, and
# the ambient DEVICECTL_CHILD_ credential, focus, clear and relay variables are dropped first.
phone_launch_and_check() {
  local udid="$1" client="$2" launch="$3" focus_mac="${4:-}" nonce rc=0 session mac_id=""
  session="$launch"
  [[ "$launch" != clear ]] || session=signed_out
  [[ "$launch" != relay-only ]] || session=restored
  # How the link must travel: never over the tailnet (--forbid-tailnet); through TURN (the relay-only relaunch).
  local route=()
  [[ "$FORBID_TAILNET" -eq 0 ]] || route+=(--forbid-tailnet)
  [[ "$launch" != relay-only ]] || route+=(--require-turn)
  # The paired hand-off and --approve-first check the Mac; --manual-pairing and --no-auth prove sign-in state only.
  case "$PHONE_MODE" in paired|approve) mac_id="$MAC_DEVICE_ID" ;; esac
  nonce="$(cmux_attach_readiness_nonce)"
  # In a subshell's environment, never on a command line (ps would show it).
  if ! (
    unset DEVICECTL_CHILD_CMUX_MOBILE_STACK_EMAIL DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD DEVICECTL_CHILD_CMUX_MOBILE_FOCUS_MAC \
      DEVICECTL_CHILD_CMUX_MOBILE_CLEAR_AUTH DEVICECTL_CHILD_CMUX_NEXT_CLOUD_BACKEND DEVICECTL_CHILD_CMUX_MOBILE_DEV_RELAY_ONLY
    export DEVICECTL_CHILD_CMUX_DOGFOOD_READINESS_NONCE="$nonce" DEVICECTL_CHILD_CMUX_DOGFOOD_CLIENT_ID="$client"
    # --backend: the first launch names the tag's backend (`default`: the build's own, clearing a kept one);
    # every later launch carries nothing and must keep it, as the person's own launches do.
    case "$launch" in auto_login|clear) export DEVICECTL_CHILD_CMUX_NEXT_CLOUD_BACKEND="${BACKEND_PHONE_URL:-${BACKEND_URL:-default}}" ;; esac
    if [[ "$launch" == auto_login ]]; then
      export DEVICECTL_CHILD_CMUX_MOBILE_STACK_EMAIL="$PERSONAL_EMAIL" DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD="$PERSONAL_PASSWORD"
      [[ -z "$focus_mac" ]] || export DEVICECTL_CHILD_CMUX_MOBILE_FOCUS_MAC="$focus_mac"
    elif [[ "$launch" == clear ]]; then
      export DEVICECTL_CHILD_CMUX_MOBILE_CLEAR_AUTH=1
    elif [[ "$launch" == relay-only ]]; then
      export DEVICECTL_CHILD_CMUX_MOBILE_DEV_RELAY_ONLY=1
    fi
    exec xcrun devicectl device process launch --terminate-existing --device "$udid" "$BUNDLE_ID" >/dev/null 2>&1
  ); then
    PHONE_REASON="could not launch the app ($launch; is the phone locked? unlock it)"
    return 1
  fi
  # REVIEW_WANT=asking (--approve-first): the receipt passes once the phone is on the tagged Mac, linked or not.
  local wait="${CNX_REVIEW_RECEIPT_TIMEOUT:-180}"
  # The mobile Worker the phone's receipt must name: its public one when the phone has the public origin.
  local phone_mobile="$BACKEND_MOBILE_URL"
  [[ -z "$BACKEND_PHONE_URL" ]] || phone_mobile="$BACKEND_PHONE_MOBILE_URL"
  local deadline=$((SECONDS + wait)) verdict="" receipt
  receipt="$(mktemp "${TMPDIR:-/tmp}/cnx-review-receipt.XXXXXX")"
  # A link's path can still change for a second or two after it is up (WireGuard moves from TURN, or no route, to
  # the direct route it confirms): a passing receipt is read once more, CNX_REVIEW_PATH_SETTLE s later, and that
  # one decides (a tailnet path it settled on fails --forbid-tailnet). A second read that is not ready yet keeps
  # the first verdict.
  local settle="${CNX_REVIEW_PATH_SETTLE:-5}" first_pass=""
  while :; do
    rm -f "$receipt"
    if cmux_attach_fetch_app_receipt physical_device "$udid" "$BUNDLE_ID" "$receipt" 2>/dev/null; then
      rc=0
      verdict="$(/usr/bin/python3 -I "$SCRIPT_DIR/handoff_receipt.py" check "$receipt" --nonce "$nonce" \
        --client-id "$client" --bundle-id "$BUNDLE_ID" --account "$PERSONAL_ACCOUNT" --session "$session" ${route[@]+"${route[@]}"} \
        --mac-id "$mac_id" --git-sha "$SHA" --dev-tag "$SLUG" --cloud-backend "${BACKEND_PHONE_URL:-${BACKEND_URL:-default}}" \
        ${phone_mobile:+--mobile-api "$phone_mobile"} ${REVIEW_WANT:+--want "$REVIEW_WANT"} \
        ${MAC_BUILD_SPACE:+--build-space "$MAC_BUILD_SPACE"})" || rc=$?
      if [[ $rc -eq 0 && -z "$first_pass" && "$settle" -gt 0 ]]; then first_pass="$verdict"; sleep "$settle"; continue; fi
      [[ $rc -eq 1 ]] || break
    else
      rc=1 verdict="no readiness receipt yet"
    fi
    [[ -z "$first_pass" ]] || { rc=0 verdict="$first_pass"; break; }
    (( SECONDS < deadline )) || break
    sleep 3
  done
  # The last receipt this launch wrote: mac_sees_phone reads the phone's device ids from it.
  mkdir -p "$STATE/phone-$udid"
  if [[ -f "$receipt" ]]; then mv "$receipt" "$STATE/phone-$udid/receipt.json"; else rm -f "$receipt"; fi
  if [[ $rc -ne 0 ]]; then
    PHONE_REASON="$launch launch: $verdict (after $wait s)"
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

# Sign, install, launch signed in (the tagged Mac named to focus), prove it paired, relaunch credential-free, prove it.
phone_review() {
  local udid="$1" label="$2" client app
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
  # The sanctioned install (the app-receipt auth gate): it ends in the auth gate below, and the
  # marker lets the local-build-guards devicectl interceptor tell it from a raw install.
  if ! CMUX_SANCTIONED_IPHONE_INSTALL=1 xcrun devicectl device install app --device "$udid" "$app" \
      >"$STATE/phone-$udid/install.log" 2>&1; then
    PHONE_REASON="install failed ($(tail -n 1 "$STATE/phone-$udid/install.log"); locked, or Developer Mode off?)"
    return 1
  fi
  case "$PHONE_MODE" in
    manual)
      # Signed in like every dev build; no Mac is named, so the person picks and pairs by hand.
      phone_launch_and_check "$udid" "$client" auto_login || return 1
      local signed_in="$PHONE_VERDICT"
      phone_launch_and_check "$udid" "$client" restored || return 1
      PHONE_LINE="$label: installed, $signed_in; credential-free relaunch: $PHONE_VERDICT; pairing left to you (--manual-pairing)"
      return 0 ;;
    approve)
      phone_approve "$udid" "$label" "$client" || return 1
      return 0 ;;
    none)
      phone_launch_and_check "$udid" "$client" clear || return 1
      phone_launch_and_check "$udid" "$client" signed_out || return 1
      PHONE_LINE="$label: installed, not signed in (--no-auth): the tag's stored session cleared, at the welcome screen; relaunch: still signed out"
      return 0 ;;
  esac
  # The phone pairs on its own; the tagged Mac's dev auto-approve allows its own tag's phone.
  phone_launch_and_check "$udid" "$client" auto_login "$MAC_DEVICE_ID" || return 1
  local first="$PHONE_VERDICT"
  mac_sees_phone "$udid" || { PHONE_REASON="the tagged Mac does not list this phone as paired and connected"; return 1; }
  phone_launch_and_check "$udid" "$client" restored || return 1
  local restored="$PHONE_VERDICT"
  # At home the link may take the LAN (or, with Tailscale on both, the tailnet); away from home it goes through TURN.
  phone_launch_and_check "$udid" "$client" relay-only || return 1
  PHONE_LINE="$label: installed, $first; Mac sees it paired and connected; credential-free relaunch: $restored; relay-only relaunch (TURN only, as a phone away from home): $PHONE_VERDICT"
}

# One field of a JSON object (empty when absent or null).
json_field() {
  /usr/bin/python3 -I -c 'import json, sys
try:
    v = json.loads(sys.argv[1] or "{}").get(sys.argv[2])
except (ValueError, AttributeError):
    v = None
print("" if v is None else v)' "$1" "$2"
}

# The tagged Mac app's name as the person sees it in the Dock ("cmux DEV <tag>"): several dev builds on one
# computer share the Mac's name, so the report names the app too.
mac_app_label() {
  local name=""
  [[ -z "${MAC_APP:-}" ]] || name="$(basename "$MAC_APP" .app)"
  printf '%s' "${name:-cmux DEV $SLUG}"
}

# --approve-first: no code. The tagged Mac (its dev auto-approve off) shows "Allow “<phone>” (<key>) to connect to
# this Mac?", which only the person answers. In order:
#  1. the Mac's paired phones before the phone starts: its paired list outlives its relaunch, so a phone it
#     paired earlier links at once and is never asked (reported, not passed);
#  2. the phone signs in and picks the tagged Mac from the account's Mac list (its receipt, --want asking);
#  3. the Mac shows its request within 60 s (review_mac.py allow-state: the request under Connection Requests
#     and the open prompt's title), and the run says where, by the Mac's name and app, before it waits;
#  4. the person's Allow: the Mac lists the phone as paired (CNX_REVIEW_ALLOW_TIMEOUT, default 600 s);
#  5. a credential-free relaunch is linked with the tagged Mac, which lists the phone paired and connected.
# The link is proven by the relaunch, never by the first launch's receipt: the app stops writing that one 180 s
# after launch (DogfoodReadiness.window), so an Allow pressed later never reached it, and a run with a person at
# the Mac still timed out "not paired in time" (pv1121e-ap, 2026-11-21).
phone_approve() {
  local udid="$1" label="$2" client="$3" before ids id json state mac prompt asked allowed where shown
  local timeout="${CNX_REVIEW_ALLOW_TIMEOUT:-600}" args=()
  before="$(mac_py phones "$MAC_SOCKET" 2>/dev/null | /usr/bin/python3 -I -c '
import json, sys
try:
    rows = json.load(sys.stdin).get("phones") or []
except (ValueError, AttributeError):
    rows = []
print("\n".join(str(r.get("id", "")).lower() for r in rows if isinstance(r, dict) and r.get("paired")))' 2>/dev/null)" || before=""
  REVIEW_WANT=asking phone_launch_and_check "$udid" "$client" auto_login "$MAC_DEVICE_ID" || return 1
  asked="$PHONE_VERDICT"
  ids="$(/usr/bin/python3 -I "$SCRIPT_DIR/handoff_receipt.py" phone-ids "$STATE/phone-$udid/receipt.json" 2>/dev/null)" ||
    { PHONE_REASON="signed in, but its receipt names none of the phone's device ids"; return 1; }
  for id in $ids; do args+=(--phone-id "$id"); done
  json="$(mac_py allow-state "$MAC_SOCKET" ${args[@]+"${args[@]}"} --until asked --timeout 60 2>/dev/null)" || json=""
  state="$(json_field "$json" state)" mac="$(json_field "$json" mac_name)" prompt="$(json_field "$json" prompt)"
  where="the tagged Mac “${mac:-?}” ($(mac_app_label))"
  if [[ "$asked" == *"paired and linked with"* ]]; then
    for id in $ids; do
      if printf '%s\n' "$before" | grep -qixF -- "$id"; then
        PHONE_REASON="not asked: $where had paired this phone before this run, so it linked with no Allow prompt; to see the prompt, remove the phone in that Mac's Settings > Mobile and rerun"
        return 1
      fi
    done
    # The person pressed Allow before the first receipt.
    allowed="$asked (allowed on the Mac “${mac:-?}”, --approve-first)"
  else
    case "$state" in
      waiting|paired) ;;
      off) PHONE_REASON="iPhone connections are off on $where (Settings > Mobile > Allow iPhone connections); only the person turns them on"; return 1 ;;
      *) PHONE_REASON="the phone is signed in and on $where, but that Mac shows no request from it after 60 s (its Settings > Mobile lists the phones it sees)"; return 1 ;;
    esac
    if [[ -n "$prompt" ]]; then
      shown="shows “${prompt}” (also under Connection Requests in its Settings > Mobile)"
    else
      shown="lists the request under Connection Requests in its Settings > Mobile, but shows no Allow prompt (it shows on a window of that app on screen)"
    fi
    if [[ "$state" == waiting ]]; then
      if [[ -n "$prompt" ]]; then
        echo "==> $label: waiting for Allow on the Mac: “${prompt}” is showing on $where; press Allow there (up to $timeout s)"
      else
        echo "==> $label: waiting for Allow on the Mac: $where $shown; press Allow there (up to $timeout s)"
      fi
      json="$(mac_py allow-state "$MAC_SOCKET" ${args[@]+"${args[@]}"} --until answered --timeout "$timeout" 2>/dev/null)" || json=""
      state="$(json_field "$json" state)"
      case "$state" in
        paired) ;;
        gone) PHONE_REASON="the request is gone from $where without an Allow (Don't Allow, or the phone signed out)"; return 1 ;;
        off) PHONE_REASON="iPhone connections were turned off on $where while it waited for Allow"; return 1 ;;
        *)
          PHONE_REASON="waiting for Allow on the Mac: nobody pressed Allow in $timeout s. The tagged Mac “${mac:-?}” ($(mac_app_label)) $shown, and the phone is signed in and waiting for it, not linked yet. Next: at that Mac, rerun this command and press Allow when the prompt shows"
          return 1 ;;
      esac
      if [[ -n "$prompt" ]]; then shown=", which showed “${prompt}”"; else shown=", which listed its request (no prompt on screen)"; fi
    else
      shown=""  # allowed between the receipt and the Mac's first answer
    fi
    allowed="${asked%%, on the tagged Mac*}, asked $where$shown; allowed on the Mac (--approve-first)"
  fi
  phone_launch_and_check "$udid" "$client" restored || return 1
  local relaunched="$PHONE_VERDICT"
  mac_sees_phone "$udid" ||
    { PHONE_REASON="allowed, and a credential-free relaunch is linked, but the tagged Mac does not list this phone as paired and connected"; return 1; }
  PHONE_LINE="$label: installed, $allowed; credential-free relaunch: $relaunched; Mac sees it paired and connected"
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
      # --urgent: a person waits on the phone now; both fleet builds go first (logged with a reason).
      --urgent) URGENT=1; shift ;;
      --workspace) WORKSPACE="${2:-}"; shift 2 ;;
      --manual-pairing) [[ "$PHONE_MODE" == none ]] || PHONE_MODE=manual; shift ;;
      # --approve-first: the person's Allow on the Mac pairs the phone (no auto-approve).
      --approve-first) [[ "$PHONE_MODE" == none ]] || PHONE_MODE=approve; shift ;;
      # --no-auth implies no pairing, whatever order the flags come in.
      --no-auth) PHONE_MODE=none; shift ;;
      --forbid-tailnet) FORBID_TAILNET=1; shift ;;
      --backend) BACKEND_ARG="${2:-}"; [[ -n "$BACKEND_ARG" ]] || die "--backend needs a value"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "review.sh: unknown argument $1" >&2; usage >&2; exit 2 ;;
    esac
  done
  [[ -n "$TAG" ]] || { usage >&2; die "--tag is required"; }
  cmux_attach_validate_dev_tag "$TAG" || exit 2
  SLUG="$(cmux_attach__slug "$TAG")"
  BUNDLE_ID="dev.cmux.mobile.$SLUG"
  review_resolve_backend
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
  review_start_stack
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
  local mac_ok=1 ios_ok=1 target sim_reused=0
  if sim_reusable; then sim_reused=1; else fleet_start_sim; fi
  { fleet_submit_mac && fleet_finish_mac; } || mac_ok=0
  [[ $sim_reused -eq 1 ]] || fleet_finish_sim || ios_ok=0
  [[ $ios_ok -eq 0 ]] || read_ios_artifact || ios_ok=0
  review_await_backend
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
