# Terminal composer: classic cmux iOS parity

Branch `feat-cmux-next-ios-composer-classic`, 2026-10-26. The task: make the
cmux NEXT iOS terminal composer bar match the classic cmux iOS app's composer
bar (layout, controls, key row, behavior, keyboard interaction, animations)
while keeping cmux NEXT's own components, theming and data flow.

Sources compared:

- Classic (`origin/main` e28b3235): `Packages/iOS/CmuxMobileShellUI/.../TerminalComposerView.swift`,
  `TerminalComposerPromptEditor.swift`, `Packages/iOS/CmuxMobileTerminal/.../TerminalInputTextView.swift`
  (the key toolbar), `TerminalArrowNubView.swift`, `TerminalInputAccessoryAction.swift`,
  `GhosttySurfaceView.swift` (the bottom dock), `CMUXMobileCore/ComposerDockReducer.swift`,
  `CmuxMobileSupport/MobileComposer*.swift`, `ComposerDictationController.swift`.
- cmux NEXT (`origin/feat-cmux-next` f722db93): `cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileTerminal/`
  `Composer/TerminalComposer.swift`, `Composer/ComposerTextView.swift`, `KeyBar/*.swift`,
  `Screen/TerminalViewController.swift`, `Screen/TerminalModel.swift`, `Input/*.swift`.

## Differences

### Dock layout

| | Classic | cmux NEXT (before) |
| --- | --- | --- |
| Order, top to bottom | terminal, key toolbar, composer, keyboard (the composer is nearest the keyboard) | terminal, composer card, key bar, keyboard |
| Key row visibility | Always shown, keyboard up or down | Hidden at rest; shown only while the terminal or composer has focus (SPEC M4), clipped to the keyboard's height while it moves |
| Composer visibility | Open by default per terminal, unfocused (keyboard down) until tapped; the compose key closes it (session-only) | Always shown; cannot be closed |
| Hide all chrome | A "Hide Toolbar" key hides the key row, composer and keyboard until the next terminal tap | None |
| Gaps | Key row 28 pt + 8 pt below it; composer 2 pt top, 8 pt bottom; 12 pt side insets | Card 6 pt padding, 8 pt side insets; 8 pt between card and key bar; key bar 44 pt |

### Key row

| | Classic | cmux NEXT (before) |
| --- | --- | --- |
| Container | No bar: each key is its own glass capsule, 28 pt tall, on a clear strip | One 44 pt glass capsule holding 34 pt keys |
| Pinned (left) | Keyboard toggle (keyboard / keyboard.chevron.compact.down, cross-dissolve), arrow nub, text field toggle (character.textbox, 13 pt like its neighbors) | esc, ctrl, ^C |
| Pinned (right) | None (the row scrolls to the screen edge) | Joystick, hide keyboard |
| Scrolling keys | ⌃ ⌥ ⌘ ⇧ paste, Tab, Esc, ⏎, ^C, ^D, Claude, Codex, Ollama, ↑ ↓ ← →, Clear, ~ $ / @ \|, ^Z, Home, End, PgUp, PgDn, zoom out, zoom in, then Hide Toolbar and Customize | tab, ⇧tab, ↑ ↓ ← →, ^D ^Z ^L, alt, \| ~ / -, paste, ` { } [ ], ^R, ^B |
| Key size | Hugs its label, min 32 pt wide (glyph keys exactly 32), 4 pt gaps, 14 pt medium text | Fixed 44 pt wide, 6 pt gaps, snaps to whole keys, 15 pt monospaced |
| Modifiers | ⌃ ⌥ ⌘ ⇧: tap arms for one key, double tap locks; armed and locked use the accent fill, locked adds a border | ctrl and alt only: same tap/double-tap rule; accent fill, locked adds an underline |
| ⌘ | ⌘← / ⌘→ send ^A / ^E (line start/end); ⌘↑ ⌘↓ send the plain arrow | Not offered |
| ⇧ | ⇧Tab is back-tab; other keys unshifted | ⇧tab is its own key |
| Arrow input | A 28 pt glass nub with a 12 pt dot; drag past 8 pt sends that arrow, repeating; the dot springs back in 0.15 s | A 32 pt joystick whose thumb follows the finger past the circle; 400 ms delay then 10-18/s |
| Zoom | Two keys step the terminal font size | Settings only |
| Launchers | Claude, Codex (each with Return), Ollama (`ollama run `, no Return) | None |
| Fades | Keys dissolve at the leading edge against the compose toggle | 12 pt fades both ends; keys cut at rest are not drawn |

### Composer row

| | Classic | cmux NEXT (before) |
| --- | --- | --- |
| Structure | Paperclip button (40 pt glass circle), mic button (40 pt glass circle), then the field in a rounded glass container (radius 20, min 40 pt) with a 28 pt send circle inside it, riding the last line | One glass card (radius 24) holding a 36 pt `+` circle, the field, and a 36 pt send circle |
| Attach menu | Photo Library, Choose Files, Paste | Paste (only for an image or file, first), Camera, Photos, Files |
| Dictation | Mic toggles on-device dictation into the field (pulsing red mic while listening; the field locks while it listens) | None (the keyboard's own mic) |
| Placeholder | "Message" | "Send to <program>", or "Typing into terminal" with a keyboard glyph while keys go to the terminal |
| Return key | Inserts a new line; only Send sends | Sends (Shift-Return or the edit menu's New Line inserts one) |
| Lines | Grows 1 to 14 lines, then scrolls | 1 to 6 lines |
| Send | arrow.up on the accent fill when there is text or an attachment; disabled (dim) when empty; spinner while sending; red ! on failure | arrow.up on blue with text; a "return" glyph that sends a bare Return when empty; long press: Send without Return |
| Send path | Bracketed paste of the draft, then Return | The same (`ComposerSubmit`); typed keys for a one-line draft in a full-screen app |

### Behavior and keyboard

| | Classic | cmux NEXT (before) |
| --- | --- | --- |
| Tap on the terminal | Keyboard up, keys go straight to the terminal; the composer stays visible and unfocused | The same, and the composer's placeholder switches to "Typing into terminal" |
| Compose key | Open (and focus) when closed; reveal and focus when shown but unfocused or hidden; close only when shown and focused (`ComposerDockState`) | n/a |
| Keyboard key | Shows the keyboard (for the last target) or hides it | `TerminalModel.toggleKeyboard` exists but has no on-screen key; a hide-keyboard key shows only while it is up |
| Keyboard tracking | The dock rides `keyboardLayoutGuide`; composer growth reflows over 0.25 s ease-in-out | The stack rides `keyboardLayoutGuide` (unchanged) |

### Animations

| Classic | cmux NEXT (before) |
| --- | --- |
| Composer band height (typing a new line, attachments, close) 0.25 s ease-in-out; keyboard key glyph cross-dissolve 0.2 s; nub dot spring-back 0.15 s; mic pulse while listening; armed key restyles at once | Card height via SwiftUI; key press scale 0.92 spring; Jump to bottom fade 0.2 s; attachment strip 0.3 s smooth |

## What changes (plan)

Classic's layout, controls, key row, behavior and keyboard interaction, built
from cmux NEXT's own pieces:

- `TerminalViewController` keeps one bottom stack on `keyboardLayoutGuide`, now
  key row on top and composer nearest the keyboard; the key row is always shown;
  the composer can be closed and the whole chrome hidden. The resting stack
  height the PTY is sized against includes the key row.
- `TerminalKeyBar` becomes classic's row: pinned keyboard key, joystick and
  compose key, then a scroller with classic's keys in classic's order, ending in
  Hide Toolbar. Keys keep cmux NEXT's `KeyCapStyle` look (quiet fill, accent when
  armed, underline when locked) at classic's metrics.
- `TerminalStickyModifiers` and `TerminalInputRouter` gain ⌘ and ⇧ with classic's
  meanings.
- `TerminalComposer` becomes classic's row (paperclip, mic, field with inline
  send), keeps cmux NEXT's attachments, notices, Jump to bottom and upload flow;
  dictation reuses the shared `CmuxMobileSupport.ComposerDictationController`
  (the class classic uses).
- `ComposerTextView`: Return inserts a new line (new `ComposerReturnStyle.message`),
  14 lines, placeholder "Message".
- Portable rules (`ComposerDockState`, the key row's order, zoom steps,
  modifier encoding) are unit tested; the app-level behavior has an XCUITest.

Kept from cmux NEXT on purpose:

- Theming: dark style over the terminal background, glass on 85 % terminal
  background, accent fill, the `KeyCapStyle` fills, monospaced key labels.
- The joystick's engine (thumb follows past the circle; 400 ms then 10-18/s
  repeat): both were user requests for cmux NEXT (2026-10-14, Codex QA F5). The
  joystick takes classic's place and 28 pt size.
- Camera stays in the attach menu (after classic's three items), and Send without
  Return stays on a long press of Send.
- No Customize key: cmux NEXT has no key-row editor, and a key that does nothing
  is not shipped.
