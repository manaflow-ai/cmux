# mobile link connectivity

> Superseded in part (2026-10-19, `feat-cnx-ios-turntls`): the Worker relay
> frames this note measures are retired. WireGuard without UDP now rides TURN
> over TLS on 443; see PROTOCOL.md "WireGuard paths" and
> `verify/transport-wireguard-everything.md`.

## WireGuard performance: before and after (2026-10-13, afternoon)

Branch `feat-cnx-ios-wgperf`. `cmux-mobile-dial` (release) on Aziz's MacBook,
`cmux-mobile-host` (release, with `cmux-mobile-stub-tui`) on `mini-cmuxs-mac-mini-2` under
`~/cmux-next-ios-e2e/wgperf` (user-local, removed afterwards), personal space of
the DEBUG dev account (tokens in 0600 files, deleted afterwards), Tailscale
excluded, 50 pings and a 10 MiB echo per run. "Before" is the binaries of
`feat-cnx-ios-relay` (same Rust as this branch's base), "after" is this
branch with Worker 0.6.0. The runs alternated within 25 minutes.

| Mode | Build | Path | Runs passed (10 MiB echo) | RTT median (range of medians) | Echo each way |
| --- | --- | --- | --- | --- | --- |
| WireGuard, relay only | before | `relay` (Worker) | 3 of 8 (4 `keepalive timed out`, 1 tunnel closed) | 238 to 345 ms | 3.3 to 4.2 Mbit/s |
| WireGuard, relay only | after | `turn` | 5 of 5 | 14.4 to 14.9 ms | 15.0 to 78.7 Mbit/s (median 32.0) |
| WireGuard, relay only, `--no-turn` | after | `relay` (Worker) | 4 of 5 (1 WireGuard handshake timed out mid-echo) | 56.7 to 66.5 ms | 5.2 to 5.7 Mbit/s |
| WireGuard, default | before | `direct` (same LAN) | 5 of 6 (1 signaling reset) | 0.5 ms | 223 to 247 Mbit/s |
| WireGuard, default | after | `direct` (same LAN) | 5 of 5 | 0.5 to 0.7 ms | 58 to 238 Mbit/s |
| WebRTC, relay only | before | `turn` | 1 of 6 (5 `offline` or timed out, see finding 4) | 14.6 ms | 19.5 Mbit/s |
| WebRTC, relay only | after | `turn` | 5 of 5 | 14.8 to 15.6 ms | 12.1 to 134.7 Mbit/s |

WireGuard relay-only RTT is now 0.97x the TURN RTT of WebRTC (target 1.5x),
the 10 MiB echo passed 5 of 5, and throughput was at least 15 Mbit/s and
usually above 30 Mbit/s. Today the mini's UDP to the LAN worked, so the
default mode went direct; the one-way case is covered by the Rust test
`wireguard_one_way_lan_settles_on_turn`.

### Findings

1. **The Worker relay's latency is Cloudflare routing, not our code.** The
   `workers.dev` address answered from `CDG` (Paris) at 14:20, from `PDX` at
   14:30 and from `DFW` at 14:40, while `cloudflare.com` and
   `turn.cloudflare.com` answered from `SJC` with 7 to 10 ms. ICMP to the
   Worker's address took 10 ms, but TCP took 148 ms to connect: the traffic
   was forwarded to a far colo after reaching the edge, which happens to
   free-plan traffic. Each relayed datagram crosses ingress, hub and
   ingress again for both sockets, and the two sockets can enter at
   different colos, so RTT ran 240 to 345 ms. The personal hub runs in `SJC`
   (`GET /v1/teams/:id/hub`). A WebSocket round trip to it measured 290 ms
   before the 0.6.0 deploy and 47 ms after, through `PDX` both times.
2. **Fix: WireGuard over TURN.** The dialer now allocates on Cloudflare TURN,
   which is well routed, and offers the relayed address. The Mac sends to it
   like to any endpoint, so old Macs work unchanged. This path does not use
   the Worker, so it has the same RTT as WebRTC.
3. **`keepalive timed out` was head-of-line blocking.** The link's keepalive
   ping waited behind up to 10 MiB of queued echo data (the writer queue
   holds 1024 frames of up to 256 KiB). At 4 Mbit/s the ping waited more
   than 20 s, and a healthy link closed. Pings and pongs now go ahead of
   data, and any inbound frame counts as life. Red-green tests:
   `ping_overtakes_queued_bulk_data` and `keepalive_counts_any_inbound_frame`.
4. **A stale tunnel broke the next dial.** After a WireGuard session ended
   without `bye`, the Mac's tunnel kept sending relay frames. The Worker
   answered every frame with an `offline` error, and every dial in progress
   on that socket failed on the first error: "device is offline" on 5 of 6
   WebRTC runs. Now dials ignore errors naming another session, a closed
   tunnel sends `bye`, and the Worker sends one refusal per session every
   5 s. One run also saw the Worker close the Mac's socket with 1013
   "Service overloaded".
5. **Path flapping.** A side that received the peer's LAN UDP made it the
   route even when its own UDP to that address was refused (`EHOSTUNREACH`),
   and then stopped spraying the other endpoints, so it never found the TURN
   address. Refused addresses are now never the route. A changed route
   needs a new marker, and a route silent for 14 s falls back to the relay.
6. **The Worker relay is still slow under bulk load**, about 5.5 Mbit/s at
   60 ms RTT. The 256 KiB TCP window would allow about 35 Mbit/s, so the
   limit is the cost per WebSocket message in the hub (one message per
   datagram). The binary rate limit (4000/s, burst 8000) was not the cap
   at these rates; it is now 12000/s, burst 24000. Batching datagrams per
   message is the next step if the Worker relay must carry bulk data. With
   TURN it is only the fallback.
7. **Hub placement.** New hubs get a `locationHint` from the caller's
   geolocation instead of the colo that received the first request, so a
   day of bad ingress can no longer place a hub far away for good. Existing
   hubs keep their place.

Rerun (tokens in 0600 files, never printed):

```bash
cmux-mobile-dial --base-url https://cmux-mobile-api-dev.debussy.workers.dev --token-file <token> \
  --team personal-<sub> --mac <mac device id> --exclude-cgnat --pings 50 \
  --transport wireguard --relay-only [--no-turn]
curl -H "authorization: Bearer $(cat <token>)" \
  https://cmux-mobile-api-dev.debussy.workers.dev/v1/teams/personal-<sub>/hub
```

## Relay only: simulated distant network (2026-10-13)

Every Mac reachable from the office sits behind the same NAT, so a distant
phone is simulated by forcing relayed paths. Relay only is a phone-side dial
option (`ConnectOptions.relayOnly` in the FFI, `cmux-mobile-dial --relay-only`,
Settings → Developer → "Relay only (simulate distant network)" in DEBUG and
Demo builds). WebRTC uses ICE transport policy `relay`, so only TURN
candidates from `/v1/ice` are used. WireGuard sends no endpoints and ignores
the Mac's, so it stays on the Worker's relay frames. The Mac needs no change.

Setup:
- Client: `cmux-mobile-dial` (release, branch `feat-cnx-ios-relay`) on Aziz's MacBook.
- Mac: `cmux-mobile-host` from the same branch on `mini-cmuxs-mac-mini-2`, started
  with `scripts/host/run-host.sh` under `~/cmux-next-ios-e2e/relay` (user-local,
  removed afterwards). It ran a real cmux-tui session daemon with the
  workspaces `cmux-mobile-demo` and `notes`, and acpmux.
- Service: dev Worker v0.3.0. `/v1/ice` now returns Cloudflare TURN (6 TURN
  URLs, ttl 14400) plus STUN.
- Account: the dev test account from 1Password. Tokens stayed in 0600 files,
  the mini got the refresh token over ssh stdin, and every token file was
  deleted afterwards.
- Both sides used Tailscale exclusion (`--exclude-cgnat`,
  `CMUX_MOBILE_EXCLUDE_CGNAT=1`). `cmux-mobile-dial` ran 50 pings, a 10 MiB echo, and
  `daemon` `identify` (answered by cmux-tui, protocol 12) plus `run`, which
  was refused `forbidden`.

### cmux-mobile-dial, personal space

| Mode | Transport | Path | Signaling | Connect (total) | RTT min / median / p95 / max | 10 MiB echo | `identify` |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Relay only | WebRTC | `turn` | 3972 ms | 16.0 s | 14.2 / 28.3 / 82.6 / 253 ms | 6.4 s, 13.1 Mbit/s each way | ok |
| Relay only, rerun | WebRTC | `turn` | 597 ms | 3.1 s | 13.6 / 14.8 / 17.7 / 22.9 ms | 0.88 s, 94.9 Mbit/s each way | not run |
| Relay only | WireGuard | `relay` | 744 ms | 1.6 s | 237 / 239 / 245 / 247 ms | 16.7 s, 5.0 Mbit/s each way (3 of 4 runs passed; another took 19.3 s, 4.3 Mbit/s; one closed with `keepalive timed out`) | ok |
| Default | WebRTC | `direct` (same LAN) | 1188 ms | 4.8 s | 0.5 / 1.1 / 5.2 / 5.7 ms | 3.6 s, 23.6 Mbit/s each way | ok |
| Default | WireGuard | `relay` (one-way UDP, see below) | 518 ms | 1.2 s | 235 / 237 / 245 / 289 ms | failed 3 of 3 (`keepalive timed out`); 4 MiB took 8.2 s, 4.1 Mbit/s | ok |

### App (simulator `cmux-mobile-relay-ios26`, iOS 26.5, headless)

The app signed in with the same account. That account has one Stack team,
so the app used the team and not the personal space; `cmux-mobile-host` was
restarted in that team for these runs. `verify/record-live.sh <udid> <dir> 75
relay-only <transport>` ran the DEBUG demo `relay-only`. It starts with
relay only off. After 14 s it opens Settings → Developer, switches Relay
only on through the toggle's `UserDefaults` key, and returns to Workspaces.
Evidence is git-ignored, in `verify/evidence/2026-10-13/relay/{webrtc,wireguard}`
(`live.mp4`, `app.log`, stills).

| Transport | Before (relay only off) | After switching relay only on | Workspaces |
| --- | --- | --- | --- |
| WebRTC | `Connected · WebRTC direct · 1 ms` (2.5 s after the dial) | Redialed with `relayOnly=true`: `Connected · WebRTC TURN · 14 ms` 4.5 s later; RTT 14 to 43 ms afterwards | `cmux-mobile-demo` and `notes` listed under "cmux mini 2 · Online" before and after |
| WireGuard | `Connected · WireGuard relay · 324 ms` (2.0 s) | Redialed: `Connected · WireGuard relay · 297 ms` 1.9 s later; RTT 288 to 374 ms afterwards | same |

CmuxMobileLiveTests (31 tests, including `relayOnlyChangeRedials` and
`relayOnlyReachesTheDialer`) pass on `cmux-mobile-relay-ios26`. The Rust tests
`wireguard_relay_only_stays_on_the_relay` and
`webrtc_relay_only_without_turn_fails_fast` (cmux-mobile-link-ffi) cover the core.

### Findings

1. **TURN works.** Relay-only WebRTC connected over TURN every time and has
   the best RTT of the relayed paths (about 15 ms; Cloudflare's anycast TURN
   is nearby). The first connect took 16 s: signaling alone took 4 s while
   Stack was slow (below), and ICE took 12 s. The rerun connected in 3.1 s.
2. **The Worker relay is far away today.** Its RTT was about 240 ms in the
   personal space and 290 to 370 ms in the Stack team, against 27 ms on
   2026-10-12. A TeamHub Durable Object stays where it was first created, so
   these hubs (a new account) likely live in a distant region. That is a
   realistic distant path, but it caps WireGuard at about 5 Mbit/s.
3. **WireGuard bulk transfer over the relay is fragile.** A 10 MiB echo
   sometimes ends with `keepalive timed out` (relay only: 1 of 4 runs).
   Without relay only it failed 3 of 3. Here UDP works only from the phone
   to the Mac, so the phone sends over the LAN and the Mac answers through
   the 240 ms relay. Small transfers and the app's daemon traffic were fine.
   The relay drops binary frames above 4000/s without notice, and smoltcp's
   retransmissions may then starve the 10 s keepalive. Not yet confirmed.
4. **Stack was rate-limiting during this run.** Password sign-in and token
   refresh returned 429 several times. Worker calls with a valid token
   intermittently returned 401 after about 6 s, consistent with the
   Worker's JWKS fetch from Stack timing out. `cmux-mobile-host` recovered by
   itself after about 5 minutes of backoff, and `cmux-mobile-dial` was retried.
5. Every `cmux-mobile-dial` run registers a new phone device. The backend has no
   delete route, so those registrations remain.

To rerun (tokens in 0600 files, never printed):

```bash
cmux-mobile-dial --base-url https://cmux-mobile-api-dev.debussy.workers.dev --token-file <token> \
  --team <team> --mac <mac device id> --exclude-cgnat --daemon --pings 50 \
  --transport webrtc --relay-only     # or --transport wireguard; drop --relay-only to compare
```

## Earlier runs (2026-10-12)

Client: `cmux-mobile-dial` (release) on Aziz's MacBook (macOS 27.0.1).
Mac: `cmux-mobile-host` (release) on `mini-cmuxs-mac-mini-2` (macOS 27.0.1), built
from `feat-cnx-ios-rust` under `~/cmux-next-ios-e2e`, started over SSH as `cmux`.
Both runs used `--exclude-cgnat` / `CMUX_MOBILE_EXCLUDE_CGNAT=1`, so neither side
offered or used a Tailscale (100.64.0.0/10) address.

### Live backend run (Worker v0.3.0, personal space)

Credentials: password sign-in with the DEBUG dev credential from
`CmuxAuthRuntime`. Tokens were kept in 0600 files and never printed; the
mini got the refresh token over ssh stdin, and every token file was deleted
afterwards. Team `personal-<sub>`. `cmux-mobile-host` registered the mini and
`cmux-mobile-dial` registered a phone device in that space. `/v1/ice` returns STUN
only (the TURN secrets are empty). Both sides used Tailscale exclusion.
`daemon` ran against `cmux-mobile-stub-tui`: `identify` was answered and `run`
refused (`forbidden`) on every successful link.

| Transport | Path | Signaling | Connect (total) | RTT min/median/max | 10 MiB echo |
| --- | --- | --- | --- | --- | --- |
| WebRTC (STUN only) | none: ICE timed out (25 s) | n/a | n/a | n/a | n/a |
| WireGuard | relay through the Worker | 377 ms | 568 ms | 21 / 27 / 124 ms | 13.1 s, 6.4 Mbit/s each way |
| WireGuard, forced relay | relay through the Worker | 350 ms | 545 ms | 21 / 26 / 72 ms | 11.8 s, 7.1 Mbit/s each way |

Why no direct path: both hosts share one NAT, and the mini's sshd-launched
`cmux-mobile-host` cannot send UDP to the LAN, so UDP works only from the phone to
the Mac. WireGuard detects this (no `0xff` marker comes back) and stays on
the relay. WebRTC has no TURN to fall back on.

### Distant run: not done

- No Freestyle API key on this Mac: `~/.secrets/freestyle-beta.env` is
  missing, and no other `.env` holds one.
- The Blacksmith CLI is not installed.
- Every reachable fallback host shares the same public IP (104.184.154.177):
  Aziz's other MacBook and all `mini-cmux*` hosts.
- AWS Macs (via `cmux-lawrence`) are on another network but were not
  approved for this, so I did not use them.

Expected once a VM exists: WireGuard over the Worker relay works from an
IPv6-only VM, since `cmux-mobile-dial` then sends no endpoints. WebRTC needs TURN,
because the mini has no global IPv6.

To rerun (tokens in 0600 files, never printed; the team is `personal-<sub>` or a Stack team):

```bash
# Mac (over ssh; token piped on stdin into ~/cmux-next-ios-e2e/token, mode 0600)
CMUX_MOBILE_BASE_URL=https://cmux-mobile-api-dev.debussy.workers.dev CMUX_MOBILE_TEAM_ID=<team> \
CMUX_MOBILE_ACCESS_TOKEN_FILE=~/cmux-next-ios-e2e/token CMUX_MOBILE_EXCLUDE_CGNAT=1 \
CMUX_MOBILE_TUI_SOCKET_DIR=~/cmux-next-ios-e2e/sock ~/cmux-next-ios-e2e/target/release/cmux-mobile-host
# client
cmux-mobile-dial --base-url https://cmux-mobile-api-dev.debussy.workers.dev --token-file <token> \
  --team <team> --mac <mac device id> --exclude-cgnat --daemon [--force-relay]
```

### Fake backend run (real network, no Stack credentials)

Signaling and relay frames went through `cmux-mobile-fake-backend` on this Mac,
reached by the mini over Tailscale (signaling only). STUN was Cloudflare's.
The `daemon` service ran against `cmux-mobile-stub-tui`. The mini has no cmux-tui
binary or session; its `~/.local/bin/cmux` is the macOS app CLI.

**The network turned out not to be distant.** Both machines sit behind the same
NAT (same public IP 104.184.154.177, same gateway 172.20.20.1). The mini's
`cmux-mobile-host`, started from sshd, gets `EHOSTUNREACH` sending UDP to this
Mac's LAN address. macOS Local Network privacy is the likely cause. So UDP
works in one direction only: phone to Mac.

| Transport | Path | Connect | RTT min/median | 10 MiB echo | daemon |
| --- | --- | --- | --- | --- | --- |
| WebRTC | none (ICE timed out after 25 s) | n/a | n/a | n/a | n/a |
| WireGuard | relay (Mac→phone), UDP (phone→Mac) | 65 ms | 0.7 / 0.9 ms | 0.65 s, 129 Mbit/s each way | `identify` ok; `run` refused `forbidden` |
| WireGuard, forced relay | relay | 13 ms | 0.5 / 0.5 ms | 0.62 s, 135 Mbit/s each way | same |

RTTs are sub-millisecond because the relay here is this Mac's fake backend
on the same LAN, not the Cloudflare Durable Object.

- **WebRTC:** ICE needs connectivity checks in both directions. With
  Mac→phone UDP refused, no hairpin NAT, and no TURN from the fake backend's
  `/v1/ice`, there is no usable pair. The real backend's TURN servers should
  fix this. Not yet measured.
- **WireGuard, first attempt:** it failed. The Mac received the phone's UDP,
  switched to UDP-only replies it could not deliver, and the handshake never
  finished. The fix is commits `84f5e39f122` (red test) and `e2c06295cc7`
  plus the follow-up marker commit. A side now goes UDP-only only after the
  peer's `0xff` relay marker confirms its UDP arrives (PROTOCOL.md). The rerun
  above held the link on the relay.
