#!/usr/bin/env bash
# Live proof of the phone's in-app tailnet node on a throwaway tailnet (headscale in docker), with
# the Linux build of the same Rust path the app links (examples/phone_probe.rs).
#
# On a private docker network labelled with a unique run id:
#   headscale  control server (sqlite, MagicDNS base_domain test.cmux, embedded DERP over HTTP)
#   mac        `phone_probe echo`: a tsnet node named `mac`, echoing on tailnet port 7000 (the
#              stand-in for the Mac's transport.tailnetCarrier listener)
#   relay      `phone_probe relay 0.0.0.0:7100`: a plain TCP echo (the stand-in for the relay)
#   phone      `phone_probe probe`: joins as `iphone` with its own ephemeral single-use key, then
#              rows for join time, direct path, carrier on (RTT), tailnet dial failing (fallback),
#              carrier off (relay), carrier on again, and Forget
# and checks the routes, then that headscale no longer lists the phone after Forget.
#
# It never touches the host's tailscaled or network: tsnet runs inside containers. Cleanup removes
# only the containers and network carrying this run's label.
#
# Usage: phone-node-e2e.sh PHONE_PROBE_BINARY   (built with
#   cargo build -p cmux-mobile-tailnet --features tsnet --example phone_probe; a glibc binary, run
#   in $RUNTIME_IMAGE, default ubuntu:24.04)
# env: KEEP=1, ROUNDS (default 200)
set -euo pipefail

BIN=${1:?usage: phone-node-e2e.sh PHONE_PROBE_BINARY}
BIN=$(readlink -f "$BIN")
HEADSCALE_IMAGE=${HEADSCALE_IMAGE:-headscale/headscale:0.27.1}
RUNTIME_IMAGE=${RUNTIME_IMAGE:-ubuntu:24.04}
ROUNDS=${ROUNDS:-200}
RUN_ID="cmux-phone-node-e2e-$(date +%s)-$$-$RANDOM"
LABEL="cmux.phone-node-e2e.run=$RUN_ID"
NET="$RUN_ID"
HS="$RUN_ID-headscale"

if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then
  DOCKER=(sudo -n docker)
else
  echo "FAIL setup: cannot reach docker (neither docker nor sudo -n docker)" >&2
  exit 2
fi
d() { "${DOCKER[@]}" "$@"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cmux-phone-node-e2e.XXXXXX")
chmod 700 "$WORK"
mkdir -m 700 "$WORK/keys"

FAILS=0
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
result() { # result PASS|FAIL name detail
  printf '%s %s%s\n' "$1" "$2" "${3:+ - $3}"
  [[ $1 == PASS ]] || FAILS=$((FAILS + 1))
}
redact() { sed 's/tskey-[A-Za-z0-9-]*/tskey-REDACTED/g; s/hskey-[A-Za-z0-9_-]*/hskey-REDACTED/g'; }

cleanup() {
  local rc=$?
  if [[ ${KEEP:-0} == 1 ]]; then
    log "KEEP=1: leaving run $RUN_ID (label $LABEL), work dir $WORK"
    return
  fi
  local ids
  ids=$(d ps -aq --filter "label=$LABEL" 2>/dev/null || true)
  [[ -n $ids ]] && d rm -fv $ids >/dev/null 2>&1 || true
  ids=$(d network ls -q --filter "label=$LABEL" 2>/dev/null || true)
  [[ -n $ids ]] && d network rm $ids >/dev/null 2>&1 || true
  rm -rf -- "$WORK"
  log "cleaned up run $RUN_ID"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

cat >"$WORK/config.yaml" <<'EOF'
server_url: http://headscale:8080
listen_addr: 0.0.0.0:8080
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 127.0.0.1:50443
grpc_allow_insecure: false
noise:
  private_key_path: /var/lib/headscale/noise_private.key
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential
derp:
  server:
    enabled: true
    region_id: 999
    region_code: headscale
    region_name: Headscale Embedded DERP
    verify_clients: true
    stun_listen_addr: 0.0.0.0:3478
    private_key_path: /var/lib/headscale/derp_server_private.key
    automatically_add_embedded_derp_region: true
    ipv4: ""
    ipv6: ""
  urls: []
  paths: []
  auto_update_enabled: false
  update_frequency: 24h
disable_check_updates: true
ephemeral_node_inactivity_timeout: 66s
database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite
    write_ahead_log: true
log:
  level: info
  format: text
policy:
  mode: file
  path: /etc/headscale/policy.json
dns:
  magic_dns: true
  base_domain: test.cmux
  override_local_dns: false
  nameservers:
    global: []
    split: {}
  search_domains: []
  extra_records: []
unix_socket: /var/run/headscale/headscale.sock
unix_socket_permission: "0770"
logtail:
  enabled: false
randomize_client_port: false
EOF
cat >"$WORK/policy.json" <<'EOF'
{ "acls": [{ "action": "accept", "src": ["*"], "dst": ["*:*"] }] }
EOF

log "run $RUN_ID: images $HEADSCALE_IMAGE, $RUNTIME_IMAGE"
d network create --label "$LABEL" "$NET" >/dev/null
d create --name "$HS" --label "$LABEL" --network "$NET" --network-alias headscale \
  "$HEADSCALE_IMAGE" serve >/dev/null
mkdir -p "$WORK/etc-headscale"
cp "$WORK/config.yaml" "$WORK/policy.json" "$WORK/etc-headscale/"
d cp "$WORK/etc-headscale/." "$HS:/etc/headscale/"
d start "$HS" >/dev/null
hs() { d exec "$HS" headscale "$@"; }
for _ in $(seq 1 60); do
  hs users list >/dev/null 2>&1 && break
  sleep 0.5
done
hs users list >/dev/null 2>&1 || { d logs "$HS" 2>&1 | tail -30; result FAIL setup "headscale did not come up"; exit 1; }
hs users create cmux >/dev/null
USER_ID=$(hs users list -o json | jq -r '.[] | select(.name=="cmux") | .id')
# What the key sheet suggests: one ephemeral, single-use, short-lived key per device.
for who in mac phone; do
  ( umask 077
    hs preauthkeys create --user "$USER_ID" --ephemeral --expiration 1h -o json | jq -r .key >"$WORK/keys/$who" )
  [[ -s $WORK/keys/$who ]] || { result FAIL setup "could not mint a key for $who"; exit 1; }
  chmod 644 "$WORK/keys/$who" # read by root in containers; the dir stays 0700
done
log "headscale up; user cmux id=$USER_ID; one ephemeral single-use key each for mac and phone"

run() { # run NAME ALIAS ARGS...
  local name=$1 alias=$2; shift 2
  d run -d --name "$RUN_ID-$name" --label "$LABEL" --network "$NET" --network-alias "$alias" \
    -e TS_DEBUG_USE_DERP_HTTP=1 \
    -v "$BIN:/usr/local/bin/phone_probe:ro" \
    -v "$WORK/keys:/run/keys:ro" \
    "$RUNTIME_IMAGE" /usr/local/bin/phone_probe "$@" >/dev/null
}
run relay relay relay 0.0.0.0:7100
run mac mac echo --state /tmp/mac --hostname mac --control-url http://headscale:8080 \
  --authkey-file /run/keys/mac --port 7000
for _ in $(seq 1 240); do
  d logs "$RUN_ID-mac" 2>/dev/null | grep -q '"echo-up"' && break
  sleep 0.25
done
MAC_UP=$(d logs "$RUN_ID-mac" 2>/dev/null | grep '"echo-up"' || true)
[[ -n $MAC_UP ]] || { d logs "$RUN_ID-mac" 2>&1 | redact | tail -20; result FAIL setup "mac node never Running"; exit 1; }
log "mac node: $MAC_UP"

T0=$(date +%s)
d run --name "$RUN_ID-phone" --label "$LABEL" --network "$NET" -e TS_DEBUG_USE_DERP_HTTP=1 \
  -v "$BIN:/usr/local/bin/phone_probe:ro" -v "$WORK/keys:/run/keys:ro" \
  "$RUNTIME_IMAGE" /usr/local/bin/phone_probe probe --state /tmp/phone \
  --control-url http://headscale:8080 --authkey-file /run/keys/phone \
  --peer mac --port 7000 --dead-port 7999 --relay relay:7100 --rounds "$ROUNDS" \
  >"$WORK/rows.jsonl" 2>"$WORK/probe.err" || true
grep -h '^{' "$WORK/rows.jsonl" | sed 's/^/    /'
grep -h '^phone_probe:' "$WORK/probe.err" | redact | sed 's/^/    err: /' || true

r() { jq -c "select(.check==\"$1\")" "$WORK/rows.jsonl" 2>/dev/null | head -1; }
JOIN=$(r join)
[[ $(jq -r .state <<<"$JOIN" 2>/dev/null) == running ]] \
  && result PASS join "phone node Running in $(jq -r .joinMs <<<"$JOIN") ms" \
  || result FAIL join "$JOIN"
PATH_ROW=$(r peer-path)
[[ $(jq -r '.peer.direct' <<<"$PATH_ROW" 2>/dev/null) == true ]] \
  && result PASS direct-path "mac seen online and direct after $(jq -r .afterMs <<<"$PATH_ROW") ms" \
  || result FAIL direct-path "$PATH_ROW"
check_route() { # check_route CHECK ROUTE [REASON]
  local row; row=$(r "$1")
  local route reason
  route=$(jq -r '.route.route // empty' <<<"$row" 2>/dev/null)
  reason=$(jq -r '.route.why.reason // empty' <<<"$row" 2>/dev/null)
  if [[ $route == "$2" && ( -z ${3:-} || $reason == "$3" ) && $(jq -r .error <<<"$row") == null ]]; then
    result PASS "$1" "$route${reason:+ ($reason)}; dial $(jq -r .dialMs <<<"$row") ms; rtt p50 $(jq -r .rttMs.p50 <<<"$row") p95 $(jq -r .rttMs.p95 <<<"$row") ms; change: $(jq -r .change <<<"$row")"
  else
    result FAIL "$1" "$row"
  fi
}
check_route carrier-on tailnet
check_route carrier-direct-only tailnet
check_route tailnet-dial-fails relay dial-failed
check_route carrier-off relay setting-off
check_route carrier-on-again tailnet
FORGET=$(r forget)
[[ $(jq -r .ok <<<"$FORGET" 2>/dev/null) == true ]] && result PASS forget "logged out, state removed" || result FAIL forget "$FORGET"
GONE=0
for _ in $(seq 1 40); do
  if ! hs nodes list -o json 2>/dev/null | jq -e '[.[]? | select(.given_name=="iphone")] | length > 0' >/dev/null; then
    GONE=1; break
  fi
  sleep 0.5
done
[[ $GONE == 1 ]] && result PASS forget-removes-node "headscale no longer lists iphone" \
  || result FAIL forget-removes-node "$(hs nodes list -o json | jq -c '[.[]? | {given_name, online}]')"
log "probe took $(( $(date +%s) - T0 )) s"

[[ $FAILS == 0 ]] && log "all checks passed" || log "$FAILS check(s) failed"
exit "$FAILS"
