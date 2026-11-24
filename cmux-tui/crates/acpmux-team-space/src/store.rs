//! The seam to the hosted store's team spaces.

use crate::model::{FeedPage, NewPost};
use crate::record::PersonRecord;
use std::fmt;

/// Why the store refused or failed a call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StoreError {
    /// The agent is not admitted to the space, or its key does not hold the grant. Joining is a
    /// person's act, so the client never retries this.
    Forbidden { space: String },
    /// The space does not exist, or the store will not say whether it does.
    NotFound { space: String },
    /// The store could not be reached or answered with an error. The cursor is not advanced, so
    /// the next read resumes from the same place.
    Unavailable(String),
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Forbidden { space } => write!(f, "not admitted to team space {space}"),
            Self::NotFound { space } => write!(f, "no team space {space}"),
            Self::Unavailable(why) => write!(f, "the hosted store is unavailable: {why}"),
        }
    }
}

impl std::error::Error for StoreError {}

/// A post the store accepted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Posted {
    pub post_id: String,
    pub seq: u64,
}

/// The hosted store as an acpmux work thread uses it. The store authenticates the caller from its
/// credential (a per-org agent key), so no call here carries an author.
pub trait TeamSpaceStore {
    /// Post into a space. The store dedupes on `post.idempotency_key`: a repeat returns the first
    /// post's id and seq.
    fn post(&self, post: &NewPost) -> Result<Posted, StoreError>;

    /// The space's events after `after`, oldest first, at most `limit` of them (the store may
    /// return fewer).
    fn feed(&self, space: &str, after: u64, limit: usize) -> Result<FeedPage, StoreError>;

    /// Append to a person's digest log: a digest shown to them, or what they did with one of its
    /// items. Only the person, or an agent acting on their behalf, writes their log, and only for
    /// a space the caller was admitted to.
    fn append_record(&self, record: &PersonRecord) -> Result<(), StoreError>;

    /// A person's digest log from `since` (ms since the epoch, inclusive), oldest first. Only the
    /// person, or an agent acting on their behalf, reads it.
    fn records(&self, person: &str, since: u64) -> Result<Vec<PersonRecord>, StoreError>;
}
