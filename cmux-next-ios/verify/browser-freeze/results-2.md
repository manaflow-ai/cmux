# Browser freeze soak, round 2 (2026-10-24 UTC)

## Rig

The rig is the one in README.md:

- **Phone.** Simulator `cmux-brfz` on mini-cmux8s, TestFlight configuration, account B.
- **Mac.** The `lrbase` app on mini-cmux11s.
- **Link.** Real Worker and Cloudflare TURN.

Phone builds used:

- **`ee3bedc8151e`** (runs b and c, and the no-op run a). This is ddbd4b2f598c plus the
  missing Cargo.lock line, a local commit on the rig that was never pushed. It is the
  same source as 9d56432f3b21.
- **`0000223ca7fb`** (run a), which fixes the kill hook. Mini-cmux8s filled its disk
  during this build. So it was built on mini-cmux11s instead, with
  `CMUX_MOBILE_XCFRAMEWORK` set to the xcframework mini-cmux8s had built for this SHA
  (cache key `8a022399bc3b471f`).

Driver: brfz_soak.py with `--env K=V`, `--minutes`, and list rows tracked by id. It
goes back and forward only over history the run itself created. switches.py prints the
per-switch table.

Raw runs: `runs2/` (on the mini: `~/brfreeze/runs/r2-*`).

## a. Route switch: `CMUX_MOBILE_DEV_KILL_MEDIA_EVERY_S=40` (0000223ca7fb), 11 min

The hook worked:

- The phone logged 13 times `media session killed (test)`. The host logged
  `media session down reason="bye: closed"` 40 s after each session came up, then a new
  session came up 1-2 s later.
- The lane switched route only while a tab was streaming. That was 4 host
  `media lane switched route` lines, all in the first 2 minutes. After 05:02:31 no tab
  streamed (see the second finding), so the later kills switched nothing.

| # | Switch (host UTC) | From -> to | Shown tab | Next phone frame | Gate asks |
| --- | --- | --- | --- | --- | --- |
| 1-2 | 05:00:53.838 / 05:00:54.176 | wg-udp -> track, then track -> wg-udp | s116 (tag 7a3d70b3, restored at launch) | none for 22.7 s; ended when the driver opened tab A at 05:01:16 | 84 asks in 22 s, each `ts == newest` |
| 3 | 05:01:35.015 (kill at 05:01:33.58) | wg-udp -> track | tab A (tag 4efb8a9f) | none for 14 s; recovered at 05:01:49.96, when the watchdog reopened the stream ("no picture after a keyframe request; restarting the decoder" at :46.8, then "still no picture; opening the stream again") | 58 asks in 16 s, each `ts == newest` |
| 4 | 05:02:29.215 | wg-udp -> track | tab A after the reopen (tag a13a255d) | one frame at 05:02:31.39, then `closed: eof` at 05:02:31.43; the stream never reopened (see below) | 6 asks, each `ts == newest` |

No "Reconnecting browser…" text appeared during the switches themselves.

### Finding 1 (decisive): the gate refuses an equal timestamp

The gate rejects the new route's keyframe because its timestamp equals the tab's newest:

```
05:00:53.838 host  media lane switched route at a keyframe from="wireguard-udp" to="webrtc-track"
05:00:53.844 phone media gate: nothing passed for 250 ms; asking for a keyframe source=2 current=Some(1)
                   keyframe=true tag=Some("7a3d70b3") ts=58241389 newest=Some(58241389) carrier=Some("webrtc-track")
   ... repeated every ~267 ms with the same ts until 05:01:16.054 (84 lines)
05:01:33.899 phone media gate: ... source=3 current=Some(2) keyframe=true tag=Some("4efb8a9f") ts=887472 newest=Some(887472) carrier=Some("webrtc-track")
   ... until 05:01:49.767 (58 lines)
```

What the lines show:

- All 151 gate lines in run a, and the one in run c, have `keyframe=true` and
  `ts == newest`.
- There were none with `keyframe=false` and none with `ts < newest`.
- No "a viewer is not reading its frames" lines appeared.
- "lane frames for another tab" appeared only while a newly opened tab claimed the lane.

The mechanism:

1. On a still page the browser host paints nothing new.
2. So every keyframe a request produces is a re-encode with the same capture timestamp.
3. The first copy passed on the old route and set `newest`.
4. The copies on the new route are never "newer", because the check is strict:
   `(ts - newest) as i32 > 0`.
5. So the gate keeps the old source current and keeps asking.
6. It ends only when the page repaints, the lane changes tabs, or the stall watchdog
   reopens the stream.

This also explains frames == keyframe_requests + 1 on the base.

### Finding 2: after the watchdog reopen, the stream closed and never came back

```
22:01:49.960 (local) browser new-11be14fd-t1: still no picture; opening the stream again
05:02:29.215 host    media lane switched route ... to="webrtc-track"
22:02:31.394 (local) browser new-11be14fd-t1: 1 fps ... via track
22:02:31.432 (local) browser new-11be14fd-t1 closed: eof
```

- From then until the end of the run (05:12) the page showed "Reconnecting to the Mac…"
  over a black page (`runs2/r2-switch/reconnecting-050256.png`).
- Over the same period:
  - The link kept logging `link connected`.
  - Media sessions kept coming up.
  - There was no new browser `open at` line.
  - The host logged no browser close for that tab.
- Every input after 05:02:42 got no response.
- `eof` is the code the viewer uses for a close by the app.

## b. WireGuard only (`CMUX_MOBILE_DEV_NO_WEBRTC_MEDIA=1`, ee3bedc8), 10 min

- Video ran via wg-rtp at 33-55 fps peaks from 04:36 to 04:40, with 2-7 host keyframe
  requests a minute.
- There were 0 gate lines, 1 "gave a gap up", 0 decode failures and no reconnects.
- From 04:40 the driver lost its way on the workspace list (an old driver, before the
  rows were tracked by id). So the rest of this run is not video evidence.

## c. Relay only (`CMUX_MOBILE_DEV_RELAY_ONLY=1`, ee3bedc8), 10 min

- Two tabs and two switches between them.
- Video ran via track at up to 55 fps, with 1-7 host keyframe requests a minute and no
  storm.
- There was 1 gate line, at 04:59:35.77, after a stall forced a track -> wg-udp switch.
  It was again `keyframe=true ts=49003043 newest=Some(49003043)`, and recovered at once.
- There were 7 "gave a gap up" lines (losses on the relay), 26 "lane frames for another
  tab" lines (all during tab claims), 0 decode failures and no reconnects.
- After 04:59 the page showed 4 fps with latency up to 31 s. That is the relay under
  load, not a freeze.

## Not done

- In run a, the per-switch table covers only 4 switches, not the ~12 expected. The
  other kills came after the stream had closed for good (finding 2).
- No run on a build where the gate accepts an equal timestamp.
