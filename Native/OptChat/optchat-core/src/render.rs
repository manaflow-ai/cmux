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
    /// The view's parts, one per line, oldest first: the tree node each line
    /// shows. With the stored node texts they give `text` back
    /// (`render_parts`), so a host can record a turn's view by its parts.
    pub parts: Vec<NodeId>,
}

fn flatten(text: &str) -> String {
    text.replace('\n', " ")
}

/// `<chat>`, one `id+n|text` line per part (newlines shown as spaces), `</chat>`.
pub fn render_view(memory: &Memory, store: &dyn Store) -> RenderedView {
    render_parts(memory.view(), store)
}

/// The view whose parts are `parts`, rendered as `render_view` does: a past
/// view (a turn's, recorded by its parts) comes back byte for byte, since
/// nodes are never rewritten.
pub fn render_parts(parts: &[NodeId], store: &dyn Store) -> RenderedView {
    let mut text = String::from("<chat>\n");
    for part in parts {
        text.push_str(&view_line(*part, store.node(*part).as_deref()));
        text.push('\n');
    }
    text.push_str("</chat>");
    let marks = cache_marks(&text);
    RenderedView {
        text,
        marks,
        parts: parts.to_vec(),
    }
}

/// One view line, `id+n|text` (newlines shown as spaces); an unbuilt part
/// shows the placeholder.
pub fn view_line(part: NodeId, body: Option<&str>) -> String {
    format!("{}|{}", part.name(), flatten(body.unwrap_or(PLACEHOLDER)))
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

/// Lines per cache block (spec 3.3, gist 3c190e0): the view goes in blocks
/// of 4 lines; one cache mark sits on the last whole block and one on the
/// request's end. Anthropic stores entries only at marks and looks back up to
/// 20 blocks from a mark for an earlier one, so the next call finds this
/// mark and pays only for the lines after it.
pub const BLOCK_LINES: usize = 4;

/// Byte offsets in `text` (a rendered view: `<chat>`, one line per part,
/// `</chat>`) just after every `BLOCK_LINES` lines of the view: after the
/// header line and lines 4, 8, 12, ... A cut depends only on the bytes
/// before it, so an unchanged prefix keeps its cuts from call to call.
pub fn block_cuts(text: &str) -> Vec<usize> {
    let mut cuts = Vec::new();
    let mut lines = 0usize;
    for (byte, ch) in text.char_indices() {
        if ch == '\n' {
            // The first newline ends the `<chat>` header.
            if lines > 0 && lines.is_multiple_of(BLOCK_LINES) && byte + 1 < text.len() {
                cuts.push(byte + 1);
            }
            lines += 1;
        }
    }
    cuts
}

/// `text` cut at its `block_cuts`: every piece but the last is a whole
/// block (the first with the header), the last holds the rest and the
/// closing tag. The mark goes on the second to last piece, when there is one.
pub fn block_pieces(text: &str) -> Vec<&str> {
    let mut pieces = Vec::new();
    let mut start = 0;
    for cut in block_cuts(text) {
        pieces.push(&text[start..cut]);
        start = cut;
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
