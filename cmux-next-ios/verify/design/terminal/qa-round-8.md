# Terminal QA round 8 (termqa implementer, 2026-10-15 01:45 PT onward, in progress)

Input: qa-round-7.md (`0889e650`). The shared rig (`cmux-mobile-e2e-604fc689` on mini-2, simulator `cmux-mobile-termqa-1`)
belongs to a fresh verifier: not touched. Simulator work is on `cmux-mobile-termqa-impl` (the only simulator this
implementer boots), Demo build in `build/impl-dd`. Laptop load 90-146: no timing claims.

## Status

| Item | Status | Evidence |
| --- | --- | --- |
| **V6-2** following at the cap goes black after a prune | **fixed, rig** (red `9ebdef70`, green `40eeec9b`, watch `6531d477`) | below |
| **V6-3** Jump to bottom black for seconds | **fixed, rig** (same changes): 12 jumps, 0 multi-frame black; 1 one-frame black mid-fling | below |
| **V6-4** black page after two quick drops (W-T) | **watch in place, not re-run** (needs the WebRTC transport) | Next |
| **V5-2** a fling snaps to the bottom at a prune | **fixed, rig 0 of ~48 flings** (in `53761b01`: a prune's clamp never counts as a fling reaching the bottom) | below |
| **V2-3 residual** restore 116 rows off | **fixed, unit** (red `8d77ea70`, green `53761b01`); rig read-drop not re-run | below |
| **V6-1** bottom-pin gap after the draft shrinks | **changed, not verified** (`afb501b4`) | below |
| **V6-5** t1 diverged from the Mac | **not found** (read the output pump; no stuck path seen) | Next |
| **New: 370 ms hitch every 3 s while following** (round 7's D11 save) | **fixed, rig** (`d6af91c5`): max frame 184 ms, no periodic hitch | below |
| Two row numberings (scroll bug) | **confirmed and fixed, simulator** (red `5725bd38`, green `1be137a9`; hold red `e2cdc690`, green `71de2f83`) | below |
| V5-4 new tab replays the open tab | **fixed on the phone** (red `7f48afdb`, green `f84de2c0`); rig not re-run | below |
| G-17 old-SHA regression runner | not started | Next |
| G-14 selection limits | not started | Next |
| D6 onboarding Continue | not started | Next |
| Rig checks (V5-6, D11, V5-5, D1, selection, link reader, D10, V2-6, 60-min sessions, D7) | not run | Next |

## Rig (02:10-02:25 PT, exclusive after the round-6 verifier)

The rig simulator `cmux-mobile-termqa-1` runs `d6af91c5` from `~/cmux-next-ios-e2e/impl8/CmuxMobileApp.app` (Demo,
`-CmuxMobileFrameLog`); `termqa-state.json` `app_path` points there. Transport: WireGuard (G-D), as the verifier
left it. `cmux-mobile-termqa-impl` is shut down (one simulator booted by this implementer). Tools:
`verify/termqa/v8.py` and `v8_drops.py` (the round-6 verifier's helpers, writing to `verify8/`),
`v8_hold.py` (hands-off following during a GEN loop typed on the phone), `v8_jump.py` (Jump to bottom
from deep history and mid-fling). Laptop 1-min load 15-25: timing rows still invalid; correctness only.

| Run | Build | Prunes while following | Black runs (motion.py) | `blank page` recoveries | Frames > 100 ms |
| --- | --- | --- | --- | --- | --- |
| `r8-hold-gd` 90 s | `afb501b4` | 7 (17739 -> 16854) | 1 single frame at 14.77 s | 0 | a 370 ms frame every 3.1 s (the frame save) |
| `r8-hold-gd2` 90 s | `d6af91c5` | 6 | **0** | 0 | 11, max 184 ms; frame log `blank` 0 of 8270 frames |
| `r8-jump-gd` 12 jumps (6 from deep history, 6 mid-fling) | `d6af91c5` | streaming at the cap | 1 single frame at 15.07 s (mid-fling, before the tap; `verify8/r8-jump-gd-15.07s-oneframe.jpg`) | 0 | `a fling reached the bottom`: 0 |

Round 6 had 5 of 5 prunes black for 1-11.5 s and 3 of 20 jumps black for 3-5.6 s on the same rig.

### V6-2 / V6-3 cause and fix

After a prune while following, Ghostty's viewport follows the output, so no prune is detected
(`TerminalHistoryPrune` needs a pinned viewport) and `presentedTop` stays in the old numbering (17589).
The next frame (one new row) matched candidate shift +1 and was placed at 17590, past the document's
end (16854): a black page, and every later frame matched +1 from there, until a touch. Fix:
`TerminalPresentMatch.match` never returns a top outside `0...activeTop`; the fallback is the report.

**Blank-page watch** (`TerminalBlankWatch`, every display frame through `FrameClock`): if the frame on
screen does not cover the visible document rows for 250 ms, the page is placed by Ghostty's report (when
it covers them) or a viewport request is forced, the match history is dropped, a frame is requested,
and `blank page: …` is logged; again every 250 ms until covered. The G-04 frame log has a `blank` field
per frame (uncovered rows). With the match fix the watch did not have to act in these runs.

Residual: one-frame black during a fast mid-fling scroll at the cap (1 frame in ~120 s of flinging).

### V5-2

`setContentHeight` marks a shrinking content size, and the "a fling reached the bottom" rule now needs
the offset to be moving down and the content not shrinking (a prune's clamp moved the offset to the
bottom in the same millisecond). No unit test (UIKit path); rig: 0 in `r8-jump-gd`.

### V2-3 residual

The restore's content search could not read the replay's rows near the anchor (Ghostty addresses only
the viewport, the active area and the first `grid.rows` rows; see the row numberings section), so it fell
back to the same distance from the end, and the 116 rows that arrived during the drop moved it.
`TerminalReadingMark` now keeps the document's last 40 rows; after the replay they are found near the new
end (readable) and vote for the shift, applied to the anchor (step 3, before the distance fallback).
`TerminalReadingMarkTests.theOldEndRowsGiveTheShiftWhenTheAnchorCannotBeRead`: red 14382, green 14266.
Limit: more than about 110 rows during the drop pushes the old end out of the active area.

### V6-1

The composer card reports its SwiftUI height (`onGeometryChange`); the screen invalidates the hosting
view's intrinsic size and lays out again, so the bottom inset follows a shrinking draft. Not measured
(`v6pin.py` on the termverify6 branch is the measure).

### Frame save hitch (new, from round 7's D11)

`TerminalModel.saveFrameSoon` rendered the whole 151-row IOSurface through Core Image on the main thread
every 3 s while output streamed (370 ms frames). The save now waits for 0.5 s without drawn output (at most
15 s), and `presentedImage(clip:)` renders only the part on the page.
`TerminalFrameSaveScheduleTests.noSaveWhileOutputStreamsUntilTheMaxWait`.

### V5-4

The daemon sends `resized` with a replay to byte mirrors for a cell-pixel-only change
(`cmux-tui-core` `pty_surface.rs` `commit_geometry_for_runtime` -> `broadcast_attach_frame_to_replay_taps`;
also a Kitty-limits resync, `resynchronize_attach_taps_locked`). The phone's ordered stream already holds
that state, so `DaemonTerminalEventParser` now drops a `resized` at the grid it mirrors and logs
`resized event at the mirrored grid …: kept, no reset`. A different grid still resets. No daemon change
(the Mac's other byte mirrors may rely on the frame). Rig check: + -> New Terminal, the log line appears and
no `mirror reset cause=resized-event`.

### Two row numberings

**Confirmed, and the cause is not an offset.** Demo phase `rowprobe` (`c158eea4`, DEBUG) reads rows by
each Ghostty point tag. Ghostty's C API clamps every exact point's y to the grid's last row, whatever the
tag (`ghostty-next` `src/apprt/embedded.zig`, `Point.pin`: `clamped_y = @min(self.y, screen.pages.rows -| 1)`).
On the simulator (grid 151 rows: 39 visible plus margins, scrollbar `456/305/151`):

| Read | Text |
| --- | --- |
| screen y 0 | `Last login: Mon Oct 12 0…` (row 0, correct) |
| screen y 150, 151, 152, 305, 455 | all `    Checking rand_core v…` (row 150, clamped) |
| viewport y 0, active y 0 | `cmux-next-ios/rust/cmux-mobile-host)` (row 305, correct) |

So screen y equals the scrollbar's absolute row only for the first `grid.rows` rows; every larger row
reads row `grid.rows - 1`. Round 7's "screen y 109 = row 305" was a misread of this clamp. Effects of
round 7's helpers (absolute rows passed as screen y):

- `lastNonBlankRow(from: cursor + 1, through: total - 1)` (an inline TUI's rows below the cursor) always
  read the clamped row, found text, and ended the document at the scrollback's end. After `clear` the
  document kept the active area's blank rows below the prompt: `rowprobe` before the fix logged
  `doc=0+1060` with the cursor at screen row 2 (148 blank rows below the prompt; the page showed blank
  rows with the prompt off screen).
- `TerminalReadingMark` (link-drop restore) read clamped rows for any row past the first 151, so its
  search compared against one repeated row.
- `leadingBlankRows` read at most the first 151 rows (harmless while the blank origin is above row 151).

**Fix:** `TerminalRowSpace.swift`. `TerminalAbsoluteRow` (the scrollbar's numbering) and the three
Ghostty numberings `TerminalViewportRow`, `TerminalActiveRow`, `TerminalScreenRow` are separate types;
the Ghostty ones are made only by `TerminalRowSpace` (total, grid rows, viewport top), which returns nil
for a row Ghostty cannot address (never another row). `TerminalSurfaceView` reads rows only through
`TerminalRowTextSource` (one method per type); the old Int-taking `rowText`, `lastNonBlankRow`,
`leadingBlankRows` and `screenRowsText` are gone. `TerminalRowReader` resolves an absolute row to the
active area, else the viewport, else the screen's first rows. The document end and origin scans, the
reading mark and selection read through it; the replay content check reads the active area.

A second cause of the same symptom: `TerminalEndHold` (D2) released its held end only when the cursor
was on the screen's first row. A prompt with a blank line above it (the mock shell, zsh with starship)
lands on row 2, so the end stayed at the screen's bottom. It now also releases when the cursor jumps up
by more than half the screen without the total shrinking (an inline TUI's cursor moves a few rows).

Tests: `TerminalRowSpaceTests` (6, a model of Ghostty's clamping addressing: scrollback, `clear`
without ESC[3J, ESC[3J, the mirror's blank top rows, history pruning): red 3 of 6 fail at `5725bd38`
(`clearLeavesNoContentBelowThePrompt`: end 751 instead of 603), green at `1be137a9`.
`TerminalEndHoldTests.aClearedScreenWithATwoLinePromptLetsTheEndMoveUp`: red at `e2cdc690` (end 1060
instead of 912), green at `71de2f83`. `CmuxMobileTerminalTests` 158 of 158 on mini-cmux11s.

Simulator after the fix: `rowprobe` logs `doc=0+912` after `clear` (cursor at 911), and the page shows
the remaining rows with the prompt just above the composer (`artifacts/shots/r8-clear-after-fix.jpg`).

Limit: an absolute row outside the active area, the viewport and the first `grid.rows` rows cannot be
read through the C API, so the reading mark's search beyond them falls back to the same distance from
the end (`TerminalReadingMark` step 3). Reading arbitrary rows needs a ghostty-next change (no clamp
for screen and history points); not made this round.

## Next (in order)

1. Rig, now (exclusive until handed off): V6-4 two quick drops on **WebRTC** (Settings transport switch,
   `v8_drops.py TAG twoquick`); V2-3 read-drops at the cap (`v8_drops.py`); V6-1 with `v6pin.py`
   (termverify6 branch); V5-4 at + -> New Terminal; V6-5 (t1, the overruled tab, following real Codex
   next to the Mac's screen).
2. The rig checks from round 7 (V5-6, D11, V5-5, D1 with real Codex, selection, link reader with a
   transport switch), D10, V2-6, the 60-minute Codex and Claude Code sessions per transport, D7.
3. G-17 runner, G-14 limits (autoscroll, full scrollback, TUI), D6.
4. The one-frame black mid-fling at the cap (`r8-jump-gd` 15.07 s).
