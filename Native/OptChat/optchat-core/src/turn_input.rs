//! Cache-stable turn input (plans/cmux-next/optchat.md 5a, a cmux rule).
//!
//! A turn reads the system prompt and tools, then the FROZEN VIEW (the view
//! as it was rendered at the last re-render, the same bytes every turn),
//! then the DELTA: every log entry after the view's front, one line each,
//! in blocks that never change once sent. Only a re-render (5a.4) changes
//! anything before the delta's end. Both brains build their input here; a
//! host only stores the `Frozen` record between turns.

use crate::memory::{Memory, Store};
use crate::node::{Kind, NodeId};
use crate::render::{render_parts, render_view, RenderedView};

/// A delta over this many bytes re-renders when the compactor has built
/// nodes past the front (5a.4 a): the new view is then shorter than view
/// plus delta. About 2,000 tokens.
pub const DELTA_MAX: usize = 8_000;
/// A delta over this many bytes re-renders even when the compactor is
/// behind (5a.4 b): the growth cap between folds.
pub const DELTA_HARD: usize = 32_000;
/// The system prompt's rule for entries that change an earlier line (5a.2).
pub const DELTA_RULE: &str = "A line after </chat> that names an earlier line id (edit of, retracted, deleted) replaces what that line says.";

/// What a host keeps between turns: the frozen view by its parts, the log
/// index it covers up to, and where earlier requests' deltas ended.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Frozen {
    /// The view's parts, oldest first (`RenderedView::parts`).
    pub parts: Vec<NodeId>,
    /// The first log index no part covers: the delta starts here.
    pub front: u64,
    /// Log indexes where a sent request's delta ended, ascending: a block
    /// boundary each, so a block once sent is sent again byte for byte.
    pub cuts: Vec<u64>,
    /// Size and FNV-1a hash of the view's text when it was frozen. A view
    /// whose parts no longer render the same bytes (a node built or lost
    /// since, a reset memory) is rendered again.
    pub bytes: usize,
    pub hash: u64,
}

/// One turn's input after the system prompt.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TurnInput {
    /// The frozen view, rendered from its parts (section-8 cuts as ever).
    pub view: RenderedView,
    /// The delta's blocks, oldest first; each line starts with a newline,
    /// so `view.text` followed by the blocks reads `</chat>\n<id>|...`.
    pub delta: Vec<String>,
    /// The record to store for the next turn (this request's end is a cut).
    pub frozen: Frozen,
    /// Whether this turn rendered a new view (one cache write of the view).
    pub rendered: bool,
}

/// 64-bit FNV-1a of `text`: a cheap, stable fingerprint (not a security hash).
pub fn fingerprint(text: &str) -> u64 {
    text.bytes().fold(0xcbf2_9ce4_8422_2325, |h, b| {
        (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3)
    })
}

/// Whether `text` is an entry that changes an earlier line (5a.2).
fn changes_a_line(text: &str) -> bool {
    let id_then = |rest: &str| {
        let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
        digits > 0 && (rest.len() == digits || rest[digits..].starts_with(':'))
    };
    ["edit of ", "retracted ", "deleted "]
        .iter()
        .any(|head| text.strip_prefix(head).is_some_and(id_then))
}

/// The text of a note that edits line `target` (5a.2).
pub fn edit_of(target: u64, text: &str) -> String {
    format!("edit of {target}: {text}")
}

/// The text of a note that retracts line `target`.
pub fn retracted(target: u64) -> String {
    format!("retracted {target}")
}

/// The text of a note that deletes line `target`.
pub fn deleted(target: u64) -> String {
    format!("deleted {target}")
}

/// One delta line, `<id>|<kind>: <text>` as a message reads in zoom, with
/// newlines as spaces; a note that edits, retracts or deletes a line reads
/// `<id>|edit of <target>: <text>` (`retracted <target>`, `deleted <target>`).
pub fn delta_line(id: u64, kind: Kind, text: &str) -> String {
    let flat = text.replace('\n', " ");
    if kind == Kind::Note && changes_a_line(text) {
        format!("{id}|{flat}")
    } else {
        format!("{id}|{}: {flat}", kind.as_str())
    }
}

/// The delta from `front` up to `end` (the log's length for a turn being
/// built; a traced turn's own end to show it again): one line per entry (imported
/// entries are left out: zoom opens them), cut into blocks at each change
/// between `user` and the other kinds and at every index in `cuts`.
pub fn delta_blocks(
    memory: &Memory,
    store: &dyn Store,
    front: u64,
    end: u64,
    cuts: &[u64],
) -> Vec<String> {
    let mut blocks: Vec<String> = Vec::new();
    let mut last_user: Option<bool> = None;
    for id in front..end.min(memory.len()) {
        if memory.is_imported(id) {
            continue;
        }
        let (kind, text) = store.message(id);
        let user = kind == Kind::User;
        if last_user != Some(user) || cuts.binary_search(&id).is_ok() || blocks.is_empty() {
            blocks.push(String::new());
        }
        last_user = Some(user);
        let block = blocks.last_mut().expect("a block was pushed");
        block.push('\n');
        block.push_str(&delta_line(id, kind, &text));
    }
    blocks
}

fn delta_bytes(blocks: &[String]) -> usize {
    blocks.iter().map(String::len).sum()
}

/// A view rendered now over the entries before `first_new` (this turn's new
/// messages go to the delta, never into the view: 5a.3).
fn render_fresh(memory: &Memory, store: &dyn Store, first_new: u64) -> (RenderedView, u64) {
    let parts: Vec<NodeId> = render_view(memory, store)
        .parts
        .into_iter()
        .filter(|p| p.end() <= first_new)
        .collect();
    let front = parts.iter().map(|p| p.end()).max().unwrap_or(0);
    (render_parts(&parts, store), front)
}

/// Whether the compactor built a line past `front` that a new view would
/// show in place of several delta lines (5a.4 a).
fn built_past(memory: &Memory, front: u64, first_new: u64) -> bool {
    memory
        .view()
        .iter()
        .any(|p| p.l > 0 && p.end() > front && p.end() <= first_new && memory.is_built(*p))
}

/// The turn's input (5a): the frozen view and the delta, or a new view and
/// an empty delta (but for this turn's new messages) when 5a.4 says so.
/// `first_new` is the log index of this turn's first new message (the
/// log's length when it has none); they are logged before this call.
pub fn turn_input(
    memory: &Memory,
    store: &dyn Store,
    frozen: Option<&Frozen>,
    first_new: u64,
) -> TurnInput {
    let first_new = first_new.min(memory.len());
    let kept = frozen.filter(|f| f.front <= first_new).and_then(|f| {
        let view = render_parts(&f.parts, store);
        (view.text.len() == f.bytes && fingerprint(&view.text) == f.hash).then_some((f, view))
    });
    if let Some((f, view)) = kept {
        let delta = delta_blocks(memory, store, f.front, memory.len(), &f.cuts);
        let bytes = delta_bytes(&delta);
        let stay =
            bytes <= DELTA_HARD && (bytes <= DELTA_MAX || !built_past(memory, f.front, first_new));
        if stay {
            let mut next = f.clone();
            let end = memory.len();
            if end > f.front && next.cuts.last() != Some(&end) {
                next.cuts.push(end);
            }
            return TurnInput {
                view,
                delta,
                frozen: next,
                rendered: false,
            };
        }
    }
    let (view, front) = render_fresh(memory, store, first_new);
    let delta = delta_blocks(memory, store, front, memory.len(), &[]);
    let end = memory.len();
    let frozen = Frozen {
        parts: view.parts.clone(),
        front,
        cuts: if end > front { vec![end] } else { Vec::new() },
        bytes: view.text.len(),
        hash: fingerprint(&view.text),
    };
    TurnInput {
        view,
        delta,
        frozen,
        rendered: true,
    }
}
