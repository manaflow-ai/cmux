//! OptChat memory (plans/cmux-next/optchat.md): one endless chat whose memory
//! is the chat itself. Every message is appended to a log; a background
//! compactor builds a purely binary tree of one-line summaries; each turn
//! reads a fixed-size view of the whole chat that changes only near its end.
//!
//! This crate is the pure part, shared by every placement: the Rust daemon
//! (on the user's MacBook or Mac mini) and the hosted Durable Object (as
//! WebAssembly). It does no I/O: hosts store messages and nodes, call the
//! model, and keep time. The behavior follows Victor Taelin's OptChat
//! specification (published for replication); section numbers in comments
//! refer to it.

mod compact;
mod memory;
mod node;
mod render;

pub use compact::{
    compact_request, cut_at_bytes, finish_line, size_check, size_check_in, strip_head,
    system_prompt, CompactPrompt, CompactRequest, MissingNode, SizeCheck, CMUX_PROMPT_ADDITIONS,
    MIDRUN, RULER, TAELIN_PROMPT,
};
pub use memory::{most_due, Checkpoint, Memory, NotRunning, Store, Work, AHEAD};
pub use node::{Kind, NodeId};
pub use render::{
    block_cuts, block_pieces, cache_marks, cache_pieces, render_parts, render_view, view_line,
    zoom, RenderedView, ZoomError, BLOCK_LINES,
};

/// Target size of one summary line, in UTF-8 bytes (section 3).
pub const NODE: usize = 512;
/// Budget of the view: the sum of its lines' text, in UTF-8 bytes. Past it,
/// one batch merges the view down to half (spec 3.2, gist 3c190e0: a
/// 64-128 KB sawtooth); the compaction view runs from a quarter down to an
/// eighth of it (16-32 KB).
pub const VIEW: usize = 128_000;
/// Compactor model calls running at once (section 4.1; the spec runs 8, the
/// reference client 64). Bounded by the provider's rate limits: 64 calls of
/// about 1 s are under 4,000 requests a minute, and a call refused with 429
/// is retried after `RETRY`. A host may run fewer at once (the acpmux
/// compactor's `COMPACTOR_SESSIONS`); the rest wait for a slot.
pub const JOBS: usize = 64;
/// Attempts per node to get under `NODE` (section 4.3).
pub const TRIES: usize = 5;
/// Largest tool result logged, in characters; head and tail are kept (section 7).
pub const CAP: usize = 30_000;
/// Longest message a compactor call shows whole, in characters; a longer
/// one (a huge paste or tool input) shows its head and tail only, in that
/// call alone, so it fits the compactor model's context. The log keeps it whole.
pub const STEP_MESSAGE: usize = 200_000;
/// Cache breakpoints inside the rendered view, in characters (section 8).
pub const MARKS: [usize; 3] = [50_000, 80_000, 100_000];
/// What an unbuilt view line shows; no model call ever sees it (section 6).
pub const PLACEHOLDER: &str = "(not summarized yet: zoom it)";
