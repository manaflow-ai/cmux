//! The records a work thread exchanges with the hosted store. Field names follow the store's
//! identity record (kind, id, `on_behalf_of` authenticated; session and host as reported).

use serde::{Deserialize, Serialize};

/// Who wrote a post: an agent or a person.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AuthorKind {
    Person,
    Agent,
}

/// A post's author as the store returns it. `kind`, `id`, `team_address` and `on_behalf_of` are
/// what the store authenticated. `session` and `host` are what the agent reported, and a reader
/// shows them as reported.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Author {
    pub kind: AuthorKind,
    pub id: String,
    /// The author's team-scoped address (`@team/reviewer`), when it has one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub team_address: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on_behalf_of: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
}

/// The agent a client acts as. The store authenticates `id` and `on_behalf_of` from the agent's
/// credential. The client sends `session` and `host` as reports.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentIdentity {
    pub id: String,
    pub team_address: String,
    pub on_behalf_of: String,
    pub session: Option<String>,
    pub host: Option<String>,
}

impl AgentIdentity {
    /// Whether `author` is this agent (its own posts are never delivered back to it).
    pub fn is(&self, author: &Author) -> bool {
        author.kind == AuthorKind::Agent && author.id == self.id
    }
}

/// A post's type. A kind this build does not know reads as [`PostKind::Other`], which is never
/// delivered as a question.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PostKind {
    Question,
    Answer,
    Finding,
    Status,
    #[serde(other)]
    Other,
}

/// What a work thread posts.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NewPost {
    pub space: String,
    /// The store's thread key. A work thread uses its acpmux inbox thread key.
    pub thread: String,
    pub kind: PostKind,
    pub text: String,
    /// Team addresses the post is addressed to (`@team/reviewer`). Empty: addressed to nobody.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub to: Vec<String>,
    /// The same post sent again is the same post.
    pub idempotency_key: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reported_session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reported_host: Option<String>,
}

/// One entry of a space's feed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Event {
    pub seq: u64,
    pub space: String,
    pub thread: String,
    pub post_id: String,
    pub kind: PostKind,
    pub author: Author,
    pub text: String,
    #[serde(default)]
    pub to: Vec<String>,
}

/// A page of a space's feed: events after the cursor the reader gave, oldest first, and the
/// space's head seq so a reader knows when it is caught up.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FeedPage {
    pub events: Vec<Event>,
    pub head: u64,
}
