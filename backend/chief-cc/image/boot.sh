#!/usr/bin/env bash
# Joins a Cloud Chief VM made from the chief-cc snapshot to the tailnet (chief-brain-cc/vm.ts runs it
# once per VM, as root, with the one-use tailnet auth key on stdin). The key goes to a root-only
# tmpfs file, is used once by `tailscale up`, and is deleted. Then the agent user's tailnet block
# and the model forward (proxy.mjs) are checked. Prints "ready" on success.
set -euo pipefail
host="${1:?hostname}"
upstream="$(cat /etc/chief-cc/upstream)"
umask 077
install -d -m 700 /run/ts /run/chief
cat > /run/ts/key
systemctl start tailscaled
tailscale up --auth-key=file:/run/ts/key --hostname="$host" --accept-dns=false --accept-routes=false --timeout=30s
rm -f /run/ts/key
# Until the Worker applies the Chief's network settings (apps/api/src/chief-brain-cc/net.ts, right after
# this script; by default the public Internet and DNS), the agent user (Claude Code) reaches only the
# model forward on 127.0.0.1:4017: no Internet, no tailnet address, no DNS, no other local port. The agent
# is the node's Tailscale operator (msg 8200 item 4: `tailscale status`, `tailscale ping` without root); what
# the node reaches is the tailnet policy of its tag (CHIEF_CC_TS_TAG). Root (chief-turn-runner, the notes posts) and ccproxy keep their
# network. The guest kernel has no xt_owner, so the rule is nftables `meta skuid`. systemd-resolved
# goes too: its varlink and D-Bus lookups are open to every user, and root resolves through the
# nameservers in /etc/resolv.conf without it.
tailscale set --operator=chief
chmod 755 /var/run/tailscale
systemctl mask --now systemd-resolved.service >/dev/null 2>&1 || true
uid="$(id -u chief)"
if ! nft list table inet chiefcc >/dev/null 2>&1; then
  nft add table inet chiefcc
  nft add chain inet chiefcc out '{ type filter hook output priority 0; }'
  nft add rule inet chiefcc out meta skuid "$uid" oif lo ip daddr 127.0.0.1 tcp dport 4017 accept
  nft add rule inet chiefcc out meta skuid "$uid" counter reject
fi
systemctl start chief-cc-proxy
for _ in $(seq 1 50); do
  code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$upstream/_subrouter/health" || true)"
  [[ "$code" == "200" ]] && { echo ready; exit 0; }
  sleep 0.2
done
echo "gateway not reachable" >&2
exit 3
