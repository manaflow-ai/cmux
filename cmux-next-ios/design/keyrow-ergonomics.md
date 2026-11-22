# iPhone key row and keyboard hiding: proposal (on hold)

Leo, 2026-11-22 17:03Z:

> "what the hell? THOSE are what the ios buttons do????? and THEY ARE THE ONES IN FRONT OF THE ARROW BUTTONS!?
> surely we can think of more ergonomic ways to do things...? just debate this for a while, hold and present...
> there's likewise the whole situation around the hiding of the built in keyboard."

He asked for a debate to hold and present, not a change. Nothing in this file has shipped. The two fixes
from the same message (swipe down to collapse the composer, and zoom with no layout shift) are in PR
#50843. Every option below that touches the row would be built behind `KeyBarLayout` first. Today's
layout stays the default until Leo picks one.

## What the row does today (measured from the code at `feat-cmux-next` a8153876)

`TerminalKeyBar` puts three keys at the leading edge, before anything else. They stay put while the rest
of the row scrolls under them:

| Pinned key | Glyph | What a tap does |
|---|---|---|
| Keyboard | `keyboard` / `keyboard.chevron.compact.down` | Opens or closes the system keyboard. With the composer shown, opening it focuses the composer; otherwise it focuses the terminal (`TerminalModel.toggleKeyboard`). |
| Joystick | white dot with four arrowheads | Drag for arrow keys. The farther the drag, the faster they repeat (`JoystickEngine`). |
| Compose | `character.textbox` | Shows or hides the text field (`composeKeyTapped`, `ComposerDockState`). Hiding it leaves the keyboard up and typing goes to the terminal. |

Then the scroller (`KeyBarLayout.arrowsBeforeAgents`, Leo 11-21): ⌃ ⌥ ⌘ ⇧ Paste Tab Esc, ⏎ ^C ^D, ↑ ↓ ← →,
Claude Codex Ollama, Clear ~ $ / @ | ^Z Home End PgUp PgDn, Zoom out, Zoom in, Hide toolbar.

What goes wrong:

1. **The three keys you see first are about the view, not the program.** The keyboard and compose keys
   both change the layout, and their glyphs look alike. Neither sends a byte. The keys a terminal needs
   most (Esc, ^C, Tab, the arrows) come after them, or start offscreen.
2. **The arrows appear twice:** the joystick, and ↑ ↓ ← → in the scroller. The pinned joystick sits in
   front of the arrow keys, which is what Leo pointed at.
3. **There are four ways to hide the keyboard,** and each leaves a different state behind:
   - the keyboard key closes it and keeps the text field;
   - the compose key hides the text field and keeps the keyboard;
   - Hide toolbar hides the row, the text field and the keyboard until the next tap on the terminal;
   - the system's own gestures (swipe down on the keyboard, tap the terminal).

   You have to learn which key does what.
4. **The view keys sit at the end of the row** (zoom, hide toolbar): a long scroll for things you use rarely.

## Options

### A. Keys that send bytes come first; view controls move to one place (recommended)

- The pinned edge holds Esc and the joystick. The terminal keys come first: Esc ^C Tab, then the
  modifiers, then the rest.
- The keyboard and compose keys merge into **one pinned key at the trailing edge**, where iOS puts
  "dismiss keyboard". A tap opens or closes the keyboard. A long press opens a menu: Show text field or
  Type into terminal; Hide toolbar; Zoom in, Zoom out.
- The scroller's ↑ ↓ ← → go. The joystick is the arrow input, and its accessibility actions stay.

For: the first thumb position sends Esc. One control decides where your typing goes and how the screen
looks. The row gets about 10 keys shorter.

Against: the compose key's one-tap switch becomes a long press. People who use both often lose a tap.
Removing the arrow keys is a removal, so it needs Leo's word (rulebook: never remove a component unless
he says so).

### B. Keep the pinned keys, but make them say what they do

- Keep the three pinned keys and redraw their glyphs: the keyboard key shows a keyboard with a down
  chevron only while the keyboard is up; the compose key gets a text label ("Text" / "Term"), showing
  where typing goes.
- Move zoom and Hide toolbar into the compose key's long-press menu.

For: the smallest change. Nothing is removed. People who already know the row keep it.

Against: the view keys are still in front of the arrows, which is what Leo objected to.

### C. Use the gestures people already know; drop the view keys

- Keyboard: swipe down on the terminal or the composer closes it. The composer part is in #50843; the
  terminal's half is not checked yet (assumed). A tap on the terminal opens it.
- Text field: swipe up from the key row shows it; swipe down inside it collapses it (#50843).
- Zoom: pinch on the terminal (it already pans, so pinch needs care with the scroll view). The
  magnifier keys go.
- Hide toolbar: a two-finger tap on the terminal.

For: the row holds only keys that send bytes. This is how phone chat composers and the iOS keyboard
already behave.

Against: gestures can't be discovered without a first-run hint. A pinch fights the terminal's own
scroll and text selection. It removes three keys, so it needs Leo's word.

### D. Two rows

The keyboard's own accessory row holds the terminal keys. A second, thinner row above it holds the view
controls. It costs about 28 pt of terminal height and was ruled out for classic for that reason.

## Hiding the system keyboard

Whatever the layout, the rule would be: **one key hides the keyboard and nothing else, and every way of
hiding it leaves the same state behind** (text field shown as it was, terminal focused on the next tap).
Today Hide toolbar also hides the row and the text field. That should be a separate choice (the long-press
menu in A and B), not a third kind of hide.

## Recommendation

A, built as `KeyBarLayout` variant D in the DEBUG gallery next to today's A/B/C, with screenshots of
both in the follow-up PR. Leo decides:

1. Removing the scroller's arrow keys (the joystick stays): yes or no.
2. Merging the keyboard and compose keys into one key with a long-press menu: yes or no.
3. Pinch to zoom in place of the magnifier keys (option C): yes, no, or both.
