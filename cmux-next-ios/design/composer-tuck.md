# Tucking the harness's status rows and the key row while composing

Leo, 2026-11-23: "honestly, better ways/heuristics of auto-tucking swathes of the coding harness
tui and the weird little action buttons above the composer is a worthwhile endeavour too."

## The rule

- **In use:** the composer has focus, or it holds a draft while the terminal does not have focus.
- **What tucks while it is in use:**
  - The key row over the keyboard.
  - The rows at the bottom of a coding harness's screen that only repeat what the composer already shows:
    - the harness's own input box (its rules and its empty `❯`/`›` line);
    - its footer hints (`? for shortcuts`, the permission mode, the model and cwd);
    - its live spinner line (`✻ Misting… (4s …)`, `Working (3s · esc to interrupt)`).
- **What never tucks:**
  - The conversation above those rows.
  - A finished turn's record (`✻ Churned for 8s`, `Worked for 1m`).
  - Any screen with a question the person must answer: a permission dialog, a numbered menu, a y/n. The key row comes back for those, with its arrows and Return.
- **What brings everything back:**
  - Putting the composer away.
  - Tapping the terminal. That is how the person asks for the keys.
  - A question from the harness.

The rule is `harness_tuck` in Rust (`cmux-mobile-link-ffi/src/harness_tuck.rs`). The screen's
rows go in as text, and it returns the first row of the bottom block. It knows:

- **Claude Code:** a ruled box with a footer.
- **Codex CLI:** a `›` line with an indented footer, or a status row.
- **opencode:** a `┃` box closed by `╹▀▀`.
- **Boxed harnesses (Gemini, Amp, pi):** a `╭─╮` box.

It is unit tested on real recorded screens.

## Why the conversation does not jump

Swift moves only the page's bottom edge. The scroll view's bottom inset shrinks by the tucked
rows, so the harness's rows slide under the composer and the keyboard. It happens:

- in the same layout pass that the keyboard's (or the dock's) animation drives, so it is one motion;
- while the composer is in use, whenever the harness redraws. When the block grows or shrinks, the content and the tuck change by the same number of rows, so the offset does not change and no row moves.

## Variants (`-cmuxMobileComposerTuck`)

| Variant | Key row | Harness rows | Note |
|---|---|---|---|
| `keys` | tucks | stay | The smallest change. The harness's own box still shows under the phone's composer. |
| `chrome` | stays | tuck | The keys stay over the keyboard while composing; the conversation gets the rows. |
| `both` (ships) | tucks | tuck | What Leo named: both swathes go, and both come back on a tap or a question. |

`both` ships: it is the only variant that does both things the ask names. The screenshots of all
three are attached to `TerminalComposerTuckUITests`.

## Numbers

These are conversation rows gained with the composer focused, from the Rust tests on real 100x32
screens. The gain is the rows the harness's status takes.

| Harness | Working | Done |
|---|---|---|
| Claude Code 2.1.310 | +7 | +5 |
| Codex 0.164.0 | +7 | +6 |
| opencode 1.19.5 | +20 | +7 |

The simulator numbers for each variant are in the UI test's `tuck-numbers` attachment.
