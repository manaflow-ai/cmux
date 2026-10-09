//! The reply as it streams (parity item 4): drafts of the turn's reply,
//! published to every client of the conversation (`conversation.draft`, an
//! ephemeral event; the posted message stays the only authoritative reply).

/// One draft event of a turn's reply.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Draft {
    /// The idempotency key of the reply the turn will post.
    pub turn: String,
    /// The reply segment (0-based; a new one starts after each tool call).
    pub segment: u64,
    /// 1, 2, 3 ... per turn, across segments.
    pub seq: u64,
    /// `talk` (thoughts are not drafted).
    pub kind: &'static str,
    /// The delta since the last event of the segment, or with `fresh` the
    /// whole segment so far.
    pub text: String,
    pub fresh: bool,
    /// The turn ended: clients drop the draft.
    pub done: bool,
    /// A fresh segment longer than the limit: `text` is its end.
    pub truncated: bool,
    /// The harness profile that runs the turn.
    pub harness: Option<String>,
}
