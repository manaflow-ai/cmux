# TUI mode on iOS: capability matrix

Verification of every TUI-mode capability of the iPhone app over the real
link, 2026-10-21, for PR #24081 (TUI scrolling, disclosure groups, bottom
bounce). The first run is below as recorded; **Resolution** says what changed
after it and what was re-verified.

## Resolution

| Item | Status | Change |
| --- | --- | --- |
| less: phone kept the first page while the Mac's less scrolled | Fixed, re-verified PASS | `TerminalRowShift`: the alternate screen's margins are the Mac's rows (7d72cac3147, f00e536ac39) |
| F1 taps never click | Fixed, re-verified PASS | A tap in an app that asked for the mouse is a left click at that cell (`TerminalSurfaceView.click`, `ghostty_surface_mouse_button`), then focuses the terminal as before. Tests `aTapIsAClickWhenTheAppAskedForTheMouse`, `aTapSendsNothingWithoutMouseReporting` |
| Drag-select inside a mouse-mode app | By design | One finger is the trackpad: a drag is the wheel (T-SCROLL-12). Selection is the long press (iOS text selection), which works in every TUI |
| N1 composer Send in vim normal mode inserted `:q` | Fixed, re-verified PASS | In a full-screen app a one-line draft is typed, not pasted (`ComposerSubmit(fullScreenApp:)`), and Return follows 250 ms later, past an agent's paste-burst window should one run on the alternate screen (Codex QA F1: Return within about 120 ms of typed text became a newline). Several lines stay one bracketed paste. Test `aFullScreenAppGetsAOneLineDraftTyped`. A one-line Send to Codex on the alternate screen is UNVERIFIED: Codex was not logged in on the rig mini |
| F2 hardware arrows, PgUp/PgDn, Home/End, forward Delete | UNVERIFIED, no change | They go through `UIKeyCommand`s (`navigationKeyCommands`, returned by `keyCommands`), which repeat when held; AXe's injected key events may not reach key commands. Needs a real Bluetooth keyboard on a device; no code change without that evidence |
| F3 OSC 8 links not tappable | Not done here: needs a trust decision | Opening a URL that a remote program printed is a trust policy change (on the Mac Ghostty asks for Cmd-click). Recommendation posted to manaflow-ai/cmux#13742; no behavior change in this PR |
| Key bar has no PgUp/PgDn, Home/End, F-keys | Not offered (product scope) | The joystick gives arrows; hardware F-keys work |

## Re-verify (e03153ad391)

Same rig, a Demo build of e03153ad391a3da609d683104e2d8599f3a72d29. The Mac's screen is the oracle.

| Check | Result | Mac side | Evidence |
| --- | --- | --- | --- |
| Tap three lines in vim `mouse=a` | PASS | ruler 1,1 → 10,7 → 23,7 → 34,7, each the tapped row | frames/rv-vim-tap*-after.png, videos/rv-vim.mp4 |
| Tap htop's CPU% header | PASS | sort PID → CPU% | frames/rv-htop-after-tap.png |
| Tap the other tmux pane (mouse on) | PASS | active pane 1 → 0 → 1 | frames/rv-tmux-after-tap-left.png, videos/rv-tmux.mp4 |
| Composer `:q` + Send in vim normal mode | PASS | vim quit; no `:q` in the file | frames/rv-vimq-after-send.png |
| Tap in the shell focuses the terminal | PASS | composer reads "Typing into terminal" | frames/rv-shelltap-after-tap.png |
| Long press → Copy in less | PASS | pasteboard "15" | frames/rv-lesscopy-menu.png |
| Drag in htop scrolls | PASS | first process row changed | frames/rv-htop-after-drag.png |
| Multi-line composer Send into Claude Code | PASS | one prompt, submitted, answered | frames/rv-claudeml-answer.png |

## First run (7d72cac3147)

- Build: cmux-next-ios Demo simulator app at `7d72cac3147ccbd73ff55b4a915b3ab9aa6272d9` (feat-cmux-next-ios-tui-scroll), bundle `dev.cmux.mobile.tuiscroll`, built on mini-cmux11s.
- Rig: headless iOS 26.5 simulator `cmux-mobile-tuiscroll` on the laptop. Real link to a hidden tagged cmux-next Mac app (tag `mobilenaming`) on mini-cmux11s.
- Oracle: the Mac terminal screen (`cmux terminal <id> screen read`) and the Mac's tmux state.
- Evidence paths are relative to `~/cmux-next-ios-e2e/tuiscroll/` on the verifying laptop (git-ignored media, not committed). Videos are in `videos/` and frames in `frames/`; `raw-*.json` holds per-test data.
- Tools on the mini (brew): htop, mc, lazygit, tmux, cmatrix. All installed.
- Rig caveat: the simulator uses a hardware keyboard, so the on-screen soft keyboard never appears. "Keyboard" states below mean the key bar or composer state.

| Capability | Program | Result | Evidence | Notes |
|---|---|---|---|---|
| Wheel scroll (mouse reporting) | htop | PASS | videos/v2-htop.mp4, frames/v2-htop-*.png, videos/m-perf-htop.mp4 | PID list: 0 → 1233 → 0; the phone matches the Mac |
| Wheel scroll | Claude Code | PASS | videos/v2-claude.mp4, frames/v2-claude-*.png | 270 → 215 → 240 |
| Wheel scroll while output streams | Claude Code (600 lines) | PASS | videos/m-claude.mp4, frames/m-claude-stream-drag.png | Each drag moves the view about 25 lines against live output |
| Wheel scroll | Codex | NOT RUN | – | `codex login status` on the mini: Not logged in |
| Wheel scroll | vim `-u DEFAULTS` (mouse=a) | PASS | videos/v2-vim.mp4, frames/v2-vim-*.png | 1 → 76 → 4 → 223 |
| Wheel scroll | tmux `set -g mouse on` | PASS | videos/m-tmux.mp4, frames/m-tmux-wheel-scroll.png | A drag enters copy mode and scrolls ([110/267]) |
| Alternate-scroll arrows (1007) | less | PASS | videos/v2-less-gestures.mp4, frames/v2-less-gestures-*-after.png | Phone and Mac top lines equal after all 8 gestures: 24, 48, 25, 89, 150, 90, 66, 4 |
| Alternate-scroll arrows | `man ls` | PASS | videos/m-misc.mp4, frames/m-man-ls-scrolled.png | Header → "directory operands…" → "-O …" (fling) → back up |
| Momentum and direction | less, htop, vim | PASS | v2-less-gestures, v2-vim | A fast swipe moves about 3× a slow drag; content always moves with the finger |
| less mirror matches Mac with keys | less, j/k | PASS | videos/v2-less-keys.mp4, frames/v2-less-keys-*.png | 15, 11, 15 equal on both sides (failed before 7d72cac) |
| Tap = mouse click at cell | vim `:set mouse=a` | **FAIL** | videos/m-mouse-vim.mp4, frames/m-mouse-vim-tap.png | Taps on rows 10, 20 and 5: the vim ruler stays at 228,1 (see F1) |
| Tap = click | htop header (sort by CPU%) | **FAIL** | videos/m-mouse-apps.mp4, frames/m-mouse-htop-header-tap.png | Sort column unchanged (F1) |
| Tap = click | mc panel | **FAIL** | frames/m-mouse-mc-open.png, frames/m-mouse-mc-tap.png | Mac screen unchanged after the tap (F1) |
| Tap = click | tmux pane select | **FAIL** | videos/m-tmux2.mp4, frames/m-tmux2-taps.png | The active pane stays 1 after tapping the left pane (F1) |
| Tap = click | lazygit | NOT RUN separately | – | Same root cause as F1, since no click events exist at all |
| Drag-select in mouse mode | vim visual by drag | **FAIL (by design today)** | videos/m-mouse-vim.mp4 | A drag is the wheel; no button-1 drag is sent (F1). The long press below is the iOS selection path. |
| Long press → iOS selection → Copy → pasteboard | less | PASS | videos/m-copy-tui.mp4, frames/m-copy-longpress-menu.png | `simctl pbpaste` = "17", the selected word |
| Long press selection | Claude Code | PASS | frames/taplp-after-longpress.png | Handles plus a Copy / Select All menu |
| Tap focuses the terminal | Claude Code | PASS | frames/taplp-after-tap.png | Composer shows "Typing into terminal" |
| Key bar: esc, ^C, tab, ⇧tab, arrows, ^D, ^Z, ^L, ^R, ^B | keys.py (raw echo) | PASS | videos/m-keys.mp4, raw-m-keys.json | Bytes: `\x1b` `\x03` `\t` `\x1b[Z` `\x1b[A/B/C/D` `\x04` `\x1a` `\x0c` `\x12` `\x02` |
| Sticky ctrl / alt | keys.py | PASS | raw-m-keys.json | ctrl then a = `\x01`; alt then x = `\x1bx` (Meta as ESC prefix) |
| PgUp/PgDn, Home/End, F-keys on the key bar | – | NOT OFFERED | – | The bar has no such keys (KeyBarKey.middle); the joystick gives arrows |
| Hardware F1, F2, F5, F12, Esc | keys.py | PASS | raw-m-keys.json (`hw_focused`) | `\x1bOP` `\x1bOQ` `\x1b[15~` `\x1b[24~` `\x1b` |
| Hardware arrows, PgUp/PgDn, Home/End, forward Delete | keys.py | **FAIL (rig-suspect)** | raw-m-keys.json (`hw_focused`) | Nothing arrives (F2) |
| Bracketed paste | vim insert (key bar Paste) | PASS | videos/m-clipboard.mp4, frames/m-paste-vim.png | File content equals the 3 pasted lines exactly, indentation kept (no autoindent cascade) |
| Bracketed paste | Claude Code | PASS | videos/m-claude.mp4, frames/m-claude-bracketed-paste.png | 3 lines land in the prompt without submitting |
| Composer Send in vim normal mode | vim | NOTE | videos/v2-vim-control.mp4 | `:q` sent from the composer is inserted as text, not run (N1) |
| Alternate screen keeps shell scrollback | less in and out | PASS | frames/m-altscreen-scrollback.png | Lines 1001-1036 are scrollable after quitting less |
| Key bar show/hide while in a TUI | htop | PASS | videos/m-resize.mp4, frames/m-resize-keybar-*.png | Bottom row stays on the composer; Mac grid stays 38×53 (the Mac owns the size; the phone shifts) |
| Rotation | – | NOT RUN | – | No headless orientation command in `simctl io` or AXe |
| 256-colour, truecolour, SGR attributes | printf | PASS | frames/m-display-colors-unicode.png | Ramps, bold, italic, underline and strike all render |
| Unicode, CJK, emoji | printf | PASS | frames/m-display-colors-unicode.png | Wide CJK alignment correct; ZWJ family and flag emoji render |
| Cursor shape (DECSCUSR) | printf in a running program | INCONCLUSIVE | frames/m-cursor-prog-*.png | Cursor not visible in the captured frames. The prompt shows a bar from Ghostty shell integration; vim shows a block. |
| Title (OSC 2) | printf; sleep | PASS (partial) | frames/m-title.png | Mac title = hello-title. On the phone it appears in the tab's accessibility label ("hello-title, ~/…"); the bottom pill showed the command name at that moment. |
| OSC 52 clipboard | printf | PASS | frames/m-osc52.png | `simctl pbpaste` = "osc52-hi" |
| OSC 8 hyperlink | printf | **FAIL / unsupported** | frames/m-display-osc8-tap.png | Text renders, but there's no link styling and a tap only focuses the terminal (F3) |
| Bell (BEL) | printf | NOT OBSERVABLE | frames/m-bell.png | No visual feedback; haptics can't be observed in the simulator |
| tmux prefix keys | tmux: C-b %, C-b o, C-b [ | PASS | videos/m-tmux2.mp4, raw-m-tmux2.json | Split, pane switch and copy mode all work through key bar ^B |
| Reconnect: background/foreground | htop, less, vim mouse=a | PASS | videos/m-reconnect.mp4, frames/m-reconnect-*-bgfg*.png | Redraw correct; the wheel still reaches the app (htop 0→1164, less 1→25, vim 1→70) |
| Reconnect: cold relaunch | htop, less, vim mouse=a | PASS | frames/m-reconnect-*-cold*.png | htop 1323→6753, less 25→49, vim 69→141; alternate screen restored, no garbage |
| Performance: cmatrix `-u 2` | cmatrix | PASS | videos/m-perf-cmatrix.mp4, frames/m-perf-cmatrix.png | 42.8 fps recorded, p50 17 ms, p95 33 ms, max 200 ms |
| Performance: htop 1 s refresh with drags | htop | PASS (no stalls seen) | videos/m-perf-htop.mp4 | Recorder gaps include the deliberate holds and pauses (p95 233 ms); no frozen content seen |

## Failures

**F1: Taps never send mouse clicks.**
- Reproduction: `vim -n -u DEFAULTS -c 'set mouse=a' FILE`, then tap a line. Likewise htop's column header, mc, and tmux with `mouse on`.
- Expected: on the Mac the cursor moves, the sort changes, or the pane is selected (SGR button 0 press/release at the cell).
- Actual: no change on the Mac.
- Likely cause: `TerminalViewController.terminalTapped()` only calls `focusTerminal()`. `TerminalSurfaceView+Input.swift` sends only `ghostty_surface_mouse_pos` and `ghostty_surface_mouse_scroll`; there is no `ghostty_surface_mouse_button` anywhere in CmuxMobileTerminal. A drag is always the wheel, so app-level drag selection can't happen either.

**F2: Hardware navigation keys don't arrive.**
- Reproduction: `python3 keys.py` (raw echo), tap the terminal to focus, then send hardware Up, PgUp, Home, End or forward Delete with AXe (`axe key 82/75/74/77/76`).
- Expected: `\x1b[A`, `\x1b[5~` and so on, as Esc and F-keys produce.
- Actual: no bytes arrive.
- Likely area: `TerminalSurfaceView+Keys.swift`. Navigation keys are skipped in `beginPresses` and rely on `navigationKeyCommands()` (UIKeyCommand). If those commands aren't returned from `keyCommands`, or don't win, the key is dropped.
- Caveat: AXe injects HID events; this may be a rig artifact. Confirm with a real Bluetooth keyboard.

**F3: OSC 8 links aren't tappable.**
- Reproduction: `printf '\e]8;;https://example.com\aLINK\e]8;;\a'`, then tap LINK.
- Expected: the link opens or offers to open.
- Actual: the tap focuses the terminal.
- Cause: the tap path (`terminalTapped`) has no link lookup.

## Notes

**N1: Composer Send isn't a way to run vim commands.** The draft goes as a bracketed paste and then Return (`ComposerSubmit`). vim normal mode takes the paste as inserted text, so `:q` lands in the buffer. Typing in the focused terminal works.

## Impossible on iOS (or in this rig)

- **Rotation:** the headless simulator has no orientation command (`simctl io` and AXe). NOT RUN; the app may well support it.
- **Bell haptics:** can't be observed in the simulator.
- **Soft keyboard resize:** the simulator has a hardware keyboard attached, so the soft keyboard never shows. Covered here with the key bar and composer states only.
- **True mouse hover:** there's no pointer on touch. It's possible with a trackpad or pointer device, which this rig can't test.
