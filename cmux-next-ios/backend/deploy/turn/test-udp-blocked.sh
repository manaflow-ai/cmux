#!/usr/bin/env bash
# The UDP-blocked-network proof (RFD 0088, cmux#52947): a real eturnal (the one install.sh deploys, same
# eturnal.yml limits) with ONLY a TLS listener, and the client run with UDP blocked. The client must reach
# its Mac through TURN over TLS and report path `turn-tls` (both sides), else the test fails.
# Needs: curl, openssl, cargo. No root: eturnal runs from a temp dir on loopback; the HMAC credential is
# made the way the Worker makes it (username "<expiry>:cmux", base64 HMAC-SHA1 under the secret).
# Run on Linux: cmux-ci test -- cmux-next-ios/backend/deploy/turn/test-udp-blocked.sh
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
VERSION="${ETURNAL_VERSION:-1.12.3}"
work="$(mktemp -d)"; pid=""
cleanup() { [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
cache="${XDG_CACHE_HOME:-$HOME/.cache}/cmux-eturnal"; mkdir -p "$cache"
tgz="$cache/eturnal-$VERSION-linux-glibc-x64.tar.gz"
[[ -s "$tgz" ]] || curl -fsSL "https://eturnal.net/download/linux/$(basename "$tgz")" -o "$tgz"
mkdir "$work/e" "$work/etc" "$work/home"; tar -xzf "$tgz" -C "$work/e" --strip-components=1

secret="test-$(openssl rand -hex 8)"; port=$((20000 + RANDOM % 20000)); relay_lo=$((port + 1)); relay_hi=$((port + 100))
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/etc/key.pem" -out "$work/etc/crt.pem" -days 2 \
  -subj /CN=localhost -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null
openssl x509 -in "$work/etc/crt.pem" -outform der -out "$work/etc/crt.der"
# Production's limits (max_bps, max_allocations, TLS) with only what a loopback test must change: one TLS
# listener (no UDP listener at all) and no peer blacklist (the Mac is on loopback).
cat > "$work/etc/eturnal.yml" <<Y
eturnal:
  secret: "$secret"
  listen:
    - {ip: "127.0.0.1", port: $port, transport: tls}
  relay_ipv4_addr: "127.0.0.1"
  relay_min_port: $relay_lo
  relay_max_port: $relay_hi
  max_allocations: 5000
  max_bps: 4000000
  blacklist_peers: []
  blacklist_clients: []
  tls_crt_file: $work/etc/crt.pem
  tls_key_file: $work/etc/key.pem
  log_dir: stdout
  log_level: info
Y
ETURNAL_ETC_DIR="$work/etc" HOME="$work/home" "$work/e/bin/eturnal" foreground > "$work/eturnal.log" 2>&1 &
pid=$!
for _ in $(seq 120); do ss -ltn 2>/dev/null | grep -q ":$port " && break; sleep 0.5; done
ss -ltn | grep -q ":$port " || { tail -20 "$work/eturnal.log" >&2; echo "eturnal did not start" >&2; exit 1; }

user="$(( $(date +%s) + 3600 )):cmux"
cred="$(printf '%s' "$user" | openssl dgst -sha1 -hmac "$secret" -binary | base64)"
export CMUX_ETURNAL_URLS="turns:127.0.0.1:$port?transport=tcp" CMUX_ETURNAL_USER="$user" \
  CMUX_ETURNAL_CREDENTIAL="$cred" CMUX_ETURNAL_CA_DER="$work/etc/crt.der"
cd "$repo/cmux-next-ios/rust"
cargo test -p cmux-mobile-link --test loopback wireguard_with_udp_blocked_rides_a_real_eturnal_over_tls \
  -- --ignored --nocapture 2>&1 | tee "$work/test.log" || { echo "--- eturnal log" >&2; tail -30 "$work/eturnal.log" >&2; exit 1; }
grep -q "udp-blocked path: turn-tls" "$work/test.log" || { echo "FAIL: the link did not report turn-tls" >&2; exit 1; }
grep -qi "allocat" "$work/eturnal.log" || echo "(eturnal log has no allocation line; the test above is the proof)"
echo "PASS: UDP blocked, eturnal reached over TLS, path turn-tls"
