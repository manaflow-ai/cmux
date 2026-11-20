#!/usr/bin/env bash
# Installs the connectivity canary (PROTOCOL.md "Connectivity canary") on an always-on Mac as two
# LaunchAgents of the logged-in user: a cmux-mobile-host (the Mac the canary dials) and
# cmux-mobile-canary (the prober), both signed in as the canary account.
#
#   install.sh --bin-dir DIR --credentials FILE --base-url URL --team TEAM [--label-prefix dev.cmux.canary]
#   install.sh --uninstall [--label-prefix dev.cmux.canary]
#
# Run it ON the canary Mac. DIR holds release builds of cmux-mobile-host and cmux-mobile-canary for
# that Mac. FILE is a KEY=VALUE file with CMUX_CANARY_STACK_EMAIL/PASSWORD (or the agent test account's
# CMUX_UITEST_STACK_*); it is copied to ~/.cmux-mobile-canary/credentials (0600) and never printed.
# Use a dedicated canary account: a shared account's sessions can be revoked by another sign-in.
set -euo pipefail

prefix=dev.cmux.canary
bin_dir= credentials= base_url= team= uninstall=0
while (($#)); do
  case "$1" in
    --bin-dir) bin_dir=$2; shift 2 ;;
    --credentials) credentials=$2; shift 2 ;;
    --base-url) base_url=$2; shift 2 ;;
    --team) team=$2; shift 2 ;;
    --label-prefix) prefix=$2; shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    *) echo "unknown argument $1" >&2; exit 64 ;;
  esac
done

agents="$HOME/Library/LaunchAgents"
state="$HOME/.cmux-mobile-canary"
host_state="$state/host"
uid=$(id -u)

if ((uninstall)); then
  for name in host prober; do
    launchctl bootout "gui/$uid/$prefix.$name" 2>/dev/null || true
    rm -f "$agents/$prefix.$name.plist"
  done
  echo "removed $prefix.host and $prefix.prober (state kept in $state)"
  exit 0
fi

[[ -n $bin_dir && -n $credentials && -n $base_url && -n $team ]] || { echo "needs --bin-dir, --credentials, --base-url and --team" >&2; exit 64; }
for b in cmux-mobile-host cmux-mobile-canary; do [[ -x $bin_dir/$b ]] || { echo "$bin_dir/$b is missing" >&2; exit 66; }; done

mkdir -p "$state/bin" "$host_state" "$agents"
chmod 700 "$state"
install -m 0755 "$bin_dir/cmux-mobile-host" "$bin_dir/cmux-mobile-canary" "$state/bin/"
install -m 0600 "$credentials" "$state/credentials"

# Two password sign-ins (no device, no dial), two Stack sessions: the prober's (it signs in again by
# itself only when Stack refuses its session) and the host's, so neither refreshes the other's token.
for dir in "$state" "$state/host-auth"; do
  rm -f "$dir/refresh-token"
  "$state/bin/cmux-mobile-canary" --base-url "$base_url" --team "$team" --mac 00000000-0000-0000-0000-000000000000 \
    --state-dir "$dir" --credentials-file "$state/credentials" --sign-in-only >/dev/null 2>&1 || true
  [[ -s $dir/refresh-token ]] || { echo "sign-in failed: no refresh token in $dir" >&2; exit 1; }
done
mac_id=$(CMUX_MOBILE_STATE_DIR="$host_state" "$state/bin/cmux-mobile-host" --print-device-id)

# sed, not ${v//&/...}: bash 5.2 reads & in a replacement as the match.
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

plist() { # label, then program arguments; env pairs after "--env"
  local label=$1; shift
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n'
    printf '<key>Label</key><string>%s</string>\n<key>ProgramArguments</key><array>\n' "$label"
    while (($#)) && [[ $1 != --env ]]; do printf '<string>%s</string>\n' "$(xml "$1")"; shift; done
    printf '</array>\n'
    if [[ ${1:-} == --env ]]; then
      shift
      printf '<key>EnvironmentVariables</key><dict>\n'
      while (($#)); do printf '<key>%s</key><string>%s</string>\n' "$1" "$(xml "$2")"; shift 2; done
      printf '</dict>\n'
    fi
    printf '<key>RunAtLoad</key><true/>\n<key>KeepAlive</key><true/>\n<key>ThrottleInterval</key><integer>30</integer>\n'
    printf '<key>StandardOutPath</key><string>%s/%s.log</string>\n<key>StandardErrorPath</key><string>%s/%s.err.log</string>\n' "$(xml "$state")" "${label##*.}" "$(xml "$state")" "${label##*.}"
    printf '</dict></plist>\n'
  } > "$agents/$label.plist"
}

plist "$prefix.host" "$state/bin/cmux-mobile-host" --env \
  CMUX_MOBILE_BASE_URL "$base_url" CMUX_MOBILE_TEAM_ID "$team" \
  CMUX_MOBILE_REFRESH_TOKEN_FILE "$state/host-auth/refresh-token" CMUX_MOBILE_STATE_DIR "$host_state" \
  CMUX_MOBILE_DEVICE_NAME "cmux connectivity canary Mac"
plist "$prefix.prober" "$state/bin/cmux-mobile-canary" --base-url "$base_url" --team "$team" --mac "$mac_id" \
  --state-dir "$state" --credentials-file "$state/credentials"

unload() { # bootout, then wait (bounded) until launchd has really let go of the job
  launchctl bootout "gui/$uid/$1" 2>/dev/null || return 0
  for _ in $(seq 1 50); do launchctl print "gui/$uid/$1" >/dev/null 2>&1 || return 0; sleep 0.2; done
  echo "$1 did not unload" >&2; return 1
}
for name in host prober; do
  unload "$prefix.$name"
  launchctl bootstrap "gui/$uid" "$agents/$prefix.$name.plist"
done
echo "installed $prefix.host (Mac $mac_id) and $prefix.prober; logs in $state"
