# iPhone key row: launchers and keyboard hiding (debate, HOLD, not for merge)

Leo, 2026-11-22 ~17:02Z: "what the hell? THOSE are what the ios buttons do????? and THEY ARE THE ONES IN FRONT OF
THE ARROW BUTTONS!? surely we can think of more ergonomic ways to do things...? just debate this for a while, hold
and present... there's likewise the whole situation around the hiding of the built in keyboard."

## What is there today (code facts)

- Default order: `⌃ ⌥ ⌘ ⇧ Paste Tab Esc | ⏎ ^C ^D | ↑ ↓ ← → | Claude Codex Ollama | Clear ~ $ / @ | ^Z Home End
  PgUp PgDn | zoom− zoom+ HideToolbar` (KeyBarKey.swift:164, 202-213). Claude sits 4 pt from →.
- Keys are 28 pt tall, 32 pt wide, 4 pt apart (KeyBarClipping.swift:125-127): below the HIG's 44 x 44 pt minimum.
- A launcher types the command and sends Return with no confirmation (TerminalModel.swift:798-801). Claude and
  Codex send Return; Ollama does not (KeyBarKey.swift:236-242). One stray thumb on → runs
  `claude --dangerously-skip-permissions` in whatever directory the pane is in.
- Three ways to hide things: the pinned keyboard toggle (TerminalKeyBar.swift:161-179), a nav-bar toggle
  (TerminalScreen.swift:39-45), and `.hideChrome` as the last key of the scroller (TerminalModel.swift:840-846).

## What the others do (sources)

- HIG Buttons: "hit region of at least 44x44 pt". HIG Accessibility: "about 12 points of padding around elements
  that include a bezel". HIG Virtual keyboards: custom keys should be "relevant to the current task".
- Termius: snippets live in their own panel, not the key row; "Tap a snippet and it will be run immediately", and
  long-press → Paste inserts without running.
- Blink: Smart Keys are fixed modifiers, arrows and Esc; no command buttons (discussion #2194).
- Prompt (Panic): 16 customizable keys; clips reached through a separate button in the bar.
- a-Shell: toolbar set by `config -t` / `.toolbarDefinition`; commands are user-defined.
- iSH: fixed Tab, Ctrl, Esc and arrows (wiki User-Interface).
- None of the surveyed apps puts a command that runs on one tap into the key row, beside the arrows.

## Three positions

| | A: keys only | B: safe launchers (recommended) | C: context decides |
|---|---|---|---|
| Launchers | Leave the row for the composer's + menu ("Run…") and a long-press on new tab | Stay in the row, but last, after a hairline separator, tinted with a `›_` glyph | A chip strip shows only at an idle shell prompt; gone while a program or TUI runs |
| One tap | Inserts into the draft; Send confirms | Inserts the command, **no Return**; long-press offers Run now / Edit | Inserts; the chip turns into "Run ⏎" |
| Next to the arrows | Nothing but keys | Nothing but keys | Nothing: key slots never move |
| Hit size | 44 pt hit shapes | 44 pt hits, 6 pt spacing | 44 pt; chip strip 36 pt tall |
| Keyboard hiding | One control: tap toggles the keyboard, long-press "Hide toolbar too" | Keyboard key moves to the trailing edge; the other two stay | A grabber appears when the chrome is hidden |
| Setting | none | Settings → Key Row → Launchers, per-launcher "Send Return" (off by default); Ollama off by default | none |
| Weakness | Launchers take two taps to reach | Still one row of things to scroll | `isTUI` only knows the alternate screen and `programName` is fragile, so chips can appear at the wrong time |

## Recommendation: B, with A's single keyboard control

- The accident Leo hit has two causes: the launcher sits next to →, and one tap sends Return. B removes both while
  keeping the launchers one tap away for the people who use them. The no-Return default is what Termius does
  with paste, and nothing surveyed runs on a tap from the key row.
- 44 pt hits fix the near-miss class for every key, not just the launchers (HIG).
- Keyboard hiding: one control that toggles the keyboard, with "Hide toolbar too" on long-press, instead of three.
  Removing `.hideChrome` from the scroller removes a component, so it needs Leo's OK.
- A is the fallback if Leo wants the row to be keys only. C is the most ambitious, but its context detection is not
  reliable enough today.

## Gallery

Mocks for A, B and C (and C's three sub-variants: chips above the row, chips in place of the scroller, chips in the
empty composer) build on hold branches through `KeyBarGallery`. Shots wait on a fleet simulator run, since the
controller isn't reachable from this VM.
