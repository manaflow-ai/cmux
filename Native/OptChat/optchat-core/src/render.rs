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
/// An unbuilt imported line is left out, as the reference client's turn
/// view shows built lines only: during an import the view then ends at the
/// build front, and a turn's cached prefix holds from one turn to the next
/// (`zoom` still opens the left-out messages). An unbuilt line of the chat's
/// own side (a stuck node) shows the placeholder.
pub fn render_view(memory: &Memory, store: &dyn Store) -> RenderedView {
    let parts: Vec<NodeId> = memory
        .view()
        .iter()
        .copied()
        .filter(|p| memory.is_built(*p) || !memory.is_imported(p.end() - 1))
        .collect();
    render_parts(&parts, store)
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
/// `</chat>`) just after the `<chat>` header and after every `BLOCK_LINES`
/// lines of the view: after the header and lines 4, 8, 12, ... The header
/// is its own block (the reference client's grid), so a view with no whole
/// block still has one to mark, and every request carries our mark from
/// the first turn (measured 2026-10-08 on the Claude Code path: early turns
/// read 93-94% instead of 86-87%, later turns unchanged). A cut depends
/// only on the bytes before it, so an unchanged prefix keeps its cuts from
/// call to call.
pub fn block_cuts(text: &str) -> Vec<usize> {
    let mut cuts = Vec::new();
    let mut lines = 0usize;
    for (byte, ch) in text.char_indices() {
        if ch == '\n' {
            // The first newline (lines 0) ends the `<chat>` header.
            if lines.is_multiple_of(BLOCK_LINES) && byte + 1 < text.len() {
                cuts.push(byte + 1);
            }
            lines += 1;
        }
    }
    cuts
}

/// Blocks the API looks back from a cache mark for an earlier entry: a mark
/// more than this many blocks past the last request's mark finds nothing,
/// and the request writes the whole prefix again.
pub const LOOKBACK_BLOCKS: usize = 20;

/// How many blocks a turn's mark may move past the last turn's mark: inside
/// `LOOKBACK_BLOCKS`, with room for the blocks Claude Code adds.
pub const MARK_REACH: usize = 16;

/// The piece of `block_pieces(view)` that carries the request's one mark, or
/// None when the text has no block (no header). It is the last whole block
/// (the header while there is none), unless
/// `prev` (the view's text up to and including the last request's marked
/// piece) is still a prefix of `view` ending on a block cut and the last
/// whole block lies more than `MARK_REACH` pieces past it: then the mark
/// goes `MARK_REACH` pieces past it, so this request reads the last one's
/// entry and writes the next one in reach. A turn that adds hundreds of view
/// lines (a long tool run) then costs the new lines once, not the whole view.
pub fn mark_piece(view: &str, prev: Option<&str>) -> Option<usize> {
    let pieces = block_pieces(view);
    let last = pieces.len().checked_sub(2)?;
    let Some(prev) = prev.filter(|p| !p.is_empty() && view.starts_with(p)) else {
        return Some(last);
    };
    let mut end = 0;
    for (k, piece) in pieces[..=last].iter().enumerate() {
        end += piece.len();
        if end == prev.len() {
            return Some(last.min(k + MARK_REACH));
        }
        if end > prev.len() {
            break;
        }
    }
    Some(last)
}

/// `text` cut at its `block_cuts`: the header, then the whole blocks, then
/// the rest with the closing tag. The mark goes on the second to last piece, when there is one.
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

/// Delta bytes above which a turn re-renders when the compactor has built past the front (spec 5a.4a).
pub const DELTA_MAX: usize = 8_000;
/// Delta bytes above which a turn re-renders anyway: the growth cap between folds (spec 5a.4b).
pub const DELTA_HARD: usize = 32_000;

/// A frozen view (spec 5a.1): the parts shown at the last render and the log front they cover.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Frozen {
    pub parts: Vec<NodeId>,
    pub front: u64,
    /// Parts that were unbuilt at the render: they keep showing the placeholder until the next
    /// re-render, even after the compactor builds them, so the frozen bytes never change.
    pub unbuilt: Vec<NodeId>,
    /// Log indexes where an earlier request's delta ended, ascending: each starts a block, so a
    /// block once sent is sent again byte for byte (spec 5a.2) even when the next entry has the same
    /// kind (an approval answer, a resume note, a steer logged after the turn's messages).
    pub cuts: Vec<u64>,
    /// Log indexes where a turn's new messages began (a forced block start), ascending. Kept apart
    /// from `cuts` (request ends) so a block sent once keeps its start even when a user entry that is
    /// not new (an approval answer) came right before the new messages.
    pub starts: Vec<u64>,
}

/// The frozen view's text: the parts as rendered at the freeze (unbuilt ones as the placeholder).
pub fn frozen_text(f: &Frozen, store: &dyn Store) -> String {
    let mut text = String::from("<chat>\n");
    for part in &f.parts {
        let body = if f.unbuilt.contains(part) {
            None
        } else {
            store.node(*part)
        };
        text.push_str(&view_line(*part, body.as_deref()));
        text.push('\n');
    }
    text.push_str("</chat>");
    text
}

/// One turn's input (spec 5a): the frozen view, then the delta blocks; `rerendered` when this turn froze a new view.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TurnInput {
    pub frozen: Frozen,
    pub rerendered: bool,
    /// The frozen view's text, byte-identical to every turn since its render.
    pub view: String,
    /// The delta: every message after the front in view-line form, one block per run of `user`
    /// messages and one per run of other kinds, oldest first (spec 5a.2).
    pub delta: Vec<String>,
}

/// One delta line: `<i>+1|<kind>: <text>` (newlines as spaces, at most `CAP` characters of text).
/// A note that edits, retracts or deletes an earlier line reads as spec 5a.2 writes it:
/// `<i>+1|edit of <target>: <text>`, `<i>+1|retracted <target>`, `<i>+1|deleted <target>`.
pub fn delta_line(i: u64, kind: crate::Kind, text: &str) -> String {
    let flat = flatten(text);
    let body: String = flat.chars().take(crate::CAP).collect();
    if kind == crate::Kind::Note && changes_a_line(text) {
        return format!("{}|{}", NodeId::new(0, i).name(), body);
    }
    format!("{}|{}: {}", NodeId::new(0, i).name(), kind.as_str(), body)
}

/// Whether `text` is a note that changes an earlier line (`edit_of`, `retracted`, `deleted`).
fn changes_a_line(text: &str) -> bool {
    let id_then = |rest: &str| {
        let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
        digits > 0 && (rest.len() == digits || rest[digits..].starts_with(':'))
    };
    ["edit of ", "retracted ", "deleted "]
        .iter()
        .any(|head| text.strip_prefix(head).is_some_and(id_then))
}

/// The text of a note that edits message `target` (spec 5a.2).
pub fn edit_of(target: u64, text: &str) -> String {
    format!("edit of {target}: {text}")
}

/// The text of a note that retracts message `target`.
pub fn retracted(target: u64) -> String {
    format!("retracted {target}")
}

/// The text of a note that deletes message `target`.
pub fn deleted(target: u64) -> String {
    format!("deleted {target}")
}

/// The delta blocks of the entries `front..end` as a turn whose new messages start at `new_from`
/// built them (a traced turn's, shown again by an inspector).
pub fn delta_range(
    memory: &Memory,
    store: &dyn Store,
    front: u64,
    new_from: u64,
    end: u64,
    cuts: &[u64],
    starts: &[u64],
) -> Vec<String> {
    delta_blocks(memory, store, front, new_from, end, cuts, starts).0
}

fn delta_blocks(
    memory: &Memory,
    store: &dyn Store,
    front: u64,
    new_from: u64,
    end: u64,
    cuts: &[u64],
    starts: &[u64],
) -> (Vec<String>, usize) {
    let mut blocks: Vec<String> = Vec::new();
    let mut last_user: Option<bool> = None;
    let mut bytes = 0;
    let mut prev: Option<u64> = None;
    for i in front..end.min(memory.len()) {
        // An imported message stays out of the delta, built or not: its build state changes later,
        // and a block once sent must not change (spec 5a.2). The view shows it after a re-render,
        // and zoom opens it.
        if memory.is_imported(i) {
            continue;
        }
        // The turn's new messages always start a block, and so does the entry after an earlier
        // request's end (also when the entry at the cut was left out), so those ends stay block ends.
        let cut = prev.is_some_and(|p| cuts.iter().any(|c| p < *c && *c <= i));
        let start = prev.is_some_and(|p| starts.iter().any(|s| p < *s && *s <= i));
        if i == new_from || cut || start {
            last_user = None;
        }
        prev = Some(i);
        let (kind, text) = store.message(i);
        let user = kind == crate::Kind::User;
        let line = delta_line(i, kind, &text);
        // Only what earlier turns added counts toward a re-render: a turn's own new messages (a long
        // paste) never force one, or every turn with a big message would render again (spec 5a.4).
        if i < new_from {
            bytes += line.len() + 1;
        }
        match blocks.last_mut() {
            Some(b) if last_user == Some(user) => {
                b.push_str(&line);
                b.push('\n');
            }
            _ => blocks.push(format!("{line}\n")),
        }
        last_user = Some(user);
    }
    (blocks, bytes)
}

/// The turn input of spec 5a for `frozen` (None: no view frozen yet). The caller stores the
/// returned `frozen` and passes it to the next turn; the turn's `new` messages (the last `new`
/// of the log) are logged before this call, and a re-render never shows them in the view (spec 7
/// anchoring: they are delta lines only).
pub fn turn_input(
    memory: &Memory,
    store: &dyn Store,
    frozen: Option<&Frozen>,
    new: u64,
) -> TurnInput {
    let new_from = memory.len().saturating_sub(new);
    if let Some(f) = frozen.filter(|f| f.front <= new_from) {
        let (delta, bytes) = delta_blocks(
            memory,
            store,
            f.front,
            new_from,
            memory.len(),
            &f.cuts,
            &f.starts,
        );
        // A fold past the front: a built view line above level 0 now covers the front message, so a
        // re-render is shorter than view + delta (a short message built at pump alone does not count).
        let built_past = f.front < memory.len()
            && memory.view().iter().any(|p| {
                p.l > 0 && p.start() <= f.front && f.front < p.end() && memory.is_built(*p)
            });
        if !(bytes > DELTA_HARD || (bytes > DELTA_MAX && built_past)) {
            let mut next = f.clone();
            if memory.len() > f.front && next.cuts.last() != Some(&memory.len()) {
                next.cuts.push(memory.len());
            }
            if new_from > f.front
                && new_from < memory.len()
                && next.starts.last() != Some(&new_from)
            {
                next.starts.push(new_from);
            }
            return TurnInput {
                view: frozen_text(f, store),
                frozen: next,
                rerendered: false,
                delta,
            };
        }
    }
    let shown: Vec<NodeId> = render_view(memory, store)
        .parts
        .into_iter()
        .take_while(|p| p.end() <= new_from)
        .collect();
    let v = render_parts(&shown, store);
    let front = v.parts.last().map_or(0, |p| p.end());
    let (delta, _) = delta_blocks(memory, store, front, new_from, memory.len(), &[], &[]);
    let unbuilt = v
        .parts
        .iter()
        .copied()
        .filter(|p| !memory.is_built(*p) || store.node(*p).is_none())
        .collect();
    TurnInput {
        frozen: Frozen {
            parts: v.parts,
            front,
            unbuilt,
            cuts: if memory.len() > front {
                vec![memory.len()]
            } else {
                Vec::new()
            },
            starts: if new_from > front && new_from < memory.len() {
                vec![new_from]
            } else {
                Vec::new()
            },
        },
        rerendered: true,
        view: v.text,
        delta,
    }
}
