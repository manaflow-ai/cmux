//! "N new messages" where the new part of a chat starts when you return to it, and the return
//! opens there, as the GUI chat's New line does (cmux#51709, #49657, #51029, #51773, #52469,
//! #55461, #56110). Leo, 2026-11-24: "in terminals and guis alike perhaps terminal simply needs to
//! also have the fixes and enhancements".
//!
//! - Leaving a chat notes how many items it held; returning to it with more marks the first new
//!   one. The line stays until another chat is selected.
//! - A running turn's own rows are not new (#55461; Leo, 2026-11-25: "dont mark it as new if it's
//!   still going"): the new part ends where that turn's prompt starts, and a return whose news is
//!   all that turn draws no line.
//! - The line takes no height (#49657): it is drawn over the blank row the transcript already
//!   leaves before the first new block, so nothing below moves and the layout cache stays valid.
//! - A return lands at it when the news runs past one screen (#51709).

use acpmux::transcript::{Item, Transcript};

/// The line of the chat on screen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewLine {
    pub session: String,
    /// The first new item.
    pub item: usize,
    /// The messages (your prompts and the agent's replies) in the new part.
    pub messages: usize,
    /// Whether the return has landed at it already.
    pub landed: bool,
}

impl NewLine {
    /// The line for a return to `session` that held `seen` items when it was left, or None when
    /// nothing new arrived outside a running turn.
    pub fn on_return(session: &str, t: &Transcript, seen: usize) -> Option<Self> {
        let end = if t.status == "running" {
            t.items
                .iter()
                .rposition(|i| matches!(i, Item::User { queued: false, .. }))
                .unwrap_or(t.items.len())
        } else {
            t.items.len()
        };
        if end <= seen {
            return None;
        }
        let messages = t
            .items
            .get(seen..end)
            .unwrap_or_default()
            .iter()
            .filter(|i| matches!(i, Item::User { .. } | Item::Assistant { .. }))
            .count();
        Some(Self { session: session.to_owned(), item: seen, messages, landed: false })
    }

    /// Older history was put in front of the chat: its items moved down by `added`.
    pub fn shift(&mut self, session: &str, added: usize) {
        if self.session == session {
            self.item += added;
        }
    }

    pub fn label(&self) -> String {
        match self.messages {
            0 => "New".to_owned(),
            1 => "1 new message".to_owned(),
            n => format!("{n} new messages"),
        }
    }
}

/// The row the line is drawn on: the blank row before the first row of item `from` or later, or
/// None when no blank row is there to take (a line never adds height).
pub fn row(rows: &[(usize, &str)], from: usize) -> Option<usize> {
    let first = rows.iter().position(|(item, _)| *item >= from)?;
    if first == 0 {
        return None;
    }
    [first, first - 1]
        .into_iter()
        .find(|&r| rows.get(r).is_some_and(|(_, text)| text.trim().is_empty()))
}

/// The offset a return lands at: the line's row at the top when what follows it runs past one
/// screen, else None (the latest rows already show it).
pub fn landing(row: usize, total: usize, visible: usize) -> Option<usize> {
    (total.saturating_sub(row) > visible).then_some(row)
}

/// The line's text centered in `width`: "──── 3 new messages ────".
pub fn rule(label: &str, width: usize) -> String {
    use unicode_width::UnicodeWidthStr;
    let tag = format!(" {label} ");
    let side = width.saturating_sub(tag.width()) / 2;
    if side == 0 {
        return label.to_owned();
    }
    let right = width.saturating_sub(tag.width() + side);
    format!("{}{tag}{}", "─".repeat(side), "─".repeat(right))
}

#[cfg(test)]
#[path = "new_line_tests.rs"]
mod tests;
