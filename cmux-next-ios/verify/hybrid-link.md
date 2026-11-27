# WireGuard for the link, WebRTC for browser video

Branch `feat-cnx-ios-hybrid-link`, 2026-10-19 (base `origin/feat-cnx-ios`
`3e6a2b56eff`). The contract is PROTOCOL.md "Media session".

## What changed

- **WireGuard is the default transport.** An install with no saved choice
  dials WireGuard (it dialed WebRTC). A saved choice stays: the key
  `cmuxMobile.settings.transport` is written only when the person picks a row.
  Settings → Transport lists "WireGuard (recommended)" first ("Encrypted
  tunnel to your Mac. Browser tabs stream over WebRTC when that is
  faster.") and "WebRTC only" ("Everything over one WebRTC connection,
  direct when possible."). The Settings root shows "WireGuard" or "WebRTC
  only". An install that never chose is treated as new: there was no
  choice to keep.
- **One WebRTC media session beside a WireGuard link.** The link (every
  channel, the input lane, and browser video as RTP in the tunnel) rides
  WireGuard. A WebRTC peer connection to the same Mac carries only the
  browser video track while it works. It is signaled through the same
  TeamHub (`webrtc-offer` with `mediaFor`), uses the same `GET /v1/ice`
  Cloudflare TURN credentials, and has no data channel.
- **"WebRTC only"** is unchanged: one peer connection carries the link and
  the video track, as before.

## Design

### Two routes, one stream, switched at keyframes

```
Mac: browser host ─ rd ─▶ TrackBridge ─▶ VideoClaim::send ─▶ route table (media/routes.rs)
                                                   ├─▶ WebRTC media session track  (preferred)
                                                   └─▶ RTP on overlay UDP 7422 in the tunnel (floor)
phone: WebRTC track ─▶ ReceiverCore ─┐
       tunnel RTP   ─▶ ReceiverCore ─┴─▶ VideoIn gate (current source; a keyframe moves it) ─▶ viewer
```

- The Mac's `VideoOut` keeps one sender core per route (own sequence
  numbers, TWCC, NACK history and congestion controller). A frame goes on
  the preferred usable route. A route is usable while its sender runs, its
  carrier says healthy (the media session's peer connection is
  connected), and it is not waiting out a stall.
- **Switching only at a keyframe.** When the preferred route changes, the
  Mac asks the browser host for a keyframe (rd `need_recovery`, at most
  every 250 ms). If the old route still works, its P frames keep flowing
  until the keyframe, which then starts the new route: no gap. If it does
  not, the frames in between are dropped and the phone keeps showing the
  last frame: no black tab, at most one keyframe round trip of freeze.
- **Stall detection.** A connected peer connection whose path died
  silently is caught by feedback: the current route with packets out and no
  TWCC feedback for 500 ms (TWCC comes every 25 ms) moves video to the next
  route, and is tried again after 1 s, doubling to 16 s, back to 1 s after
  10 s of feedback. ICE consent on the media session reports disconnected
  after 3 s and failed after 8 s (webrtc-rs defaults are 5 and 25 s).
- **The phone** runs a receiver core per source and passes a source's
  frames only while it is current; a keyframe from another source makes
  that one current. A late P frame of the old route is never decoded.
  Keyframe requests (PLI) go out on every source.
- **Channel fallback** is unchanged: without the tunnel's media lane (an
  older Mac, or the lane off) video rides the `browser` channel, and the
  Mac lists `webrtc-media` only when it has the tunnel's lane, so the
  session never exists without its floor.

### Lifecycle (phone, `cmux_mobile_link::hybrid::MediaManager`)

- Opened lazily: a shown browser stream (`BrowserStream.set_visible`, from
  `StreamedBrowserPage` appearing) holds it; a workspace with browser tabs
  warms it for 60 s (`LinkHandle.warm_media`, at most every 20 s), so the
  peer connection is usually up by the time a tab is opened.
- Closed (`bye`) 30 s after the last browser tab was hidden and the warm-up
  ran out.
- Never in the way of the link: the dial runs on its own task after the
  link is up, on the warm signaling socket, and nothing waits for it.
- A failed dial or a session that failed or closed is redialed after 1, 2,
  4, 8, 16, then every 30 s while video is wanted.

### The Mac (cmux-mobile-host `media_session.rs`)

- A media offer is admitted like any dial (`fromUserId` is the owner), and
  then only for a live WireGuard link registered with `webrtc-media`, from
  that link's phone device, and (with pairing on) after that link passed
  `auth`: no new trust path. Otherwise `bye unknown_link` / `unpaired`.
- The session's track becomes a route of that link's lane; a newer session
  for the link replaces the older; all end with the link.
- Labels: `phone_media {session_id, media_path}`; the iPhone card adds
  "Video over WebRTC (direct|TURN)".

### Input path

Input stays on the WireGuard link's input lane (PROTOCOL.md "Lanes"):

- Browser input is part of the `browser` channel's rd stream (exactly-once
  input events, acknowledged by the host in the same ordered stream as rb
  control); moving it to a second connection would split one ordered
  conversation across two paths.
- The input lane exists from link up; the media session is lazy and may be
  down (UDP blocked, or still dialing), so input there would need a
  fallback of its own for no gain.
- Both paths take the same network route on the rig, so their round trips
  match (measured below).

## Tests

Rust (on rbx, `cargo test --workspace`; all green):

- `cmux-mobile-link` `media::routes` unit tests: the WebRTC route wins and the first
  frame needs no keyframe; a dead route falls back only at a keyframe and
  drops frames meanwhile (keyframe asked once per 250 ms); a recovered route
  takes over at a keyframe while the old one keeps sending; a stalled route
  backs off (1 s, then 2 s) and is tried again; the last route never stalls
  away; no route left closes the lane.
- `cmux-mobile-link/tests/hybrid.rs` (in-process boringtun pair, real webrtc-rs
  peer connections, the fake signaling server):
  - `video_moves_onto_the_media_session_falls_back_into_the_tunnel_and_returns`:
    nothing opens before video is wanted; a held demand opens the session
    and video moves onto it; killing the Mac's session moves video back into
    the tunnel, the phone redials and video returns; every carrier change is
    a keyframe; no gap over 1.5 s; after the linger the session closes and
    video stays in the tunnel.
  - `a_silent_media_session_stalls_video_falls_back_and_the_session_is_tried_again`:
    the session's packets vanish under a connected peer connection; video
    is back in the tunnel within 1.5 s and returns to the session after the
    backoff once the path works.
  - `with_udp_blocked_the_media_session_fails_and_video_stays_in_the_tunnel`.
  - `a_mac_without_media_sessions_leaves_the_lane_out` (and an older phone).
- `cmux-mobile-link-ffi/tests/browser.rs`
  `browser_video_rides_the_media_session_beside_wireguard`: the exported
  API end to end with cmux-mobile-host's real `serve_signaling` and
  `media_session.rs`: the open tab's video rides `webrtc-track`, falls back
  to `wireguard-udp` when the session is killed, and returns.
- `cmux-mobile-host` `media_session::tests`: a media session needs a live, paired
  link of the same phone (another phone, a closed link and an unpaired link
  are refused).

Swift (`verify/termqa/cmux_mobile_kit-test.sh` on mini-cmux11s):

- `TransportDefaultTests`: no saved choice gets WireGuard; a saved WebRTC
  or WireGuard choice stays; choosing saves; the picker order and titles.
- `LinkStatusMediaTests`: the status line with the session up (direct,
  TURN), failed ("video in the tunnel"), and a stale link's media ignored.
- CmuxMobileKit `CmuxMobileLiveTests|CmuxMobileBrowserStreamTests|CmuxMobileModelTests|CmuxMobileTransportTests|CmuxMobileShellTests`:
  345 tests in 94 suites passed.
- CmuxNext `MobileHostTests` (fleet step): `phone_media` parsing and state.

## Review (fresh subagent, correctness first)

Findings and what was done:

| Finding | Severity | Resolution |
| --- | --- | --- |
| A late, older keyframe of the route the Mac just left (the PLI every source gets when the session's source is added; the tunnel over TURN over TLS is slower than the session) took the phone's gate back, and the newer route's P frames were then rejected with nothing asking for a keyframe: a frozen tab | must fix | The gate moves only on a keyframe newer than the newest frame it passed (RTP timestamp = capture time on both routes, serial compare); a source stuck behind the gate for 250 ms asks for a keyframe (at most every 250 ms). Unit tests `a_late_older_keyframe_of_the_left_route_never_takes_the_gate_back`, `a_source_stuck_behind_the_gate_asks_for_a_keyframe` |
| The tunnel route could be put into stall backoff while the session waited out its own, leaving no usable route: video dark until a retry, up to 16 s | must fix | Only a route with a floor below it stalls away. Red-then-green unit test `the_floor_never_stalls_away_while_the_preferred_route_backs_off` (found by this author before the review too) |
| A media dial or answer that failed or timed out after its peer connection existed leaked it (webrtc-rs does not close a dropped one); a phone on a UDP-blocked network retries every 30 s | should fix | The peer connection is made before the bound and closed on every failure and on the timeout, on both sides |
| An older answer that finished after a newer offer for the same link replaced the newer session | should fix | hostd numbers offers per link on arrival and drops an answer whose offer is no longer the newest |
| Demand not released when the app goes to the background | nice | The scene phase hides every streamed page (`StreamedBrowserDirectory.setAppActive`) |
| Ended media sources kept forever on the phone's lane | nice | Removed when they end; their counters stay in the sum |
| The test kill left a permit for the next session | nice | `notify_waiters` |
| The status re-sent every 5 s with a new RTT | nice | Only when the RTT moved by 20 % and 2 ms |
| A stale hostd registration's drop could remove a newer one | nice | Registrations carry a token |
| A tab opened while hidden holds the session until `opened()` hides it | nice, not done | The stream reports hidden right after it opens; the session lingers at most 30 s |
| The media source uses the WireGuard link's RTT for its NACK deadline | nice, not done | The deadline is clamped to 80 to 400 ms; both paths measured within a few ms on the rig |

## Live check (2026-10-19, real link)

Rig: `mini-cmuxs-mac-mini-3`. Mac: fleet build `cmux-mobile-e2e-ce1d3585` (job
`dd065e7afd8577993eead970`, this branch's cmux-mobile-host), its settings passed
with `open --env` only (`verify/e2e/mac.py` no longer edits or re-signs the
Info.plist). Phone: this branch's Demo build (`cb003359`) in one headless
iOS 26.5 simulator. Both reached each other through the shared dev Worker's
TeamHub and Cloudflare TURN; nothing loopback or mocked on the phone.
Another agent's rig app (`cmux-mobile-e2e-90375ce5`) was running on the same mini
and the same dev account; it was left alone, and the run chose its own Mac
by device id (`CMUX_MOBILE_E2E_ALLOW_OTHER_RIGS=1`). Evidence (recordings,
frames, results.json, hostd log) stays on the mini in
`~/cmux-mobile-hybrid-evidence/run2`, `run3` and `label`.

**Load caveat.** The mini's 1-minute load was 500 to 900 during run 2 (CI
jobs and the other rig), so absolute numbers are noisy and run-to-run
spread is large. Treat these as a smoke comparison, not a benchmark.

### Hybrid (WebRTC video) vs WireGuard only (RTP in the tunnel)

`browser-track-bench.py --configs hy-track,wg-track,hy-track,wg-track
--seconds 12 --taps 5`, `bench.html?scroll=6`, both paths direct:

| Config | Carrier seen | Glass to glass p50 / p90 / max (ms) | fps | Frame interval p95 / max (ms) | Stalls > 100 ms | Page tap to phone frame p50 (ms) |
| --- | --- | --- | --- | --- | --- | --- |
| `hy-track` | track (834 frames) | 40 / 67 / 181 | 34.5 | 51.7 / 115 | 2 | 88 |
| `wg-track` | wg-rtp (947) | 56 / 1741 / 2207 | 30.2 | 50.0 / 83 | 0 | 69 |
| `hy-track-2` | track (799) | 83 / 216 / 299 | 23.8 | 83.3 / 417 | 10 | 276 |
| `wg-track-2` | wg-rtp (853) | 51 / 101 / 544 | 34.0 | 66.7 / 537 | 6 | 111 |

Reading it: each configuration rode the carrier it asked for, for every
OCR'd frame. On a same-machine direct path the two carriers are within the
noise of this loaded rig (p50 40 to 83 ms against 51 to 56 ms); the
`wg-track` p90 of 1.7 s is a run of late frames during a load spike, and
`hy-track-2` ran during the next spike. The case for WebRTC video is the
one the earlier runs showed (verify/browser-video-track.md): the tunnel's
RTP shares the link's path, so when WireGuard falls to TURN over TLS (one
ordered TCP stream) video pays head-of-line blocking, while the media
session keeps its own UDP path. A clean A/B on an idle Mac, and on a real
cellular path, is still to do.

### Fallback (run 3, `hy-track`, 20 s)

cmux-mobile-host got `SIGUSR2` (close every media session) at 4.09 s, and `SIGUSR1`
(black hole under the track, peer connection still connected) at 11.09 s and
off at 15.10 s. Carrier per recorded frame, and hostd's log:

| Event | hostd | Phone overlay |
| --- | --- | --- |
| Session closed (4.09 s) | session down; the phone's redial was up 1.19 s later (path Direct); switched to `webrtc-track` 43 ms after at a keyframe | `wg-rtp` from 4.32 s (0.23 s), `track` again from 5.34 s |
| Black hole on (11.09 s) | "media route stalled (no feedback)" 595 ms later; switched to `wireguard-udp` at a keyframe 24 ms after; retried after 1 s, stalled again, backed off | `wg-rtp` from 11.91 s |
| Black hole off (15.10 s) | the next retry took the track | `track` from 15.49 s |

The longest gap between frames over the 20 s was 650 ms (at the black
hole, the stall time plus a keyframe), and the tab never went black: the
phone kept the last frame. Every switch was at a keyframe.

### Block UDP (run 3, `hy-track-tls`)

The phone with `CMUX_MOBILE_DEV_BLOCK_UDP=1`: the link came up over TURN over TLS
(hostd `path=TurnTls`), the media session never connected (hostd: "the
media session's peer connection failed", every attempt), the phone retried
at 1, 2, 4, 8, 16, then every 30 s plus the 12 s dial, and video stayed on
`wg-rtp` for every frame. Glass to glass was 1009 ms p50 here: TURN over
TLS on a mini at load 500+ (the media lane over one TCP stream).

### Labels

- Phone, Settings → Devices, the rig Mac's row: "Connected · WireGuard
  direct · video WebRTC (direct) · 0 ms" (`label/hybrid-devices-status.png`).
- Phone, Settings → Transport: "WireGuard (recommended)" checked, "WebRTC
  only" below (`label/hybrid-transport.png`).
- Mac: hostd logs the media path and every route switch; the iPhone card's
  "Video over WebRTC (direct)" is covered by `MobileHostTests` and was not
  looked at in the rig app's window (a hidden app; taking a screenshot of it
  would need focus on the mini).

### Input path, measured

The media session's ICE pair and the WireGuard link were both direct on the
rig (link RTT 0 to 4 ms in the status line). With equal paths, moving input
to a new data channel on the media session buys nothing and loses the
always-there input lane, so input stays on WireGuard. On a path where the
link is on TURN over TLS and the session is on UDP, input over the session
would win; that is a follow-up once measured on a real network.
