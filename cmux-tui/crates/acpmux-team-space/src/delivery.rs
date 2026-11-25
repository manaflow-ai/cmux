//! What a team-space event does to the agent reading it.
//!
//! Ask-first is the default: a question addressed to this agent goes into its digest, which rides
//! its next ordinary turn as an inbox item (`hub/inbox.rs`), and wakes no model. Waking on an
//! addressed question is the owner's opt-in ([`WakePolicy::WakeFromTeam`]), never a default.
//! Leo has not ruled on wake-by-default yet.

use crate::model::{AgentIdentity, Author, Event, PostKind};

/// The agent owner's policy for team-space questions addressed to it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum WakePolicy {
    /// An addressed question waits in the digest. Nothing wakes the agent.
    #[default]
    AskFirst,
    /// The owner lets teammates wake this agent with an addressed question.
    WakeFromTeam,
}

impl WakePolicy {
    /// Read the owner's setting. Anything but the exact opt-in reads as ask-first, so a typo or an
    /// unknown value never turns wakes on.
    pub fn from_setting(value: Option<&str>) -> Self {
        match value.map(str::trim) {
            Some("wakeFromTeam") => Self::WakeFromTeam,
            _ => Self::AskFirst,
        }
    }
}

/// One digest entry: enough for the agent to decide whether to open the thread.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DigestItem {
    pub space: String,
    pub thread: String,
    pub post_id: String,
    pub seq: u64,
    pub kind: PostKind,
    pub author: Author,
    /// Whether the post names this agent. Unaddressed posts are not delivered at all.
    pub addressed: bool,
    /// The post's text cut to [`DIGEST_TEXT_CHARS`], with a cut marker when it was longer.
    pub text: String,
}

/// The digest keeps each post's text short. The thread holds the whole post.
pub const DIGEST_TEXT_CHARS: usize = 280;

/// What to do with one event for one agent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Delivery {
    /// Not for this agent: its own post, or a post that does not name it. It stays readable in
    /// the space.
    Skip,
    /// Into the agent's digest, read at its next ordinary turn. Wakes nobody.
    Digest(DigestItem),
    /// The owner opted in and this is a question addressed to the agent: start a turn.
    Wake(DigestItem),
}

impl Delivery {
    pub fn item(&self) -> Option<&DigestItem> {
        match self {
            Self::Skip => None,
            Self::Digest(item) | Self::Wake(item) => Some(item),
        }
    }
}

/// Decide one event for `me` under `policy`.
pub fn classify(event: &Event, me: &AgentIdentity, policy: WakePolicy) -> Delivery {
    if me.is(&event.author) {
        return Delivery::Skip;
    }
    let addressed = event.to.iter().any(|to| to == &me.team_address);
    if !addressed {
        return Delivery::Skip;
    }
    let item = DigestItem {
        space: event.space.clone(),
        thread: event.thread.clone(),
        post_id: event.post_id.clone(),
        seq: event.seq,
        kind: event.kind,
        author: event.author.clone(),
        addressed,
        text: cut(&event.text, DIGEST_TEXT_CHARS),
    };
    match (policy, event.kind) {
        (WakePolicy::WakeFromTeam, PostKind::Question) => Delivery::Wake(item),
        _ => Delivery::Digest(item),
    }
}

pub(crate) fn cut(text: &str, chars: usize) -> String {
    let total = text.chars().count();
    if total <= chars {
        return text.to_owned();
    }
    let kept: String = text.chars().take(chars).collect();
    format!("{kept} [cut {}]", total - chars)
}
