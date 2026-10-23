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
phone is device `b553a6e0-…`.

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

## Signaling resets

(Filled in below with the Worker and rig evidence.)

## Rig

(Filled in below.)
