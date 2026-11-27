# Browser freeze soak: results (2026-10-24 UTC)

Rig and commands: README.md. Raw runs: `runs/` (screenshots only for the
decisive freeze; the rest stay on mini-cmux8s in `~/brfreeze/runs/`).

## Reproduced on the base (bb9c03bf phone)

Run `runs/base-default`. The configuration was the default: WireGuard over Cloudflare
TURN plus the WebRTC media session. The rig Mac was on mini-cmux9s.

The freeze started 26 s into the first tab, after the first route switch of the media
lane. It needed no second tab:

```
03:13:10.905 host  browser: host started tab="new-a9b9d947-t1"      (tab A, wikipedia)
03:13:11.612 phone browser new-a9b9d947-t1: 1 fps ... via wg-rtp     (the only frame tab A ever showed)
03:13:21.905 host  media session failed ... the media session's peer connection failed
03:13:23.127 host  media session up ... path=Direct
03:13:23.134 host  media lane switched route at a keyframe from="wireguard-udp" to="webrtc-track"
03:13:26.014 host  browser: media lane frames=13  ... loss=0.0 keyframe_requests=12
03:13:56.241 host  browser: media lane frames=127 ... loss=0.0 keyframe_requests=126
03:16:57.122 host  browser: media lane frames=806 ... loss=0.0 keyframe_requests=806
03:16:59.126 host  browser: another tab took the media lane; video returns to the channel   (tab B opened)
03:17:04.147 host  ... keyframe_requests=816   (storm over; tab B then ran at 9-54 fps via track)
```

- For 3 min 41 s the phone asked for a keyframe 3.8 times a second, which is the gate's
  250 ms `RejectAndAsk` plus the round trip. Every request was answered: frames equal
  keyframe_requests + 1, with no loss.
- The phone showed none of those frames. No `browser ... fps` line appeared after the
  first one, and that line is logged on shown frames 1, 31, 61, and so on.
- There was not one `decode failed`, `no decoder` or `bad parameter sets` line in the
  sim's os_log, which was streamed at debug level the whole time. The keyframes stopped
  before VideoToolbox. That rules out candidate 3, the decoder, for this freeze.
- Every input on tab A got no screen change: 10 out of 10 scrolls, taps, back/forward and
  searches.
- The storm ended only when another tab took the lane.
- Same signature as the user's log: about 4 PLIs a second with loss near zero, and the
  host keeps sending.

Candidates:

- **1 (gate).** Supported in its general form: the gate on the phone rejects the next
  route's keyframes and asks again every 250 ms. Here it was the same tab, with one
  capture clock on both routes. So cross-tab clocks alone do not explain this instance.
  The comparison of the new route's keyframe timestamp with `newest_ts` still failed.
- **2 (overflow).** Not seen. An overflow asks on every frame batch, not at a steady
  250 ms.
- **3 (decoder).** Ruled out here: no decode errors.

The phone's Rust log has no gate or PLI lines, because the code does not log them.

| min (UTC) | decoded frames | max fps | via | host PLIs | inputs / no response | median RTT s |
| --- | --- | --- | --- | --- | --- | --- |
| 03:12 | 30 | 1 | wg-rtp | 0 | 0/0 | - |
| 03:13 | 0 | 0 | - | 209 | 6/6 | - |
| 03:14 | 0 | 0 | - | 226 | 3/3 | - |
| 03:15 | 0 | 0 | - | 226 | 1/1 | - |
| 03:16 (tab B at :59) | 420 | 53 | track | 30 | 7/1 | 0.94 |
| 03:17 | 360 | 45 | track | 0 | 5/4* | 0.96 |
| 03:18 | 390 | 42 | track | 0 | 4/2* | 1.32 |

\* After 03:17 the no-response inputs are back/forward without history and the driver's
search in the address bar. The page itself kept streaming.

## After the fix (d0fc144e4cf1 phone), same rig Mac (moved to mini-cmux11s)

Run `runs/fix-d0fc-default`, 19 min, default configuration:

- No keyframe storm: 1 to 9 host PLIs a minute for the whole run.
- Every minute with interaction decoded frames: 23 to 54 fps peaks, via track.
- Long scroll at 03:40:05: 15 pans in 12.9 s. The page answered (0.26 s) and no
  "Reconnecting" text showed.
- Still idle at 03:51:05: 125 s on tab C with the app foregrounded, then no
  "Reconnecting" text, and the next scroll answered. The host log shows no link or media
  drop in that window.
- Background for 20 s at 03:50:09. Frames resumed at 03:50 (50 fps peak), with an input
  round trip of 3.9 s right after the return.
- No `decode failed` lines, and no watchdog close or reopen lines.

| min (UTC) | decoded frames | max fps | via | host PLIs | inputs / no response | median RTT s |
| --- | --- | --- | --- | --- | --- | --- |
| 03:38 | 0 (tab A loading, 69 s) | 0 | - | 5 | 1/0 | 1.72 |
| 03:39 | 450 | 43 | track | 3 | 5/3 | 1.2 |
| 03:40 | 90 | 50 | track | 6 | 3/2 | 1.73 |
| 03:41 | 0 | 0 | - | 5 | 1/1 | - |
| 03:42 | 120 | 25 | channel,track | 5 | 1/0 | 1.02 |
| 03:43 | 30 | 13 | track | 4 | 1/1 | - |
| 03:44 | 180 | 53 | track | 1 | 5/1 | 1.12 |
| 03:45 | 270 | 54 | track | 4 | 9/4 | 1.46 |
| 03:46 | 420 | 41 | track | 9 | 0/0 | - |
| 03:47 | 180 | 35 | track | 7 | 4/4 | - |
| 03:48 | 240 | 39 | track | 7 | 2/2 | - |
| 03:49 | 60 | 23 | track | 5 | 4/4 | - |
| 03:50 (bg 20 s) | 210 | 50 | track | 4 | 5/2 | 3.92 |
| 03:51 (still idle) | 0 | 0 | - | 6 | 0/0 | - |
| 03:52 | 120 | 30 | track | 6 | 1/0 | 3.14 |
| 03:53 | 360 | 42 | track | 7 | 0/0 | - |
| 03:54 | 120 | 29 | track | 6 | 4/4 | - |
| 03:55 | 300 | 39 | track | 6 | 0/0 | - |

The "no response" counts in this run come from the driver, not from frozen video. Video
was flowing in those same minutes and the host's PLI count stayed flat. They are
back/forward with no history, taps on non-links, and a page whose "Show toolbar" pill
kept `back_to_list` from reaching the list, so tab switches 2 to 5 failed.

**Gap:** in this run the media session came up at the first try (03:37:10) and stayed up.
The lane never switched route, so the exact trigger of the base freeze (a
wireguard-udp -> webrtc-track switch while a tab is shown) did not happen. The 45 s on
the list did not end the session. The run shows no regression and no storm, but it does
not prove the fix against that trigger. To force it: make the first media session fail
(it did on the base when the rig mini was loaded), or add a debug hook that kills the
media session (`LinkHandle.killMedia`) reachable from a launch variable.

## Other configurations

Not run: WireGuard-only (`--config wgonly`), relay-only (`--config relay`) and loss
(`--config loss --drop-permille 40`). The coordinator asked for the default after-run
first. The commands are in README.md.

## Rig problems hit and fixed

- The production dogfood account's simulator password sign-in fails (`StackAuthError`).
  Test account B works.
- mini-cmux9s at load 230: "the app did not start a browser host in time". The rig Mac
  moved to mini-cmux11s.
- Fleet cmux build `a9b696c799b17e1e9397c02e` stayed queued for 60 min (AWS workers
  `host_lock`, minis `disk`) and was cancelled. The existing fleet `lrbase` production app
  was used instead.
- Driver: the soft keyboard has no `_` or `=` key, so the URLs and searches avoid them.
  `back_to_list` gets an edge-swipe retry.
