# termfix r13: live re-run of the verifier's scenarios

Branch `feat-cnx-ios-termfix-r13` at 43c6ef8947e. Date 2026-10-19 (US Pacific).

## Rig

| Part | Value |
| --- | --- |
| Phone | Demo simulator build of 43c6ef8947e (`DEBUG CMUX_MOBILE_DEMO`, bundle `dev.cmux.mobile.r13`, launched with `-CmuxMobileTermProbe`), iPhone 17 Pro, iOS 26.5, headless on **mini-cmux11s** (the laptop's CoreSimulator was wedged by an earlier hung `simctl shutdown`). Deleted after |
| Mac | Fleet build `cmux-mobile-e2e-e6d43df7` (job de1152bc2decbd8196e98e1d), hidden on the same mini; settings only via `open --env` (tq.py LocalMac); Info.plist never edited, never re-signed. Mac-side code equals 43c6ef89 |
| Link | Dev Worker; WebRTC direct. Phone and Mac on the **same host**, so this is the real link stack but a LAN-less path; latency numbers are lower than a two-host rig |
| Analysis | `termqa/motion.py` with the verifier's bands, on the laptop |
| Contamination | Another agent's parity rig (`cmux-mobile-e2e-dc79f937`, same dev account, same computer name) runs on this mini, and two other phones linked to this rig Mac during the run. It affected D4 (below) |

Every recording is `invalid` under §1.4 (simulator records on change; 27-37 effective fps), as in the verifier's run.

## Results, before → after

| Defect | Metric (verifier's scenario) | Before (3e6a2b56eff) | After (43c6ef89) | Verdict |
| --- | --- | --- | --- | --- |
| D1 keyboard up | s2b, stream20 20 rows/s, 60 fps, band 70-384 pt: one-frame 1-row jumps / reversals | 46 / 297 in 66 s | **1 / 11 in 61 s**; the 1 flash and all 11 reversals are one event at 53.6-54.1 s, a multi-row catch-up after a stall (moves of 96-192 px), not the torn-row pattern | fixed (1 residual event, different mechanism) |
| D1 after Jump to bottom | s3b 15 s window from the first jump, band 70-629 pt: flashes | 11 | **0** (0 reversals in both following windows after the 2 jumps; the window's 68 reversals are the fling gestures) | fixed |
| D3 AutoFill | tap the focused composer, AX + screenshot | pill 67/67 s | **0/5 s**, no pill in the screenshot | fixed |
| D2b hostd kill | `pkill -9 cmux-mobile-host` mid-stream: pill back to live / hostd `link up`, after the kill | 26.7 s / 25.1 s after hostd was listening | **2.35 s / 2.35 s** (0.40 s after hostd's signaling); repeat runs 4.22 s / 3.27 s and, over `top`, 2.26 s / 1.74 s (0.15 s after signaling) | fixed (≤ ~2 s after the host is back) |
| D2 reattach blank | motion.py over the reattach | `top`: 11 blank frames, then half drawn | **0 black, 0 flashes** (stream and `top`); frame strip over `top` shows a full screen in every frame | fixed |
| D2a signaling reset | phone builds a second link? | yes, 2/2, terminal repainted | **no, 2/2**: two natural Worker resets (`signaling ended`, 06:32:02 and 06:35:24 UTC, the first during the s2b recording) left our phone's link up; no new `link up` for it until the hostd kill | fixed (natural events, n=2) |
| D4 Mac app gone | offline label after a graceful quit | never in 20 min | **not shown in 60 s** ("Reattaching…" stays) on this rig; last frame stays visible and readable. Cause in this rig: the phone's link moved to the *other* online Mac on the same account (the parity rig on this mini; `link connected … rtt 0-3 ms` after the quit), and the terminals' offline state follows the link's phase, not their own Mac. After a hostd kill the pill did show "Mac offline" (1.73 s) | **not verified; a product gap remains** (see below) |
| D5 stale input | composer Send and direct typing while the Mac is down; relaunch after > 1 min | ran 15.4 min later | composer kept `echo STALE_COMPOSER` with "Not sent: reconnecting to …"; typed keys dropped with "Keys typed while your Mac was unreachable were not sent."; **nothing ran** on the Mac after the relaunch; tab live 3.56 s after the launch call | fixed |
| D6 grid card | card OCR vs Mac, twice per grid open | frozen (78 vs 143→201) | **advances while open** (e.g. 998→1030 as the Mac went 1016→1046); 16-19 rows (~1 s) behind the Mac in 11 of 12 samples | fixed |
| D7 New Terminal | + tap → prompt (rig OCR) | 5.59 s (≈4.5 s after the pick) | **3.36 s**; the pick tap completes at 2.22 s, so ≤ 1.14 s pick → prompt; the app logs the Mac listing the tab 187 ms after the pick | phone part within 1.5 s; rig tapping dominates |
| D7 close prompt | tap Close (running program) → Cancel found (AX polling) | 2.1-2.4 s | **0.97-1.04 s** (3/3), message "Still running: python3.14." at once | improved; remaining time is the rig's AX polling |
| D7 idle close | card gone after tap | 4.4 s | 3.42 s | |
| D7 hidden controls | AX tree on the zoomed page | 'Close e2e-t1', 'Done', 'New', 'More' exposed | **none** | fixed |
| D7 "+" label | grid + button | lost its label | the rig still matches an unnamed inner Button at (38, 788); the TabsKit fork says the labelled outer PopUpButton is the one to match | rig, not re-checked |
| D7 first switch | grid → tab | 0.76 s first, 0.05-0.07 later | settle-after-tap (incl. zoom animation and ~0.3 s axe tap) 1.00, 1.18, 1.00 s for the 1st, 3rd, 5th switch: **no first-switch penalty**; the verifier's 0.15 s metric needs an in-app timing log | BLOCKED (metric) |

## Tools (G-07, G-08, G-09)

- Echo probe: 20 `~` keys typed into the shell at idle: **n 20, p50 23.1 ms, p95 30.0 ms, p99 33.9 ms** (`echo-idle.json`).
- Text export + `crcgen.py 2000`: **2000 rows, 0 lost, 0 duplicated, in order, 0 CRC errors**, `TOTAL 2000 0e3af32b`.
  - Tool bug found and fixed: `termprobe.py export` armed its wait for the app's reply after posting, so it missed the reply (the files were written). It now arms the waiter first.
- `sizelog.py` over 40 min: resizes first 6, settled 2, settled-tui 3; resets attach 5, reattach 3, resized-event 9; 14 replays, longest 125 ms.

## D4: what remains

With two Macs on the account, a terminal whose own Mac is gone shows "Reattaching…" indefinitely when the link has moved to the other Mac. `LiveCoordinator.updateTerminalsOffline` derives every terminal's offline state from the single link phase, which is "connected" (to the other Mac). The fix belongs there: a terminal should be offline when *its* Mac's presence is offline, whatever the link is doing. A clean single-Mac re-run of T-LIFE-13 is still needed (this mini hosts another agent's rig on the same account).

## Files

`live/`: motion analyser json (`s2b-follow-kbup`, `s3b-jump`, `s3b-after-jump1/2`, `life-e-hostd-kill`, `life-e-hostd-kill-top`), `tabs-switch.settle.json`, scenario logs (`s23b-log`, `life-e-hostd-kill*`, `life13-d45`, `life13-d4`, `tabs-ab`, `life-c`, `tabs-switch`, `echo-idle`, `sizelog`), screenshots. Raw videos: `~/cmux-next-ios-e2e/r13-raw/` on the laptop.

## D4/D5 re-run on 64dbc81595f (terminals know their own Mac)

The same rig (phone simulator plus the hidden `cmux-mobile-e2e-e6d43df7` Mac app on mini-cmux11s, the other agent's parity rig still online on the same account). Graceful quit of the rig Mac app with stream20 running in `e2e-t1`, then a composer Send and direct typing, then a relaunch after more than 1 minute (`live/life13-d45-r2.json`).

| Check | Before (3e6a2b56eff) | 43c6ef89 | 64dbc81595f |
| --- | --- | --- | --- |
| Offline label after the quit | never in 20 min | never in 60 s (the link moved to the other Mac) | **"Mac offline" at the first poll, 0.45 s** after the quit started (app and hostd gone at the same poll); still offline 70 s later |
| Last frame | — | visible | visible and readable, dimmed status rows intact; 0 black frames, 0 flashes over the quit (motion.py, 12 s) |
| Composer Send while down | cleared, ran later | kept, "Not sent: reconnecting…" | kept `echo STALECOMP2` with "Not sent: cmux11's Mac mini is offline. Send again when it's back." |
| Direct typing while down | ran later | dropped with a notice | dropped: "Keys typed while your Mac was unreachable were not sent." |
| After relaunch | ran 15.4 min later | nothing ran | **nothing ran** (neither token on the Mac screen) |
| Relaunch → tab live | 2.3 s | 3.56 s | 3.88 s from the launch call (the call itself 1.36 s) |

D4 (T-LIFE-13) now passes on this rig: offline label ≤ 5 s, reattach after relaunch about 2.5 s after the app is up.
