# Browser video as a WebRTC video track

Branch `feat-cnx-ios-rbvideo`, 2026-10-14. User decision: "use WebRTC video
tracks for browser streaming". This replaces, on WebRTC links, the reliable
`browser` channel as the carrier of a streamed tab's pictures
(verify/browser-stream.md). Everything else about the tab (rb control,
input, clock probes, popups) stays on the channel.

## Why

On the channel, every rd shard rides SCTP's ordered, reliable stream. One
lost packet holds every later frame, and every other channel on the link,
until it is retransmitted (head-of-line blocking). The browser-stream run on
a loaded Mac fell to 8 fps with a p90 of 200 ms. A track gives RTP over
SRTP: a lost packet is NACKed or the frame is skipped, nothing else waits,
and congestion feedback (TWCC) measures the real path.

## Design

```
Mac: cmux-mobile-host                                   iPhone: cmux-mobile-link-ffi (CmuxMobileKit)
browser host (CEF, VT encoder, rd engine)
  │ rd shards on loopback
  ▼
TrackBridge (hostd = rd viewer of stream 0)       ReceiverCore
  reassemble ─▶ SenderCore ─▶ RTP ═══ track ═══▶ release on marker ─▶ BrowserFrame
  feedback ◀── target, window ◀── TWCC, PLI ◀═════ TWCC, NACK, PLI      (VideoToolbox, unchanged)
  rb control, input, clock probes ◀────── `browser` channel ──────▶ rd Session (as before)
```

### One lane per link, one track switched by tab

- Negotiation is pre-negotiated in the first offer, so there is no
  renegotiation and no second ICE or TURN session. The phone's offer has one
  `recvonly` H.264 transceiver and lists the lane `video` in the signaling
  `lanes` (the same field as the input lane).
- A Mac that streams browser video adds a `sendonly` track before it
  applies the offer, so webrtc-rs's `satisfy_type_and_direction` binds it
  to the phone's m-line. It lists `video` back.
- An older Mac answers with an empty media engine. webrtc-rs rejects the
  m-line, the lane stays out and the link works (test
  `an_older_mac_leaves_the_lane_out_and_the_link_works`).
- An older phone offers no m-line, so no track is created.
- The version service adds `browser-video-track-v1` next to
  `browser-stream-v1`.
- The phone opens `browser {tab, url, video: "track"}`:
  - hostd honors `video: "track"` only when the link has a lane.
  - An older hostd ignores the field and streams on the channel.
  - The phone's viewer reads frames from both sources, so every mix works.
- One track per link is switched by tab. A newer `browser` channel's claim
  takes the lane. The older tab's video returns to its channel, with an IDR
  forced for its own rd viewer (test `browser_video_rides_the_webrtc_track`).
  The phone shows one page at a time, so per-tab tracks would only add
  renegotiation.
- WireGuard links carry the same lane as RTP inside the tunnel (option A
  below, built on `feat-cnx-ios-wgmedia`; section "WireGuard carrier").

### Mac side: hostd bridges rd to RTP; the host is unchanged

hostd becomes the rd viewer of the page's main stream on loopback. The
`browser_track.rs` `TrackBridge` reassembles the host's shards with
`cmux-rd-core`'s `Reassembler` and writes each access unit to the track. The
host's capture time becomes the RTP timestamp at 90 kHz, so the phone can
still compute each frame's age from the rd clock probes.

The bridge answers the host's media engine as a viewer at the end of the
real path would:

- **Bitrate.** Each host datagram is timed through a virtual bottleneck at
  the lane's TWCC-derived target. Sending above the target builds virtual
  queueing delay, which the host's delay-based controller reads as overuse.
  The VideoToolbox bitrate therefore follows the WebRTC path with no change
  to the host. Unit test `the_hosts_bitrate_follows_the_lanes_target`:
  - it uses the real `MediaEngine`;
  - the host starts at 8 Mbit/s;
  - it settles at 0.9 to 2.2 Mbit/s for a 1.5 Mbit/s lane.
- **Frame skipping.** A frame is acknowledged once it is on the track,
  unless the lane's in-flight window is full. The window is the target times
  the feedback delay plus 60 ms, and at least 96 KB. While the window is
  full:
  - the ack waits and the host's frame gate stays shut;
  - the page's damage coalesces into the next frame;
  - so frames are dropped at the source and never queued.
- **Keyframes.** The phone's PLI or FIR, rate-limited to one per 250 ms,
  becomes rd `need_recovery`. The engine answers with an IDR
  (VideoToolbox `ForceKeyFrame`).

### Phone side

Frames go from the track into `ReceiverCore`:

- **No jitter or playout buffer.** A frame is released the moment its
  marker packet completes it, in order.
- **Gaps.** A gap holds later frames only while a NACK can still recover it.
  The deadline is 2 × (RTT + NACK interval) + 20 ms, clamped to 80 to
  400 ms, using the link's ping RTT.
- **Giving up.** After the deadline the frame is dropped, a PLI goes out,
  and the next complete keyframe (STAP-A with SPS) is released however much
  was skipped. The decoder never gets a frame whose reference is missing.
- **Decoding.** Frames become the same `BrowserFrame` as before, so Swift's
  `BrowserVideoDecoder` and `AVSampleBufferDisplayLayer` path is unchanged.
  The overlay and log name the carrier (`track` or `channel`) and the
  dropped and recovered counts.

### Latency choices

| Choice | Value | Why |
| --- | --- | --- |
| Playout delay | 0 (release on marker) | UI, not a call: show a frame the moment it can be decoded. |
| NACK generator interval | 20 ms (webrtc-rs default 100 ms) | One NACK round on a 13 ms TURN path instead of a frame stall of 100 ms or more. |
| TWCC feedback | every 25 ms (default 100 ms) | Fresher delay samples for the controller. |
| Give-up deadline | 2 × (RTT + 20 ms) + 20 ms | Two NACK rounds, then skip to a keyframe. |
| RTP payload | 1100 bytes | Fits TURN, SRTP and extension overhead on a 1280-byte IPv6 path. |
| Start bitrate | 2.5 Mbit/s lane (host starts at 8 and follows) | |
| Congestion controller | rd's delay-gradient controller (`cmux-rd-core::cc`) | Same algorithm and constants as the channel path, now fed by TWCC. |

### What webrtc-rs provides and what we wrote

Taken from webrtc-rs 0.17 as is:

- ICE, DTLS and SRTP on the link's existing peer connection;
- RTP and RTCP routing per SSRC;
- the `rtp` crate's H.264 payloader (STAP-A for the parameter sets, FU-A)
  and its depacketizer;
- the NACK generator and responder interceptors (the responder keeps the
  send history);
- the TWCC receiver interceptor (feedback generation) and its `Recorder`;
- sender and receiver reports;
- the RTCP packet types (PLI, FIR, NACK, TWCC).

Written here, because webrtc-rs has no fitting part. I checked webrtc-rs
0.17, `interceptor` 0.17 and `webrtc-media` 0.17; none has a bandwidth
estimator or a GCC port, and there is no `cc` crate:

1. **Bandwidth estimation.** The core stamps the transport-cc extension
   itself, so it knows each packet's send time. It parses TWCC feedback
   (`media/twcc.rs`, about 40 lines) and feeds the existing rd
   delay-gradient controller and loss meter. These are reused, not new.
2. **The frame buffer** (`media/receiver.rs`). webrtc-media's
   `SampleBuilder` releases a frame only when a packet of the next frame
   arrives (`PendingTimestampPacket`). That costs a frame interval, and a
   still page's last frame is never released. It also hands on frames whose
   reference was lost.
3. **Encoder bitrate control from congestion feedback.** This is the
   virtual bottleneck plus the ack window in `TrackBridge`, because the
   encoder lives in the browser host's rd engine.
4. **Decode pacing.** There is none by design: frames decode on arrival, as
   on the channel path.

The transport-cc sequence stamping is about 5 lines in `SenderCore`, kept so
send times are known. webrtc-rs's TWCC sender interceptor stamps the same
numbers but does not expose them.

### Prior art: cmux-screen (feat-cmux-screen-kit, feat-cmux-next-vnc-rust)

- cmux-screen runs Google libwebrtc (LiveKit's `libwebrtc` crate) on the
  Mac. That gives it GCC, a pacer and libwebrtc's VideoToolbox encoder. It
  only sets sender parameters:
  - `DegradationPreference::MaintainResolution` for text;
  - 12 Mbit/s maximum at 60 fps in Auto;
  - fixed presets that pin `min_bitrate`.
- It measured 30 to 63 ms p50 glass-to-glass.
- We keep webrtc-rs, for these reasons:
  - it is already the phone's link stack, so a second WebRTC stack on iOS
    would bring the binary size and the duplicate `RTC*` Objective-C
    classes that effort hit;
  - the browser host already owns capture, the VideoToolbox encoder and a
    delay-based controller;
  - only GCC is missing, and the rd controller fed by TWCC covers it.
- Their text-first preference matches the rd ladder's text path, which
  keeps resolution and lowers fps.
- We would revisit if field data shows the rd controller under-using
  cellular paths, where GCC's probing is stronger.

## WireGuard carrier (built: option A, `feat-cnx-ios-wgmedia`)

The user approved option A below: RTP on the tunnel's datagram path with
webrtc-rs's `rtp`, `rtcp` and `interceptor` crates, no PeerConnection in the
tunnel and no SRTP.

```
Mac: hostd TrackBridge ─▶ VideoOut ─▶ SenderCore ─▶ interceptors ─▶ WgCarrier
                                                   (resend guard,      │ overlay UDP 7422,
                                                    NACK responder,    │ RTP = Priority::Media
                                                    sender reports)    ▼ inside boringtun
phone: BrowserFrame ◀─ VideoIn ◀─ ReceiverCore ◀─ interceptors ◀─ WgCarrier
                                                   (NACK generator, TWCC receiver,
                                                    receiver reports) ─▶ RTCP back, Interactive
```

- **Carrier** (`cmux-mobile-link/src/media/wireguard.rs`, `WgCarrier`). Binds overlay
  UDP 7422 on the session's `WgNet`, beside TCP 7420 (the link) and UDP 7421
  (roaming). One task owns the socket: it sends what the writers queue and
  sorts what arrives into RTP and RTCP by the second byte (RFC 5761). A
  datagram from another overlay address, or RTP with another SSRC, is
  dropped and counted.
- **Interceptors.** The registry the track uses (`interceptor_registry`)
  is built once per carrier and bound as `RTCRtpSender` and `TrackRemote`
  do: RTCP writer first (the NACK generator and TWCC receiver start their
  loops on it), then the RTCP reader, then the local (Mac) or remote (phone)
  stream with a fixed `StreamInfo` (payload type 102, TWCC id 1, SSRC
  `0x636e7876`, `nack`, `nack pli`, `ccm fir`, `transport-cc`). Pump tasks
  read the chains so a reader that stops waiting never loses a packet half
  way through a chain.
- **MTU.** The datagram service takes 1232 bytes (1280 minus IPv6 and UDP).
  The carrier reports a payload limit of 1232 − 12 (RTP) − 24 (extensions:
  the TWCC block plus room for two more) = 1196 bytes, and `SenderCore`
  packetizes at the carrier's limit (the WebRTC track keeps 1100). A packet
  over the limit would be counted and dropped, never fragmented; the tests
  assert it never happens.
- **Negotiation.** `wg-init` and `wg-resp` carry `lanes: ["input","video"]`.
  The Mac binds 7422 before it answers and lists `video` only if that
  worked; the phone binds before it opens the link stream. Older Mac or
  phone: no lane, video on the channel (tests below).
- **Roaming.** The `WgNet` and its sockets survive a roam (only the
  underlay's UDP socket changes), so nothing is renegotiated. The session
  counts network changes (its own roam after the rebind, and each endpoint
  announcement the peer sends on 7421) and the carrier exposes the count
  (`MediaCarrier::path_changes`). The phone's receiver sends a PLI at once
  without dropping what it holds; the Mac's sender forgets its in-flight
  bytes, resets the controller's delay baseline (`on_path_changed`) and asks
  the source for a keyframe, rate limited together with PLIs, so one
  keyframe results.
- **Reused unchanged.** `ReceiverCore` (release on marker, give-up deadline,
  keyframe gating), hostd's `TrackBridge` (rd to RTP, virtual bottleneck to
  the VideoToolbox bitrate, ack window and frame skipping, PLI to IDR, tab
  switching), the cmux-mobile-link-ffi viewer. The overlay names the carrier `wg-rtp`.

### Two fixes to the shared cores, found with the capped-link test

Both affect the WebRTC track too.

1. **NACK storm.** webrtc-rs's generator asks for every missing packet each
   interval (20 ms) with no retry limit, and the responder resends each time.
   On a 1.5 Mbit/s bottleneck with a 250 ms queue the resends queued behind
   the losses they repaired and were lost too: 30 to 55 % loss for four
   seconds with the target at its 250 kbit/s floor. `media/resend.rs` sits
   below the responder and lets a sequence number go again only 40 ms after
   its last send, at most 3 times (libwebrtc bounds resends by RTT and count
   as well). A packet still missing is the receiver's to give up.
2. **Controller cadence.** The rd controller cuts 15 % per overusing sample
   and assumes rd's 50 ms feedback. TWCC comes every 25 ms. `SenderCore` now
   batches TWCC arrivals into one sample per 50 ms and, after a decrease,
   holds the next sample for the feedback delay plus 50 ms (100 to 400 ms):
   one decrease per round trip, so a queue that is still draining does not
   read as fresh overuse.

Capped-link test (1.5 Mbit/s, start 2.5 Mbit/s, adaptive source, 10 s):

| | target after 1 s | after 10 s | loss on the way |
| --- | --- | --- | --- |
| neither fix | 259 kbit/s | 531 kbit/s | not traced |
| cadence only | 250 kbit/s (the floor) | 464 kbit/s | 30 to 55 % for 4 s (NACK storm) |
| both | 915 kbit/s (lowest 459) | 830 kbit/s, rising 8 %/s | 15 to 35 % for 1.2 s, then 0 |

The controller still overshoots on a start above the path: rd's controller
cuts relative to its own target rather than to the measured delivery rate
(GCC's 0.85 × acknowledged rate), and grows at most 8 % per second. Moving
it closer to GCC is a change to `cmux-rd-core` and is left as follow-up.

### Review of the whole lane (rbvideo and wgmedia), 2026-10-14

A correctness-first review of the branch found, and these commits fixed:

- **Frames still arriving were given up.** The receiver started the give-up
  deadline when a frame's first packet arrived, so a large IDR on a slow
  path (100 kB at 2.5 Mbit/s is about 320 ms) was dropped with no loss at
  all, and the PLI asked for another large IDR. Only a hole in the
  sequence numbers starts the deadline now.
- **A lane task leaked per WebRTC link that never streamed.** The phone's
  receiver waited forever for a track. Both cores now end when the link
  closes.
- **A packet could be lost without a NACK on WebRTC.** `recv_rtp` read the
  track through the interceptors inside a `select!`; a read dropped after
  the NACK generator counted the packet lost it. A task now pumps each
  track into a queue, as the WireGuard carrier does.
- **Frame ages of 13 hours** when the RTP timestamp was slightly ahead of
  the clock estimate (signed now).
- **Extra keyframes after a roam.** One roam is announced twice, and a
  signaling move announces an empty list; only a new first endpoint moves
  the path epoch now, and path-change PLIs are rate limited.
- **Tab switch.** The phone's new tab took the lane's frames before the
  Mac's claim for it existed (`Link::open` only queues the request), so it
  could show the old tab's frames, and a refused `open` left the old tab
  with no video at all. Each `browser` open now carries a random
  `video_tag`; hostd appends it to that tab's lane access units as an
  H.264 SEI after the slices (`media/tag.rs`); every viewer subscribes
  beside the others and keeps only its own frames, from its first
  keyframe. The packetizer, the carriers and the receiver core never look
  inside, and the SEI is stripped before decoding. A second review found
  the first fix (subscribing after the `open`) cosmetic.
- **Lost tails.** Starting the deadline only at a hole made a frame whose
  marker was lost, with nothing sent after it (a still page), wait
  forever. A hole now waits from when it was found and an incomplete tail
  from the newest arrival.
- **hostd** treated a lagged keyframe receiver as no request, and reopened
  the frame gate up to 100 ms after the lane drained.

Open suspicion: NACK resends reuse the original transport-wide sequence
number (no RTX), so a late resend can make TWCC report numbers in between
as lost and overstate the loss the controller sees. RTX (or restamping
resends) is the follow-up if field data shows it.

## WireGuard: media on the datagram lane vs a PeerConnection in the tunnel

The user has decided on WireGuard for everything, with WebRTC used only for
media. Research is in `verify/transport-wireguard-everything.md` (branch
`feat-cnx-ios-wgresearch`, `2ad07df5`). This is the comparison the decision
needed; option A is now built (above).

Both options keep what this branch built:

- the `MediaLane` and `MediaCarrier` seam;
- `SenderCore` (rtp-crate packetization, TWCC send times, the rd
  controller, the ack window, PLI and FIR);
- `ReceiverCore` (release on marker, give-up deadline, keyframe gating, PLI);
- hostd's `TrackBridge` (rd to RTP, virtual bottleneck to the VideoToolbox
  encoder);
- the cmux-mobile-link-ffi viewer.

They differ only in what moves the RTP and RTCP packets.

| | A. RTP on the tunnel's datagram lane | B. PeerConnection inside the tunnel |
| --- | --- | --- |
| Carrier | `WgDatagramCarrier: MediaCarrier` over `WgDatagramSocket`. RTP goes as `Priority::Media` (50 ms stale drop) and RTCP as `Interactive`, on one port, demuxed by payload type (RFC 5761). | `WgUdpConn: webrtc::util::Conn` over the same socket, then `UDPNetwork::Muxed` with the overlay IP as the only host candidate. The track carrier from this branch is reused unchanged. |
| NACK, TWCC, reports | The `interceptor` crate used as a library: the same `Registry` (generator, responder, TWCC receiver, reports) built with `Registry::build`, with its `bind_local_stream`, `bind_remote_stream` and `bind_rtcp_writer` writers pointed at the socket. No SRTP, because WireGuard encrypts. | The same interceptors inside the PeerConnection, as on WebRTC links today. |
| Negotiation | No SDP. Fixed payload type 102, TWCC extension id 1 and the Mac's SSRC, announced on the `video` lane (link `lanes` or the version service). | SDP offer and answer over a link channel in the tunnel (no Worker), then ICE checks, DTLS and SRTP keying. |
| Effort | About 3 to 4 days: carrier 1, interceptor wiring 1, lane negotiation 0.5, tests (loopback WireGuard pair, loss and reorder) 1. | About 3 to 4 days: `Conn` adapter, settings, in-link signaling and tests. The research's "1 to 2 weeks for media tracks" is mostly done in this branch. |
| What we write that webrtc-rs has | Nothing protocol-level. We skip ICE, DTLS and SRTP, which WireGuard makes redundant. We write the about 100-line glue that webrtc-rs's `RTCRtpSender` and `TrackRemote` do internally (binding interceptors to a stream). | Nothing. |
| Added per-packet cost | WireGuard only. | Also SRTP and DTLS, a second encryption layer, plus ICE consent checks. CPU not measured; likely more than WireGuard itself (research §2). |
| First frame after link up | No extra handshake. | Plus about 1 RTT of ICE checks and 2 of DTLS before the first frame, on every link. |
| Latency and quality | Same cores, so the same behavior: release on marker, NACK, TWCC to the rd controller, PLI. | Same. |
| MTU | We packetize at 1100 B of payload, so RTP is about 1130 B against a 1232 B datagram limit: about 100 B spare. | About 1146 B with SRTP, so about 86 B spare. Data channels using webrtc-rs defaults have 4 B. |
| Risks | The `interceptor` crate outside webrtc-rs is less used; its public API works, but no webrtc-rs code path exercises it that way. The Worker-relay fallback (TCP) loses unreliability, which applies to both. | A second connection state machine (ICE consent, DTLS) inside a tunnel that roams. The interface-enumeration plus `nat_1to1` trick to get a single overlay candidate. Tight data-channel margins. |
| Roaming | Needs WireGuard roaming (not built: no `WgNet::rebind`; 2 to 3 days, research). Then the lane is unaffected. | Same dependency. The PeerConnection's single overlay pair survives WireGuard roaming without an ICE restart. |

The research's own recommendation is a third option: carry the
`cmux.rd/1` shards themselves on the datagram lane. That uses rd's FEC,
NACK and controller, needs no RTP and no hostd bridge, and takes about 2 to
3 days. It reimplements nothing either, because rd exists already. It does
not reuse this branch's RTP core or the WebRTC track, and on WebRTC links it
would need a second unreliable data channel to match.

### Recommendation

If the user wants standard RTP media, meaning one media path that WebRTC
links have today and later screen viewing could share, choose A:

- it has the same cores;
- the webrtc-rs `rtp`, `rtcp` and `interceptor` crates are used as
  libraries;
- there is no double encryption and no in-tunnel handshake.

B costs about the same effort, adds a second encryption layer and a
per-link handshake, and buys nothing A lacks.

If the user prefers the smallest change for browser tabs alone, the rd
datagram lane is smaller, but browser video then has two media formats
(RTP on WebRTC, rd on WireGuard) until the WebRTC transport is retired.

Option A was chosen and is built (section "WireGuard carrier").

## Tests

- cmux-mobile-link `media::*` unit tests:
  - H.264 STAP-A and FU-A round trip;
  - TWCC feedback read-back;
  - sender sequence numbers and timestamps;
  - PLI and FIR rate limiting;
  - stalled-path window;
  - TWCC from a 1 Mbit/s path lowering the target;
  - receiver in-order release with no buffering;
  - a NACK resend completing a frame in order;
  - reorder;
  - an unrecoverable gap leading to PLI and resuming at a keyframe;
  - a late joiner releasing nothing before a keyframe.
- cmux-mobile-link `tests/media.rs`, over real webrtc-rs peer connections:
  - frames ride the track with TWCC flowing;
  - 3% loss below the NACK responder recovers by NACK and stays decodable;
  - older Mac and older phone leave the lane out;
  - a newer claim preempts the older one.
- cmux-mobile-link `tests/media.rs`, WireGuard (two in-process boringtun peers over
  loopback UDP with the fake signaling relay):
  - frames ride RTP in the tunnel, keyframes over 30 kB arrive whole, TWCC
    flows, the link's TCP streams still work;
  - 3% loss below the NACK responder recovers by NACK (at least 200 of 240
    frames, recovered frames seen);
  - a 1.5 Mbit/s bottleneck: the target ends under the cap, never falls
    under a fifth of it, and the queue drains (no standing delay or loss);
  - an unrecoverable loss (600 ms of packets and all their resends):
    the gap is given up, PLI, and decoding resumes at the requested keyframe;
  - the phone roams mid-stream: same lane, a PLI, a keyframe after the roam
    (the source makes none unasked), 150+ frames after it;
  - an older Mac and an older phone stay on the channel.
- cmux-mobile-link unit tests: RTP/RTCP demux, a full packet fits the 1232-byte
  datagram, the test bottleneck and blackout, the resend guard.
- cmux-mobile-host `browser_track` unit tests, against the real rd `MediaEngine`:
  - the host's bitrate follows the lane;
  - a full window holds the gate;
  - PLI leads to an IDR;
  - only the main stream's media is the bridge's.
- cmux-mobile-host `tests/host.rs`:
  - `browser_video_rides_the_webrtc_track`, including the takeover;
  - `browser_video_rides_rtp_inside_the_wireguard_tunnel`, the same over
    WireGuard;
  - `browser_video_stays_on_the_channel_for_an_older_phone_over_wireguard`.
- cmux-mobile-link-ffi `tests/browser.rs`: the exported viewer over the track, the
  channel, and RTP inside the WireGuard tunnel.

## Measurement support

- hostd `CMUX_MOBILE_VIDEO_DROP_PERMILLE=N` drops N of every 1000 outgoing video RTP
  packets. The drop sits below the NACK responder, so the responder can
  resend them, as on a lossy path.
- hostd `CMUX_MOBILE_VIDEO_LANE=0` turns the lane off.
- hostd `CMUX_MOBILE_VIDEO_CAP_KBPS=N` (or `$CMUX_MOBILE_STATE_DIR/video-cap-kbps`): a
  bottleneck of N kbit/s with a 250 ms queue for outgoing video RTP, on the
  WireGuard lane only.
- Phone (simulator) `SIMCTL_CHILD_CMUX_MOBILE_DEV_NO_TURN=1`: no TURN server, so a
  relay-only WireGuard link rides the backend's WebSocket relay; the bench's
  `-wss` configurations use it.
- Phone, Settings → Transport → Developer → "Browser video on channel"
  (`-cmuxMobile.dev.browserVideoOnChannel YES`) is the baseline with no lane.

## Live verification (2026-10-14, rerun): the host streams again

Branch `feat-cnx-ios-rbfix-bench`, evidence
`verify/evidence/2026-10-14/browser-video-track/162551/` (local, not
committed).

### The cause of the blocked run

The `CVDisplayLinkCreateWithCGDisplay failed. CVReturn: -6670` line was a red
herring: it comes from CEF's GPU process on the host's virtual screen, and
`data:` and `about:blank` pages render with it. The real fault was the
login Keychain:

- Chromium's network service waits for the "Chromium Safe Storage" key
  before it reads cookies. That key's Keychain ACL names the app that made
  it, so the background host can only get it through a prompt, which a
  windowless, Dock-less host cannot show.
- So every http(s) request stalled after `COMPUTED_PRIVACY_MODE` (net log),
  before its transaction started. No page committed and no frame was
  produced, on either carrier and on every machine with that Keychain item.
- Fix (`feat-cnx-ios-rbfix` `d48308b3`): the host starts CEF with
  `--use-mock-keychain`. Its profile is fresh per launch and removed on
  exit, so nothing at rest needed the Keychain. New pin `2765fa17` (fleet
  step `15e910a1`).
- Offline check: `verify/scripts/rb-host-http-frames.sh` (a loopback http
  page or any URL, the host's own `--probe` viewer, the last frame decoded to
  PNG). It fails on the old host and passes on the new one.

The rig had the same class of fault. Writing the drop share into the rig
app's Info.plist re-signed it ad hoc, so its next Keychain read (the iPhone
host identity) waited on an unseen prompt and cmux-mobile-host never started. The
rig now passes the host override at launch (`open --env`) and the loss share
through hostd's `video-drop-permille` file.

### What ran

- Mac: the rig app `cmux-mobile-e2e-1bd377aa` (as below), started with
  `CMUX_MOBILE_E2E_RB_HOST` set to the fixed host.
- Phone: this branch's Demo build in one simulator on this Mac, over the
  real link (TeamHub signaling, WebRTC). No loopback shortcut on the phone.
- The page: `bench-page/bench.html?scroll=6`, which scrolls every frame.
- Each configuration: 12 s of streaming, then 10 taps 1.3 s apart.

### Results

| Configuration | Path | Glass to glass p50 / p90 / max (ms) | fps | Frame interval p95 / max (ms) | Stalls > 100 ms | Jitter (ms) | Tap at the page to its frame on the phone p50 / p90 (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `track` | WebRTC direct | 47 / 57 / 2060 | 52.0 | 33.3 / 36.7 | 0 | 6.4 | 62 / 95 |
| `channel` | WebRTC direct | 29 / 38 / 128 | 53.4 | 33.3 / 35.0 | 0 | 7.4 | 94 / 135 |
| `track-relay` | TURN | 17 / 33 / 113 | 53.3 | 33.3 / 35.0 | 0 | 6.1 | 48 / 67 |
| `channel-relay` | TURN | 29 / 47 / 804 | 40.7 | 35.0 / 1221.7 | 4 | 59.9 | 59 / 100 |
| `track-loss30` | WebRTC direct, 3% RTP drop | 35 / 52 / 627 | 46.3 | 35.0 / 335.0 | 2 | 19.7 | 66 / 120 |

Reading the numbers:

- Every configuration streamed at 41 to 53 fps (60 Hz page), and the carrier
  the overlay showed was the one asked for.
- On a clean direct path the track and the channel are close (the track's
  direct p50 of 47 ms was not seen again on TURN, 17 ms, so treat a 30 ms
  spread as run-to-run noise). The single 2 s glass-to-glass maxima are one
  sample each in 350 and were not examined (an OCR misread or a start-up
  frame). The relay is where the carriers differ: the channel on TURN fell
  to 40.7 fps with 4 stalls of up to 1.2 s and 60 ms jitter; the track on
  TURN had none.
- With 3% of the track's RTP dropped (run `171155`, hostd's file setting;
  178 NACKs in its media-lane report), the track held 46 fps with 2 stalls
  (max 335 ms). The rd controller fed by TWCC lowered the lane's target to
  256 kbit/s, so the picture stayed live at a lower bitrate.
- A plain `track` rerun in the same session (`171155/track`) gave 16 / 26 /
  82 ms glass to glass at 53.3 fps. Its recording is the end-to-end video:
  the page streams over the real link, 10 taps and 4 touch swipes reach the
  page (its tap counter), and every frame shows `· track`.
- "Tap at the page to its frame" starts at the page's own `pointerdown`
  time. The time from the simulator's tap to the page (`tap_to_mac_ms`, about
  260 to 350 ms) is the simulator's touch injection, not the link.
- All runs are on one Mac (the simulator and the Mac app share the clock),
  so these are loopback-network numbers through the real signaling and TURN
  service; they are not cellular numbers.

## Channel, WebRTC track and WireGuard RTP in one run (2026-10-14, merged cores)

Branch `feat-cnx-ios-rbfix-wg` (`feat-cnx-ios-wgmedia` plus the rig fixes),
evidence `verify/evidence/2026-10-14/browser-video-track/175127/` (local).

- Mac: the rig app `cmux-mobile-e2e-1bd377aa` with `cmux-mobile-host` from
  `feat-cnx-ios-wgmedia` (release, built after `c29749d1`: NACK resend
  pacing, controller cadence, per-tab `video_tag`), and the fixed browser
  host (pin `2765fa17`, `CMUX_MOBILE_E2E_RB_HOST`, no wrapper).
- Phone: the `feat-cnx-ios-wgmedia` Demo build, one simulator on this Mac,
  over the real link (TeamHub signaling; WebRTC, or WireGuard over UDP,
  TURN or the WSS relay).
- Page: `bench.html?scroll=6`; 12 s of streaming, then 10 taps. One session,
  9 configurations, recorded with `--record-only`, then `--analyze`.
- Loss: hostd's `video-drop-permille` file, 30 of 1000 video RTP packets
  dropped below the NACK responder. hostd's media-lane report confirmed it
  on both transports (WireGuard: 466 NACKs, loss 1.8 %; WebRTC: 787 NACKs,
  loss 2.1 %).

| Configuration | Transport and path (hostd at link up) | Carrier seen | Glass to glass p50 / p90 / max (ms) | fps | Frame interval p95 / max (ms) | Stalls > 100 ms | Jitter (ms) | Page tap to phone frame p50 / p90 (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `track` | WebRTC, direct | track | 16 / 32 / 118 | 53.2 | 33.3 / 35.0 | 0 | 6.4 | 36 / 111 |
| `channel` | WebRTC, direct | channel | 17 / 34 / 4039 | 53.4 | 33.3 / 36.7 | 0 | 5.6 | 77 / 114 |
| `wg-track` | WireGuard, starts on the WSS relay, then roams | wg-rtp | 44 / 60 / 1134 | 53.4 | 33.3 / 35.0 | 0 | 5.5 | 71 / 108 |
| `wg-channel` | WireGuard, as above | channel | 14 / 31 / 2018 | 52.9 | 33.3 / 36.7 | 0 | 6.2 | 43 / 93 |
| `track-relay` | WebRTC, TURN | track | 21 / 37 / 2057 | 51.6 | 33.3 / 100.0 | 0 | 7.9 | 100 / 111 |
| `wg-track-relay` | WireGuard, relay only (hostd logged `Direct`) | wg-rtp | 23 / 40 / 2089 | 53.4 | 33.3 / 36.7 | 0 | 6.4 | 44 / 122 |
| `wg-track-wss` | WireGuard, WSS relay (no TURN) | wg-rtp | 39 / 57 / 4041 | 44.5 | 33.3 / 83.3 | 0 | 9.2 | 60 / 99 |
| `track-loss30` | WebRTC, direct, 3 % drop | track | 26 / 60 / 2036 | 35.4 | 71.7 / 85.0 | 0 | 22.2 | 92 / 108 |
| `wg-track-loss30` | WireGuard, 3 % drop | wg-rtp | 25 / 59 / 2061 | 39.5 | 70.0 / 85.0 | 0 | 20.2 | 40 / 144 |

Reading it:

- Every configuration streamed, with the carrier it asked for, at 35 to 53
  fps and no stall over 100 ms.
- Clean paths: the three carriers are within noise of each other at about
  53 fps and a 15 to 45 ms p50. WireGuard RTP's higher p50 on `wg-track`
  (44 ms) is the first configuration after the browser host started, not
  the lane (see "Why WireGuard RTP direct read 44 ms" below).
- The WSS relay (TCP) is the slowest path for RTP: 44.5 fps, 39 ms p50.
- Under 3 % loss the WebRTC track and WireGuard RTP behave alike (35 to
  40 fps, 25 ms p50, 20 ms jitter, no stall): both run the same NACK and
  controller cores. The channel was not measured under loss (its loss is
  TCP-like retransmission inside SCTP, not this drop).
- The single 2 to 4 s glass-to-glass maxima are one sample in 300 to 370 and
  were not examined (an OCR misread or a start-up frame).
- `wg-track-relay` came up as `path=Direct` in hostd's log although the
  phone asked for relay only; `cmux-mobile-link` labels the path by carrier, and this
  label was not investigated.
- One Mac, one simulator: loopback-network numbers through the real
  signaling, TURN and relay services, not cellular numbers.

## Why WireGuard RTP direct read 44 ms in 175127, and the rerun (2026-10-14, `feat-cnx-ios-media-int`)

In run 175127, WireGuard RTP direct read 44 ms at p50, against 14 ms for
the channel over WireGuard. It was not slower. It was the first
configuration measured after the browser host started, and the first
stream after the host starts runs about 20 to 30 ms slower glass to glass
on every carrier:

| Run | First configuration | Its p50 | The same configuration later |
| --- | --- | --- | --- |
| 162551 | `track` | 47 ms | 16 ms (`171155/track`) |
| 175127 | `wg-track` | 44 ms | 10 to 17 ms (below) |
| `order-d` (no warm-up) | `wg-channel` | 31 ms | 12 to 18 ms (below) |

Where the 30 ms is not:

- **Not the lane.** During 175127's `wg-track`, hostd's media-lane report
  read a TWCC feedback delay of 8 to 12 ms. That delay is a full round trip
  from the sender core's stamp to the phone's TWCC interceptor and back. The
  phone's overlay read 10 ms from capture to decode, while glass to glass
  read 44 ms. The WebRTC track and WireGuard RTP share everything after the
  TWCC interceptor (the receiver core, cmux-mobile-link-ffi, the decoder,
  `DisplayImmediately`), and the channel shares the decoder on.
- **Not the suspects named in the task.**
  - The sender has no pacer: a frame's packets go back to back.
  - cmux-wg's media class is unpaced (after interactive traffic) and only
    drops packets older than 50 ms.
  - The frame buffer releases a frame when its marker packet arrives. It
    adds no playout delay and never waits for the next frame's packet.
  - NACK acts only on a gap.
  - The 25 ms TWCC interval feeds only the controller.
- **Not identified.** The rig Mac app, the CEF host and the simulator all
  start within seconds of the first measurement on a loaded laptop. The
  host's first-second encode p95 was 36.7 ms; after that it was 4 to 9 ms.
  The bench now streams 30 s unmeasured first (`--warmup`, the default).
  **Open follow-up:** a person's first stream after the host starts pays
  this too. Measure the time to a warm stream after host start without the
  warm-up before calling it a rig artifact.

The 1 to 5 s glass-to-glass maxima, one per configuration, were OCR
misreads of one seconds digit. In `warm-e/wg-track-relay` frame 249 the
phone shows `59:43.245` and OCR read `59:48.225`. In `wg-track` frame 171,
`59:07.823` was read as `59:09.823`. The analysis now drops a sample more
than 500 ms above both neighbours (`g2g_ocr_misreads` counts them). A real
stall raises a run of frames, not one.

`wg-track-relay` was logged as `path=Direct` because the Mac reaches a
relay-only phone by plain UDP to the phone's TURN relayed address. hostd
could not tell that address from a direct one. `wg-init` now lists the
phone's relayed endpoints (`relayed`, optional). A roam's endpoint
announcement does the same. The Mac labels such a route `turn`, and hostd
logs every later path change (`link path changed`). Older phones send no
list and the label stays `direct`. Tests: `udp_to_the_peers_relayed_address_is_a_turn_path`,
and `wireguard_roam_takes_a_fresh_turn_allocation` now checks the Mac's
label before and after the roam (red, then green).

### Rerun

Run `warm-e` (evidence `verify/evidence/2026-10-14/browser-video-track/warm-e/`,
local), on the same rig as 175127:

- the `cmux-mobile-e2e-1bd377aa` app with the `feat-cnx-ios-wgmedia` hostd;
- the fixed host (pin `2765fa17`);
- the wgmedia Demo phone build in one simulator on this Mac, over the real
  link;
- `bench.html?scroll=6`, 30 s warm-up, then 12 s of streaming and 5 taps
  per configuration;
- each configuration's frames analysed (every second frame OCR'd), with
  misreads dropped.

The `-2` rows repeat a configuration at the end of the session. The rig ran
the older wgmedia hostd, which logs the path only at link up (`Relay` for
every WireGuard link, before the phone confirms UDP). So "direct" below
is the configuration, backed by a feedback delay of about 10 ms against
41 to 49 ms on the WSS relay. It is not a logged path. Rerun on this
branch's hostd to quote its `link path changed` lines. One run per cell;
run-to-run noise is about ±5 ms.

| Configuration | Path | Glass to glass p50 / p90 / max (ms) | fps | Frame interval p95 / max (ms) | Stalls > 100 ms | Jitter (ms) | Page tap to phone frame p50 / p90 (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `wg-channel` (baseline) | WireGuard, direct | 12 / 28 / 211 | 54.1 | 33.3 / 36.7 | 0 | 5.8 | 90 / 98 |
| `wg-channel-2` | WireGuard, direct | 18 / 34 / 108 | 54.9 | 33.3 / 35.0 | 0 | 6.5 | 58 / 89 |
| `wg-track` | WireGuard RTP, direct | 13 / 29 / 46 | 54.9 | 33.3 / 35.0 | 0 | 6.0 | 89 / 91 |
| `wg-track-2` | WireGuard RTP, direct | 17 / 25 / 225 | 55.5 | 31.7 / 35.0 | 0 | 6.6 | 48 / 79 |
| `wg-track-relay` | WireGuard RTP, TURN only | 27 / 39 / 186 | 52.4 | 33.3 / 183.3 | 2 | 11.2 | 73 / 106 |
| `wg-track-wss` | WireGuard RTP, WSS relay | 37 / 54 / 87 | 47.0 | 35.0 / 83.3 | 0 | 9.3 | 75 / 85 |
| `wg-track-loss30` | WireGuard RTP, direct, 3 % drop | 21 / 55 / 101 | 39.0 | 66.7 / 85.0 | 0 | 19.3 | 62 / 78 |

The cold run `order-d`, with no warm-up, has the same order of rows:

| Row | Glass to glass p50 / p90 (ms) | fps |
| --- | --- | --- |
| `wg-channel` (first) | 31 / 40 | 52.3 |
| `wg-track` | 10 / 26 | 52.0 |
| `wg-track-relay` | 27 / 44 | 52.6 |
| `wg-track-wss` | 46 / 79 | 44.6 |
| `wg-track-loss30` | 29 / 64 | 38.0 |

Reading it:

- On a warm host, WireGuard RTP direct matches the channel over the same
  tunnel within run-to-run noise (13 and 17 ms against 12 and 18 ms). It
  needed no change to the lane.
- Relay paths cost what their network costs: TURN about 27 ms and the WSS
  relay about 37 ms at p50. The WSS relay drops to 47 fps.
- Under 3 % loss, RTP keeps 39 fps with no stall over 100 ms. 175127 had
  the same result (39.5 fps), against the channel's stalls.
- Taps go through the simulator's touch injection (about 300 ms before the
  page sees them). The page-to-phone leg above is 48 to 106 ms. That figure
  rests on 3 to 4 taps per row and is noisy.
- One Mac, one simulator: these are loopback-network numbers through the
  real signaling, TURN and relay services, not cellular numbers.

## Live verification (2026-10-14): blocked by the Mac's browser host (resolved above)

The comparison did not run. The tools are ready, but the browser host
produced no video on either machine, on either carrier.

### What ran

- Mac: the fleet DEV build `cmux-mobile-e2e-1bd377aa` (job `da84189e`), which is
  `feat-cnx-ios-mactry` `fe736b45` with this branch's `cmux-next-ios/rust`. The
  linux-pool fleet route does not bundle `cmux-mobile-host`, so this branch's
  `cmux-mobile-host`, built locally, was placed in `Contents/Resources/bin`.
- Phone: the Demo build of this branch, in one simulator.

### What worked

- The E2E rig signed in, paired with the DEBUG seed and connected over
  WebRTC direct.
- hostd logged `link up ... video=true`, so the lane was negotiated live
  through the TeamHub signaling.
- The `browser` channel opened, and hostd logged `browser: video on the
  link's media lane`.

### What failed

The app-launched `cmux-remote-browser-host` sent no media datagrams. hostd's
5-second report stayed at `host_datagrams=0 frames=0`, and the phone showed
0 fps. It is the host, not the track:

- **Rig on this Mac** (macOS 27.0.1): the `track` configuration showed
  0 fps.
- **mini-cmuxs-mac-mini-2 GUI session** (macOS 27.0.1, as in
  browser-stream.md): `track` again gave `host_datagrams=0`.
- **Offline harness** (`cmux-mobile-link-ffi/tests/browser.rs real_host_over_the_track`,
  ignored, `CMUX_MOBILE_RB_HOST_EXE`): hostd started the host binary itself. Both
  this build's host and the 2026-10-13 known-good `cmux-mobile-br-2` host (job
  `8c3a903d`) gave 0 frames, on the track and on the channel
  (`CMUX_MOBILE_RB_CHANNEL=1`). The host answered `welcome`, `started`,
  `rb.opened`, `rb.screen_applied` and `rb.page`, but sent no frame and no
  clock pong.

Every host log shows `CVDisplayLinkCreateWithCGDisplay failed. CVReturn:
-6670`. The likely cause is the 27.0.1 update, which postdates the
2026-10-13 run. That is unconfirmed, and it is outside cmux-next-ios.

The mini also ran out of disk (100%, under 2 GB free), so the known-good app
could not be installed there.

### Ready to rerun once the host streams again

- `verify/scripts/browser-track-bench.py`:
  - rig mode, or `--remote HOST --team --mac-device --offset-ms` with
    `verify/scripts/browser-track-mac.sh` on a fleet Mac;
  - configurations `track`, `channel`, `track-relay`, `channel-relay` and
    `track-loss30`;
  - `--record-only`, then `--analyze DIR`.
- It measures:
  - glass to glass, by OCR of the page clock against the phone overlay's
    clock in each recorded frame;
  - frame pacing, from page-area changes per video frame;
  - input to frame, split at the page's own receipt time;
  - the carrier, from the overlay's `· track` or `· channel`.
- Loss: hostd reads `$CMUX_MOBILE_STATE_DIR/video-drop-permille` at each new link.
  The app passes no other environment to hostd.

## Live run over WireGuard (2026-10-14, `feat-cnx-ios-wgmedia`): lane up, frames not measured (measured above)

### Builds

- Phone: this branch's Demo simulator app and `CmuxMobileLinkFFI.xcframework`, built on
  `mini-cmuxs-mac-mini-3` (Xcode 26.6), run in one simulator
  (`cmux-mobile-wgmedia-bench`, deleted afterwards).
- Mac: the `cmux-mobile-e2e-1bd377aa` DEV app re-tagged `cmux-mobile-e2e-wgmedia1` (own
  bundle id, sockets and ports), with this branch's `cmux-mobile-host` (release,
  built on the same mini). For the rbfix workaround
  (`feat-cnx-ios-rbfix` `d48308b3`, `--use-mock-keychain`) the bundled
  host's executable became a script that execs the real host with that
  argument.

### What the real link showed

- hostd: `link up kind=WireGuard path=Relay video=true` with
  `video_lane=76.1ms` in the answer timeline. The lane was negotiated live
  through the TeamHub signaling (`wg-init`/`wg-resp` `lanes`), and the
  `browser` channel took it ("video on the link's media lane").
- The same run's WebRTC links also came up with `video=true`.

### What blocked the numbers

1. The first wrapper renamed the host binary. CEF derives its helper app
   names from the executable's name, so every helper launch failed
   (`GPU process launch failed: error_code=1003`, then `GPU process isn't
   usable. Goodbye.`). No frame was produced on either transport.
2. The second wrapper keeps the unchanged host bundle under the original
   name in `Contents/HelpersReal` (same depth, so the CEF framework symlink
   resolves). It is untested: from then on the rig Mac app did not start
   `cmux-mobile-host` in three launches, even with fresh rig and state folders,
   and without `HelpersReal`. The phone listed only the other Macs on the
   dev account. Not diagnosed. The app's unified log had no entries readable
   from this session.
3. The shared rig was busy. The terminal QA agent's rig app
   (`cmux-mobile-e2e-1bd377aa`) ran from 16:27 to 16:52 and started again at 17:12.
   This run backs off whenever another rig app is live.

### To rerun

- Use a host built from `feat-cnx-ios-rbfix` (or the rebuilt host pin)
  instead of a wrapper, and a fresh tag (`cmux-mobile-e2e-wgmedia2` is prepared
  under `~/cmux-mobile-builds/20261014-wgmedia-e2e/app/`).
- Then run:

  ```
  verify/scripts/browser-track-bench.py --mac-app APP --no-build \
    --sim-name cmux-mobile-wgmedia-bench --record-only \
    --configs wg-track,wg-channel,track,channel,wg-track-relay,wg-track-wss,wg-track-loss30,track-loss30
  ```

  Then `--analyze DIR`.
- The `wg-*` configurations dial WireGuard. `wg-track-wss` removes TURN on
  the phone (`CMUX_MOBILE_DEV_NO_TURN`), so the link rides the WebSocket relay.
- The overlay names the WireGuard lane `wg-rtp`.

