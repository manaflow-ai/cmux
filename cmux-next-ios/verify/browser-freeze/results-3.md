# Browser freeze soak, round 3: route switches on the fix (2026-10-24 UTC)

## Setup

- **Phone:** **17f8ba58a628** (origin/fix-cmux-next-ios-browser-freeze-2, review head), TestFlight-configuration simulator app in `cmux-brfz` on mini-cmux8s, account B.
- **Mac:** the `lrbase` rig Mac on mini-cmux11s.
- **Link:** real Worker signaling, Cloudflare TURN.
- **Launch variable:** `CMUX_MOBILE_DEV_KILL_MEDIA_EVERY_S=40`.
- **Driver plan `--plan shown`:** one tab (en.wikipedia.org/wiki/Cat) shown and streaming for the whole 11 min. It alternates 35 s of scrolls and taps with 70 s untouched (still page), six times. Every still stretch spans at least one kill.
- **Load:** mini-cmux8s ran at load 50–120 during the run. That inflates the phone input round trips (3–7 s).

## Media session kills and route switches

There were 16 media session kills ("media session killed (test)", 34 kill-related lines). Each one gave a new session 1–2 s later and a host `media lane switched route at a keyframe from="wireguard-udp" to="webrtc-track"`, so 16 switches in 11 min.

The next-frame column is the time from the host switch line to the phone's next `browser …: N fps` line. That line is written once per 30 shown frames, so the column is an upper bound. On a still page (3–4 frames a second) the next line can be 8–10 s away even while frames flow. Continuity is shown by the per-minute frame counts below. Video never stopped.

| # | Switch (UTC) | Next fps line s (upper bound) | Line |
| --- | --- | --- | --- |
| 1 | 05:49:38.8 | 4.25 | 4 fps via track |
| 2 | 05:50:19.8 | 1.77 | 4 via track |
| 3 | 05:51:00.9 | 6.60 | 4 via track |
| 4 | 05:51:42.1 | 1.11 | 21 via track |
| 5 | 05:52:23.8 | 6.92 | 4 via track |
| 6 | 05:53:06.0 | 6.61 | 1 via track |
| 7 | 05:53:47.2 | 4.41 | 4 via track |
| 8 | 05:54:28.5 | 3.58 | 4 via track |
| 9 | 05:55:09.7 | 9.79 | 10 via track |
| 10 | 05:56:04.2 | 2.38 | 4 via track |
| 11 | 05:56:45.3 | 7.21 | 4 via track |
| 12 | 05:57:26.5 | 1.88 | 17 via track |
| 13 | 05:58:07.7 | 7.82 | 4 via track |
| 14 | 05:58:49.1 | 3.58 | 4 via track |
| 15 | 05:59:30.2 | 1.17 | 4 via track |
| 16 | 06:00:11.4 | 6.00 | 4 via track |

| Min (UTC) | Decoded frames | Max fps | Via | Host PLIs on the shown route | Inputs / no change | Median RTT s |
| --- | --- | --- | --- | --- | --- | --- |
| 05:49 | 240 | 24 | track | 0 | 4/3 | 3.43 |
| 05:50 | 270 | 54 | track | 0 | 0/0 | - |
| 05:51 | 240 | 21 | track, wg-rtp | 0 | 5/0 | 5.2 |
| 05:52 | 180 | 8 | track | 0 | 3/0 | 3.37 |
| 05:53 | 270 | 32 | track | 0 | 4/2 | 3.24 |
| 05:54 | 180 | 10 | track | 0 | 1/1 | - |
| 05:55 | 240 | 22 | track, wg-rtp | 1 | 3/3 | - |
| 05:56 | 270 | 41 | track | 0 | 3/1 | 3.72 |
| 05:57 | 240 | 20 | track | 0 | 2/1 | 3.44 |
| 05:58 | 300 | 37 | track | 0 | 5/2 | 3.37 |
| 05:59 | 180 | 4 | track | 0 | 0/0 | - |

The "no change" inputs are taps on non-links and scrolls at the page's end. The tab kept decoding in those minutes, and the page ends on a tapped image (`runs3/r3-switch/end.png`).

## Phone diagnostics over the whole run

| Line | Count |
| --- | --- |
| `media gate: nothing passed for 250 ms` | 0 |
| `media lane: a viewer is not reading its frames` | 0 |
| `media receiver: gave a gap up` | 0 |
| Swift `skipped N frames waiting for a keyframe` | 0 |
| `decode failed` | 0 |
| `lane frames for another tab` | 13, all at 05:49:19–:30 while the app's restored tab s148 and the new tab claimed the lane at launch |
| "Reconnecting" (os_log, or the AX tree after each still stretch) | none |
| Browser host crash | none (no new `cmux-remote-browser-host` report on mini-cmux11s; one `host started` per tab) |

## Observation for the code owner

The phone's tunnel source keeps sending PLIs while the WebRTC track is the current route. The host's wireguard-udp route sender counts PLI/FIR RTCP it receives (sender.rs `keyframe_requests += 1`). Its reports, logged only while it is the shown route right after each kill, rise steadily:

- 270 at 05:51:00
- 803 at 05:53:46
- 1202 at 05:55:51

That is about 3.2 a second for the whole run. The track route's count stays at 1–2. The same appeared in the e1dec68 run (636 at 05:32:15, 1293 at 05:35:40, 1947 at 05:39:06).

The sender rate-limits keyframes (`keyframe_allowed`), and video was unaffected. It is still constant RTCP on the idle route. The phone code doesn't log where these come from: no gate or gap lines.

## Superseded run: e1dec68ffef3 (`runs3/r3-switch-e1dec68-blankpage`)

Same plan, 16 switches, all followed by frames. Gate lines 0, Reconnecting 0, crash 0.

Not usable for inputs: right after opening, the driver's list round trip tapped the page toolbar's Back. That is the page's history, so the tab showed its blank start page for the rest of the run. The driver now stays on the opened tab in `--plan shown`.

## Rerun

On mini-cmux8s:

```bash
BRFZ_SRC=$HOME/brfreeze/bsrc ~/brfreeze/tf-build.sh <sha>
```

From the laptop:

```bash
python3 -u relay.py mini-cmux8s-mac-mini /Users/cmux/brfreeze/src/cmux-next-ios/verify -- \
  --app /Users/cmux/brfreeze/app-<sha12>/CmuxMobileApp.app --sim cmux-brfz \
  --rig 'mini-cmux11s-mac-mini:~/brfreeze-rig:brfz-term' --creds /Users/cmux/.secrets/brfz-prod.creds \
  --reuse --install --config default --plan shown --env CMUX_MOBILE_DEV_KILL_MEDIA_EVERY_S=40 \
  --minutes 11 --out /Users/cmux/brfreeze/runs/<name>
```

Then, on mini-cmux8s, run `python3 switches.py RUN_DIR` and `python3 summarize.py RUN_DIR`.
