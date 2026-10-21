# Terminal QA round 9 (termqa implementer, 2026-10-15 02:20 PT onward, stopped for context)

Input: qa-round-8.md (`b64ef74d`). The shared rig (`cmux-mobile-e2e-604fc689` on mini-2, simulator `cmux-mobile-termqa-1`)
belongs to a fresh verifier: not touched (one read-only copy of its Mac app bundle was taken, see Rig).
Laptop load 14-102 during the round: no timing claims.

## Status

| Item | Status | Evidence |
| --- | --- | --- |
| CmuxTabsKit re-sync to `016f87d3` (coordinator add-on) | **done** (`231c3461`); `check-tabskit-sync.sh` ok; CmuxTabsKit `swift test` 53 of 53 on mini-cmux11s; Demo build green | below |
| V5-6 active card after the sync | **green on my rig**: the grid card of a working agent shows its prompt (`reg-1350-new-*-grid.jpg`, `prompt_in_card: true`, twice) | G-17 1350-a |
| **G-17** old-SHA regression runner | **built** (`a8c94706`, `8625cbbc`): `verify/termqa/reg.py`; old SHAs built; first red/green: **T-REG-1350-a red on 2e1369f0 (2 of 2), green on new (2 of 2)** | below |
| T-REG-1337 (near-bottom oscillation) | **not reproduced** with the codexlike fixture on 2e1369f0 (0 spontaneous moves, 2 runs); needs real Codex | below |
| T-REG-1259 | scenario written, **not run** | Next |
| T-REG-1350-b (phantom card) | scenario written; the runner did not open the `New` pop-up's Claude item (menu not found): **not decided** | Next |
| **G-14** autoscroll + full-scrollback copy | **implemented** (red `69de411c`, green `afc76465`); unit 15 of 15; **not run on the simulator** | below |
| G-14 TUI selection (vim, htop) | **not implemented**; design below | Next |
| D6 onboarding Continue | 1 probe on a fresh install: advanced on the first tap (0.75 s) after the page had sat ~60 s; the immediate-tap case was **not** probed | Next |
| V6-5, D10, V2-6, 60-min sessions, D7 | **not run** (no Codex login on mini-cmux10s; laptop rig not built) | Next |

## Rig instance (mine; reusable)

- Mac: `mini-cmux10s-mac-mini`, `~/cmux-next-ios-e2e/termqa-impl9` (rmac.py, killtest.py, `repo/` with the verify
  tooling and the auth source file, `proj/`, `rig/mac/cmux DEV cmux-mobile-e2e-604fc689.app`). The app is a copy of
  mini-2's rig app (daemon `e1edf234`), prepared for this folder. It was **quit** at the end of the round
  (it signs in to the shared dev account, so a running copy is listed on the verifier's phone). Relaunch:
  `ssh mini-cmux10s-mac-mini 'cd cmux-next-ios-e2e/termqa-impl9 && python3 rmac.py launch'`. Mac name
  "cmux10's Mac mini", device id `d113c3b7-94ca-4fa1-8c36-28e7cd1930ee`. Fixtures are staged at `~/tqf`.
- Phone: simulator `cmux-mobile-termqa-impl` (C9E42CC5…), headless; shut down at the end. State:
  `~/cmux-next-ios-e2e/termqa-impl9-state.json` (seed workspace `e2e-022838`, tabs `e2e-t1`/`e2e-t2`).
- Select it with `TQ_STATE=~/cmux-next-ios-e2e/termqa-impl9-state.json TQ_HOST=mini-cmux10s-mac-mini
  TQ_RBASE=cmux-next-ios-e2e/termqa-impl9 TQ_RAW=~/cmux-next-ios-e2e/termqa-raw/tv9` (tq.py now reads these; the
  defaults are the shared rig, so existing scripts are unchanged). `rmac.py` now uses its own folder as
  its base. `rigsetup.py` sets up a new instance: fresh install, real onboarding, link, seed workspace.
- mini-cmux10s has no Codex login and no Claude Code. mini-cmux11s runs another agent's rig (parity,
  `cmux-mobile-e2e-dc79f937`), so `refuse_other_rigs` would refuse a second one there.
- Transport on this instance: WebRTC direct (the phone's default; not switched this round).

## G-17: reg.py

```
python3 reg.py builds
python3 reg.py run SCENARIO BUILD [--agent codexlike|codex]
python3 reg.py both SCENARIO OLD_BUILD [NEW_BUILD=new]
```

- Builds: `scripts/demo-build.sh --ref <sha> --tag r<sha8> --skip-device --skip-mac` (cached CmuxMobileLinkFFI keys
  existed for both): `~/cmux-mobile-builds/20261015-224d15e90f-r224d15e9`, `…-2e1369f054-r2e1369f0`. Each is
  a Demo build with its own bundle id (`dev.cmux.mobile.r224d15e9`, `dev.cmux.mobile.r2e1369f0`), so they sit
  beside the new build (`dev.cmux.mobile`) and each keeps its sign-in; `install` signs in and onboards a
  build on its first run. The red SHA of each video is still to be pinned from the phone's build
  number (§13); both candidates are built.
- Each scenario types its commands on the phone, logs every touch (M-TOUCH), records the simulator,
  runs `motion.py` at 60 fps with the touch log, and writes one verdict per T-REG row to
  `design/terminal/reg/<scenario>/<build>-<time>.json`. `both` writes `compare-*.json`: a row passes
  only when it is red on the old build and green on the new one.
- `--agent codexlike` runs `fixtures/codexlike.py`: an inline TUI that streams `#%07d` diff rows above a
  live area it erases and redraws in place, then idles with its cursor in the prompt box while footer
  rows below the cursor come and go (D2's mechanism). It is a fixture, not real Codex; §13 requires real
  Codex for the row's pass. `--agent codex` starts `codex --yolo` on the phone and prompts it.

| Run | Build | Result |
| --- | --- | --- |
| 1350 | 2e1369f0 | **1350-a red**: the card shows history rows `#0000161…`, no prompt (`reg/1350/2e1369f0-1015-024545.json`, `-024939.json`); 1350-b not decided |
| 1350 | new (`afc76465` + runner) | **1350-a green**: the card shows the prompt (`new-1015-024712.json`, `-025150.json`) |
| 1337 | 2e1369f0 | green: 0 spontaneous moves, 0 flashes, 0 Jump-to-bottom toggles (`2e1369f0-1015-024026.json`, `-024324.json`): **not a reproduction** |

The 1337 fixture result means the 13:37 oscillation needs something codexlike does not do (real Codex's
redraw timing, synchronized output, or its resize handling). Next: the same scenario with
`--agent codex` on a rig with a Codex login.

## G-14

- **Autoscroll.** `TerminalSelectionAutoscroll` (portable): a 48 pt zone at the top and bottom of the
  visible rows (split in half when the band is short, keyboard up); speed 90-2400 pt/s, quadratic in the
  depth, maximum past the edge. `TerminalSelectionController` runs a display link while a handle or the
  long press's drag sits in a zone, moves the content offset (the view controller's `scroll.began()` /
  `settleScroll()` around it, so the page reads, like a finger drag), and keeps the moving end on the
  cell under the still finger. The surface's viewport follows the scroll, so `cellAt` (rendered rows
  only) reaches every row of the scrollback.
- **Copy anywhere in the scrollback, no ghostty-next change.** Round 8's limit is the exact-point clamp
  (`Point.pin`, `clamped_y = @min(self.y, screen.pages.rows -| 1)`). Whole-screen reads
  (`COORD_TOP_LEFT`/`COORD_BOTTOM_RIGHT`) are not clamped. `rowprobe` on the simulator: the rectangle
  read and the plain read both give 409 lines for 456 rows (the active area's trailing blank rows are
  trimmed), with line i = absolute row i. `TerminalScreenRows` aligns the rectangle read (one line per
  row) with the plain read (soft wraps joined) in linear time (1 MiB line: 80 ms), keeps a wrapped row's
  trailing blanks, and copies joined only at soft wraps. A selection outside the surface's rows copies
  through it (`TerminalSurfaceView.screenRows()`); inside, through `viewportText` as before.
  Tests: `TerminalSelectionAutoscrollTests` 5, `TerminalScreenRowsTests` 5 (red at `69de411c`: 14
  issues; green at `afc76465`), `TerminalTextSelectionTests` 5, on mini-cmux11s.
- The same read can lift round 8's `TerminalReadingMark` limit (rows past the first `grid.rows` fall back
  to the same distance from the end): not done.
- **Full-screen apps.** Ghostty (and so the cmux-next Mac, which embeds it): selection works on the
  alternate screen; when the app captures the mouse (htop, vim with `mouse=a`), a plain drag goes to the
  app and Shift-drag selects. The phone never forwards touches as mouse events, so the match is "a long
  press always selects, like Shift-drag". Today `isEnabled` is false in a TUI and the TUI surface lives in
  `tuiHost`, not the scroll view. Design: install the long press on `tuiClip` too; in TUI mode `cellAt`
  maps a point in `tuiHost` to an active row (`TerminalActiveRow`, no document), `rectFor` the reverse,
  `text` reads `activeAreaText` rows; no autoscroll (no scrollback on the alternate screen); clear the
  selection when the TUI leaves. Not implemented.

## Next (in order)

1. A rig with a Codex login: either log in Codex on mini-cmux10s (needs the user), or the laptop hidden
   rig (copy `termqa-impl9/rig/mac/*.app` back, `rmac.py` in a laptop folder, `open -g -j`, headless
   simulator, the laptop's `~/.codex` as is). Then `reg.py both 1337 2e1369f0 --agent codex`, `1259`,
   and the same on `224d15e9`.
2. 1350-b: tap the `New` pop-up (PopUpButton "New"); find whether the old build lists "New Claude Chat"
   and whether this Mac refuses it (the video's refusal came from the Mac's cwd policy).
3. G-14 on the simulator: long press, drag the end handle to the composer's edge and hold 3 s, Copy,
   compare with the Mac's rows; then the TUI design above.
4. D6 immediate-tap probe (tap Continue the moment the page appears, fresh install: `rigsetup.py --rec`
   with `continue_probe` started before the status shows); V6-5, D10, V2-6, the 60-minute sessions and D7
   on the Codex rig.
