#!/usr/bin/env bash
# End-to-end check of the tailnet media relay (remote-desktop-v2.md section 3)
# with two signed-in cmux-tailnet nodes owned by the same Tailscale user.
#
#   host machine:    tailnet-turn-check.sh host   [--state DIR] [--hostname NAME]
#   viewer machine:  tailnet-turn-check.sh viewer --target HOST:4181 --user U --pass P --peer IP:PORT [--state DIR]
#
# `host` runs `cmux-tailnet turn-serve`: the TURN-over-TCP relay on tailnet
# port 4181 with a UDP echo on this machine as its only allowed peer, and
# prints the exact `viewer` arguments. `viewer` runs `cmux-tailnet forward`
# (loopback -> the viewer's own tsnet node -> host:4181), waits for its
# "Forwarding" line, then `cmux-tailnet turn-check` through the forward:
# a TURN Allocate, a datagram to the echo, and the echo back. Pass line:
# `turn-check ok: relay ... echoed 15 bytes ...`.
#
# What it proves: tsnet dial/listen, WhoIs + Access on the relay port, the
# credential check, TURN-over-TCP framing, the relay's peer allowlist, and
# UDP back to the host. It does not run libwebrtc; the screen host and a
# tailnet viewer do that.
#
# Build with the relay feature first (on a fleet Mac or the Rust builder):
#   cargo build -p cmux-tailnet --features relay --release
# and set CMUX_TAILNET to the binary if it is not target/release/cmux-tailnet.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="${CMUX_TAILNET:-$root/target/release/cmux-tailnet}"
role="${1:-}"
shift || true

state="$HOME/.config/cmux-tailnet-check/$role"
hostname=""
target="" user="" pass="" peer=""
local_port="${CMUX_TAILNET_FORWARD_PORT:-34181}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --state) state="$2"; shift 2 ;;
    --hostname) hostname="$2"; shift 2 ;;
    --target) target="$2"; shift 2 ;;
    --user) user="$2"; shift 2 ;;
    --pass) pass="$2"; shift 2 ;;
    --peer) peer="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -x "$bin" ]] || { echo "no cmux-tailnet binary at $bin (set CMUX_TAILNET)" >&2; exit 2; }

case "$role" in
  host)
    exec "$bin" turn-serve --state "$state" --hostname "${hostname:-cmux-turn-check-host}"
    ;;
  viewer)
    [[ -n "$target" && -n "$user" && -n "$pass" && -n "$peer" ]] || {
      echo "viewer needs --target HOST:4181 --user U --pass P --peer IP:PORT (printed by the host)" >&2
      exit 2
    }
    # Start the forward and wait for its ready line (an event, not a timer).
    fifo_dir="$(mktemp -d)"
    mkfifo "$fifo_dir/forward"
    "$bin" forward --state "$state" --hostname "${hostname:-cmux-turn-check-viewer}" \
      --local "127.0.0.1:$local_port" "$target" >"$fifo_dir/forward" 2>&1 &
    forward_pid=$!
    trap 'kill "$forward_pid" 2>/dev/null || true; rm -rf "$fifo_dir"' EXIT
    exec 3<"$fifo_dir/forward"
    while IFS= read -r line <&3; do
      echo "forward: $line"
      case "$line" in
        "Sign in to Tailscale: "*) echo "Open the link above to sign in this viewer node, then the check continues." ;;
        Forwarding*) break ;;
      esac
    done
    "$bin" turn-check --via "127.0.0.1:$local_port" --user "$user" --pass "$pass" --peer "$peer"
    ;;
  *)
    echo "usage: $0 host|viewer [options]" >&2
    exit 2
    ;;
esac
