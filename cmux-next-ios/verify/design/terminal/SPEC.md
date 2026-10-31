# Inside a workspace: tabs, terminal, Files and Links, reattach

Designer pass, 2026-10-14, on `feat-cnx-ios` at `9b38033d` (merged into
`feat-cnx-ios-design-terminal`). The designer writes no app code. This page
says what is wrong, what it should be, and how to check it. CmuxTabsKit
changes are upstream requests to `feat-cmux-next-tabs-kit` (last section),
never a local fork.

Read first: `verify/terminal-flood.md`, `verify/terminal-input-lane.md`,
`verify/perf-latency.md`. Nothing here reverses them; the flood, input lane and
follow policy work is kept.

## How this was captured

- **Mock.** Debug build (`-derivedDataPath /tmp/cmux-mobile-term-design-dd`), one
  headless iPhone 17 Pro, iOS 26.5, `cmux-mobile-design-terminal3`, launched with
  `-cmuxMobile.dev.mockData YES` ("mock (layout only)"). Dark appearance. Files
  `raw/[a-h]*.jpg`.
- **Live.** The E2E rig (`verify/e2e/e2e.py --sim-name cmux-mobile-design-terminal3
  --keep --latency none`, Demo config) against the real hidden cmux-next DEBUG
  Mac build `cmux-mobile-e2e-604fc689`. Results 10 pass, 2 fail (below). Then extra
  live captures on the same session. Files `raw/L*.jpg`, `raw/rig-*.jpg`,
  `video/*.mp4`. Light appearance (the rig's default). Never paired with the
  user's Mac; never touched the user's iPhone.
- The simulator was deleted and the rig Mac app quit at the end.
- Load: the 1-minute load was 10 to 12 for `v01`, `v02` and 47 for `v04`.
  `v03` (tab open from the grid) ran at load 101, so its timing is not
  evidence; only its frames' content is used.
- Raw images are downscaled to 603 × 1311 (1.5 px per pt). Measurements below
  are in pt, read from the accessibility frames (`axe describe-ui`) unless
  marked px.

## Severity summary

| # | Severity | Issue | Evidence |
| --- | --- | --- | --- |
| B1 | Blocker | Live terminal draws the Mac's top-anchored screen bottom-anchored, with about 29 blank rows above it and about 2 screens of blank rows you can scroll into | `img/01-live-blank-rows-above.jpg` |
| B2 | Blocker | ^C is hidden inside a 116 pt "More keys" scroller, 3rd page; the rig's `term_keys` step fails on it | `img/02-keybar-more-keys-live.jpg`, `raw/rig-09-term_keys.jpg` |
| M1 | Major | Armed ctrl does not apply to the next typed letter; letters go into the composer as text and ctrl stays armed | `img/08-ctrl-armed-types-into-composer.jpg` |
| M2 | Major | Shell composer runs autocorrect, predictions and AutoFill | `img/08-ctrl-armed-types-into-composer.jpg` (right), `raw/e08-composer-tap-3.jpg` |
| M3 | Major | Glass composer, key bar and toolbar sit over live terminal text; the text under them is legible and clashes with the placeholder | `img/06-chrome-over-text.jpg` |
| M4 | Major | Key bar presence differs: shown at rest in mock, hidden at rest live; hidden entirely with a hardware keyboard | `img/05-terminal-rest-vs-keyboard.jpg` |
| M5 | Major | Terminal text has a 0 pt leading inset; columns touch both screen edges | `raw/e01-terminal.jpg`, `raw/L05-live-seq-bottom.jpg` |
| M6 | Major | Dismissing the keyboard by drag also scrolls the terminal off the prompt | `img/10-keyboard-drag-dismiss-frames.jpg`, `video/v02-live-keyboard-drag-dismiss.mp4` |
| M7 | Major | Refused file preview keeps live-looking controls (Preview/Source toggle, More) and the rig reads it as "blank" | `img/04-files-links-list-refusal.jpg` (middle) |
| M8 | Major | Hidden accessible controls on the page: "Close <tab>" at (372, 0) 30 × 30 under the status bar, "Page Menu" and "Reload" inside the title pill | AX dump in this page, "Dead and hidden controls" |
| P1-P12 | Polish | Listed below | |

What is already right and must be kept:

- Fling is smooth: in `video/v01-live-fling.mp4` distinct frames arrive every
  16 to 17 ms through two flings and a slow drag; the longest gap during motion
  is 33 ms (the recorder caps at 60 Hz, so 120 Hz could not be checked).
- Composer and key bar ride on the keyboard (composer bottom 500, key bar
  519-553, keyboard top 566 in `raw/L06-live-keyboard-up.jpg`).
- The keyboard follows the finger once the drag crosses its top edge and
  dismisses on release (`v02`), matching Messages.
- Last-frame warm tabs: after 30 s in the background the terminal comes back
  showing its last frame at once, and "Reattaching…" clears in about 250 ms
  (`img/09-return-reattach-frames.jpg`). Opening a tab from the grid shows its
  content during the zoom, never a blank page (`video/v03-live-tab-open-from-grid.mp4`).
- Output never moves a reader who scrolled up (`raw/L04-live-after-seq.jpg`),
  and the jump-to-bottom button appears (`terminal-flood.md` #10).
- Opening a workspace restores its last tab (rig `last_tab_restore` pass).
  A Needs-you workspace opens on its waiting agent tab instead
  (`WorkspacesList.openWorkspace`); that is intentional and kept.
- The Files and Links refusal says why ("Aziz's MacBook Pro isn't sharing any
  folders with this phone yet…") with Try Again (`raw/rig-files-preview-040400.jpg`).

## Blockers

### B1. Blank rows above the Mac's screen

**Seen.** Tab `e2e-t2` on the Mac (`cmux terminal … screen read`, 42 rows ×
54 cols) holds 10 lines in rows 0-9 and the cursor on row 9. The phone
(`raw/L11-live-fresh-shell.jpg`) draws those 10 lines from y ≈ 543 pt to
y ≈ 726 pt, directly above the composer. From the top inset (62 pt) to 543 pt,
about 481 pt (29 rows at 16.4 pt) is black. VoiceOver reports the terminal as
"3 pages" for a 10-line session; scrolling up shows only black
(`raw/L03-live-scrolled-to-top.jpg`, `raw/L01-live-now.jpg`: an entire black
screen with only the jump-to-bottom button). The tab-grid thumbnail repeats it
(`raw/L09-live-tab-grid.jpg`, right card: content in the last 10 % of the
card).

**Should be.** The phone renders exactly what a terminal renders:

1. Primary screen, short session: row 0 sits at the top content inset (62 pt,
   under the status bar), like Terminal.app, Blink and Termius. Blank space is
   below the cursor, never above row 0.
2. The scrollable document is scrollback + the screen's rows. Its top is the
   first scrollback row. There are no rows above it that the user can scroll
   into. With no scrollback, the terminal does not scroll vertically at all
   (rubber-band only).
3. When the keyboard comes up and the cursor would be covered, the content
   moves up just enough to keep the cursor row 8 pt above the composer
   (ChatGPT-style "keep the last line visible"), and moves back down when the
   keyboard goes away. This is a viewport offset, not blank rows in the
   document.
4. `clear` (and `ESC[2J ESC[3J`) puts the prompt back on row 0 at the top.
5. The thumbnail uses the same layout (row 0 at the card's top).

Check: rig step `term_scrollback` must also assert that, after `clear`, the
prompt's on-screen y is within one row of the top inset, and that a 10-line
session's terminal reports "1 page".

### B2. ^C is buried

**Seen.** Live key bar (`img/02-keybar-more-keys-live.jpg`): pinned `esc ctrl
alt`, then a "More keys" scroller only 116 pt wide (x 178-294), then the
joystick (40 pt) and the keyboard toggle. The scroller shows 2.5 keys at a
time, hard-clipped at both edges with no fade (the `→` key is cut at x 178, the
`^D` key at x 294). ^C is on the second swipe page. The rig's `term_keys` step
fails: `key bar has no 'Control C'` (`raw/rig-09-term_keys.jpg`).

**Should be.** Reference: Blink Shell's smart-keys bar and Termius' extra-keys
row both put the modifiers and the most used control keys on the first screen,
and scroll the rest full-width.

- Row layout, 402 pt wide, 44 pt tall keys (hit target), 34 pt visual height:
  - pinned leading: `esc`, `ctrl`, `^C` (new: one tap sends 0x03).
  - scroller, flexible width (about 186 pt on a 402 pt phone): `tab ⇧tab ↑ ↓
    ← → ^D ^Z ^L | ~ / - paste`.
  - pinned trailing: joystick, keyboard toggle.
  - Move `alt` into the scroller (it is the rarest of the three modifiers).
- The scroller fades its content over 12 pt at each edge (gradient mask), and
  it snaps to whole keys so a key is never shown cut in half. When content is
  scrolled, the leading fade shows; at rest the leading edge is hard.
- The scroller's frame must start after a 6 pt gap from the pinned group and
  its first key must be fully visible at rest.
- "More keys" (accessibility): keep the custom actions for keys outside the
  visible area (`KeyBarClipping`), and expose ^C as a normal button always.
- The rig step `term_keys` should pass unchanged once ^C is pinned.

## Majors

### M1. Armed ctrl and the composer

**Seen.** Tap `ctrl` (armed: fill goes from about #2A2A2A to #3A3A3A, nothing
else changes), then type `h` `e` on the soft keyboard: the composer shows
"he"; ctrl stays armed (`img/08-ctrl-armed-types-into-composer.jpg`). The
armed state is barely distinguishable from rest.

**Should be.**

- Armed ctrl means "the next key goes to the terminal as a control
  character", regardless of focus. Typing `c` sends 0x03 to the shell
  immediately, does not touch the composer text, and disarms ctrl. Same for
  alt (ESC prefix).
- Double tap locks a modifier until tapped again (Blink's behavior).
- Armed: accent fill (`tint`, the app's blue) with white label. Locked: accent
  fill plus a 2 pt underline. Rest: current fill.
- VoiceOver: value "armed" / "locked" on the key.

### M2. The shell composer must not autocorrect

**Seen.** Typing `he` in the shell composer shows the QuickType bar ("HD",
"her", "HR"), `autocorrect` is on, and a second tap shows an AutoFill callout
(`raw/e08-composer-tap-3.jpg`).

**Should be.** For a terminal composer: `autocorrectionType = .no`,
`autocapitalizationType = .none`, `spellCheckingType = .no`,
`smartQuotesType = .no`, `smartDashesType = .no`,
`smartInsertDeleteType = .no`, `textContentType = nil` (no AutoFill),
`inlinePredictionType = .no`. The QuickType bar then shows nothing and does not
add 44 pt above the keyboard. The agent chat composer keeps its natural
language settings.

### M3. Chrome over terminal text

**Seen.** At the bottom of a full terminal the composer (y 676-737 at rest),
the key bar (740-784) and the toolbar (792-840) are translucent glass; rows
scroll under all three and remain readable through them, including under the
"Send to …" placeholder (`img/06-chrome-over-text.jpg`, left: mock scrolled
up; right: live, colored rows under the composer and the pill).

**Should be.** Reference: ChatGPT's composer over a transcript, Blink's bar.

- The terminal's bottom content inset equals the top of the composer card
  (plus 8 pt) in every state, so the last row is never under chrome at rest.
- When the user scrolls content under the chrome, a scroll edge effect fades
  it: iOS 26 `scrollEdgeEffectStyle(.soft, for: .bottom)` on the terminal
  scroll view, or a 24 pt black-to-clear gradient behind the composer. The
  glass backing gets 85 % opacity of the terminal background so text under it
  is not legible.
- Same at the top under the status bar: today the top row is half-cut at
  y 52-62 pt (`raw/f05-zsh-again.jpg`, top). Use `.soft` at the top too.

### M4. One key bar rule

**Seen.** Mock at rest: composer + key bar + toolbar (`raw/e01-terminal.jpg`).
Live at rest: composer + toolbar, no key bar (`raw/L02-live-bottom.jpg`).
With a hardware keyboard: no key bar (`raw/e08-composer-tap-3.jpg`). Mock and
live also differ in the composer: no attachment `+` in mock, `+` in live.

**Should be.**

- The key bar is shown whenever the terminal or its composer has focus, with
  the soft keyboard or a hardware keyboard (esc, ctrl, ^C and the arrows matter
  most on a hardware keyboard without them, e.g. iPhone + Magic Keyboard).
- At rest (no focus) the key bar is hidden and the composer sits alone above
  the toolbar. This is the live behavior; the mock must match it.
- The mock terminal must use the same composer as live (with `+`), so
  "mock (layout only)" captures are representative.

### M5. Terminal leading and trailing inset

**Seen.** Glyphs start at x = 0 pt (`raw/e01-terminal.jpg`, "Last login"
starts at the screen edge; `raw/L05-live-seq-bottom.jpg`, row numbers touch
the edge). On a device with rounded corners the first column of the top and
bottom rows is cut by the corner radius.

**Should be.** 6 pt leading and 6 pt trailing padding inside the terminal
surface (Blink and Termius both pad; iOS readable margins for content are
16 pt, but a terminal trades margin for columns). The column count is
computed from `width - 12 pt`. Background color still fills edge to edge.

### M6. Drag-dismiss should not scroll the reader away

**Seen.** In `v02`, the drag starts at y 300 above the keyboard; the terminal
scrolls up with the finger until the finger reaches the keyboard, then the
keyboard follows. After release the viewport is 50 rows above the prompt, and
the jump button appears (`img/10-keyboard-drag-dismiss-frames.jpg`, frames
10-20).

**Should be.** Keep `.interactive` keyboard dismissal (the user's preference:
the keyboard clips from the top and follows the finger). When the terminal
was following the bottom when the drag began:

- while the keyboard follows the finger, the content stays pinned to the
  composer (it moves down with it, row for row), so the prompt stays directly
  above the composer for the whole gesture;
- the drag above the keyboard still scrolls normally if the reader was
  already scrolled up.

TUI and alt-screen apps (`vim`, `top`; `raw/rig-tui-top-040400.jpg`) always
stay pinned to the composer: the alt screen never scrolls, so a drag over it
only moves the keyboard. The PTY resizes once, after the keyboard settles, not
per frame.

### M7. Refused file preview

**Seen.** `raw/rig-files-preview-040400.jpg`: the sheet title is truncated
("cmux-mobile-e2e-040…") while the refusal headline wraps the same name at a hyphen
("Can't open cmux-mobile-\ne2e-040400-sample.md"); the Preview/Source segmented toggle
and the More (…) menu stay enabled although there is nothing to preview. The
rig reports "stayed blank for 10 s", which is a rig check that predates the
refusal message; the screen itself is not blank.

**Should be.**

- On refusal and on Empty file: hide the Preview/Source toggle; More keeps only
  "Copy Path" and "Open on Mac" if available, otherwise it is hidden. No dead
  controls.
- Headline: "Can't open this file". The file name goes in the description,
  with `lineBreakMode = .byTruncatingMiddle` on its own line.
- Rig: `files_links` should pass when the refusal view (its accessibility
  identifier) is shown, and fail only on a blank page.

### M8. Dead and hidden controls on the page

**Seen** (accessibility tree, terminal page):

- `Button "Close zsh"` at (372, 0), 30 × 30: under the status bar, not
  visible, reachable by VoiceOver.
- `Button "Page Menu"` at (90, 792), 48 × 48 and `Button "Reload"` at
  (268, 792), 44 × 48, both inside the title pill (90-312). Not drawn, but
  they steal taps at the pill's ends. "Reload" has no meaning for a terminal.
- An empty `ScrollArea` at (90, 792) 48 × 82.

**Should be.** Only what is drawn is accessible. The title pill is one button
that opens the page menu (it does today, `raw/g01-title-menu.jpg`). Reload
exists only on browser tabs. Close lives in the page menu and on the grid
card. See upstream request U3.

## Polish

- **P1. Page menu duplicates.** `raw/g01-title-menu.jpg`: "Show Keyboard"
  duplicates the key bar's keyboard toggle and the composer, "Send Ctrl-C"
  duplicates the key bar (after B2 it is one tap), "All Workspaces" duplicates
  Back. Keep: Files and Links, Paste, Clear, Scroll to Bottom (disabled when at
  bottom, as now), Copy Directory, Close Tab. Order: Files and Links, Paste,
  Clear | Copy Directory | Close Tab.
- **P2. Files and Links header.** `raw/g02-files-links.jpg`: 37 pt between the
  nav bar's bottom (481) and the chips (518); the chips are a List section
  header and are clipped at x 386 by the list inset ("Video" cut). Chips go
  directly under the title (8 pt gap), scroll edge to edge with a 16 pt leading
  content inset. Every chip shows its count ("Files 4"); chips with 0 items are
  hidden. The selected chip gets the `.isSelected` trait (today every chip is a
  plain Button).
- **P3. Empty filter copy.** The overlay "Nothing referenced yet" also shows
  for an empty filter. For a filter: "No folders yet" etc.; the generic text
  only for All.
- **P4. Image preview at half height.** `raw/g03-file-preview.jpg`: the image
  is drawn at half-sheet size with 300 pt of black under it. Opening an image
  or video moves the sheet to the large detent and fits the media (aspect
  fit, pinch to zoom).
- **P5. Reattach indicator.** `img/09-return-reattach-frames.jpg`, frames 3-5:
  "Reattaching…" is a small, low-contrast caption floating mid-screen in the
  blank area (which only exists because of B1). Move it to the title pill's
  subtitle ("Reattaching…" replacing the cwd for the duration), and show it only
  if reattach takes longer than 400 ms. A 250 ms reattach shows nothing.
- **P6. Grid active tab.** Neither grid marks the current tab
  (`img/03-tab-grid-mock-live.jpg`). Upstream U1.
- **P7. Grid card titles.** Mock grid titles are 17 pt semibold with icon,
  truncated to "Refactor transport l…" (`raw/d01-tabs-grid.jpg`). Safari uses
  13 pt (footnote) medium, centered under the card. Upstream U2.
- **P8. Joystick affordance.** The joystick is a 40 pt circle with a 14 pt
  grey dot, indistinguishable from a radio button. Show 4 faint chevrons inside
  the ring (↑↓←→ at 30 % opacity), and on touch-down scale the dot 1.2× and
  give a light haptic per cursor step.
- **P9. Attachment menu.** `raw/L12-live-attach-menu.jpg`: Paste, Files,
  Photos. Add Camera (ChatGPT order: Camera, Photos, Files), and keep Paste
  first only when the pasteboard has an image or file. Each attachment appears
  as a chip in the composer above the text line, with an × to remove, before
  it is sent.
- **P10. State restoration.** Relaunching the app returns to Home, not to the
  workspace and tab that were open (`raw/f01-relaunch.jpg`). Restore the
  navigation path (Workspaces tab, workspace, tab), with the last frame shown
  warm until reattached.
- **P11. Send button glyph.** The send button is ↩ when empty (sends Return)
  and ↑ with text (`img/08-…`, right). Keep, but give the ↑ state the accent
  fill so "send" reads as primary, like the agent composer.
- **P12. Files and Links sheet over the terminal.** The terminal behind the
  half sheet is not dimmed; its glyphs show in the 20 pt side margins
  (`raw/g02-files-links.jpg`, left edge). Acceptable for iOS 26 floating
  sheets; dim nothing, but stop terminal output from repainting the region
  behind the sheet more than twice a second (already the reconcile rate in
  `terminal-flood.md`).

## Upstream CmuxTabsKit requests (feat-cmux-next-tabs-kit)

Write these as requests in `verify/tabskit-upstream-requests.md` on the tabs-kit
branch; do not patch CmuxTabsKit here. Every change also lands, pushed, in
`feat-cmux-next-tabs-kit` (CmuxTabsKit sync rule).

- **U1. Active tab ring.** In the grid, the active tab's card gets a 3 pt
  accent-colored ring outside the card (Safari's grid). Accessibility: the
  active card has the `.isSelected` trait.
- **U2. Card title style.** Title under the card: footnote (13 pt), medium,
  centered, single line, middle truncation for file-like titles; kind icon
  12 pt leading. Today the mock grid uses 17 pt semibold, leading-aligned
  (`raw/d01-tabs-grid.jpg`).
- **U3. Page chrome accessibility.** The kit's page chrome exposes only drawn
  controls: no hidden Close button at the page's top-right, no Page Menu /
  Reload buttons overlaid on the title pill. A data source can opt in to a
  Reload toolbar item (browser tabs only).
- **U4. Thumbnail anchoring hook.** A data-source hook so a terminal tab's card
  snapshot can be taken from the terminal's own top-anchored render, not the
  page's current scroll offset (supports B1 point 5).
- **Pending user decision, not decided here:** CmuxTabsKit's ~240 ms grid zoom
  duration. `video/v03-live-tab-open-from-grid.mp4` shows the zoom (about 4
  frames at 10 fps under load 101, so not a timing measurement). This spec
  neither shortens nor keeps it.

## Rig follow-ups (verify/e2e)

- `term_keys`: passes once ^C is pinned (B2); no rig change needed.
- `files_links`: treat the refusal view as a valid end state (M7).
- `term_scrollback`: add the B1 assertions.
- Don't send `axe key` / `key-sequence` to a simulator that will later need the
  soft keyboard: one HID key event switches iOS into hardware keyboard mode,
  and the soft keyboard stays hidden until the simulator reboots (this broke
  this pass's first rig run: `sign_in` "no soft key for '4'").

## What could not be captured

- Reference app screenshots (Safari tabs, Blink, Termius, Prompt 3, ChatGPT)
  were not freshly captured; the comparisons use their documented behavior.
  `~/Downloads/cmux-native-references/` has ChatGPT, Claude and Grok but no
  terminal or Safari references.
- 120 Hz smoothness: the simulator recorder caps at 60 fps.
- Interactive drag-dismiss **cancel** (drag the keyboard partway and back):
  `axe swipe` cannot reverse direction mid-gesture.
- The joystick drag, the double-tap lock (not implemented), and a hardware
  keyboard's key bar on a live session.
- Tab switch latency: `v03` ran at load 101; `perf-latency.md` remains the
  timing source.
- A TUI during the keyboard animation (M6's alt-screen rule) on video; only
  the still `raw/rig-tui-top-040400.jpg` exists.
- Agent chat tabs and browser tabs were out of scope.
