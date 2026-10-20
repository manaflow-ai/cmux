# Terminal screen verification (CmuxMobileTerminal)

Date: 2026-10-12. Branch `feat-cnx-ios-term`. Simulators (headless, own):
`cmux-mobile-term-ios26` (iPhone 17 Pro, iOS 26.5) and `cmux-mobile-term-ios27` (iPhone 17 Pro,
iOS 27.0). Xcode 27.0. Evidence media is in
`cmux-next-ios/verify/evidence/2026-10-12/terminal/` (git-ignored).

## What was built

`cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileTerminal` (new SwiftPM target, depends on
`Packages/Shared/CmuxGhosttyKit`):

| Part | Files |
| --- | --- |
| Data source: `TerminalSession` protocol (bytes in, input out, resize, alternate-screen flag), `AlternateScreenDetector`, `MockTerminalSession` (zsh-like line editor, `ls`, `git log`, `git status`, a 360-line `cargo build`, `cat`, `htop` and `vim` on the alternate screen) | `Session/` |
| Ghostty (ghostty-next, mirror mode): process-wide app with action routing, `TerminalSurfaceView` (surface, UITextInput / hardware keys adapted from CmuxiOSTerminal) | `Ghostty/` |
| Screen: `TerminalScreen` (SwiftUI, toolbar, sheets), `TerminalViewController` (UIKit layout, scrolling, keyboard), `TerminalModel` | `Screen/` |
| Composer: UITextView field (dark keyboard, Return sends, 1-6 lines), `+` menu (Photos via PhotosPicker, Files via document picker, Paste), inline attachment previews, send = text + Return or a bare Return when empty | `Composer/` |
| Key bar: esc / sticky ctrl / sticky alt fixed, scrolling middle (tab, shift-tab, arrows, ^C ^D ^Z ^L ^R, paste, symbols, ^B), joystick (3 gears), hide-keyboard | `KeyBar/` |
| Files and links: `ArtifactSource` protocol + `MockArtifactSource`, `ArtifactExtractor` (paths, `path:line:col`, URLs, `ls -l` directories, ANSI stripped), sheet with filter chips, previews (HTML in WKWebView with Source toggle, Markdown rendered with Source toggle, syntax-colored code with line numbers, zoomable image, AVKit video, folder listing, binary card) | `Artifacts/` |
| DEBUG demo driver (`-CmuxMobileTerminalDemo`, `-CmuxMobileTerminalDemoPhases scroll,keyboard,tui,vim,attachments,artifacts`) | `Demo/` |

Hook: `Screens.swift` `WorkspaceDetailPlaceholder` shows `TerminalScreen` for a
terminal tab (mock session); the app shows `TerminalDemoRoot` only in DEBUG with
the launch argument.

## How it works (the parts that needed evidence)

**Keyboard tracking.** The bottom stack (key bar, composer) is a UIKit view whose
geometry is derived only from `view.keyboardLayoutGuide` (`usesBottomSafeArea =
false`): bottom = min(keyboard top, safe-area bottom) - 8, key bar height =
min(44, keyboard height) inside a clipping view, gap = min(8, key bar height). No
constraint changes from keyboard notifications: the keyboard's own animated
layout pass moves everything. The first implementation changed the key bar
height from `keyboardWillShow` (with and without `UIView.animate` using the
notification's curve) and measurably drifted from the keyboard (up to 22 pt at
the start of a hide, a 52 pt jump at the start of a show); that approach is gone.
TUI mode puts the surface in a clip view whose bottom is the stack's top and
whose top is the safe-area top: the grid keeps its rows, rides the keyboard and
is clipped at the top while the keyboard is up (hard top edge effect).

**Native scrolling.** The surface lives inside a `UIScrollView` whose content
height is the session's rows times the cell height (document end = cursor row).
Ghostty's viewport is moved with the `scroll_to_row:N` binding only when the
visible rows come within half a margin of the rendered rows (the surface is
the screen plus 48 rows above and below, capped at Metal's 8192 px). Ghostty
rebuilds cells on its renderer thread and presents asynchronously, and its
scrollbar reports and frames reach the main thread in either order (a frame
rendered before a request can land after it). The surface is therefore moved
only in the transaction that sets the new frame (`IOSurfaceLayer.contents` KVO),
and the frame's viewport is read from its own pixels: per-row hashes sampled
from the IOSurface are matched against the previous frame for the candidate
shifts (report, request, earlier requests, active area). Two bugs found by the
frame analysis and fixed: a sync `ghostty_surface_draw` draws stale cells (it
does not rebuild them), and the cursor probe (`scroll_to_row` to the active
area and back) leaked a frame of the active area when run during a fling.

## Evidence

Scripts in `cmux-next-ios/verify/scripts/`: `record_demo.sh` (install, record with
`simctl io recordVideo`, copy the demo timeline), `frames.sh` (ffmpeg, every
recorded frame named by presentation time), `track_video.py` /
`analyze_keyboard.sh` / `keyboard_track.py` (keyboard transitions),
`scroll_track.py` / `scroll_smoothness.py` (scroll), `montage.py`.

### Keyboard (frame by frame, full resolution)

Per transition: keyboard top (from keyboard pixels) and stack bottom per frame,
progress of each from start to end position, `lag` = (p_keyboard - p_stack) x
stack travel. TUI: the htop footer row against its position predicted from the
stack's progress. 1 px = 0.33 pt.

| Run | Transitions | Stack vs keyboard lag | TUI last row vs stack |
| --- | --- | --- | --- |
| `ios26-kb` (composer + TUI) | 4 show, 4 hide | -0.38 .. +1.00 pt, one frame -1.67 pt | -0.73 .. +0.22 pt |
| `ios27-kb` | 4 show, 4 hide | -0.35 .. +1.00 pt | -0.46 .. +0.23 pt |
| `ios26-full` (all phases) | 7 show, 7 hide | -0.38 .. +1.00 pt, one frame -2.00 pt | -0.46 .. +0.22 pt |
| `ios27-full` | 6 show, 6 hide | -0.49 .. +1.00 pt, one frame -1.67 pt | -0.46 .. +0.19 pt |

Results in `*.keyboard.txt`, per-frame tables in `frames/*.txt` (regenerate
with `analyze_keyboard.sh`). The stack starts and ends on the same frames as the
keyboard and moves on its curve; at rest the gap is exactly 8 pt on both
versions (keyboard top 566 pt on iOS 26, 573 pt on iOS 27). The +1.00 pt values
are the last frame of a hide (keyboard top near the screen edge). Frames where
the system has not drawn the keyboard yet (0-3 at the start of a show; the
stack already moves on the guide) are counted separately as
`keyboard-not-drawn`. Two rows in the full runs labelled hide at about 68 s
are the photo picker sheet, not the keyboard.

### Scroll

Each fling (7000 and 3500 pt/s up, 9000 pt/s down, UIScrollView's normal
deceleration on the display link) is measured pair by pair: vertical shift
between consecutive frames and the residual after aligning them.

- 18 flings after the fixes (`ios26/27-scroll8`, `-scroll9`, `-full`): no
  direction reversals, no misplaced frames; shifts decay smoothly from 317 px to
  1 px per frame, almost never a multiple of the 48 px row (pixel-smooth, not
  row-by-row); residual after alignment at most 0.83 of 255. One flagged pair is
  a recorder pacing hiccup (a repeated frame then a double step; the app's own
  pacing counter shows no hitch).
- Before the fixes the same analysis found one-frame jumps of one row (sync
  draw of stale cells) and of 17-22 rows (out-of-order frames, the cursor
  probe) in about one fling in four.
- App-side pacing during the flings (CADisplayLink, `pacing` in the timeline):
  542 frames / 0 hitches (iOS 26), 547 / 0 (iOS 27); longest interval 16.7 ms;
  longest main-thread step 4.3 ms / 7.8 ms.
- `xctrace record --template 'Animation Hitches'` against the simulator app:
  "Hitches is not supported on this platform" (`ios26-hitches.trace`). Needs a
  device run.

### Screens

`shots/ios26-full-*.png`, `shots/ios27-full-*.png` (18 moments each: scroll,
composer typing, empty send, htop with and without keyboard, vim with joystick,
sticky ctrl, photo picker, file picker, attachments strip, files-and-links
sheet, HTML preview and source, Markdown, image, code, video).

## Comparison with references

- Key bar against Termius ([mobile terminal docs](https://docs.termius.com/terminal/mobile-terminal),
  [touch terminal](https://termius.com/blog/new-touch-terminal-on-ios),
  [changelog](https://docs.termius.com/changelog/ios)) and Blink Smart Keys
  ([docs](https://docs.blink.sh/)): same set (Esc, sticky Ctrl/Alt, Tab and
  Shift-Tab for Claude Code, arrows, a scrolling middle, hidden with a hardware
  keyboard on device). Termius' three-gear arrow gesture is the joystick (8-16,
  16-24, over 24 pt; 160 / 80 / 30 ms). Blink cannot customize its bar; ours is
  a static list for now (SPEC 10.4 settings not built).
- La Terminal ([site](https://la-terminal.net/)) and both apps keep the terminal
  under a plain bar; ours follows SPEC 10.1 instead: glass toolbar with title
  menu and a keyboard toggle, content under the bars with the soft edge, hard
  edge in TUI mode. No reference capture of these apps was taken (no phone use).

## Gaps

- Real sessions: only the mock runs. In non-TUI mode the local grid has more rows
  than the session's (screen + margins, so scrollback renders under the bars);
  with a real owner (cmux-mobile-link-ffi, mirror mode) linear output works, but absolute
  cursor addressing on the primary screen assumes the owner's rows. The grid
  policy for a real owner needs a decision when the link lands.
- Interactive keyboard dismissal (drag down) is enabled but not exercised: the
  demo cannot synthesize touches without Simulator.app.
- Photo and file pickers are shown by the demo but nothing is picked; the strip
  is exercised with mock attachments. Uploads are not implemented (the mock
  inserts `~/.mobile/uploads/<name>`).
- Unit tests (`CmuxMobileKit/Tests/CmuxMobileTerminalTests`: alternate screen, extractor,
  joystick gears, frame matching) are written but not run: `nx-remote` cannot
  resolve `cmux-lawrence-2` from this Mac (REPAIR.md row 114), and the repo
  forbids local `xcodebuild test`.
- Not built from SPEC 10: long-press selection mode, full-screen joystick on
  long press, mic button, camera, key bar customization, title menu tab
  switching (the menu lists tabs passed in; the workspace hook passes none),
  connection details from a real link.
- The Workspaces -> workspace -> terminal path compiles and uses the same
  screen; it was not driven in the simulator (no touch input).
- The pixel-signature matching reads the presented IOSurface (4 or 8 bytes per
  pixel). Very periodic output can match several shifts; ties go to Ghostty's
  report, then the request.
