# iOS terminal: fit to the phone, never resize the Mac for it

Status: design, 2026-11-25. It replaces the "projection default, Fit to Phone one tap away" split in
`cmuxterm-hq` `docs/design/ios-terminal-projection.md` and `decisions/junctions.md` (2026-11-21).

Leo, 2026-11-25, on Claude Code on his phone:

> "Well like... but we know what a Mac's Claude code pane looks like. And we know it/can know it for any
> variation/combination at various phone sizes. Isn't the tradeoff there that you either deal with slow, wholly
> synchronous with Mac screen or you just... do everything at parity on the phone? So do the latter"

> "No, you obviously fit to phone by default? But im just saying like... why would the Mac on an iPhone connection
> ALWAYS be resized down anyways!?"

> "Aziz warned me about this approach I pushed for iOS which evidently does indeed break things for now comparatively
> but I feel like it's the only way to have snappy terminals aka not having to wait on sluggish ass screen data sync
> stuff but I think we should be able to get best of both worlds correctness and speed"

## Correctness and speed: local-first render, host authority

- **Local-first.** The phone draws at once from its own model: the agent renderer, local reflow, and predictive echo
  for typing. A keystroke or a resize never waits on a round trip.
- **Host authority.** The host's state is the truth. It sends versioned diffs of only what changed (the hybrid
  stream's shape: `stream`, frame numbers, `base`). The phone checks each frame it drew against them, as Mosh's state
  sync does. A mismatch is corrected within one round trip and counted.
  - For an agent CLI drawn at the phone's width, there is no phone-width screen on the host to diff against, because
    the CLI draws only at its PTY's size. The host's authority is therefore its **state**, not its cells: the records,
    plus the facts the records lack (spinner verb, timer, tokens, permission dialog and its options, menus,
    notices). The host reads those facts from its own screen and sends them as versioned records. The phone renders
    records and facts at its own width.
  - Records alone reach 77% (live) and 84% (seeded) of cells (cmux#43265). The gap is that missing state, not layout,
    and the facts close it.
- **Correctness gates.** These parity harnesses run in CI and block a merge:
  - agent render at phone widths;
  - projection, cell by cell, covering wide characters, emoji, colours, full-screen programs and scrollback.
- **A live counter of mismatches** goes in the app's terminal diagnostics. It counts host corrections of a drawn
  frame, and moments drawn through a fallback. Drift then shows in Leo's own use, not only in tests.

## Aziz's warnings (cmux#42219, 2026-11-13), each with its test

| # | Aziz | Test |
| --- | --- | --- |
| 1 | Claude Code and Codex hard-wrap at the PTY's width, so reflow turns 120-column lines into 54+54+12 fragments | To add: the agent parity harness at phone widths (`cmux-agent-cli-render` `tests/parity.rs`, per width). The agent path never reflows the Mac's cells |
| 2 | Rules, boxes, right prompts, `ls` columns, tables and diffs are laid out for the Mac's width | `cmux-terminal-projection` `golden.rs` `headers_claude_code`, `headers_codex`, `left_and_right_aligned`, `compaction_keeps_every_glyph`; `projection.rs` `claude_codes_bare_rules_are_one_phone_row_each_at_the_macs_width` (cmux#56689). To add: `ls` columns, a table, a diff |
| 3 | Full-screen apps show a Mac-grid frame before the resize lands | `TerminalProjectionResizeHarnessTests.theAlternateScreenIsShownAtTheMacsGridAndTypingFitsOnce` ("before any frame of it at the Mac's grid"). To add: the alt-screen rule's tests (part 3) |
| 4 | A second VT emulator must match Ghostty's | `cmux-terminal-projection` `tests/parity.rs`: Ghostty's VT core is the oracle, per corpus, phone width and chunking |
| 5 | Mouse positions on the primary screen are not mapped back to host cells | Wheel: `held_rows.rs` `a_mouse_mode_app_with_nothing_held_gets_every_wheel_event`. To add: a click on the primary screen lands on the host cell (`Projection::locate`) |
| 6 | Memory: one host-grid model per warm terminal (~100 MB at 100k rows) | To add: a bound on `footprint()` per warm terminal at the history limit |

## Rule

Every terminal on the phone fits the phone's width by default. A phone attaching never resizes the Mac pane by
itself. How a terminal fits depends on what runs in it:

| What runs | How the phone fits it | Mac PTY resized? |
| --- | --- | --- |
| Claude Code, Codex (agent CLIs) | Drawn on the phone at the phone's grid, at parity with how the CLI draws a pane that size | Never |
| A shell, scrollback, any primary-screen program | Reflowed on the phone at its width, from the cells and their soft-wrap flags (projection, compact) | Never |
| A full-screen program (alternate screen: vim, htop, less) | While the Mac is not showing that pane: the PTY takes the phone's grid. While the Mac shows it: the Mac's grid, scaled on the phone | Only while the Mac does not show it |

The old "Fit to Phone" action (claim the PTY at the phone's size) becomes an override for an odd program. It is no
longer the way anything looks right.

## 1. Agent CLIs: parity rendering on the phone

The phone draws Claude Code's screen itself at its own grid, the way Claude Code would draw a pane of that size. It
does not mirror the Mac's cells, and it does not reflow them.

**Where it lives.** It lives in `cmux-tui/crates/cmux-agent-cli-render` (Rust; Leo 2026-11-14 started it). The crate's
`claude::render(records, chrome, cols, rows) -> Grid` already draws Claude Code 2.1.310 from acpmux records. The phone
gets the grid through the same FFI as the hybrid stream's frames. Swift only draws the grid it is given, as
`.github/language-boundaries.toml` requires.

**What it reads.**

- The session's acpmux records: prompts, answer text, tool calls with input and result, and turn state. A seeded chat
  carries tool calls; live View Only records carry only text today, and that gap is the first one to close.
- `Chrome`: facts the records lack, as the session reports them. These are the version, model, permission mode,
  effort, the person's draft, the spinner's verb, its timer and tokens, and permission prompts. Agent hooks and ACP
  events already carry most of them; each one that is missing gets a record kind, never a Mac cell.
- The phone's grid (cols and rows) and the terminal theme. The CLI's colours are authored (256-colour and RGB) and
  resolved by the phone's theme, as a PTY's are.

**Which sizes.** The column and row counts the app computes for every supported iPhone, in portrait and landscape,
at the default font size and the largest and smallest it offers. The harness derives the list from the same grid
code the app uses, so a new phone or font size adds a row and does not need a code change.

**The parity harness.** For each width, the same scripted session is recorded twice on a fleet Mac:

- the real Claude Code in a PTY of exactly that grid. Its bytes go through ghostty-vt, which is the reference screen;
- the acpmux records of the same moments.

`tests/parity.rs` compares `claude::render` at that grid with the reference, cell by cell (`Cell::looks_same`), for
every scripted moment. The gate is per width and per moment, and it never averages. Fixtures are recorded with
`claude` at a pinned version. Moving to a new Claude Code version means recording again, and the diff names each
row that changed. A visual check (simulator screenshot against the reference rendered by the same Ghostty) runs on
top of the cell test, not instead of it.

**Until parity holds for a moment kind** (a dialog or menu the records cannot describe yet), the phone shows that
moment through projection. That is the shell row of the table: reflowed, never with the Mac resized. Each fallback is
counted, so the gap list is measured, not guessed.

**Codex** follows the same shape (`codex::render`, its own fixtures) after Claude Code.

## 2. Shells and scrollback: client-side reflow

This already exists: `cmux-terminal-projection` re-wraps logical lines at the phone's width. Rows a program laid out
by the host's width (rules, boxes, right prompts) are laid out at the phone's width (`compact_anchored`). The work
left is the parity gaps its harness finds. The pre-attach seed is cut at the phone's columns (cmux#56689).

## 3. Full-screen programs: resize only while the Mac is not looking

A full-screen program cannot be reflowed. The phone takes the PTY's size only while no Mac view of that pane counts:

- **It counts** when it is on screen in a window that is not minimised or hidden, and the Mac is not idle.
- **The moment a Mac view counts again** (shown, focused, or the person types), the size goes back to the Mac's,
  and the phone shows the Mac's grid scaled.
- **When the phone leaves** the pane, the Mac's size is restored at once.

This is the sizing engine's `counts` rule (`docs/shared-terminal-sizing.md`) with two changes: a phone counts only
for the alternate screen, and a Mac view counts only while it is shown.

## Order of work

1. Agents. Record Claude Code fixtures at phone grids, extend `tests/parity.rs` per width, and fix `claude::render`
   until each width holds. Then turn it on for Claude Code sessions on the phone.
2. Shell reflow gaps from the projection parity harness.
3. The alternate-screen rule in the sizing engine, with tests for shown, hidden, idle, and the phone leaving.
