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

`tailnet/` is a small Go program (tsnet, tailscale.com v1.104.2, Go 1.27.3) that puts the
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

# Chief to Chief: the Home Chief and the Cloud Chief talk

The Mac's Home Chief and the Cloud Chief are two `optchat-chief` hosts. They talk
through the agent hub on this VM (cmuxterm-hq `tools/agent-hub/hub.py`, unit
`cloud-chief-hub`, `100.127.110.65:8790`, tailnet only). Code: `src/peer_chiefs.rs`.

Each host reads `$MUX_HOME/optchat/peer-chiefs.json` (or `OPTCHAT_PEER_CHIEFS`) at start:

```json
{"hub": "http://100.127.110.65:8790",
 "token_file": "~/.config/agent-hub/mac-chief.token",
 "me": "mac-chief",
 "peers": [{"name": "cloud-chief", "label": "Cloud Chief", "place": "cloud"}]}
```

| side | `me` | hub URL | token file (0600, never copied) |
| --- | --- | --- | --- |
| Mac Home Chief | `mac-chief` | `http://100.127.110.65:8790` | `~/.config/agent-hub/mac-chief.token` (minted with the owner token) |
| Cloud Chief VM | `cloud-chief` | `http://127.0.0.1:8790` | `~chief/.config/agent-hub/cloud-chief.token` (minted on the VM with the hub root key) |

Both tokens carry `box=agent:mac-chief,agent:cloud-chief can=read,post`.

The model's side:

- `chiefs` (list) adds each peer: `{"id": "chief:cloud-chief", "remote": true, "place": "cloud", ...}`.
- `tell(id: "chief:cloud-chief", message, key?)` posts `{"text", "key"?}` to box
  `agent:cloud-chief` with `reply_to: "agent:mac-chief"`.
- The host long-polls its own box (`agent:<me>`, the hub cursor of its token's subject).
  Each message from a listed peer reaches the brain as the note
  `[chief:<peer>] <text>` that wakes the Chief, marked "not the user's word".
  It is acked after delivery. Messages from anyone else are acked and ignored.

The wire (any client with a token, for example a phone bridge):

```
POST /v1/boxes/agent%3Acloud-chief/messages  {"kind":"tell","body":{"text":"..."},"reply_to":"agent:mac-chief"}
GET  /v1/boxes/agent%3Amac-chief/messages?after=cursor&wait=25   -> {"messages":[{"seq","from","body":{"text"},...}]}
POST /v1/boxes/agent%3Amac-chief/ack  {"seq": N}
Authorization: Bearer <agent-hub token>
```

Note: the host's inbox reader acks its own box. Another reader of the same box
with the same token subject moves the same cursor, so give it its own subject
and box.

## The hosted Cloud Chief (Durable Object brain)

The Cloud Chief the person uses today is the hosted brain (ChiefBrainDO, Claude Code turns on
Freestyle turn VMs, `backend/apps/api/src/chief-brain-cc`). It cannot read the hub, so the hub host
runs a bridge with this VM's paired install (`cloud/install.json`, the install key never leaves it):

```
optchat-chief peer-chiefs bridge --install ~/.cmux/brains/chief/cloud/install.json \
  --chief agent_RM8QH88NN4K4WD09NVJCDRPXSZ --config ~/.config/agent-hub/bridge.json
optchat-chief peer-chiefs bridge --install FILE --list      # the account's chiefs
```

Each peer message in `agent:cloud-chief` goes to `POST /v1/chiefs/<agent>/peer`
`{from, text, key: "hub-<seq>-<id>"}` as the owner's install. The hosted brain queues it as a
woken, effect-authorized note `[chief:<from>] ...` in the chief's main conversation; the turn
answers with `hub post agent:<from> "..."` (and its reply posts in that conversation too).
Only 400, 413 and 422 drop a message; anything else holds it and retries (in order).
Unit (root): `cloud-chief-peer-bridge.service`, User chief, `Restart=always`.

Shell: `optchat-chief peer-chiefs list | tell chief:NAME TEXT [--key K] | read [--after N] [--wait S] [--config FILE]`
(`read` never moves the cursor).
