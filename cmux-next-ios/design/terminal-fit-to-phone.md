# iOS terminal: fit to the phone, never resize the Mac for it

Status: design, 2026-11-25. It replaces the "projection default, Fit to Phone one tap away" split in
`cmuxterm-hq` `docs/design/ios-terminal-projection.md` and `decisions/junctions.md` (2026-11-21).

Leo, 2026-11-25, on Claude Code on his phone:

> "Well like... but we know what a Mac's Claude code pane looks like. And we know it/can know it for any
> variation/combination at various phone sizes. Isn't the tradeoff there that you either deal with slow, wholly
> synchronous with Mac screen or you just... do everything at parity on the phone? So do the latter"

> "No, you obviously fit to phone by default? But im just saying like... why would the Mac on an iPhone connection
> ALWAYS be resized down anyways!?"

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
