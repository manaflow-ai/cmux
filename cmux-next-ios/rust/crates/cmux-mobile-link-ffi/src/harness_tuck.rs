//! Which rows of a coding harness's screen only repeat status, so the phone can tuck them away
//! while its own composer is in use (Leo, 2026-11-23: "better ways/heuristics of auto-tucking
//! swathes of the coding harness tui and the weird little action buttons above the composer is a
//! worthwhile endeavour too").
//!
//! While the person writes in the phone's composer, the harness's own input box (its rules, its
//! empty `❯`/`›` line), its footer hints (`? for shortcuts`, the permission mode, the model and
//! cwd line) and its live spinner line say nothing the composer does not: they are tuckable. The
//! conversation above them is not. A row a person must answer never is: while a permission
//! question or a selection menu is on screen, nothing tucks ([`HarnessTuck::prompt`]).
//!
//! The rule is one block at the bottom of the screen: every row from [`HarnessTuck::tuck_from`]
//! to the last is chrome or blank. Swift moves only the page's bottom edge to that row, so
//! tucking moves no row of the conversation (the block grows or shrinks below it as the
//! harness redraws). Pure: the screen's rows as text in, a row index out. Unit tested on the
//! screens of real sessions (`cmux-agent-cli-render/tests/fixtures`).

/// A harness the phone knows by its terminal's program name.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TuckHarness {
    /// Claude Code: a ruled input box (`─` rows around `❯`), a footer under it.
    Claude,
    /// Codex CLI: an unruled `›` line, a model and cwd footer under it, a `• Working` line above.
    Codex,
    /// opencode: a `┃` barred box closed by a `╹▀▀` rule, a hint row under it.
    OpenCode,
    /// Gemini CLI, Amp, pi: a boxed (`╭─╮`, `╰─╯`) or ruled input box, a footer under it.
    Boxed,
}

/// What tucks on one screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct HarnessTuck {
    /// The harness the program name names; nil: not a harness (a shell, an editor), nothing tucks.
    pub harness: Option<TuckHarness>,
    /// The first row (0 = the screen's top) of the bottom block that only repeats status; nil:
    /// nothing tucks.
    pub tuck_from: Option<u32>,
    /// A question the person must answer is on screen (a permission dialog, a numbered menu,
    /// a y/n): nothing tucks, and the key row stays up for its arrows and Return.
    pub prompt: bool,
}

/// The harness a terminal's program name (its foreground process, or the agent its hook
/// reported) names.
#[uniffi::export]
pub fn tuck_harness(program: String) -> Option<TuckHarness> {
    let name = program.trim().rsplit('/').next().unwrap_or_default().to_ascii_lowercase();
    match name.as_str() {
        "claude" | "claude-code" | "claude code" => Some(TuckHarness::Claude),
        "codex" | "codex-cli" => Some(TuckHarness::Codex),
        "opencode" => Some(TuckHarness::OpenCode),
        "gemini" | "amp" | "pi" => Some(TuckHarness::Boxed),
        _ => None,
    }
}

/// The tuckable block of `rows` (the screen's rows, top to bottom, as text) drawn by `program`.
#[uniffi::export]
pub fn harness_tuck(program: String, rows: Vec<String>) -> HarnessTuck {
    let harness = tuck_harness(program);
    let Some(kind) = harness else { return HarnessTuck { harness, tuck_from: None, prompt: false } };
    if rows.iter().rev().take(PROMPT_SCAN_ROWS).any(|row| asks_the_person(row)) {
        return HarnessTuck { harness, tuck_from: None, prompt: true };
    }
    let tuck_from = match kind {
        TuckHarness::Claude | TuckHarness::Boxed => boxed(&rows),
        TuckHarness::Codex => codex(&rows),
        TuckHarness::OpenCode => opencode(&rows),
    };
    // A block that would leave no conversation above it is the harness's whole screen (a
    // splash, a picker): tuck nothing.
    let tuck_from = tuck_from.filter(|&from| rows[..from].iter().any(|row| !blank(row)));
    HarnessTuck { harness, tuck_from: tuck_from.map(|from| from as u32), prompt: false }
}

/// How far up from the bottom a question is looked for: a dialog sits at the bottom, and a
/// question in the scrollback above it is already answered.
const PROMPT_SCAN_ROWS: usize = 24;
/// The most rows an input box's draft may span before the block is not read as one.
const MAX_BOX_ROWS: usize = 16;
/// The most rows of footer under a box.
const MAX_FOOTER_ROWS: usize = 3;

fn blank(row: &str) -> bool {
    row.trim().is_empty()
}

/// A row that asks the person something they must answer on the harness's own screen.
fn asks_the_person(row: &str) -> bool {
    let text = row.trim();
    const ASKS: [&str; 12] = [
        "Do you want",
        "Would you like",
        "Permission required",
        "Allow once",
        "Allow always",
        "Press enter to confirm",
        "Esc to cancel",
        "enter confirm",
        "(y/n)",
        "[y/N]",
        "[Y/n]",
        "Waiting for your input",
    ];
    if ASKS.iter().any(|ask| text.contains(ask)) {
        return true;
    }
    // A numbered menu with its selection marker: `❯ 1. Yes`, `› 1. Yes, proceed`, `> 2. No`.
    let mut chars = text.chars();
    if matches!(chars.next(), Some('❯' | '›' | '>' | '▶')) {
        let rest = chars.as_str().trim_start();
        let digits = rest.chars().take_while(char::is_ascii_digit).count();
        return digits > 0 && rest[digits..].starts_with(". ");
    }
    false
}

/// A horizontal rule: mostly line-drawing characters, at least 16 of them (a box's top or
/// bottom edge, `╭───╮` and `╰───╯` included).
fn rule(row: &str) -> bool {
    let text = row.trim();
    let lines = text.chars().filter(|c| matches!(c, '─' | '━' | '═' | '▀' | '▄')).count();
    let total = text.chars().count();
    lines >= 16 && lines * 10 >= total * 8
}

/// The index of the last non-blank row, if any.
fn last_text(rows: &[String]) -> Option<usize> {
    rows.iter().rposition(|row| !blank(row))
}

/// A live status line above an input box: a spinner's verb with its interrupt hint, or Claude
/// Code's `✻ Misting… (4s · ↓ 93 tokens)` (its finished `✻ Churned for 8s` is the turn's record,
/// not status, and stays).
fn live_status(row: &str) -> bool {
    let text = row.trim();
    if text.contains("esc to interrupt")
        || text.contains("esc interrupt")
        || text.contains("ctrl+c to interrupt")
    {
        return true;
    }
    let mut chars = text.chars();
    matches!(chars.next(), Some('✻' | '✶' | '✳' | '✢' | '✽' | '·' | '*')) && chars.as_str().contains("… (")
}

/// The block's top widened by the blank rows and a live status line just above it.
fn with_status_above(rows: &[String], mut from: usize) -> usize {
    let mut i = from;
    while i > 0 && blank(&rows[i - 1]) {
        i -= 1;
    }
    if i > 0 && live_status(&rows[i - 1]) {
        from = i - 1;
    } else if i < from {
        // The blank rows between the conversation and the box go with the box.
        from = i;
    }
    from
}

/// Claude Code, Gemini, Amp, pi: footer rows, a closing rule, the draft, an opening rule.
fn boxed(rows: &[String]) -> Option<usize> {
    let last = last_text(rows)?;
    let close = (last.saturating_sub(MAX_FOOTER_ROWS)..=last).rev().find(|&i| rule(&rows[i]))?;
    let open = (close.saturating_sub(MAX_BOX_ROWS + 1)..close).rev().find(|&i| rule(&rows[i]))?;
    // The draft between the rules: at least one row, none of them a rule.
    if close - open < 2 {
        return None;
    }
    Some(with_status_above(rows, open))
}

/// Codex CLI: the footer (model and cwd, hints, or a live status line), a blank, the `›` line
/// and its wrapped rows, and a rule over it if one is drawn.
fn codex(rows: &[String]) -> Option<usize> {
    let last = last_text(rows)?;
    // The footer: indented rows up to the first blank above them.
    let mut i = last;
    let mut footer = 0;
    while i > 0
        && !blank(&rows[i])
        && (rows[i].starts_with("  ") || live_status(&rows[i]))
        && footer < MAX_FOOTER_ROWS
    {
        footer += 1;
        i -= 1;
    }
    if footer == 0 {
        return None;
    }
    while i > 0 && blank(&rows[i]) {
        i -= 1;
    }
    // The draft: indented continuation rows under the `›` line.
    let mut drafted = 0;
    while i > 0 && rows[i].starts_with("  ") && !blank(&rows[i]) && drafted < MAX_BOX_ROWS {
        drafted += 1;
        i -= 1;
    }
    if !rows[i].starts_with('›') {
        return None;
    }
    // A rule drawn over the `›` line is the box's top.
    if i > 0 && rule(&rows[i - 1]) {
        i -= 1;
    }
    Some(with_status_above(rows, i))
}

/// opencode: the hint row, the `╹▀▀` rule, the `┃` rows of its box above it.
fn opencode(rows: &[String]) -> Option<usize> {
    let last = last_text(rows)?;
    let close = (last.saturating_sub(MAX_FOOTER_ROWS)..=last)
        .rev()
        .find(|&i| rows[i].trim_start().starts_with('╹'))?;
    let mut open = close;
    while open > 0 && rows[open - 1].trim_start().starts_with('┃') && close - open < MAX_BOX_ROWS {
        open -= 1;
    }
    if open == close {
        return None;
    }
    Some(with_status_above(rows, open))
}

#[cfg(test)]
#[path = "harness_tuck_tests.rs"]
mod tests;
