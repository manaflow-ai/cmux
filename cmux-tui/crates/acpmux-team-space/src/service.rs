//! A person's digest as a tool serves it: read the feed after the person's stored cursor, show
//! it, and move the cursor only when the person says so; record what they do with an item; read
//! the numbers back.

use crate::digest::{Digest, DigestOptions, Person, Rendered, read};
use crate::log::CursorLog;
use crate::record::{Action, ActionRecord, PersonRecord, Stats, fold_stats};
use crate::store::{StoreError, TeamSpaceStore};
use serde::Serialize;

/// Characters of rendered text a digest holds unless the caller asks for another budget.
pub const DEFAULT_BUDGET: usize = 6_000;

/// What one digest read gave.
#[derive(Debug, Clone)]
pub struct Run {
    pub digest: Digest,
    pub rendered: Rendered,
    /// The cursor moved to the digest's end.
    pub acked: bool,
    /// The cursor after this call.
    pub cursor: u64,
    pub stats: Stats,
}

/// How a digest read goes.
pub struct Ask<'a> {
    pub person: &'a Person,
    pub space: &'a str,
    pub options: &'a DigestOptions,
    /// Characters of rendered text at most.
    pub budget: usize,
    /// Move the cursor past what this digest covered. Without it, the next read starts at the
    /// same place.
    pub ack: bool,
    /// Now, ms since the epoch.
    pub now: u64,
    /// The read-back covers records at or after this.
    pub since: u64,
}

/// Read the person's digest of `ask.space` after their stored cursor.
///
/// The digest is logged as shown once per feed range: reading the same range again before an
/// ack does not count its posts twice.
pub fn run(
    store: &dyn TeamSpaceStore,
    cursors: &dyn CursorLog,
    ask: &Ask<'_>,
) -> Result<Run, StoreError> {
    let Ask { person, space, options, budget, ack, now, since } = *ask;
    let after = cursors.cursor(&person.id, space);
    let records = store.records(&person.id, 0)?;
    let prior: Vec<ActionRecord> = records
        .iter()
        .filter_map(|r| match r {
            PersonRecord::Acted(a) => Some(a.clone()),
            PersonRecord::Shown(_) => None,
        })
        .collect();
    let digest = read(store, person, space, after, &prior, options)?;
    let rendered = digest.render(budget);
    let again = records.iter().any(|r| match r {
        PersonRecord::Shown(s) => {
            s.space == space && s.from_seq == digest.from_seq && s.to_seq == digest.to_seq
        }
        PersonRecord::Acted(_) => false,
    });
    if !again && (digest.posts_seen > 0 || digest.to_seq > digest.from_seq) {
        store.append_record(&PersonRecord::Shown(digest.receipt(&rendered, now)))?;
    }
    if ack {
        cursors.set_cursor(&person.id, space, digest.to_seq, now)?;
    }
    let stats = fold_stats(&store.records(&person.id, since)?);
    let cursor = cursors.cursor(&person.id, space);
    Ok(Run { digest, rendered, acked: ack, cursor, stats })
}

/// Why an action was not recorded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ActError {
    /// No digest this person was shown holds the item.
    UnknownItem(String),
    Store(StoreError),
}

impl std::fmt::Display for ActError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnknownItem(item) => {
                write!(f, "no digest shown to this person holds item {item}")
            }
            Self::Store(e) => e.fmt(f),
        }
    }
}

impl std::error::Error for ActError {}

impl From<StoreError> for ActError {
    fn from(e: StoreError) -> Self {
        Self::Store(e)
    }
}

/// Record that `person` `action`ed digest item `item` of `space`. The item must be one a digest
/// shown to them held.
pub fn act(
    store: &dyn TeamSpaceStore,
    person: &str,
    space: &str,
    item: &str,
    action: Action,
    now: u64,
) -> Result<ActionRecord, ActError> {
    let fold_key = store
        .records(person, 0)?
        .into_iter()
        .rev()
        .find_map(|r| match r {
            PersonRecord::Shown(s) if s.space == space => s.shown_keys.get(item).cloned(),
            _ => None,
        })
        .ok_or_else(|| ActError::UnknownItem(item.to_owned()))?;
    let record = ActionRecord {
        person: person.to_owned(),
        space: space.to_owned(),
        item: item.to_owned(),
        fold_key,
        action,
        at: now,
    };
    store.append_record(&PersonRecord::Acted(record.clone()))?;
    Ok(record)
}

/// The read-back as a tool prints it.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Counts {
    pub since: u64,
    pub posts_read: usize,
    pub raised: usize,
    pub summarized: usize,
    pub opened: usize,
    pub answered: usize,
    pub dismissed: usize,
}

impl Counts {
    pub fn new(stats: &Stats, since: u64) -> Self {
        Self {
            since,
            posts_read: stats.posts_seen,
            raised: stats.raised,
            summarized: stats.summarized,
            opened: stats.opened,
            answered: stats.answered,
            dismissed: stats.dismissed,
        }
    }
}
