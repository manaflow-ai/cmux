# Cloud Chief VM: the Mac app relay

The Cloud Chief VM (Freestyle, `cloud-chief`, deployed by cmuxterm-hq
`tools/cloud-chief`) runs `optchat-chief host --conversation-source cloud` with no
cmux app. Without an app, `cmux mcp serve` lists no app tools, so Cloud Chief could
not open tabs or workspaces in the user's Mac app.

`mac-app-relay.py` serves a cmux app control socket on the VM and sends each request
line to the Mac app through the Mac gate (`mac --stdin`, lawbook0:7420 over
Tailscale, about 0.4 s per request). The host unit names it with
`CMUX_CHIEF_APP_SOCKET`; the host gives it to its turns as `CMUX_SOCKET_PATH` and
keeps its own subagent workspaces on the VM daemon.

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
User=chief
Environment=HOME=/home/chief
Environment=PATH=/home/chief/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/python3 /home/chief/.cmux/brains/chief/bin/mac-app-relay.py --listen /home/chief/.cmux/brains/chief/mac-app.sock
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
```

`cloud-chief-host.service` gains:

```ini
After=network-online.target tailscaled.service cloud-chief-mac-app.service
Wants=cloud-chief-mac-app.service
Environment=CMUX_CHIEF_APP_SOCKET=/home/chief/.cmux/brains/chief/mac-app.sock
```

`--mac-socket` defaults to `/tmp/cmux-nightly.sock` (the NIGHTLY app). For another
build, pass the socket that `cmux --json identify` prints on the Mac.

Limits: one request and one answer per line, so streams (`cmux events`) do not
work. The Mac app does not know the VM's agent sessions, so a tab opened without a
target goes to the focused pane, not beside the Chief's chat: name the pane.

Test: `python3 -I deploy/cloud-vm/tests/mac_app_relay_test.py`.
