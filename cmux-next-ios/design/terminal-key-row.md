# Terminal key row: on demand, classic size, silent

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

Classic's size: a 28 pt row, glyph keys 32 pt wide, word keys hugging their label with 6 pt each side,
4 pt apart; glyph 13 pt, label 14 pt; joystick circle 28 pt (travel 14).

#53325 made the keys 44 x 44 pt (Apple's minimum hit target), glyph 17 pt, label 16 pt, joystick 44 pt.
Leo, 2026-11-25: "Did I make the iOS icons in terminal bigger or did aziz? Do we have to make them that big
so App Store gets approved?" and then "We can just bring it back to what the older size was". 44 pt is the
Human Interface Guidelines' recommended minimum, not an App Review rule; the system keyboard's own keys are
smaller. The row is back at 28 pt; the rest of #53325 (on demand, no haptics) stays.

## One touch, one control

Leo, 2026-11-25: "When I tap the composer at certain points it treats it as if I also simultaneously tapped
one of the combo buttons which needs to be fixed". A key's hit area is its own cap, inside the row's 28 pt:
nothing of the row takes a touch below its bottom edge, and the 8 pt gap and the composer card below it are
never a key's. `TerminalComposerTapBleedUITests` taps the card's top edge and the gap under every key and
the joystick, with the draft empty, one line, nine lines and with attachments, and fails if any key fires;
a tap in the middle of Esc must fire it (the positive control).

What it found (2026-11-25, fleet simulator, iPhone 17 Pro): no simulator tap on the card's edge or in the gap
fires a key, at 44 pt or at 28 pt: the views do not overlap, and the 8 pt gap between the row and the card
takes no control. A simulator tap is an exact point; a finger's is not (unverified on a phone: the likely
cause is the touch point a finger reports landing in the row just above the card). If the phone still shows
it at 28 pt, the next step is to give the gap to the composer (`TerminalBottomStack.hitTest`), so a touch
between the row and the card focuses the field instead of nothing.

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

All three keep the same targets; they differ in what is drawn.

- **caps** (default): each key its own glass cap. Clearest targets.
- **strip**: one glass bar behind the row, keys drawn bare (glass only on an armed modifier). Quietest.
- **inset**: glass caps 2 pt smaller each side than their targets. Lighter look, same hit area.

The layout variants (`KeyBarLayout` A/B/C, where the arrows and agents sit) are unchanged and still in the
gallery.

## Haptics, app wide

Every haptic goes through a gate that defaults to off (`CmuxMobileHaptics`, `MobileHapticFeedback`,
`ConversationHaptics`, `ScreenKitHaptics`). No raw `UIFeedbackGenerator`, `.sensoryFeedback`,
`AudioServicesPlaySystemSound` or `playInputClick` call sits outside those files; `haptics-audit.md`
lists every site.
