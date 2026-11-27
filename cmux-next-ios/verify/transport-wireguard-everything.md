# WireGuard for everything, WebRTC only for media inside the tunnel

Research note, 2026-10-14, branch `feat-cnx-ios-wgresearch` (based on
`origin/feat-cnx-ios` at `2e1369f05418`). Read-only code study, the
Cloudflare Realtime TURN docs, and a small local benchmark on an Apple M5 Max.
No app code changed.

The idea under review: the in-app WireGuard tunnel
(`cmux-mobile-link/src/dial/wireguard.rs`, cmux-wg = boringtun + smoltcp) is always
on and is the only network between phone and Mac. A WebRTC PeerConnection
runs inside the tunnel, only for media (streamed browser tabs, whole-screen
viewing). WireGuard handles roaming, so WebRTC never needs an ICE restart.

## Update 2026-10-19: TURN over TLS shipped, the Worker relay retired

Branch `feat-cnx-ios-turntls`. Section 1 below describes the state before.
The WireGuard path now has three carriers, tried in this order, and no
fourth:

1. plain UDP (host, server-reflexive and hole-punched);
2. TURN over UDP (`turn:...?transport=udp`), as before;
3. TURN over TLS on 443 (`turns:turn.cloudflare.com:443?transport=tcp`, the
   URL `/v1/ice` already returned), when UDP gets no TURN allocation.

The backend relay frames are gone. The TeamHub Durable Object keeps
presence and signaling (introductions) and drops any binary frame with a
`relay_retired` error that names the frame's session.

What was built (PROTOCOL.md "WireGuard paths" has the contract):

- `cmux-mobile-link/src/dial/turn.rs`: `StreamConn`, a `webrtc::util::Conn` over a
  TCP or `tokio-rustls` stream. Its read side deframes STUN (`20 + len`)
  and ChannelData (`4 + len`, padded to 4) and returns each message "from"
  the server; its write side writes and flushes whole messages. The `turn`
  crate's client runs on it unchanged (the allocation stays UDP toward the
  peer, RFC 5766 §2.1). STUN retransmission is 1.5 s on a stream. A read or
  write failure marks the stream dead; the session then takes a new
  allocation (at once, then after 1, 3, 10 and 30 s) and announces it.
- Server choice: the first UDP URL; for the stream, TLS on 443, then any
  TLS, then plain TCP. The stream attempt starts 500 ms after UDP (at once
  if UDP fails), so a network that answers UDP opens no TLS connection.
- `cmux-mobile-link/src/class_queue.rs`: the relay's priority classes moved in front
  of the TURN allocation (control, input, then bulk and media by bytes;
  byte bounds; media older than 250 ms dropped), which matters once the
  carrier is one ordered TLS stream.
- Route confirmation moved into the tunnel (`{"t":"reach","from","via"}` on
  overlay UDP 7421, protocol `version: 2` in `wg-init`/`wg-resp`); a
  version-0 peer's datagrams count as the confirmation. Because nothing
  carries every datagram any more, `reach` names which of the sender's
  carriers arrived and whether at the peer's relayed address, and a side
  whose own UDP to the peer's LAN is lost (inbound still working) moves to
  that named route and keeps it while `reach` keeps naming it. The relay
  used to hide this case. Endpoint announcements after a roam
  also go through signaling (`wg-endpoints`), which the relay used to make
  unnecessary for a peer behind an address-filtering NAT.
- A Mac whose STUN servers never answer (UDP blocked on its side) takes its
  own TURN allocation and lists it in `wg-resp`.
- Debug: `block_udp` (Settings → Developer → Block UDP; simulator
  `SIMCTL_CHILD_CMUX_MOBILE_DEV_BLOCK_UDP=1`; `cmux-mobile-dial --block-udp`). Labels:
  "WireGuard relay (TURN)" and "WireGuard relay (TURN over TLS)".

Two regressions the relay had been hiding showed up in the roaming tests
and were fixed: a roam's replay of recent datagrams was sprayed to every
candidate at once and overflowed the peer's 200 KB UDP receive buffer
(now: replay once a route exists, 2 MB socket buffers), and a single lost
`reach` left a side unconfirmed for 3 s (now repeated 100, 300 and 1000 ms
after a route change).

Live numbers (TURN over UDP against TURN over TLS on the same rig) are in
the "Live comparison" section at the end of this note.

## Summary

| Question | Answer |
| --- | --- |
| 1. UDP-blocked networks (TCP/443 only) | The WireGuard TURN carrier is UDP only. But WireGuard already survives UDP blocking through the backend relay, which is WebSocket over TLS on 443. Today's WebRTC path cannot use `turn:?transport=tcp` or `turns:` at all, because webrtc-rs 0.17 drops those URLs. Adding TURN-over-TLS:443 to the WireGuard carrier takes about 1.5 to 2.5 days. Cloudflare offers `turns:turn.cloudflare.com:443?transport=tcp`, and the Worker already hands it out. |
| 2. CPU at 5 to 15 Mbit/s | Crypto is not the cost. boringtun takes about 0.75 µs per 1200 B packet each way (about 1.6 GB/s). The full datagram path costs about 10 µs per packet per side, and syscalls, tokio wakeups and channels dominate. At 15 Mbit/s the phone's receive side is about 1.7 % of an M5 P-core, so roughly 2 % of an iPhone 17 Pro P-core or about 6 % of an E-core. smoltcp TCP costs about 1.7 times as much per byte as the datagram service. |
| 3. MTU | Keep the tunnel MTU at 1280 (`wireguard.rs:45`). The datagram service then carries up to 1232 B per datagram. webrtc-rs defaults fit inside that with no change: RTP 1200 plus SRTP and transport-cc is about 1226, and SCTP 1191 plus DTLS is 1228. Both margins are only 4 to 6 B. If you send RTP yourself, packetize at 1150 at most. |
| webrtc-rs inside the tunnel | Feasible. Give `SettingEngine::set_udp_network(UDPNetwork::Muxed(..))` a `util::Conn` adapter over `WgDatagramSocket`, plus host-only candidates mapped to the overlay IP. About 2 to 4 days to a working PeerConnection, more for media tracks on the Mac host. |
| Recommendation | Go for WireGuard as the only network. No-go, for now, on WebRTC inside it. Carry `cmux.rd/1` media on cmux-wg's existing `Priority::Media` datagram service, the "datagram lane" `verify/browser-stream.md` already plans. Fall back to WebRTC-in-tunnel only if rd's congestion control proves weaker than GCC. |
| Biggest risk | Roaming is not handled by WireGuard today. Endpoints and the TURN allocation are gathered once per dial (`wireguard.rs:751`, `:861`), and cmux-mobile-link never calls `WgNet::rebind`. After a Wi-Fi to cellular switch the path can fall back to the Worker relay (TCP, head-of-line blocking) for up to `DIRECT_STALE` = 14 s, and the TURN allocation is lost. Re-gathering on path change has to be built before "WireGuard handles roaming" is true. |

## 1. UDP-blocked networks

### What the Worker hands out

`backend/src/ice.ts:22-35` calls Cloudflare
`POST /v1/turn/keys/{id}/credentials/generate-ice-servers` and passes every
URL through unchanged. The Cloudflare example response contains these URLs
([generate credentials](https://developers.cloudflare.com/realtime/turn/generate-credentials/)):

```
stun:stun.cloudflare.com:3478
turn:turn.cloudflare.com:3478?transport=udp
turn:turn.cloudflare.com:443?transport=udp
turn:turn.cloudflare.com:3478?transport=tcp
turn:turn.cloudflare.com:80?transport=tcp
turns:turn.cloudflare.com:5349?transport=tcp
turns:turn.cloudflare.com:443?transport=tcp
```

So the phone already receives TURN over TCP (3478, 80) and TURN over TLS
(5349, 443) credentials.

Cloudflare constraints ([TURN overview](https://developers.cloudflare.com/realtime/turn/)):

- TURN over TLS is offered on 5349/tcp and 443/tcp, with TLS 1.1 to 1.3.
- Limits apply per allocation (per TURN user, not account wide): more than
  5 to 10 kpps and more than 50 to 100 Mbps, with higher burst rates.
  Exceeding them drops packets. 15 Mbit/s at 1252 B is about 1.6 kpps.
- The docs say "There is no specific MTU limit".
- Price is $0.05 per GB outbound to the TURN client, free only with the
  Realtime SFU.
- Not in China.
- The docs do not mention RFC 6062 (TCP allocations). We don't need it: the
  allocation stays UDP, and only the client-to-server leg is TCP or TLS
  (RFC 5766 §2.1, RFC 8656). The Mac keeps receiving plain UDP from the
  relayed address.

### What the WireGuard path does with them

- `turn_server()` (`wireguard.rs:149-169`) keeps only the first `turn:` URL
  whose query is empty or `transport=udp`. It skips every `turns:` URL and
  every `transport=tcp` URL. With the order above it always picks
  `3478/udp`, and it never tries the `443/udp` alternate either.
- `TurnCarrier::allocate` (`wireguard.rs:188-251`) binds a UDP socket and
  hands it to `webrtc::turn::client::Client` as `conn`
  (`wireguard.rs:191-201`). If the allocation fails within `TURN_WAIT` = 2 s,
  the dial goes on without TURN.
- The fallback that does work on TCP/443 is the backend relay. Every
  WireGuard datagram goes out as a binary WebSocket frame
  `[16 sessionId][16 peer deviceId][datagram]` on the signaling socket
  (`wireguard.rs:307`, `signaling.rs:131-145`, `:453`). The Team Hub Durable
  Object forwards it (`team-hub.ts:264-274`). That socket is `wss://` to the
  Worker, so TLS on 443. Until a UDP or TURN route is confirmed, every
  datagram goes on the relay as well (`HybridUnderlay::send`,
  `wireguard.rs:455-503`).
- Relay limits: a binary token bucket of 12,000 frames/s, burst 24,000, per
  socket (`team-hub.ts:43`), which is about 120 Mbit/s at 1252 B. Maximum
  frame is `32 + 65535` (`team-hub.ts:32`). One DO per team carries every
  relayed byte for that team.

So on a TCP/443-only network WireGuard connects today, over the Worker relay.
WebRTC does not. webrtc-ice 0.17.2 `gather_candidates_relay` handles only
`turn:` over UDP (`webrtc-ice-0.17.2/src/agent/agent_gather.rs:777`). For TCP
and TLS URLs it logs "Unable to handle URL in gather_candidates_relay"
(`:800`). The TCP and TLS cases are a TODO there. The premise "WebRTC can
use TURN over TCP or TLS on 443" is true of browsers and libwebrtc, not of
our webrtc-rs dialer.

The weakness of the relay fallback is distance and head-of-line blocking.
Every packet goes to the Worker's DO (one region), and one lost TCP segment
stalls every datagram behind it. Inner TCP (the link stream) over an outer
reliable stream does not trigger retransmission storms, because nothing is
lost inside the tunnel. Media datagrams lose their "unreliable" property and
arrive late instead of not at all. TURN over TLS has the same head-of-line
property, but the server is the nearest Cloudflare PoP by anycast instead of
the DO.

### Work to add TURN over TLS:443 to the WireGuard carrier

The `turn` crate client is packet-oriented but transport-agnostic: it takes
any `Arc<dyn util::Conn>`. It already pads ChannelData to 4 bytes
(`turn-0.17.2/src/proto/chandata.rs:44-54`), which RFC 5766 §11.5 requires
on TCP. The work:

1. A `StreamConn: util::Conn` over `tokio_rustls` on a `TcpStream` to
   `turn.cloudflare.com:443` (rustls is already a cmux-mobile-link dependency). The
   read side deframes. When the first two bits are `00` it is STUN, length
   `20 + len`. When they are `01` it is ChannelData, `4 + len` padded to 4.
   It returns each message from `recv_from` with the server address. The
   write side writes whole messages. About 150 to 200 lines with tests.
2. `turn_server()` returns an ordered list of UDP 3478, UDP 443, then TLS
   443 (TCP 80 optional). `allocate()` tries UDP first and starts TLS when
   UDP gets no answer within about 700 ms, or races both. About 50 lines.
3. Route bookkeeping does not change. TURN is already its own path
   (`TURN_PATH`, `wireguard.rs:387`), and the Mac sees plain UDP from the
   relayed address.
4. Tests: a framing unit test, a fake TCP TURN server or a `turn` crate
   server over TCP, then a live test with UDP blocked. On the Mac, the
   Developer "Relay only" setting plus a pf rule that drops UDP would do.

Estimate: 1.5 to 2.5 days. Quick win: also try `turn:...:443?transport=udp`.
Some networks block 3478 but allow UDP on 443.

## 2. Userspace WireGuard CPU at video bitrates

`cmux-mobile-lanebench` (`cmux-mobile-host/src/bin/cmux-mobile-lanebench.rs`) measures keystroke
latency against a live Mac. It is not a crypto or throughput benchmark, so I
wrote a standalone one. Its source is in the appendix. It was built against
this branch's `cmux-wg` and boringtun 0.7.1 (ring ChaCha20-Poly1305), with
release profile, fat LTO and one codegen unit.

Setup:

- Machine: Apple M5 Max, macOS 27.
- Tunnel benchmarks: both peers in one process on a 2-worker tokio runtime,
  over loopback UDP, using `cmux_wg::testing::loopback_pair` (MTU 1200, so
  datagram payload 1152).
- CPU is process user+sys time from `getrusage` over a 5 s paced run.

| Benchmark | Result (two runs) |
| --- | --- |
| boringtun `encapsulate`, 1200 B | 767 ns/pkt (1564 MB/s) |
| boringtun `decapsulate`, 1200 B | 733 ns/pkt (1637 MB/s) |
| boringtun `encapsulate` / `decapsulate`, 1252 B | 861 / 773 ns/pkt |
| WgNet datagram service, 5 Mbit/s (543 pps) | 1.3 % of a core, both peers, 24 µs/pkt |
| WgNet datagram service, 10 Mbit/s (1085 pps) | 2.2 to 3.0 %, 20 to 27 µs/pkt |
| WgNet datagram service, 15 Mbit/s (1628 pps) | 2.9 to 3.8 %, 18 to 23 µs/pkt |
| WgNet datagram service, 50 Mbit/s (5425 pps) | 9.5 to 11.8 %, 18 to 22 µs/pkt |
| WgNet TCP (smoltcp) stream, 5 Mbit/s | 2.0 to 2.4 %, 37 to 46 µs per 1200 B |
| WgNet TCP (smoltcp) stream, 15 Mbit/s | 5.3 to 5.9 %, 34 to 38 µs per 1200 B, about 13.7k driver wakeups in 5 s |

The "µs/pkt" figures cover both peers: encapsulate, UDP send, UDP receive,
decapsulate. Every packet was delivered (sent = recv).

What dominates:

- Crypto is about 1.5 µs of the roughly 20 µs two-peer cost, or 7 %. The rest
  is per-packet `sendto`/`recvfrom` with no batching, tokio task wakeups, and
  mpsc hops between the driver, the datagram socket, and the pacing
  scheduler.
- smoltcp adds about 15 to 20 µs per 1200 B on top of the datagram path,
  from TCP segmenting, ACKs and retransmit timers. Media on the datagram
  service is therefore about 1.7 times cheaper than media on the link's TCP
  stream.

iPhone 17 Pro estimate:

- The phone only receives at these rates, so it pays about half the two-peer
  cost: roughly 10 µs/pkt, or about 1.7 % of an M5 P-core at 15 Mbit/s.
- The A19 Pro P-core is the same core generation as the M5 at a lower clock
  (about 4.3 vs 4.6 GHz). Expect about 2 % of one P-core at 15 Mbit/s and
  under 1 % at 5 Mbit/s. If the scheduler runs the tunnel on E-cores, which
  are about 3 times slower per clock and run at lower clocks, expect about
  5 to 7 % of an E-core.
- Crypto alone at 15 Mbit/s is about 0.13 % of a P-core.

Battery: at these rates the cellular or Wi-Fi radio costs several times more
than the tunnel's CPU. A few percent of one core is in the tens of
milliwatts. WebRTC inside the tunnel would add its own per-packet stack:
ICE, the DTLS/SRTP decrypt (a second encryption layer on top of WireGuard),
interceptors, and the jitter buffer. That stack likely costs more CPU than
WireGuard itself. I did not measure it here.

## 3. MTU with WebRTC inside WireGuard

### Today

- The in-app tunnel MTU is `const MTU: u16 = 1280` (`wireguard.rs:45`,
  "room for the relay frame header and WebSocket framing"). It is passed to
  `WgConfig.mtu` (`wireguard.rs:692`). The cmux-wg default is 1420
  (`cmux-wg/src/config.rs:20`).
- The datagram service payload is `mtu - (40 IPv6 + 8 UDP)`
  (`cmux-wg/src/net_datagrams.rs:19`, `net.rs:106`). So 1232 B is the most
  an inner UDP socket (and so WebRTC) can send. The overlay is IPv4
  (10.77.0.x), so this subtraction is 20 B conservative.

### Outer packet size for an inner packet of 1280

| Path | Overhead | IPv4 outer | IPv6 outer |
| --- | --- | --- | --- |
| Direct UDP | IP + UDP 8 + WireGuard 32 | 1340 | 1360 |
| TURN, ChannelData | + 4 | 1344 | 1364 |
| TURN, Send indication (before ChannelBind) | + 36 (v4) / + 48 (v6) | 1376 | 1408 |
| TURN over TLS, or Worker relay (WSS) | TCP stream, no per-packet MTU | n/a | n/a |

The worst case, IPv6 plus a Send indication, still fits in 1500. On a
1400-byte path (some cellular or tunnelled links), IPv6 plus a Send
indication allows an inner MTU of 1400 − 40 − 8 − 48 − 32 = 1272. ChannelData
allows 1316. 1280 is also the IPv6 minimum, should the overlay ever carry
IPv6. Keep 1280. Raising it to 1360 or more buys nothing for WebRTC, whose
defaults stop at about 1200.

### Inner budget: 1232 B of UDP payload

| Inner traffic | Size |
| --- | --- |
| SRTP from `TrackLocalStaticSample` | RTP packet ≤ 1200 (`RTP_OUTBOUND_MTU`, `webrtc-0.17.2/src/track/mod.rs:10`, used at `track_local_static_sample.rs:218`) + transport-cc extension 8 + SRTP tag 10 (AES_CM_80) or 16 (AEAD_GCM) = about 1218 to 1226. Fits. |
| SCTP data channel | SCTP packet ≤ 1191 (`INITIAL_MTU`, `webrtc-sctp-0.17.2/src/association/mod.rs:63`) + DTLS 1.2 AES-GCM record (13 header + 8 nonce + 16 tag) = 1228. Fits. |
| DTLS handshake flights | Fragment at the webrtc-dtls MTU (about 1200). Fits. |

Recommendations:

- Keep the tunnel MTU at 1280.
- `RTP_OUTBOUND_MTU` is `pub(crate)`, so it cannot be set. If media goes
  through webrtc-rs, use `TrackLocalStaticRTP` and packetize yourself at
  1150 B at most. That leaves room for more header extensions, such as
  abs-send-time, mid, and playout-delay.
- `SettingEngine::set_receive_mtu` (`setting_engine/mod.rs:358`) only sizes
  the receive buffer (default 1460). Leave it.
- If the datagram lane carries `cmux.rd/1` shards instead, size them to
  `WgNet::max_datagram()` (1232) minus the rd header.

## webrtc-rs over the tunnel

Feasible with existing hooks. No fork is needed.

1. cmux-wg already has unreliable overlay UDP: `WgNet::bind_datagram(port)`
   returns `WgDatagramSocket` with `send_to(payload, peer, Priority)` and
   `recv_from()` (`net_datagrams.rs:45-131`). `Priority::Media` drops packets
   older than 50 ms (`pacing.rs:234-241`).
2. Write `WgUdpConn: webrtc::util::Conn` over it. `local_addr()` returns the
   overlay `10.77.0.x:port`. Send ICE, STUN and DTLS as
   `Priority::Interactive` and SRTP as `Media`. Telling them apart takes one
   first-byte check (RFC 7983).
3. Configure the `SettingEngine`:
   - `set_udp_network(UDPNetwork::Muxed(UDPMuxDefault::new(UDPMuxParams::new(conn))))`.
     `UDPMuxParams::new` takes any `Conn`
     (`webrtc-ice-0.17.2/src/udp_mux/mod.rs:56`).
   - `set_nat_1to1_ips(vec![overlay_ip], Host)`, so the host candidates the
     mux gathers (`agent_gather.rs:385-460`, which enumerates real
     interfaces) are advertised as the overlay address.
   - An `set_ip_filter` or `set_interface_filter` that keeps one interface,
     so there is one candidate.
   - mDNS disabled, `Udp4` only, no ICE servers.
4. Exchange the offer and answer over a link channel inside the tunnel, not
   the Worker. The PeerConnection then never sees a network change. Its one
   candidate pair is overlay to overlay and stays valid while WireGuard
   roams, so there are no ICE restarts.
5. `set_vnet` (`setting_engine/mod.rs:251`) is the simulated network for
   tests. It needs its own router, so it is the wrong hook here.

Effort:

- 2 to 4 days for the adapter, the settings, and an in-tunnel
  PeerConnection with a data channel and a loopback test.
- Real media tracks need more: an RTP sender on the Mac host (VideoToolbox
  H.264 into `TrackLocalStaticRTP`) and a receiver plus decode path on iOS.
  `browser-stream.md` estimates a second packetizer and congestion
  controller per transport, about 1 to 2 weeks.

### Why not WebRTC inside the tunnel, yet

`verify/browser-stream.md` chose `cmux.rd/1` over the link (option a) and
listed "a datagram lane per link" as the next step. cmux-rd-engine already
has delay-based congestion control, FEC, NACK and recovery frames, and no
jitter buffer. cmux-wg already has the media datagram class with stale-drop.
A WebRTC PeerConnection inside the tunnel would bring:

- a second media stack on the phone;
- double encryption (SRTP inside WireGuard);
- a jitter buffer tuned for calls;
- RTP sender work on the Mac.

All of that to get GCC, which is the one advantage the comparison table gave
WebRTC. Wiring `WgDatagramSocket` as the rd datagram lane is the smaller
step. Do it first, and revisit WebRTC-in-tunnel only if rd's congestion
control loses to GCC on real cellular runs.

## Risks and open items

- **Roaming is not handled yet.** The dialer gathers host, reflexive and
  TURN endpoints once (`wireguard.rs:751`), and the answerer does the same
  (`:861`). cmux-mobile-link never calls `WgNet::rebind`
  (`cmux-wg/src/net.rs:166`). After a network change:
  - the phone's TURN allocation is tied to the dead 5-tuple;
  - the Mac learns the phone's new address only when an authenticated
    datagram arrives (`authenticated()`, `wireguard.rs:553-596`), and only
    if the Mac's NAT lets it in;
  - otherwise the link sits on the Worker relay, after up to `DIRECT_STALE`
    = 14 s (`wireguard.rs:52`).

  "WireGuard handles roaming" needs four things: a path monitor, a rebind
  onto a fresh socket, re-gathered STUN and TURN, and a new `wg-init`-style
  endpoint update over signaling. That is about 2 to 3 days.
- **Relay as the only TCP path.** Until TURN-over-TLS lands, UDP-blocked
  networks carry all media through one DO per team. That costs DO request
  billing, a single-threaded hop, and head-of-line stalls.
- **Tight inner margins.** Only 4 to 6 B are spare at the default webrtc-rs
  sizes. A future header extension or a DTLS 1.3 change could exceed 1232
  and be dropped silently. Assert on `DatagramTooLarge`.
- **Not measured:**
  - an on-device iPhone run. Use an Instruments CPU profile with the phone
    receiving a 15 Mbit/s rd stream; Simulator numbers are the Mac's;
  - webrtc-rs per-packet CPU;
  - TURN-over-TLS throughput from Cloudflare.

## Appendix: benchmark source

The benchmark lives at `/tmp/wgbench-src` and is not checked in. Build it
with `CARGO_TARGET_DIR=/tmp/wgbench-target cargo build --release`.

`Cargo.toml` dependencies:

- `boringtun =0.7.1`, no default features
- `x25519-dalek 2` with `static_secrets`
- `rand_core 0.6` with `getrandom`
- `cmux-wg`, path to this worktree's `cmux-tui/crates/cmux-wg`
- `tokio 1` with `full`
- `libc`

```rust
// Crypto: two Tunn, handshake, then 200k encapsulate followed by 200k decapsulate
// of a synthetic IPv4/UDP packet of `size` bytes.
fn crypto_bench(size: usize, n: usize) { /* ta.encapsulate(&pkt) -> cts; tb.decapsulate(cts) == WriteToTunnelV4 */ }

// Datagram service: loopback_pair(); WgNet::start both; server.bind_datagram(5000);
// client.bind_datagram(5001); paced send_to(payload=max_datagram, Priority::Media)
// at mbit for 5 s (10 packets per tokio interval tick); count received;
// CPU = getrusage(RUSAGE_SELF) user+sys delta.
async fn tunnel_bench(mbit: f64, payload: usize, secs: f64) { /* ... */ }

// smoltcp TCP: server.listen(7420); client.connect(); paced write_all of
// 12000 B chunks at mbit for 5 s; reader counts bytes; same CPU accounting
// plus WgNet::wakeups().
async fn tcp_bench(mbit: f64, secs: f64) { /* ... */ }
```

## Live comparison (2026-10-19)

Rig: `mini-cmuxs-mac-mini-3`, one headless iPhone 17 Pro simulator (iOS 26.5)
and the tagged cmux-next Mac app `cmux-mobile-e2e-3793fcd0` (fleet job
`de0d2897987380ef5113c7d8`, branch commit `3793fcd064a`, with this branch's
cmux-mobile-host), both on the mini, against the dev Worker (API 0.9.0) and
Cloudflare TURN. The phone dialed WireGuard; Settings > Developer > Relay
only gave TURN over UDP, Block UDP gave TURN over TLS on 443 (no plain UDP
and no TURN over UDP on the phone; the Mac sends plain UDP to the phone's
relayed address). Script: `verify/e2e/turn_live.py`; evidence (git-ignored)
in `verify/evidence/2026-10-19/turn-live/`.

| | TURN over UDP | TURN over TLS (UDP blocked) |
| --- | --- | --- |
| Phone's link line | "Connected · WireGuard relay (TURN) · 15 ms" | "Connected · WireGuard relay (TURN over TLS) · 15 ms" |
| Mac's label (cmux-mobile-host) | `Turn` | `TurnTls` |
| Connected after the toggle (redial) | 3.5 s | 3.0 s |
| Link RTT shown by the phone, 12 samples over 20 s | median 14 ms (14 to 15) | median 15.5 ms (14 to 16) |
| Command typed on the phone's soft keyboard, Send to output on the Mac (8 runs) | median 1184 ms (1082 to 2165) | median 1449 ms (1251 to 3352) |
| Terminal | `echo <marker>` typed on the phone, output on the Mac and back on the phone | same |
| Browser tab | | a browser workspace opened from the phone; example.com typed in its address bar rendered, streamed over the media lane in the tunnel ("wg-rtp", latency 39 to 45 ms; cmux-mobile-host: media feedback delay 37 ms, no loss) |

The typed round trip is dominated by the rig's `axe` taps (0.3 to 0.7 s
each from the host call to the touch, PROTOCOL-independent) and by the
mini's load: during the TLS run a CI job pushed the 1-minute load from about
8 to over 250, and the signaling WebSocket of both the Mac and the phone was
reset by the network several times (the phone then redialed, each time
straight back onto TURN over TLS). The link RTT is the like-for-like
number: TURN over TLS adds about 1 ms over TURN over UDP to the nearest
Cloudflare PoP from this mini.
