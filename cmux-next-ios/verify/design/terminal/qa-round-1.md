# Terminal QA round 1 (termqa, 2026-10-14)

Branch `feat-cnx-ios-termqa`, base `origin/feat-cnx-ios-design-terminal` 867ea2ab
+ `origin/feat-cnx-ios-newtab`. Build under test: Demo config of `5e03ef59`/`83afadfa`
(round 1), then `d3142620` (fix check).

## Setup: cross-machine, real link only

- **Phone:** iOS 26.5 iPhone 17 Pro simulator `cmux-mobile-termqa-1`, headless, on the laptop.
- **Mac:** the real tagged cmux-next app `cmux-mobile-e2e-604fc689` (fleet build of
  `origin/feat-cnx-ios-machost` 604fc689, bundled cmux-mobile-host + cmux-tui daemon + acpmux)
  running on **`mini-cmuxs-mac-mini-2`** ("cmux's Mac mini (2)", the designated
  remote-Mac verification host), launched hidden in its GUI session with an isolated
  config (`cmux-next-ios/verify/termqa/rmac.py`).
- **Path:** phone app → real link (WebRTC direct, 7 ms, over the LAN) → cmux-mobile-host →
  daemon. No socket, loopback, mock session or debug path. The Mac CLI on the mini is
  used only to read the Mac's screen for comparison and to kill cmux-mobile-host (link drop).
- **Agent:** real Codex CLI (`gpt-6-astra max`, YOLO mode) on the mini, in
  `~/cmux-next-ios-e2e/termqa/proj` (a small Python project), driven only through the
  phone (composer paste + Send, soft keyboard, key bar).
- **Driver:** `cmux-next-ios/verify/termqa/tq.py` (simctl recordVideo, axe, OCR);
  `motion.py` measures per-frame vertical shift, direction reversals and flashes.
- **Load:** the laptop's 1-minute load was 24-90 (other agents) during this round,
  so latency numbers are not used as pass/fail; state, order and motion are.

## Defects

| ID | Severity | Area | Summary | Status |
| --- | --- | --- | --- | --- |
| D1 | noticeable | keyboard | Keyboard hide with Codex's short document: content moves down 276 px, then snaps back up 31 px (2 rows) at the end of the animation. 1 of 4 hides (the 3 others in `r1-s3` clean). | open, re-check |
| D2 | disruptive | follow / Codex | Following the bottom while Codex works, the page jumped **down 112 px (7 rows) and back up 80 px 1.5 s later** (`r1-s3` 26.40 s / 27.97 s). Codex erases and redraws its live area below the cursor; the document end was "the last row with text", so it moved up and back. This is the user's near-bottom flashing (13:37 video shape). | **fixed** `d3142620` (TerminalEndHold) |
| D3 | disruptive | reconnect | Link drop (cmux-mobile-host killed on the Mac, the supervisor restarts it in ~2.5 s): the phone showed a **blank screen with `[unknown surface 10]`** for 1.5-1.75 s. The mirror was reset before the attach; the first reattach after a host restart is refused for a moment. | **fixed** `d3142620` (reset only after a confirmed attach; bounded retry behind the held frame) |
| D4 | noticeable | reconnect | Every reattach replays twice: `mirror reset for a resized event (rows 39, last size asked 53x42)`. The Mac answers the attach with 39 rows although the attach carried 53x42 (attach-initial-size), then a `resized` event resets the mirror and replays again. Mac-side sizing (handed over item 6). | open (Mac side) |
| D5 | polish | tab grid | A tab never opened on the phone shows a "Connecting to cmux's Mac mini (2)…" skeleton in the grid indefinitely (`r1-s4-grid-0`). | open |
| D6 | noticeable | onboarding | "Connect your Mac": three Continue taps 1.5 s apart (button frame stable, Mac online) did not advance; a fourth tap ~20 s later did. (Handed-over item 9; reproduced on a fresh simulator.) | open |
| U1 | needs check | user video 13:37 | 2 frames (200 ms) of another region (a diff block) while scrolling near the bottom. Matches the "frame of another region" fixed in 867ea2ab (cursor viewport probe). Not reproduced in round 1 scroll runs (`r1-s1s2` 170-235 s, no flashes found). | likely fixed upstream; keep checking |
| U2 | needs check | user video 13:50 | Tab grid: the card shows an old scrolled region (a diff) instead of the live bottom, and for ~3 frames a phantom larger card with a "Chat" label is drawn behind it. | open, to reproduce |

## Scenarios run (round 1)

| Scenario | Video (`~/cmux-next-ios-e2e/termqa-raw/`) | Result |
| --- | --- | --- |
| Codex start via composer paste + Send, trust prompt via Return | `r1-s1s2-codex-start-and-scroll.mp4` 0-60 s | pass: paste + Send submits (F1 fixed); trust menu, banner, status row clean |
| Scroll while Codex streams: drags up, fling to top, Jump to bottom, fling to bottom | same, 170-235 s | pass: no flash, reader held, jump returns; reached the session's first row |
| Keyboard hide/show ×3 while streaming | `r1-s3-keyboard-during-stream.mp4` | pass ×3 (monotonic); D1 seen once earlier; D2 found here |
| Tab grid shrink/zoom ×4 while streaming, t1↔t2 | `r1-s4-tabgrid-during-stream.mp4`, `r1-s4b-grid-latency.mp4` | cards correct and current; D5; open latency not measurable at load 89 |
| Link drop mid-stream (kill -9 cmux-mobile-host) | `r1-s5-link-drop-mid-stream.mp4` | D3; screen correct after reattach |
| Link drop idle | `r1-s5b-link-drop-idle.mp4` | D3 |
| Phone vs Mac lag during a 600-line Codex stream | `lag_probe` | pass: phone within 0-4 items of the Mac every sample (steady state) |
| Shell floods: `yes \| head -200000`, `seq 1 60000`, 40 colour/CJK/emoji/fullwidth/long-wrap lines | `r1-s6-shell-floods.mp4` | pass: correct end rows, colours, wide chars and wraps |

## Fix check on `d3142620` (same rig)

- D3: link drop idle (`r2-s5b-link-drop-idle.mp4`) and mid-stream (`r2-s5-link-drop-stream.mp4`):
  no blank frame, no error line; the held frame stays until the replay. Phone vs Mac
  after reconnect: within 0-2 items for 10 samples.
- D2: 75 s of following Codex (`r2-s1-follow-codex.mp4`): 467 moves, the only
  downward move is one row (Codex's own live area shrinking a row; the held blank
  row is what the Mac shows). No 7-row jump.
