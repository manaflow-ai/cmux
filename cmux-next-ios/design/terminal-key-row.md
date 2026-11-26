# Terminal key row: on demand, 44 pt, silent

Leo, 2026-11-23: "the buttons atop the composer in the terminal warrant a redesign. why are those things
always showing? ... and the buttons are really small. and idk why the buttons are the way that they are.
and why, if ive set my built in keyboard to not have noise, do those buttons have the haptic feedback
noise? dont do that. ive turned off all haptics already, so dont inject haptic noise when i havent asked
for it. ever."

## His two questions

- **Why always showing.** `KeyBarClipping.swift` (`TerminalDockVisibility.showsKeyRow`) was
  `!chromeHidden`: a port of classic cmux's accessory dock, which kept the row up with the keyboard down
  so the keys worked without typing. Now it is `!chromeHidden && softKeyboard == .shown`: the row comes
  with the software keyboard, like the system's own accessory rows, and stays away with a hardware
  keyboard (it has Esc, Ctrl and the arrows). The PTY's resting height never counts the row, so the
  terminal keeps its rows when the keyboard comes and goes.
- **Why the haptic noise.** `TerminalKeyBar.swift` fired `.sensoryFeedback(.impact(...), trigger: taps)`
  on every key with no gate, and `Joystick.swift` fired a raw `UIImpactFeedbackGenerator` per arrow. A raw
  generator ignores the keyboard's Keyboard Feedback switch (no app can read that switch). Both are gone.
  The "Key clicks" setting stays (nothing he named removes it) but defaults to off and plays only the
  system key click sound when turned on.

## Size

Key target 28 x 32 pt before, 44 x 44 pt now (Apple's minimum hit target). Glyph 13 to 17 pt, label 14 to
16 pt, joystick circle 28 to 44 pt (travel 14 to 22).

## Every key kept, and why

No key is removed: Leo named the size, the visibility and the noise, not the set.

| Key | Why it stays |
| --- | --- |
| Joystick (pinned) | Arrow keys by drag: TUIs, shell history, cursor moves with no arrow keys on iOS. |
| Text field toggle (pinned) | Opens or closes the composer without reaching up. |
| Keyboard (pinned) | Hides the keyboard, which now also folds the row. |
| ⌃ ⌥ ⌘ ⇧ | Sticky modifiers: the iOS keyboard has none, and every terminal chord needs one. |
| Paste | One tap, no long press menu over a terminal that eats long presses. |
| Tab, Esc | Completion and vim/TUI escape: not on the iOS keyboard. |
| ⏎, ^C, ^D | Return without the composer, interrupt, end of input: the three most used terminal keys. |
| ↑ ↓ ← → | Precise single steps where the joystick overshoots. |
| Claude, Codex, Ollama | Classic's agent launchers: start an agent in one tap. |
| Clear (^L), ^Z | Clear the screen; suspend a job. |
| ~ $ / @ \| | Shell symbols two keyboard pages deep on iOS. |
| Home, End, PgUp, PgDn | Pagers and editors; no iOS equivalent. |
| Zoom out, Zoom in | Font size without opening Settings. |
| Hide Toolbar | Hides the row, composer and keyboard for a full screen terminal. |

## Variants (`KeyBarStyle`, gallery `-cmux-mobile-recovery-gallery keybar`)

All three keep 44 pt targets; they differ in what is drawn.

- **caps** (default): each key its own 44 pt glass cap. Clearest targets.
- **strip**: one glass bar behind the row, keys drawn bare (glass only on an armed modifier). Quietest.
- **inset**: 36 pt glass caps inside 44 pt targets. Lighter look, same hit area.

The layout variants (`KeyBarLayout` A/B/C, where the arrows and agents sit) are unchanged and still in the
gallery.

## Haptics, app wide

Every haptic goes through a gate that defaults to off (`CmuxMobileHaptics`, `MobileHapticFeedback`,
`ConversationHaptics`, `ScreenKitHaptics`). No raw `UIFeedbackGenerator`, `.sensoryFeedback`,
`AudioServicesPlaySystemSound` or `playInputClick` call sits outside those files; `haptics-audit.md`
lists every site.
