# Link reliability, 2026-10-23

The user reported that cmux mobile (Production, iPhone 16 Plus, build 49500 = feat-cmux-next
`3132ab4a33`) was slow to connect to the Macs, or did not connect at all. This note covers
what the two Macs' host logs show, what the rig reproduced, the root causes and the fixes.

## The real hosts (read only)

| Mac | App | cmux-mobile-host | Has #23829 (WireGuard handshake repeats, all LAN interfaces) |
| --- | --- | --- | --- |
| This laptop | cmux NIGHTLY | `7822fca9f292` | yes |
| The other MacBook | cmux NEXT (started 2026-10-21 14:50, never updated) | `331e2e901ce3` | **no** |

Both Macs are on the same home network (the same public address, Cloudflare colo SJC). The
phone is device `913dfcf6-…`.

### Every WireGuard link today, from the hosts' logs (UTC)

| Mac | Link up | Path | link_ready | Down | Lived | Reason | Media session |
| --- | --- | --- | --- | --- | --- | --- | --- |
| laptop | 01:45:35 | Turn | 370 ms | 01:46:10 | 35 s | keepalive timed out | none |
| laptop | 02:15:26 | Turn | 326 ms | 02:18:32 | 3 min 6 s | keepalive timed out | none |
| laptop | 05:48:34 | Turn | 320 ms | 05:49:40 | 66 s | keepalive timed out | up (Turn) 20 s, then failed; video moved into the tunnel 05:49:15, tunnel silent from about 05:49:12 |
| laptop | 05:51:13 | Turn | 277 ms | 05:52:03 | 50 s | keepalive timed out | up, failed after 38 s |
| laptop | 05:52:21 | Turn | 407 ms | 05:53:11 | 50 s | keepalive timed out | up, failed after 37 s |
| laptop | 14:48:31 | TurnTls | 5164 ms | 14:49:10 | 39 s | peer closed the link | failed (timed out; ICE failed) |
| laptop | 14:49:14 | Turn | 3931 ms | ? | | | up (**Direct**) |
| laptop | 14:50:44 | Turn | 4421 ms | 14:51:19 | 35 s | keepalive timed out | failed (ICE failed at 11 s) |
| laptop | 14:51:00 | Turn | 1251 ms | 14:51:35 | 35 s | keepalive timed out | failed |
| laptop | 20:00:47 | TurnTls | 5972 ms | 20:01:11 | 24 s | peer closed the link | none |
| laptop | 20:01:23 | Turn | 9006 ms | 20:01:47 | 24 s | peer closed the link | failed |
| laptop | 20:01:53 | Turn | 5944 ms | 20:02:15 | 22 s | peer closed the link | failed twice |
| laptop | 20:02:20 | Turn | 4482 ms | 20:02:59 | 39 s | peer closed the link | failed, then up (Turn) at 20:02:42 |
| laptop | 20:03:06 | Turn | 5968 ms | 20:03:41 | 35 s | keepalive timed out | failed twice |
| other | 05:48:40, 05:51:18, 05:52:26 | Turn | 5369, 5524, 5405 ms (a `REKEY_TIMEOUT` just before each) | | 45–65 s | keepalive timed out | |
| other | 14:48:41, 14:51:00, 20:00:53, 20:02:27 | Turn, TurnTls | 7012, 1575, 8979, 10150 ms | | 22 s – 2 min | keepalive / peer closed | |

What this says:

1. **No link lived longer than about three minutes, and most died within 22 to 66 s.** The
   two reasons are the same failure seen from either end. "keepalive timed out" is the Mac's
   own 15 s ping going unanswered for 20 s (15 + 20 = 35 s). "peer closed the link" 22–24 s
   after link up is the phone's first heartbeat (15 s) timing out (8 s) and the phone
   closing the link and redialing. In both, the tunnel stopped carrying data a few seconds
   after link up: boringtun's `HANDSHAKE(KEEPALIVE + REKEY_TIMEOUT)` (data sent, nothing back
   for 15 s) fires 15–20 s after link up.
2. **Every WireGuard link was relayed** (`Turn` or `TurnTls`), even though the media
   session beside one of them (14:49:23) found a **direct** WebRTC path to the same phone.
   Direct UDP between this phone and this Mac works; WireGuard does not find it.
3. **Link up is slow on the laptop despite #23829** (1.3 to 9 s), and on the other Mac it is
   the old 5 s `REKEY_TIMEOUT` stall because that host predates #23829. The other Mac's
   cmux NEXT has not updated since 2026-10-21; it needs a restart into a newer build (not
   done here: read only).
4. **The media session fails on almost every link**: ICE checking finds no pair and fails
   after about 11 s (`MEDIA_ICE_FAILED` 8 s after the last candidate). On the TurnTls links
   the phone's network passes no UDP to the TURN server, and the media session (webrtc-rs:
   TURN over UDP only) cannot work there at all, yet it is retried on a 1–30 s backoff.
5. **Signaling resets** ("Connection reset without closing handshake"): see below.

## The two kinds of drop

The logs split the drops into two kinds, and they need different readings.

- **"keepalive timed out" (the Mac's side), 35 to 66 s after link up.** boringtun's
  `HANDSHAKE(KEEPALIVE + REKEY_TIMEOUT)` comes first: nothing at all arrived from the
  phone for 15 s. On 05:48 and 05:51 the WebRTC media track (a separate UDP path and
  separate sockets) stalled at the same moment as the tunnel (video moved back into the
  tunnel at 05:49:15, the tunnel silent since about 05:49:12). Two independent paths
  dying together means the phone stopped sending: the app was suspended (screen locked
  or another app opened) or the phone lost its network. That is the Mac doing its job.
  The cost is on the way back (below).
- **"peer closed the link", 22 to 24 s after link up.** The phone closed the link. There
  is **no** `HANDSHAKE(KEEPALIVE …)` line before any of them (20:00:47, 20:01:23,
  20:01:53, 20:02:20, 14:48:31): the tunnel was delivering. 22 to 24 s is the phone's
  first heartbeat (15 s after link up) plus its 8 s ping timeout. The ping is a control
  frame, but on the Mac its pong is written after whatever already sits in the link's
  TCP stream inside the tunnel (the workspace tree, a 69 KB terminal replay, Chief's
  history, browser video). On a slow relay (TURN over TLS on a weak network) that queue
  takes more than 8 s to drain, so **the phone closed live links and redialed for 4 to
  9 s, over and over.** The same probe runs with 2 s after a foreground and 1.5 s when
  presence changes (every signaling reset), so each reset could close a busy link too.

The link's own keepalive (Rust, 15 s ping, 20 s timeout) already counts any inbound frame
as life; only the app's probes did not.

## Root causes and fixes

| # | Cause | Evidence | Fix |
| --- | --- | --- | --- |
| 1 | The app's link probes (heartbeat 8 s, foreground 2 s, presence 1.5 s) failed a link whose pong was late behind a busy queue, and closed it | "peer closed the link" 22–24 s after link up, no WireGuard handshake timeout before it, five times on 2026-10-23 | `Link::probe(timeout)`: alive on the pong **or on any frame from the peer after the ping went out**; fails only on silence. FFI `LinkHandle.probe`, `MacLink.probe`; `LinkController` probes with it. Tests: `link::tests::a_probe_counts_any_inbound_frame_and_fails_only_on_silence` (Rust), `LinkProbeTests.aBusyLinkWithALatePongIsKept` (Swift: red on the old code, 2 dials and the link closed) |
| 2 | Every WireGuard dial and roam waited for **every** STUN server, up to 1.5 s. Cloudflare lists STUN on 3478 and on 53; cellular networks often answer or drop UDP 53 | Code (`gather_endpoints`, `roam`); the test below measured 1.501 s | Once one server answered, the others get 150 ms (`STUN_GRACE`). Test `a_silent_stun_server_does_not_hold_the_gather`: red 1.501 s, green |
| 3 | Signaling resets every 30 to 60 min | Prod Worker tail 20:30–22:53 UTC: the hub's sockets closed with 1006 and `Internal error in Durable Object storage caused object to be reset` (22:37:02); one prod deploy all day (04:20 UTC); the minute sweep ran 87 times and closed 0 sockets; the same reset times on both Macs and on the rig minis | Not ours: Cloudflare resets the Durable Object. Made harmless: the Mac reconnects in 1–2 s and moves its WireGuard sessions onto the new socket (rig 21:38:18, `moved=1`); the phone's presence probe no longer closes a busy link (fix 1). No Worker change, so no deploy |
| 4 | The other MacBook's cmux NEXT runs cmux-mobile-host `331e2e901ce` (2026-10-21), without #23829 | Its link ups each wait out boringtun's 5 s `REKEY_TIMEOUT` (5.4–10.2 s) | Restart cmux NEXT on that Mac into a current build (not done here: the user's Macs are read only) |

### What did not reproduce

- **A link dying by itself.** On the rig a link lived 13 min with the phone in the
  foreground and 8 to 12 min in the relay-only run; every drop had a cause (the app
  killed or suspended, a rig Mac quitting).
- **The media session failing.** On the rig it came up Direct in 80 ms and carried the
  browser video up to 20 Mbit/s for 12 min. On the user's phone ICE fails after about
  11 s on most links. Its failure never took the WireGuard link down: the Mac moves video
  back into the tunnel at a keyframe, and links lived on after media failures (20:02:42
  media up after two failures). On a network that blocks UDP it can never work
  (webrtc-rs has no TURN over TCP or TLS); the phone retries it on a backoff.
- **Chief stuck connecting for minutes.** Mac Chief on the rig, Chief open, app sent to
  the background for 10 s, 60 s and 300 s, then back (`chief_foreground.py`): usable
  0.7, 0.8 and 1.9 s after the foreground, a message round-trip each time. The same with
  the app's process stopped while away (`--freeze`, as a device suspends it): 1.7 and
  1.3 s. On the real phone the minutes come from the links themselves: each return
  redials (4–9 s on the laptop, 5–10 s on the other Mac), and links the phone then closed
  at 22–24 s (fix 1) sent Chief back to connecting again.

## Direct path

Every WireGuard link on the rig and on the user's Macs stayed relayed, while the WebRTC
media session between the same two processes found a direct pair (14:49:23 on the
laptop, 22:01:55 on the rig).

- On the rig the hidden Mac app's hostd gets `No route to host (os error 65)` for the
  phone's LAN address: macOS Local Network privacy, which a hidden rig app can never be
  granted (wg-direct-rig-20261021.md). The phone's datagrams to the Mac's LAN address
  never arrived either.
- `CMUX_MOBILE_EXCLUDE_CGNAT=1` (set by the app) leaves Tailscale addresses out on both
  sides. The phone's Info.plist has `NSLocalNetworkUsageDescription`.
- Not explained yet: why WebRTC's direct pair has no WireGuard counterpart on the user's
  network. It needs a phone-side WireGuard trace (`CMUX_MOBILE_LOG`, added here for
  simulators) from the real phone on the same Wi-Fi. Not fixed in this PR.

## Rig

Setup:

- **Phone.** A TestFlight-configuration simulator app (`dev.cmux.app.internal`, production Worker `mobile-api.cmux.dev`, Cloudflare TURN) in one headless iPhone 17 Pro (iOS 26.5) on mini-cmux8s. It signs in to the production test account B with the simulator-only password sign-in.
- **Macs.** Two hidden rig Macs, fleet builds `--production` of this branch's base (`lrbase`) and head (`lrfix`), on mini-cmux11s (`lr-mac-a`) and mini-cmux9s (`lr-mac-b`). They are signed in to the same account, and their settings go in only through `open --env`.
- **Link.** No local socket, loopback or direct shortcut.
- **Drivers.** `verify/e2e/link_soak.py`, run through `link_soak_relay.py`, which forwards the rig commands from the laptop because the minis can't ssh to each other. `verify/e2e/chief_foreground.py`. Each run streams a terminal (`date` every 200 ms). Every minute it types a marker on the phone and reads it back from that Mac's own CLI.

| Run | Build | Network | Minutes | Echoes reached | Link ready (ms) | Drops (reason → next link up) | Media |
| --- | --- | --- | --- | --- | --- | --- | --- |
| base, 2 Macs, events | base | rig LAN (TURN path) | 30 | 7/13 before the driver lost the app | 120–330 | bg 20 s: mini11s link dropped at 21:38:42 after a signaling reset (21:38:18) and was not back for 98 s; kill: back in 2 s | — |
| base, relay only, 2 Macs, events | base | relay only | 16 | 16/16 | 113–331 | only after kill and hostd restart (links 4–8 min) | — |
| base, browser | base | rig LAN | 12 | — | 126, 388 | none while open | WebRTC Direct in 80 ms, up to 20 Mbit/s, 12 min |
| fix, 2 Macs, events | head | rig LAN (TURN path) | 30 | 24/28 (the 4 misses: rig B's app quit at 23:07 and was relaunched) | 112–135 | bg 20 s: no drop; kill: back in 10 s; hostd kill: the phone's presence probe closed the dead link and redialed in 1 s; signaling resets at 23:30 (both Macs): no drop | — |

The rig cannot recreate a slow relay that queues a pong for 8 s. Its links all ran at
125 ms through Cloudflare TURN. So the drop that matters most is proven by the tests
above and the user's logs, not by a before-and-after on the rig.

### Chief after the background

`chief_foreground.py`, Mac Chief on `lr-mac-a`, base build:

| Away | Usable after the foreground | Message round trip |
| --- | --- | --- |
| 10 s | 0.69 s | sent, answered |
| 60 s | 0.82 s | sent, answered |
| 300 s | 1.92 s | — (the driver's keyboard tap failed) |
| 10 s, process stopped (`--freeze`) | 1.68 s | — |
| 60 s, process stopped | 1.25 s | — |

The rig does not show minutes of "connecting". On the real phone, the time Chief spends
connecting is the link's time: a redial of 4–9 s, then the phone closing the new link at
22–24 s (fix 1) and redialing again.

## Not done

- **Real iPhone.** The user asked to skip it. A signed Production ipa is left for them.
- **The other MacBook's stale cmux NEXT** (`331e2e901ce`, no #23829). Restarting it into a current build is the user's call.
- **WireGuard direct on the same Wi-Fi.** Not explained yet. It needs a phone-side trace.
- **No Worker change, so no deploy.**
