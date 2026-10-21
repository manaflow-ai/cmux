# Terminal and tabs: round 1 designer review

Fresh designer, 2026-10-14, against [SPEC.md](SPEC.md). Build under review:
`origin/feat-cnx-ios` at `9cb1b242` (terminal round 1: `7d5f5b03`, `9b1bc2d9`,
`1d3adaf3`, `f63de184`, `80ec6400`, rig `c68399df`, `d9c71385`). The
designer writes no app code. Every item below was re-checked with this
review's own captures; the implementer's notes were not taken as evidence.

**Verdict: NOT signed off.** One blocker (relaunch restore never connects),
two majors (text legible around the bottom toolbar; TUI not resized for the
keyboard) and five polish items. Most of round 1 is good work: B1, B2's
pinned keys, M1, M2, M4, M5, M6, M7, P1, P2 counts, P8, P9, P11 pass.

## How this was captured

- **Live.** E2E rig from a review worktree (`verify/e2e/e2e.py --no-build
  --mac-app "cmux DEV cmux-mobile-e2e-604fc689.app" --sim-name cmux-mobile-term-review
  --keep --latency none --steps fresh_install,…,files_links,background`),
  Demo config, iOS 26.5, iPhone 17 Pro (402 × 874 pt), real hidden cmux-next
  DEBUG Mac build `cmux-mobile-e2e-604fc689`. Rig run `055005-ios26`: 12 pass, 2 fail
  (`round1-review/rig-055005-*`). A first attempt at 1-minute load 64 failed
  at `mac_discovered` and was discarded. Then manual checks on the same
  session with `axe` (taps, slow drags; text only through the soft keyboard,
  never HID key events).
- **Mock.** Debug build (`-derivedDataPath /tmp/cmux-mobile-term-review-dd`) on the
  same simulator, launched with `-cmuxMobile.dev.mockData YES` ("mock (layout only)").
- Load: recordings `v1` to `v3` were made at 1-minute load 10.4 to 12.8.
- Measurements are in pt (1206 px screenshots ÷ 3), read from pixels or from
  `axe describe-ui` frames. Screenshots in `round1-review/` are downscaled.
- Never paired with the user's Mac; no phone. The simulator was deleted and
  the rig Mac app quit at the end.

## Results

| Item | Result | Evidence | Measurement |
| --- | --- | --- | --- |
| B1 top-anchored, no blank rows | **PASS** | `06`, `08`, rig `term_scrollback` | Row 0 glyph top at 66.7-70 pt (inset 62). After `clear` (and after ctrl+L) the prompt is on row 0; a 300 pt pull-down does not move content. A 3-line session sits at the top (`08` left). |
| B1 row 0 legible at rest | **FAIL (polish, R1-5)** | `07` | Row 0 is drawn at 53 % brightness at rest (icon RGB sum 227 vs 432 on row 2): the top fade covers row 0 when nothing is scrolled. |
| B2 pinned esc / ctrl / ^C | **PASS** | `04`, AX | esc 13-57, ctrl 63-116, ^C 122-162, all 34 pt tall visual, always accessible. Rig still fails `term_keys` (see R1-6). |
| B2 scroller gap, snap, fades | **PASS with defects (R1-3, R1-4)** | `01`, `02`, `03` | Gap ^C → scroller 6 pt (162 → 168). Scroller 168-301 = **133 pt** (spec ≈ 186 pt; 2.5 keys visible). After a swipe it snaps to whole keys (`03`: ← at the leading edge, ^D fully drawn). At rest: a hard seam inside `tab` at x ≈ 180 pt (`01`), and `↑` cut at the trailing edge, 23 of 40 pt shown (`02`). |
| M1 ctrl modifier | **PASS** | `04` | Tap ctrl → accent fill, white label, AX value "armed". Typing `l` cleared the screen (0x0C), composer kept "clear", ctrl went back to rest. Double-tap lock (0.4 s window) could not be driven with `axe` (two taps are > 0.4 s apart); unit-tested only. |
| M2 composer traits | **PASS** | `05` | No QuickType bar (key bar sits directly on the keyboard), no AutoFill callout after a second tap, no autocapitalization ("clear"). |
| M3 last row above composer | **PASS** | `09` middle/right, `12` | Prompt row ends ≈ 8 pt above the composer card at rest and with the keyboard up. |
| M3 text under chrome | **FAIL (major, R1-2)** | `10`, `10b` | Scrolled up at rest, rows 262-268 are fully legible **between and below the toolbar pills** (y 772-874 pt) and at the composer's leading corner (x 0-8 pt). Under the composer card itself text is hidden (85 % backing works). |
| M3 top edge | PASS | `09` right | Rows under the status bar fade; a half row is clipped at 62 pt but dimmed. |
| M4 one key bar rule | **PASS (soft keyboard); hardware keyboard not verified live** | `09`, `21` | Hidden at rest, shown with focus, live and mock alike; mock composer now has `+`. Hardware keyboard path is unit-tested (`KeyBarVisibility`); not driven, because one HID event flips the simulator into hardware-keyboard mode. |
| M5 side padding | **PASS** | `08`, `06` | First glyph column at x 6.0 pt; long `ls` line ends at ≈ 394 pt. |
| M6 drag-dismiss pinning | **PASS** | `v1`, `11`, `12` | Drag from y 300 to 840 with the keyboard up while following: rows 280-300 and the prompt do not move while the finger is above the keyboard; the prompt rides the composer down; ends on the composer, no jump button. A reader already scrolled up scrolls normally (checked once, not kept). |
| M6 TUI single resize | **FAIL (major, R1-1)** | `13` | `top` with the keyboard up: the alt screen keeps its keyboard-down rows and is shifted up, so its header (Processes, Load Avg, CPU, PID header) is off screen and the first visible row is cut under the status bar. The PTY is never resized for the keyboard (`TerminalViewController` sizes `tuiRows` from the keyboard-down composer top only). Spec: one resize after the keyboard settles. |
| M7 refused preview | **PASS** | `15`, rig `files_links` pass | No Preview/Source toggle; More has only Copy Path; headline "Can't open this file", name on its own line with middle truncation; title "cmux-mobile-e2e-…sample.md". Accessibility id `artifacts.preview.refused`. |
| M8 hidden controls | **FAIL (deferred upstream, U3)** | `ax-terminal-page-mock.txt` | Still present live and mock: `Close e2e-t1` (372, 0, 30 × 30), `Page Menu` (90, 792), `Reload` (268, 792) inside the title pill. Filed as U3 in [UPSTREAM-REQUESTS.md](UPSTREAM-REQUESTS.md); not fixed. |
| P1 page menu | **PASS** | `14` | Files and Links, Paste, Clear, Scroll to Bottom (disabled at bottom) \| Copy Directory \| Close Tab. |
| P2 Files and Links chips | **PASS with defect (R1-7)** | `16` | Counts shown ("All 3", "Files 2", "Code 2", "Links 1"), none clipped, `.isSelected` in code. Chip top 490 pt vs Done button bottom 469 (≈ 21 pt; spec 8 pt), chip leading 23 pt (spec 16). Sheet title says "Files and links", the menu "Files and Links". |
| P4 image at large detent | Not re-checked | | No image in the rig workspace. Code adds `SheetDetentExpander`. |
| P5 Reattaching after 400 ms | **PASS (no false indicator); slow path not observed** | `v3`, `18` | Return after 40 s in the background: last frame shown at once, no mid-screen caption, title subtitle stays "~" throughout 7 s. A > 400 ms reattach was not produced; unit-tested (`ReattachDebounceTests`). |
| P8 joystick | **PASS** | `01`, `03` | Four chevrons in the ring, 14 pt dot. Haptic per step not observable in the simulator. |
| P9 Camera | **PASS with note** | `17` | Paste \| Files, Photos, Camera ("No camera on this device", disabled). Order is Files → Camera top to bottom, nearest the `+` is Camera; acceptable. Paste is shown with text on the pasteboard (spec: only for an image or file). |
| P10 relaunch restore | **FAIL (blocker, R1-0)** | `19`, `19b`, `20` | Relaunch returns to workspace `e2e-055031`, tab `e2e-t1` (good), but the page shows skeleton rows and "Connecting to Aziz's MacBook Pro…" for **60 s and more**, reproduced twice. Back shows the Mac "Online"; reopening the same workspace connects at once (`20` right). No last frame is shown (spec: last frame warm until reattached). |
| P11 accent send | **PASS** | `04` | ↑ with accent fill when there is text; ↩ quiet when empty. |
| Fling smoothness | **PASS** | `v2`, `v2-fling-frame-times.txt` | 3 flings: median frame interval 13.3-16.7 ms during motion; one 48 ms gap early in fling 1; the 82 ms gap is in the deceleration tail (frame-to-frame content change < 0.001). 60 Hz recorder cap. |
| Rig `term_keys` | **FAIL (rig)** | `rig-10-term_keys.jpg` | "key bar has no 'Left Arrow'". By hand one swipe in the 133 pt scroller lands on `← → ^D` (`03`), so the key is reachable; the rig's paging overshoots (one swipe moves 4 keys) and then leaves a half-typed `echo k9852` that breaks the next step `term_tui` ("vim edit did not reach the Mac file"). |

## Fix list (round 2)

- **R1-0 (blocker) Relaunch restore must connect.** After a cold launch that
  restores a terminal tab, the tab must attach as soon as the Mac link is up
  (same path as opening the workspace from the list). Also show the last
  frame (cached) instead of skeleton rows while it attaches. Add a rig step:
  relaunch, then assert the terminal accepts input within 10 s.
- **R1-1 (major) TUI resize with the keyboard.** When the soft keyboard
  settles (did-show / did-hide), resize the PTY once to the rows between the
  status bar inset and the composer; never per frame. During the animation
  keep the alt screen pinned to the composer as now. `top` and `vim` must show
  their header row with the keyboard up.
- **R1-2 (major) Text under the bottom toolbar.** Content scrolled below the
  composer must not be legible between and under the toolbar pills (y 772-874)
  or at the composer's leading corner. Apply the bottom scroll-edge effect
  (or the 24 pt gradient) to the whole region below the composer card's top,
  including the toolbar band.
- **R1-3 Key bar seam at rest.** The first scroller key (`tab`) shows a hard
  vertical seam about 12 pt in when the scroller is at offset 0 (`01`; same in
  mock). The leading mask strip must be fully opaque at rest.
- **R1-4 Key bar width and trailing key.** The scroller is 133 pt, not ≈ 186
  pt: 2.5 keys. Either size the scroller to a whole number of keys at rest or
  fade the trailing key so it never reads as half a key (`↑` 23 of 40 pt).
  Consider narrower trailing items (joystick 40 pt + keyboard 36 pt + gaps).
- **R1-5 Row 0 dimmed at rest.** The top fade must start above the top
  inset: at offset 0, row 0 renders at full brightness.
- **R1-6 Rig `term_keys`.** Page the scroller by one key width (or use the
  "More keys" accessibility actions), and clear the composer and command line
  (^C) when a step fails so the next step starts clean.
- **R1-7 Files and Links header.** Chips 8 pt under the nav bar, 16 pt leading
  content inset; one spelling ("Files and Links") in sheet title and menu.
- **R1-8 Paste in the attachment menu.** Show it first only when the
  pasteboard has an image or file (P9).
- **Upstream (unchanged):** M8/U3 hidden Close, Page Menu and Reload controls;
  U1 active tab ring; U2 card title; U4 thumbnail hook. The grid has no active
  ring (`22`). Pending user decision, not decided here: CmuxTabsKit's ~240 ms
  zoom.

## Not verified

- Hardware keyboard key bar (HID events would flip the simulator; unit tests
  only).
- Double-tap lock on ctrl (needs two taps < 0.4 s; unit tests only).
- A reattach that takes longer than 400 ms (P5 indicator).
- Image preview at the large detent (P4).
- 120 Hz smoothness (60 Hz recorder).
