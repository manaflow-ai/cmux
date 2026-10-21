# Cloud Chief VM: the Mac diagnostics relay

The Cloud Chief VM (Freestyle, `cloud-chief`, deployed by cmuxterm-hq
`tools/cloud-chief`) runs `optchat-chief host --conversation-source cloud` with no
cmux app. The VM is a remote security boundary: its Chief and subagents get no Mac
app actions. Only bounded app diagnostics cross the relay.

`mac-app-relay.py` serves a cmux app control socket on the VM and sends each request
line to the Mac app through the Mac gate (`mac --stdin`, lawbook0:7420 over
Tailscale, about 0.4 s per request). The host unit names it with
`CMUX_CHIEF_APP_SOCKET`; the host gives it to its turns as `CMUX_SOCKET_PATH` and
keeps its own subagent workspaces on the VM daemon. The relay refuses every
`action.run` and any method outside `system.ping`, `system.identify`, and
`system.capabilities`.

When the Mac is asleep or the app is closed, the relay answers `app.unreachable`
with the reason, the host keeps the last known tool list
(`session/.claude/cmux-tools-last.json`) and its log says why.

## Units (root, on the VM)

`/etc/systemd/system/cloud-chief-mac-app.service`:

```ini
[Unit]
Description=Cloud Chief Mac app relay (cmux app socket to the Mac app through the Mac gate)
After=network-online.target tailscaled.service
Wants=network-online.target
[Service]
User=cloud-chief-relay
Group=cloud-chief-app
Environment=HOME=/var/lib/cloud-chief-relay
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/python3 /usr/local/lib/cloud-chief/mac-app-relay.py --listen /run/cloud-chief-app/cmux.sock --socket-mode 0660
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
```

`cloud-chief-host.service` gains:

```ini
After=network-online.target tailscaled.service cloud-chief-mac-app.service
Wants=cloud-chief-mac-app.service
Environment=CMUX_CHIEF_APP_SOCKET=/run/cloud-chief-app/cmux.sock
```

`--mac-socket` defaults to `/tmp/cmux-nightly.sock` (the NIGHTLY app). For another
build, pass the socket that `cmux --json identify` prints on the Mac.

Limits: one request and one answer per line; streams and app actions do not work.
The relay service account alone holds the Mac-gate token. The Chief account can
connect to the group-owned socket but cannot read that token or widen the relay.

Test: `python3 -I deploy/cloud-vm/tests/mac_app_relay_test.py`.

# The user's own tailnet: `cmux-chief-tailnet`

`tailnet/` is a small Go program (tsnet, tailscale.com v1.104.1) that puts the
Chief VM on **the user's** tailnet as its own device, next to the VM's system
tailscaled (cmux's infra tailnet). Like Rex's built-in Tailscale it embeds
Tailscale, so the node answers only what it serves: Tailscale SSH as `chief`.
No other VM port is reachable from the user's tailnet (a second userspace
tailscaled would forward every port to the VM's loopback, where acpmux and
optchat-chief listen). Design: cmux-prompts `logs/chief-vm-tailscale-DESIGN.md`.

```
cmux-chief-tailnet up [--name "Cloud Chief"] [--advertise-tag tag:x] [--json]
    # prints auth_url: the user opens it, signs in, approves the device
cmux-chief-tailnet status [--json]   # Off | NeedsLogin | Running (dns_name, ips, owner) | Failed
cmux-chief-tailnet down              # logout: the device leaves the tailnet; state deleted
```

Off by default. State: `~chief/.cmux/brains/chief/tailnet/` (`enabled`, `state/`,
`ctl.sock`). cmuxterm-hq `tools/cloud-chief/vm/boot.sh` installs it with
`cloud-chief-tailnet.path` (starts the node when `enabled` exists) and
`cloud-chief-tailnet.service` (user chief, `Restart=on-failure`), and adds a
note to the Chief's `~/.claude/CLAUDE.md` so "add yourself to my tailnet" works
from the chat. A VM copied from a snapshot (other `/etc/machine-id`) refuses to
reuse the node and says to run `down`, then `up`.

Build (linux, about 3 min): `cd tailnet && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /tmp/cmux-chief-tailnet .`
Test: `cd tailnet && go test ./...`. Install on the VM: hq `tools/cloud-chief/deploy.sh tailnet install /tmp/cmux-chief-tailnet`.
