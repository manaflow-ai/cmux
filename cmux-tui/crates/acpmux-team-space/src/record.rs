//! What a person did with their digest, kept in the store so "digest items acted on" can be
//! counted (RFD 0064's read-back numbers: posts, duplicates, digest items acted on).
//!
//! Two records go into a person's log: a [`DigestReceipt`] when a digest is shown to them, and an
//! [`ActionRecord`] when they open, answer or dismiss one of its items. [`stats`] reads the log
//! back.

use crate::store::{StoreError, TeamSpaceStore};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// What a person did with one digest item.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Action {
    Opened,
    Answered,
    Dismissed,
}

impl Action {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Opened => "opened",
            Self::Answered => "answered",
            Self::Dismissed => "dismissed",
        }
    }

    /// Whether the person is done with the item: a later duplicate of it is not put in front of
    /// them again.
    pub fn settles(self) -> bool {
        matches!(self, Self::Answered | Self::Dismissed)
    }
}

/// One person's action on one digest item.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionRecord {
    /// The person's id (what a post's `on_behalf_of` names).
    pub person: String,
    pub space: String,
    /// The digest item's id ([`crate::digest::DigestEntry::id`]).
    pub item: String,
    /// The item's fold key, so a later duplicate of a settled item is recognised.
    pub fold_key: String,
    pub action: Action,
    /// Milliseconds since the Unix epoch, as the caller's clock reads.
    pub at: u64,
}

/// One digest as it was shown to a person.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DigestReceipt {
    pub person: String,
    pub space: String,
    /// The feed range the digest covered: after `from_seq`, through `to_seq`.
    pub from_seq: u64,
    pub to_seq: u64,
    pub posts_seen: usize,
    pub duplicates_folded: usize,
    /// Posts in the items the digest raised (needs you, affects you).
    #[serde(default)]
    pub raised: usize,
    /// Posts the digest only summarized (counted in its rest groups).
    #[serde(default)]
    pub summarized: usize,
    /// Ids of the items the rendered digest showed (items past the budget's cut are not here).
    pub shown: Vec<String>,
    /// Each shown item's fold key by its id, so acting on an item later needs only its id.
    #[serde(default)]
    pub shown_keys: BTreeMap<String, String>,
    /// Items the budget cut.
    pub cut: usize,
    pub at: u64,
}

/// An entry in a person's digest log.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum PersonRecord {
    Shown(DigestReceipt),
    Acted(ActionRecord),
}

impl PersonRecord {
    pub fn person(&self) -> &str {
        match self {
            Self::Shown(r) => &r.person,
            Self::Acted(r) => &r.person,
        }
    }

    pub fn space(&self) -> &str {
        match self {
            Self::Shown(r) => &r.space,
            Self::Acted(r) => &r.space,
        }
    }

    pub fn at(&self) -> u64 {
        match self {
            Self::Shown(r) => r.at,
            Self::Acted(r) => r.at,
        }
    }
}

/// The read-back numbers for one person since a time.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Stats {
    pub digests: usize,
    pub posts_seen: usize,
    pub duplicates_folded: usize,
    /// Posts raised to the person, summed over digests.
    pub raised: usize,
    /// Posts only summarized for the person, summed over digests.
    pub summarized: usize,
    /// Items shown, summed over digests (an item shown in two digests counts twice).
    pub items_shown: usize,
    /// Distinct shown items the person opened, answered or dismissed.
    pub items_acted_on: usize,
    pub opened: usize,
    pub answered: usize,
    pub dismissed: usize,
    /// Actions on items no receipt in the range showed (acted on from somewhere else, or shown
    /// before `since`). Not counted in `items_acted_on`.
    pub acted_unshown: usize,
}

/// Fold a person's log into [`Stats`]. Each action kind counts distinct items, so opening the same
/// item twice is one open.
pub fn fold_stats(records: &[PersonRecord]) -> Stats {
    let mut stats = Stats::default();
    let mut shown = BTreeSet::new();
    for record in records {
        if let PersonRecord::Shown(r) = record {
            stats.digests += 1;
            stats.posts_seen += r.posts_seen;
            stats.duplicates_folded += r.duplicates_folded;
            stats.raised += r.raised;
            stats.summarized += r.summarized;
            stats.items_shown += r.shown.len();
            shown.extend(r.shown.iter().map(|id| (r.space.as_str(), id.as_str())));
        }
    }
    let mut acted = BTreeSet::new();
    let mut by_action = BTreeSet::new();
    let mut unshown = BTreeSet::new();
    for record in records {
        if let PersonRecord::Acted(r) = record {
            let key = (r.space.as_str(), r.item.as_str());
            if !by_action.insert((r.action, key)) {
                continue;
            }
            match r.action {
                Action::Opened => stats.opened += 1,
                Action::Answered => stats.answered += 1,
                Action::Dismissed => stats.dismissed += 1,
            }
            if shown.contains(&key) {
                acted.insert(key);
            } else {
                unshown.insert(key);
            }
        }
    }
    stats.items_acted_on = acted.len();
    stats.acted_unshown = unshown.len();
    stats
}

/// The read-back numbers for `person` from records at or after `since` (ms since the epoch).
pub fn stats(store: &dyn TeamSpaceStore, person: &str, since: u64) -> Result<Stats, StoreError> {
    Ok(fold_stats(&store.records(person, since)?))
}
