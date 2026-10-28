# Keyboard pin: Chief and terminal composers on iOS 26 and 27

Branch `feat-cmux-next-ios-keyboard-pin`, 2026-10-28. The composer must stay
right above the keyboard through show and hide, interactive dismissal,
rotation, a hardware keyboard, iPad keyboards and content scrolling, in Chief's
conversation and the terminal, on iOS 26 and iOS 27. Earlier work on the agent
chat's dock is in `keyboard.md`.

## What was wrong

Measured on iPhone 17 Pro simulators (iOS 26.5 and 27.0) and iPad Air 11-inch
(M4) simulators running the iPhone app in compatibility mode (iOS 26.5 and
27.0), with the base build plus this branch's trace (`640939107c0f`).

| Case | iOS 26.5 | iOS 27.0 |
| --- | --- | --- |
| Chief: tap the composer | Pinned, 15.7 pt above the keyboard | The keyboard covered the composer by 300 pt on every show; it stayed at its resting place |
| Terminal: tap the composer | Pinned, 14 pt above the keyboard | Pinned on the first show; after a device rotation the keyboard covered the key row and the composer by 205 pt |
| Interactive dismissal | Composer follows the finger | Once in the state above, the keyboard slid with the finger while the composer held (a gap of about 157 pt), then dropped on release |
| iPhone app on iPad | The iPhone keyboard inside the app's window; pinned | The iPad's own keyboard across the iPad's screen; Chief's and the terminal's composers were covered (321 and 217 pt) |

Cause, from the per-frame trace:

- On iOS 27.0 with a hardware keyboard attached (the simulator always reports
  one), `UIKeyboardLayoutGuide` can read a full-width keyboard at the bottom as
  undocked: it sits at the view's bottom with zero height. Both composers were
  pinned to it. In the terminal a rotation flipped the guide into that state
  with no keyboard notification at all. In that state UIKit still moves the
  keyboard with the finger during an interactive dismissal, but neither the
  guide nor the keyboard's placeholder view reports it.
- An iPhone app on an iPad running iOS 27.0 sees a 375 x 667 screen, but its
  keyboard notifications carry the iPad keyboard in iPad points
  (`0, 881, 820 x 299` on an 820 x 1180 iPad). The app's window fills the
  iPad's height, so the keyboard's top in the app is 881 x 667 / 1180 = 498 pt.

## The fix

`MobileKeyboardDock` (CmuxMobileSupport) owns where a composer docks: a layout
guide whose top edge is the docked keyboard's top edge, or the resting line.

- Shows, hides and frame changes come from the keyboard's notified frame,
  applied inside the keyboard's own animation, so the composer rides its curve.
  Only a keyboard that reaches the view's bottom edge counts, so a floating or
  split keyboard leaves the composer at rest.
- During an interactive dismissal the guide follows UIKit's keyboard layout
  guide, which tracks the finger frame by frame, when that guide agreed with
  the keyboard as the drag began. Otherwise the finger places it: the keyboard's
  top is the finger plus the guide's `keyboardDismissPadding`, which is where
  UIKit draws it.
- A release holds the dragged position until UIKit's notification animates the
  rest (or, for a dismissal the finger called off, until the keyboard settles).
- A notified frame wider than the app's screen (the iPad keyboard of an iPhone
  app) is scaled to the app's points.

Chief's conversation, its reply thread, edit overlay, apps menu and New
Message, and the terminal's bottom stack, hang from the dock's guide.

## How it was measured

- `-cmux-mobile-kbd-pin-trace` (DEBUG) writes one line per display frame to
  `Documents/kbd-pin-trace.txt`: the keyboard as drawn (its placeholder), the
  focused composer field, the system keyboard layout guide (`kg`), the dock's
  guide (`dg`), the content's bottom edge, and one line per keyboard
  notification. A 1 pt label (`debug.kbd-pin`) carries the latest line for UI
  tests.
- `verify/record-keyboard-pin.sh <udid> <dir> <label> <demo> [steps]` drives a
  composer with real touches (AXe): show, swipe, slow drag, fling, a dismissal
  called off, a hardware key. It records the screen, takes a screenshot after
  each step settles, and runs `verify/scripts/kbd_pin_trace.py`.
- `UITests/ComposerKeyboardPinUITests.swift` (Chief, terminal) checks the
  settled pin after a show, an interactive dismissal, a second show, a
  rotation and back, and on iPad a pinch on the keyboard.
- Builds: Debug, Xcode 26.6 and Xcode 27.0, on aws-m4pro-2 (iOS 27.0 runtime
  installed there for this work). Runs one simulator at a time.

Placeholder caveats, both seen in recordings: UIKit does not move the keyboard
placeholder during an interactive dismissal (so the analyzer reads the keyboard
from `kg` there), and in an iPhone app on an iPad with iOS 27 the placeholder
keeps the iPhone keyboard's size (so the gap there is checked from simulator
screenshots).

## Results

RESULTS

## Open items

OPEN
