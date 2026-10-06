use std::fmt;

use crate::memory::{Memory, Store};
use crate::node::NodeId;
use crate::{MARKS, PLACEHOLDER};

/// The view as the agent reads it (section 5.1), with the cache cut points.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RenderedView {
    pub text: String,
    /// Byte offsets into `text` where a cached piece ends: the last line end
    /// before each of `MARKS` characters; marks past the end are skipped (section 8).
    pub marks: Vec<usize>,
}

fn flatten(text: &str) -> String {
    text.replace('\n', " ")
}

/// `<chat>`, one `id+n|text` line per part (newlines shown as spaces), `</chat>`.
pub fn render_view(memory: &Memory, store: &dyn Store) -> RenderedView {
    let mut text = String::from("<chat>\n");
    for part in memory.view() {
        let body = store.node(*part).unwrap_or_else(|| PLACEHOLDER.to_string());
        text.push_str(&format!("{}|{}\n", part.name(), flatten(&body)));
    }
    text.push_str("</chat>");
    let marks = cache_marks(&text);
    RenderedView { text, marks }
}

/// Where to cut `text` into cached pieces (section 8): byte offsets just after
/// the last line end at or before each of `MARKS` characters; a mark at or
/// past the end of the text is skipped, and a cut is never repeated. The view
/// and the compactor's `<chat>` context are cut by the same rule, so a later
/// request reads the longest piece that is still byte-identical.
pub fn cache_marks(text: &str) -> Vec<usize> {
    let total = text.chars().count();
    let mut marks = Vec::new();
    let mut last_end: Option<usize> = None;
    let mut pending = MARKS.iter().copied().filter(|m| *m < total).peekable();
    // `chars` characters come before the one at `byte`.
    for (chars, (byte, ch)) in text.char_indices().enumerate() {
        // Every mark this character would cross takes the line end before it.
        while let Some(&mark) = pending.peek() {
            if chars < mark {
                break;
            }
            if let Some(end) = last_end.filter(|end| marks.last() != Some(end)) {
                marks.push(end);
            }
            pending.next();
        }
        if pending.peek().is_none() {
            break;
        }
        if ch == '\n' {
            last_end = Some(byte + 1);
        }
    }
    marks
}

/// `text` cut at its `cache_marks`: up to four pieces that join back into it.
/// Each piece but the last ends at a mark, so it can carry a cache breakpoint.
pub fn cache_pieces(text: &str) -> Vec<&str> {
    let mut pieces = Vec::new();
    let mut start = 0;
    for mark in cache_marks(text) {
        pieces.push(&text[start..mark]);
        start = mark;
    }
    pieces.push(&text[start..]);
    pieces
}

/// Why `zoom` refused.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ZoomError {
    pub id: u64,
    pub n: u64,
}

impl fmt::Display for ZoomError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "No line {}+{}.", self.id, self.n)
    }
}

/// `zoom(id, n)` (section 7.1): the two lines of n/2 under line `id+n`, or
/// message `id` whole (newlines kept) when `n` is 1.
pub fn zoom(memory: &Memory, store: &dyn Store, id: u64, n: u64) -> Result<String, ZoomError> {
    let err = ZoomError { id, n };
    let node = NodeId::from_name(id, n).ok_or(err.clone())?;
    // Checked: `id + n` past u64::MAX must not wrap into a small, valid end.
    if node.checked_end().is_none_or(|end| end > memory.len()) {
        return Err(err);
    }
    let Some((a, b)) = node.children() else {
        let (kind, text) = store.message(id);
        return Ok(format!("{id}+0|{}: {text}", kind.as_str()));
    };
    let line = |c: NodeId| {
        format!(
            "{}|{}",
            c.name(),
            flatten(&store.node(c).unwrap_or_else(|| PLACEHOLDER.to_string()))
        )
    };
    Ok(format!("{}\n{}", line(a), line(b)))
}
