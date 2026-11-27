# Terminal QA round 10 (termqa implementer, 2026-10-15 09:50 PT onward)

Input: qa-round-9.md (`91accfc8`). The shared rig (`cmux-mobile-e2e-604fc689` on mini-2, simulator `cmux-mobile-termqa-1`)
belongs to a fresh verifier: not touched. Laptop load 20-30 at the start: no timing claims.

## Status

| Item | Status | Evidence |
| --- | --- | --- |
| G-14 TUI selection (vim, htop): a long press always selects | **implemented**: test `29260240` (red: type missing), fix `fd2e3c3a` (green: 15 of 15 with the selection and autoscroll suites, mini-cmux11s); iOS build green (`1769b3bf`, tag tq10). **Not run on the simulator yet** | below |
| Hidden laptop rig (real Codex) | **up**: Mac app hidden (0 on-screen windows, the front app unchanged, no Keychain or other prompt), rig set up with real onboarding, link `Online · Connected · WebRTC direct`; real `codex --yolo` (v0.162.1, the laptop's login) starts from the phone | Rig |
| G-17 T-REG-1337 with real Codex | **not reproducible with real Codex** (one valid run each): 2e1369f0, 224d15e9 and new are all green, 0 spontaneous moves, 0 flashes, 0 black, 0 Jump-to-bottom toggles over ~12 s at the bottom and ~12 s near it, Codex idle ("Worked for 2m 22s" on screen) | G-17 |
| G-17 T-REG-1350-a with real Codex | **red on 2e1369f0** (`reg/1350/2e1369f0-1015-040530.json`: the card shows rows 368-399, no prompt) and **red on 224d15e9** (`224d15e9-1015-041356.json`); **green on new by eye** (`artifacts/shots/reg-1350-new-040656-grid.jpg`: the card shows "Worked for 1m 3s" and Codex's prompt; the runner's OCR lost the "A" under the cursor and wrote red, detector fixed in `ca3a66f7`, **re-run 1350 on new**) | G-17 |
| G-17 T-REG-1350-b | **not decided**: this build's grid (+) "New" starts an agent chat at once and the Mac refused it ("…doesn't allow agent chats in this folder from your iPhone yet."), so the runner found no Claude item; `ca3a66f7` treats the refusal as the trigger and samples the cards after it. Re-run `both 1350 2e1369f0 --agent codex` | |
| G-17 T-REG-1259 with real Codex | **not run** (runner ready: 1500-row answer, `agent_still_streaming_at_end` in 1259-e) | Next |
| **T-LIFE-09/15** (coordinator 1, disruptive) | **fixed in code, not on the rig**: test `86a4d8f8` red (row 900 for 600), fix `60dc5462` green (ReadingMark 11 of 11, ScreenRows 5 of 5, mini-cmux11s). Cause: the anchor's rows and the old end were past the readable rows near the new end, so `locate` fell back to the same distance from the end and the rows that arrived during the drop pushed the reader down by their count. Now: the restore reads every row once (`surface.screenRows()`, unclamped), the search is centred on the reader's own row, and the last fallback is that row; the total-row delta is never applied | Next |
| Selection visibility (coordinator 6) | **changed, not sampled**: highlight and handles use `systemBlue` (`42873ae3`); the app's tint is its label colour, which drew a grey dim and black handles. T-SEL's 10 samples not run | Next |
| Coordinator 2-5, 7, 8 | **not started** | Next |
| CmuxTabsKit re-sync (coordinator) | **done** `87175151`: byte-identical to `506c1239` (includes `b962c111`); `check-tabskit-sync.sh` ok; CmuxTabsKit `swift test` 53 of 53 on mini-cmux11s; feat-cnx-ios `aa685b82` merged (`76c8bace`). Grid card and zoom re-check: after the rebuild | |
| G-14 autoscroll / full-scrollback copy on the simulator | not run yet | |
| D6 onboarding Continue | **not reproduced**: 10 of 10 fresh installs advanced on the first tap made the moment Continue is in the tree (7 at the page's push, 3 at the rig Mac's launch); the Not now→Continue swap could not be produced (the shared dev account always has an online Mac) | D6 |
| V6-5, D10, V2-6, 60-min sessions, D7 | not run yet | |

## Rig (hidden laptop rig, tag tq10)

- Mac: a fleet build of `e1edf234` (the rig app's daemon) with its own tag `tq10-e1edf234`
  (bundle `com.cmuxterm.app.debug.tq10.e1edf234`, own dev-backend stack). Fleet job
  `4faa3b2ec5167d9b355aae07`, in `~/cmux-mobile-builds/20261015-e1edf23408-tq10`. The app is used as built:
  its Info.plist is never edited and it is never re-signed. `TQ_HOST=local` (`tq.LocalMac`) launches it
  with `open -g -j -n --env ...` for every setting (shell integration, bundled CLI, daemon socket, config
  file, credential file, pairing seed). `open --env` overrides LSEnvironment (checked with a test bundle).
- Phone: simulator `cmux-mobile-tq10` (070F8E62…), headless (`simctl boot`; Simulator.app never opened). New build:
  Demo `1769b3bf`, tag tq10, bundle `dev.cmux.mobile.tq10`.
- Select: `TQ_HOST=local TQ_RBASE=~/cmux-next-ios-e2e/tq10 TQ_STATE=~/cmux-next-ios-e2e/tq10-state.json
  TQ_RAW=~/cmux-next-ios-e2e/termqa-raw/tq10 TQ_BUNDLE=dev.cmux.mobile.tq10`.
- Codex: the laptop's existing login, used as is.
- `cmux-next-ios/scripts/demo-build.sh`: the simulator build is now `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`.

## G-14: TUI selection

`TerminalSelectionController` now takes any host view (the scroll view or the TUI host); edge autoscroll
runs only in a scroll view. The view controller keeps a second controller, `tuiSelection`, in `tuiHost`:
`TerminalTUISelectionGeometry` maps a point to a viewport cell (row 0 = the top row, clamped to the grid)
and back; the text comes from `viewportText`; Select All is the whole screen. The shell's selection is
cleared when a TUI starts, the TUI's when it ends; a tap clears either. The phone never forwards touches
as mouse events, so a long press always selects, like Shift-drag on the Mac when the app captures the
mouse (htop, vim `mouse=a`).

## D6

`rigsetup.py --immediate [--d6-only]` taps Continue the moment it is in the AX tree (polled every 50 ms
plus the tree read), mid-push included. Fresh install each time (uninstall, keychain reset, install, dev
sign-in, Personal on the team step). Recordings `termqa-raw/tq10/d6-setup-1.mp4`, `d6-imm-1..6.mp4`.

| Probe | Runs | First tap advanced | Page left after |
| --- | --- | --- | --- |
| Tap at the page's push (Mac online) | 7 | 7 | 0.70-0.86 s (includes the tree poll) |
| Tap as the rig Mac launches (0.22-0.31 s after `open`) | 3 | 3 | 0.92-1.09 s |
| Watch 25 s on the page (2 runs) | | | `Continue` and "…is online" from 0.27-0.53 s, no flip |

Code reading: `PairMacStep` swaps two views (`PrimaryCapsule("Continue")` / `TextCTA("Not now")`) in a
`ZStack` with an opacity transition on `onlineMac != nil`. If the account's online-Mac state flips while
a finger is down, the pressed button is replaced and the tap is lost; the round-1 report (three taps
ignored, a fourth 20 s later works) fits a Mac that was coming online. The rig cannot produce the flip
(another Mac of the shared dev account is always online, so Continue shows before the rig Mac
launches). Not fixed: no reproduction; a candidate fix is one button with a stable identity whose
label and style change.

## G-17 with real Codex

`reg.py --agent codex` now: stops a Codex left in the tab (Control C twice from the key bar, the composer
focused first), types `mkdir -p ~/cmux-next-ios-e2e/tq10/proj && cd … && codex --yolo` and the prompt on the
phone, and reads the Mac's screen only for timing: "streaming" once eight answer rows are on screen while
Codex works, "idle" once it worked and then shows no working indicator on two reads in a row. Codex
v0.162.1, GPT-6-Astra max (the laptop's login and its default model).

- The first real-Codex 1337 run on the new build (`03:18`) is **invalid** and was discarded
  (`termqa-raw/tq10/INVALID-new-1015-031821.json`): the idle check matched the prompt's own "400" before
  Codex began, so the scenario ran while Codex streamed. Fixed in `2027a77a`.
- The next run (`03:26`, 2e1369f0) read **red** (1337-a 14 spontaneous reversals, 1337-c) and is
  **also invalid** (`INVALID-2e1369f0-1015-032610.json`): its contact sheet
  (`artifacts/sheets/reg-1337-2e1369f0-032406-01.jpg`, 11.9-12.8 s) shows Codex still streaming rows
  213-254. This Codex (v0.162.1) prints no "Working"/"esc to interrupt" on screen, so the working check
  never fired. `d3c24e21` reads the state from the answer: streaming = the screen changes with numbered
  rows on it; idle = "Worked for …" or row 400 present and the screen unchanged across two reads 3 s
  apart. Lesson for the verifier: a real-Codex T-REG verdict needs a frame check that Codex was idle.

| Run (real Codex, idle) | Build | Load | At bottom (frames / spont. moves / reversals / flashes / black) | Near bottom | Verdict |
| --- | --- | --- | --- | --- | --- |
| `reg/1337/2e1369f0-1015-034843.json` | 2e1369f0 | 52 | 754 / 0 / 0 / 0 / 0 | 701 / 0 / 0 / 0 / 0 | green |
| `reg/1337/new-1015-035349.json` | new (`d3c24e21`) | 25 | 704 / 0 / 0 / 0 / 0 | 744 / 0 / 0 / 0 / 0 | green |
| `reg/1337/224d15e9-1015-035855.json` | 224d15e9 | 27 | 715 / 0 / 0 / 0 / 0 | 742 / 0 / 0 / 0 / 0 | green |

`compare-2e1369f0-new-*.json`: every 1337 row "not reproduced (green on old)". The 1 fps sheet of the
2e1369f0 run (`artifacts/sheets/reg-1337-2e1369f0-034444-01.jpg`) shows Codex idle at rows 366-400 with
"Worked for 2m 22s", the page at the bottom, then 3 rows up after the drag, still. With codexlike (round
9) and with real Codex (here) the 13:37 oscillation does not reproduce on either old SHA on this rig
(WebRTC direct, simulator). What the video had that this does not: a long session (hundreds of diff
rows), keyboard history, the device. Recorded as not reproducible with real Codex; T-SCROLL-03 and
T-FOLLOW-05 keep covering the behaviour.

## Next (in order; context ran out here)

The coordinator's list (from VERIFY-round8.md on `origin/feat-cnx-ios-termverify8` `e0789e41`) comes first.
The shared rig is free for the implementer now (see the coordinator's state notes: cmux-mobile-termqa-1 runs the
verifier's build with -CmuxMobileFrameLog, app_path points at termverify8, e2e-t2 runs a GEN loop: ^C it,
the simulator may need a shutdown and boot).

1. T-LIFE-09/15 on the rig: drop while output arrives (both transports, 3 runs, plus a single drop with no
   prune); the page must come back on the same rows. The build with `60dc5462` is
   `~/cmux-mobile-builds/<date>-60dc5462df-tq10` (built this round; check its `==> done`).
2. One-frame black (5-22 ms) at the history cap jumps and prunes: keep the last good frame until the new
   one is placed.
3. V5-5 / T-TABS-08: closing a tab on the phone must end the Mac session promptly.
4. T-TABS-01 inactive card: refresh inactive cards from the Mac when the grid opens.
5. The ~15.1 s hitch (150-214 ms, saved-frame render on the main thread): off the main thread or cheap,
   counted in the frame log's work time.
6. T-SEL: 10 samples with the blue selection (`42873ae3`), plus `g14.py scroll` and `g14.py tui` (TUI
   selection `fd2e3c3a`, never run on a simulator).
7. Frame-log `blank` over-reports (752 frames, no black in the video).
8. Polish: the saved relaunch frame hides the letter under the cursor; the status label says "WireGuard
   TURN" while hostd reports direct. Also verify the `clear` cases (zsh `clear` wipes scrollback like the
   Mac; the clear-that-keeps-history fix).
9. G-17: re-run `both 1350 2e1369f0 --agent codex` (fixed detectors) and `both 1259 2e1369f0 --agent
   codex` plus `run 1259 224d15e9 --agent codex`; check each real-Codex verdict's frames for Codex's state.
10. Grid card and zoom transitions after the CmuxTabsKit re-sync: the 1350 grid shot on the merged build
    (`reg-1350-new-040656-grid.jpg`) shows both cards normal; zoom in/out not recorded yet.
11. V6-5 / D10 (`v65.py setup`, `v65.py run 35`), V2-6, the 60-minute sessions per transport, D7.

## Laptop rig: how to bring it back

It was shut down at the end (Mac app quit, simulator deleted). To recreate: `xcrun simctl create cmux-mobile-tq10
com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-26-5`, boot it
headless, write `~/cmux-next-ios-e2e/tq10-state.json` (`udid`, `app_path` of the unzipped tq10 build), then with
the env above: `python3 -c 'import tq; m=tq.LocalMac(); m.prepare(); m.seed_pairing(names=["cmux-mobile-tq10"]);
m.launch()'` and `python3 rigsetup.py`. The Mac app in `~/cmux-next-ios-e2e/tq10/mac` is the fleet build as
built. Check `~/cmux-next-ios-e2e/tq10/bin/onscreen <pid>` reports 0 windows after launch.
