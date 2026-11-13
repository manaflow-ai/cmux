//! The chat summary index.
//!
//! A summary is the small typed record used by the list stream. Its `extra`
//! member is deliberately a [`serde_json::value::RawValue`]: this crate keeps
//! the bytes exactly as written and never parses the opaque part. The index
//! log is append-only and the sorted snapshot is a compact restart aid; both
//! contain summaries, never chat history.
//!
//! [`SummaryIndex`] uses persistent ordered maps. Applying one summary clones
//! only the map path touched by the change, so the writer does no pass over the
//! number of chats. Readers can retain a published snapshot while the writer
//! builds the next one.

use imbl::{OrdMap, OrdSet};

/// Persistent keys changed while a snapshot is being compacted.
pub type ChangedRows = OrdSet<RowKey>;
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;
use std::cmp::Ordering;
use std::ops::Bound::{Excluded, Included, Unbounded};

mod codec;
mod compaction;
mod edition;
mod family_pages;
mod kin;
pub use family_pages::CursorGone;
pub mod folders;
#[cfg(test)]
mod kin_contract_tests;
#[cfg(test)]
mod kin_gates;
#[cfg(test)]
mod kin_lifecycle_tests;
mod log;
mod pages;
mod table_pages;
pub use pages::{IndexPage, ListFilter, ReadSide};
#[cfg(test)]
mod compaction_tests;
mod snapshot;
#[cfg(test)]
mod storage_tests;
pub use compaction::{Compaction, CompactionResult};
pub use edition::IndexEdition;
pub use kin::{FolderKey, KinTables};
pub use log::{IndexLog, replay_generation_logs, replay_log, replay_log_from};
pub use snapshot::{DiskSnapshot, SnapshotRows, SortedSnapshot};

use std::io;

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};

/// The identity of a row is independent of its current sort position.
#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Hash, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RowKey {
    pub origin: Arc<str>,
    pub chat_id: Arc<str>,
}

impl RowKey {
    pub fn new(origin: impl Into<Arc<str>>, chat_id: impl Into<Arc<str>>) -> Self {
        Self { origin: origin.into(), chat_id: chat_id.into() }
    }

    pub fn validate(&self) -> io::Result<()> {
        if self.origin.len() > MAX_FIELD_BYTES || self.chat_id.len() > MAX_FIELD_BYTES {
            REJECTED_KEYS.fetch_add(1, AtomicOrdering::Relaxed);
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "row key exceeds 256 bytes"));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct ForkOf {
    #[serde(flatten)]
    pub key: RowKey,
    pub seq: u64,
}

/// The on-wire summary of one chat. `extra` is opaque to the daemon.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    pub chat_id: String,
    pub title: String,
    pub harness: String,
    pub state: String,
    /// Milliseconds since the Unix epoch, matching v1 `updatedAt` and `updatedMs`.
    pub last_activity: u64,
    pub unread: u32,
    pub workspace: Option<String>,
    pub origin: String,
    pub pinned: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peer_form: Option<Box<RawValue>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<RowKey>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fork_of: Option<ForkOf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<String>,
    #[serde(default = "empty_object")]
    pub extra: Box<RawValue>,
}

/// Name used by the design document for a summary's durable record.
pub type SummaryRecord = Summary;

/// A summary is deliberately small: the list can never be made unbounded by
/// one harness supplied title or opaque extension.
pub const MAX_TITLE_BYTES: usize = 256;
/// Activity keeps a closed, unpinned chat hot for thirty days.
pub const HOT_WINDOW_MS: u64 = 30 * 24 * 60 * 60 * 1_000;
pub const MAX_SUMMARY_BYTES: usize = 2 * 1024;
/// Text JSON plus three raw row keys, a folder, fork seq, and fixed framing.
pub const MAX_INDEX_RECORD_BYTES: usize = MAX_SUMMARY_BYTES + 3 * (4 + 512) + 1026 + 8 + 32;
static REJECTED_KEYS: AtomicUsize = AtomicUsize::new(0);
static OMITTED_FOLDERS: AtomicUsize = AtomicUsize::new(0);
static CUT_FIELDS: AtomicUsize = AtomicUsize::new(0);
static EMPTY_EXTRAS: AtomicUsize = AtomicUsize::new(0);

pub fn rejected_keys() -> usize {
    REJECTED_KEYS.load(AtomicOrdering::Relaxed)
}
pub fn omitted_folders() -> usize {
    OMITTED_FOLDERS.load(AtomicOrdering::Relaxed)
}
pub fn cut_fields() -> usize {
    CUT_FIELDS.load(AtomicOrdering::Relaxed)
}
pub fn empty_extras() -> usize {
    EMPTY_EXTRAS.load(AtomicOrdering::Relaxed)
}
const MAX_FIELD_BYTES: usize = 256;

fn empty_object() -> Box<RawValue> {
    RawValue::from_string("{}".to_owned()).unwrap_or_else(|_| RawValue::NULL.to_owned())
}

impl Clone for Summary {
    fn clone(&self) -> Self {
        Self {
            chat_id: self.chat_id.clone(),
            title: self.title.clone(),
            harness: self.harness.clone(),
            state: self.state.clone(),
            last_activity: self.last_activity,
            unread: self.unread,
            workspace: self.workspace.clone(),
            origin: self.origin.clone(),
            pinned: self.pinned,
            peer_form: self.peer_form.as_ref().map(|value| value.to_owned()),
            parent: self.parent.clone(),
            fork_of: self.fork_of.clone(),
            folder: self.folder.clone(),
            extra: self.extra.to_owned(),
        }
    }
}

impl Summary {
    /// A compact default useful when a chat has not supplied a title yet.
    pub fn new(chat_id: impl Into<String>) -> Self {
        Self {
            chat_id: chat_id.into(),
            title: String::new(),
            harness: String::new(),
            state: String::new(),
            last_activity: 0,
            unread: 0,
            workspace: None,
            origin: "local".to_owned(),
            pinned: false,
            peer_form: None,
            parent: None,
            fork_of: None,
            folder: None,
            extra: empty_object(),
        }
    }

    pub fn key(&self) -> RowKey {
        RowKey::new(self.origin.as_str(), self.chat_id.as_str())
    }

    /// Whether v1's one-level list folding can place `child` beneath `parent`.
    /// The decision is made from the two rows supplied by the same snapshot, so an
    /// archived or non-root parent cannot hide a child after it changes.
    pub fn listed_under(child: &Summary, parent: Option<&Summary>) -> bool {
        let Some(parent) = parent else { return false };
        if child.key() == parent.key() || parent.parent.is_some() || parent.archived() {
            return false;
        }
        child.parent.as_ref() == Some(&parent.key())
    }

    fn archived(&self) -> bool {
        serde_json::from_str::<serde_json::Value>(self.extra.get())
            .ok()
            .as_ref()
            .and_then(|value| value.pointer("/tags/archived"))
            .is_some_and(|value| !value.is_null())
    }

    /// Keys are refused, never shortened. Opaque data stays opaque.
    pub fn validate(&self) -> io::Result<()> {
        self.key().validate()?;
        if let Some(parent) = &self.parent {
            parent.validate()?;
        }
        if let Some(fork) = &self.fork_of {
            fork.key.validate()?;
        }
        if self.folder.as_ref().is_some_and(|folder| folder.len() > 1024) {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "folder exceeds 1024 bytes"));
        }
        if codec::text_len(self) > MAX_SUMMARY_BYTES {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "summary texts exceed budget"));
        }
        Ok(())
    }

    pub fn prepare(mut self) -> io::Result<Self> {
        if self.folder.as_ref().is_some_and(|folder| folder.len() > 1024) {
            self.folder = None;
            OMITTED_FOLDERS.fetch_add(1, AtomicOrdering::Relaxed);
        }
        let summary = self.bounded();
        summary.validate()?;
        Ok(summary)
    }

    pub fn is_live(&self) -> bool {
        self.state != "closed"
    }

    pub fn is_hot_at(&self, now: u64) -> bool {
        self.pinned || self.is_live() || self.last_activity >= now.saturating_sub(HOT_WINDOW_MS)
    }

    /// Opaque extension bytes are compared without parsing or re-encoding.
    pub fn same_content(&self, other: &Self) -> bool {
        let Self {
            chat_id,
            title,
            harness,
            state,
            last_activity,
            unread,
            workspace,
            origin,
            pinned,
            peer_form,
            parent,
            fork_of,
            folder,
            extra,
        } = self;
        chat_id == &other.chat_id
            && title == &other.title
            && harness == &other.harness
            && state == &other.state
            && last_activity == &other.last_activity
            && unread == &other.unread
            && workspace == &other.workspace
            && origin == &other.origin
            && pinned == &other.pinned
            && peer_form.as_ref().map(|value| value.get())
                == other.peer_form.as_ref().map(|value| value.get())
            && parent == &other.parent
            && fork_of == &other.fork_of
            && folder == &other.folder
            && extra.get() == other.extra.get()
    }

    pub fn encoded_len(&self) -> usize {
        serde_json::to_vec(self).map_or(0, |bytes| bytes.len())
    }

    /// Clamps user supplied text at the index boundary. `extra` stays opaque;
    /// an extension that cannot fit is represented by the empty object rather
    /// than parsed or allowed to expand the list frame.
    pub fn bounded(mut self) -> Self {
        self.title = truncate_utf8(&self.title, MAX_TITLE_BYTES);
        self.harness = truncate_utf8(&self.harness, MAX_FIELD_BYTES);
        self.state = truncate_utf8(&self.state, MAX_FIELD_BYTES);
        self.workspace = self.workspace.map(|value| truncate_utf8(&value, MAX_FIELD_BYTES));
        if codec::text_len(&self) > MAX_SUMMARY_BYTES {
            self.extra = empty_object();
            EMPTY_EXTRAS.fetch_add(1, AtomicOrdering::Relaxed);
        }
        if codec::text_len(&self) > MAX_SUMMARY_BYTES {
            self.title = truncate_utf8(&self.title, MAX_TITLE_BYTES / 2);
        }
        // JSON escaping can make a 256-byte UTF-8 field larger than its text
        // length. Keep shrinking textual fields until the serialized record,
        // including opaque bytes, is inside the wire bound.
        while codec::text_len(&self) > MAX_SUMMARY_BYTES {
            let mut changed = false;
            macro_rules! shrink {
                ($value:expr) => {
                    if $value.len() > 1 {
                        let next = $value.len() / 2;
                        $value = truncate_utf8(&$value, next);
                        changed = true;
                    }
                };
            }
            shrink!(self.title);
            if codec::text_len(&self) > MAX_SUMMARY_BYTES {
                shrink!(self.harness);
            }
            if codec::text_len(&self) > MAX_SUMMARY_BYTES {
                shrink!(self.state);
            }
            if codec::text_len(&self) > MAX_SUMMARY_BYTES
                && let Some(value) = self.workspace.as_mut()
            {
                shrink!(*value);
            }
            if !changed {
                break;
            }
        }
        self
    }
}

fn truncate_utf8(value: &str, max: usize) -> String {
    if value.len() <= max {
        return value.to_owned();
    }
    CUT_FIELDS.fetch_add(1, AtomicOrdering::Relaxed);
    let mut end = max;
    while end > 0 && !value.is_char_boundary(end) {
        end -= 1;
    }
    value.get(..end).unwrap_or_default().to_owned()
}

/// An index-log record. The sequence is monotonic for this index and is the
/// cursor clients use to resume the list stream.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexRecord {
    pub seq: u64,
    pub chat_id: String,
    pub summary: Summary,
    #[serde(default = "local_origin")]
    pub origin: String,
    #[serde(default)]
    pub gone: bool,
}

/// The durable state of one remote origin. `local` is implicit and never has
/// an origin record in the index log.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum OriginState {
    Connected,
    Down,
    Stale,
    Removed,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OriginRecord {
    pub seq: u64,
    pub id: String,
    pub state: OriginState,
    pub since: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extra: Option<Box<RawValue>>,
}

impl PartialEq for OriginRecord {
    fn eq(&self, other: &Self) -> bool {
        self.seq == other.seq
            && self.id == other.id
            && self.state == other.state
            && self.since == other.since
            && self.extra.as_ref().map(|extra| extra.get())
                == other.extra.as_ref().map(|extra| extra.get())
    }
}

impl Eq for OriginRecord {}

fn local_origin() -> String {
    "local".to_owned()
}

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct SortKey {
    pub last_activity: u64,
    #[serde(flatten)]
    pub row: RowKey,
}

impl SortKey {
    pub fn of(summary: &Summary) -> Self {
        Self { last_activity: summary.last_activity, row: summary.key() }
    }
}

impl Ord for SortKey {
    fn cmp(&self, other: &Self) -> Ordering {
        other.last_activity.cmp(&self.last_activity).then_with(|| self.row.cmp(&other.row))
    }
}

impl PartialOrd for SortKey {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// An immutable, sorted view of the summaries at one index sequence.
#[derive(Clone, Debug)]
pub struct SummaryIndex {
    seq: u64,
    edition: u32,
    by_id: OrdMap<RowKey, Arc<Summary>>,
    ordered: OrdMap<SortKey, Arc<Summary>>,
    live_ordered: OrdMap<SortKey, Arc<Summary>>,
    disk: Option<Arc<DiskSnapshot>>,
    shadowed: OrdSet<RowKey>,
    origins: OrdMap<Arc<str>, OriginRecord>,
    leaving: OrdSet<Arc<str>>,
    removed_snapshot_seq: OrdMap<Arc<str>, u64>,
    kin: KinTables,
}

impl Default for SummaryIndex {
    fn default() -> Self {
        Self::new()
    }
}

impl SummaryIndex {
    pub fn new() -> Self {
        Self {
            seq: 0,
            edition: 1,
            by_id: OrdMap::new(),
            ordered: OrdMap::new(),
            live_ordered: OrdMap::new(),
            disk: None,
            shadowed: OrdSet::new(),
            origins: OrdMap::new(),
            leaving: OrdSet::new(),
            removed_snapshot_seq: OrdMap::new(),
            kin: KinTables::new(),
        }
    }

    pub fn from_disk(disk: Option<Arc<DiskSnapshot>>, edition: u32) -> Self {
        let origins: OrdMap<Arc<str>, OriginRecord> =
            disk.as_ref().map_or_else(OrdMap::new, |disk| {
                disk.origins()
                    .filter(|origin| origin.state != OriginState::Removed)
                    .map(|origin| (Arc::<str>::from(origin.id.clone()), origin.clone()))
                    .collect()
            });
        Self {
            seq: disk.as_ref().map_or(0, |disk| disk.seq()),
            edition,
            disk,
            origins,
            ..Self::new()
        }
    }

    /// Merge the immutable disk generation with the current hot/tail overlay.
    /// This iterator owns one bounded disk piece, never a materialized list.
    pub fn merged_rows(&self) -> impl Iterator<Item = io::Result<Arc<Summary>>> + '_ {
        let mut disk = self.disk.as_ref().map(|disk| disk.rows());
        let mut hot = self.iter().peekable();
        let mut next_disk = None;
        let mut disk_done = disk.is_none();
        std::iter::from_fn(move || {
            loop {
                if next_disk.is_none() && !disk_done {
                    match disk.as_mut().and_then(Iterator::next) {
                        Some(Ok(row)) => {
                            if self.is_shadowed(&row.key())
                                || !Self::contributes_to_index(&row)
                                || self.is_origin_removed(row.origin.as_str())
                                || self.is_snapshot_origin_hidden(row.origin.as_str())
                                || self.get_row(&row.key()).is_some()
                            {
                                continue;
                            }
                            next_disk = Some(row);
                        }
                        Some(Err(error)) => {
                            disk_done = true;
                            return Some(Err(error));
                        }
                        None => disk_done = true,
                    }
                }
                return match (hot.peek(), next_disk.as_ref()) {
                    (Some(row), Some(cold)) if SortKey::of(row) <= SortKey::of(cold) => {
                        hot.next().cloned().map(Ok)
                    }
                    (_, Some(_)) => next_disk.take().map(Ok),
                    (Some(_), None) => hot.next().cloned().map(Ok),
                    (None, None) => None,
                };
            }
        })
    }

    /// Swap disk generations without rebuilding the maps. The old shadow root
    /// is returned so its potentially large last drop can run off the writer.
    pub fn with_compacted_snapshot(
        &self,
        snapshot: Arc<DiskSnapshot>,
        changed: ChangedRows,
    ) -> (Self, ChangedRows) {
        let mut next = self.clone();
        let snapshot_seq = snapshot.seq();
        next.disk = Some(snapshot);
        let completed: Vec<_> = next
            .removed_snapshot_seq
            .iter()
            .filter(|(_, seq)| **seq <= snapshot_seq)
            .map(|(id, _)| id.clone())
            .collect();
        for id in completed {
            next.removed_snapshot_seq.remove(&id);
            if next.origin(id.as_ref()).is_some_and(|origin| origin.state == OriginState::Removed) {
                next.origins.remove(&id);
            }
        }
        let retired_shadow = std::mem::replace(&mut next.shadowed, changed);
        (next, retired_shadow)
    }

    /// Only a cold-at-capture row still covered by this snapshot can leave.
    /// This changes residency, not logical contents, sequence, or tombstones.
    pub fn evict_compacted(&mut self, key: &RowKey) -> bool {
        if !self.shadowed.contains(key)
            && let Some(row) = self.by_id.remove(key)
        {
            self.ordered.remove(&SortKey::of(&row));
            self.live_ordered.remove(&SortKey::of(&row));
            self.kin.remove(&row);
            return true;
        }
        false
    }

    /// Complete unfinished startup hydration from the compactor's captured
    /// stream, sharing the row and never overwriting a later update or removal.
    pub fn hydrate_compacted(&mut self, row: Arc<Summary>) {
        let key = row.key();
        if Self::contributes_to_index(&row)
            && !self.shadowed.contains(&key)
            && !self.by_id.contains_key(&key)
            && !self.is_origin_removed(row.origin.as_str())
            && !self.is_snapshot_origin_hidden(row.origin.as_str())
        {
            self.by_id.insert(key.clone(), row.clone());
            self.ordered.insert(SortKey::of(&row), row.clone());
            if row.is_live() {
                self.live_ordered.insert(SortKey::of(&row), row);
            }
            if let Some(row) = self.by_id.get(&key) {
                self.kin.insert(row);
            }
        }
    }

    pub fn edition(&self) -> u32 {
        self.edition
    }
    pub fn disk(&self) -> Option<&Arc<DiskSnapshot>> {
        self.disk.as_ref()
    }
    pub fn is_shadowed(&self, key: &RowKey) -> bool {
        self.shadowed.contains(key)
    }

    pub fn is_origin_removed(&self, origin: &str) -> bool {
        self.leaving.contains(origin)
    }

    pub fn is_origin_leaving(&self, origin: &str) -> bool {
        self.leaving.contains(origin)
    }

    pub fn is_snapshot_origin_hidden(&self, origin: &str) -> bool {
        self.removed_snapshot_seq
            .get(origin)
            .is_some_and(|seq| self.disk.as_ref().is_some_and(|disk| disk.seq() < *seq))
    }

    pub fn last_removed_seq(&self, origin: &str) -> Option<u64> {
        self.removed_snapshot_seq.get(origin).copied()
    }

    pub fn has_origin_rows(&self, origin: &str) -> bool {
        let start = RowKey::new(origin, "");
        self.by_id
            .range::<_, RowKey>((Included(&start), Unbounded))
            .next()
            .is_some_and(|(key, _)| key.origin.as_ref() == origin)
    }

    pub fn finish_origin_removal(&self, origin: &str) -> Self {
        let mut next = self.clone();
        next.leaving.remove(origin);
        next
    }

    pub fn origins(&self) -> impl Iterator<Item = &OriginRecord> {
        self.origins.values()
    }

    pub fn origin(&self, id: &str) -> Option<&OriginRecord> {
        self.origins.get(id)
    }

    pub fn apply_origin(&self, seq: u64, record: OriginRecord) -> Self {
        if record.id == "local" {
            return self.clone();
        }
        let id: Arc<str> = record.id.clone().into();
        if self.origin(&record.id).is_some_and(|old| old.state == record.state) {
            return self.clone();
        }
        let mut next = self.clone();
        next.seq = next.seq.max(seq);
        next.origins.insert(id.clone(), record.clone());
        if record.state == OriginState::Removed {
            next.leaving.insert(id.clone());
            next.removed_snapshot_seq.insert(id, seq);
        }
        next
    }

    pub fn replay_origin(&self, seq: u64, record: OriginRecord) -> Self {
        let mut next = self.apply_origin(seq, record.clone());
        if record.state == OriginState::Removed {
            loop {
                let (updated, removed) = next.remove_origin_batch(seq, record.id.as_str(), 256);
                next = updated;
                if removed == 0 {
                    break;
                }
            }
            next.finish_origin_removal(record.id.as_str())
        } else {
            next
        }
    }

    /// Remove up to `limit` hot rows for an origin. The origin is already
    /// hidden by `apply_origin`, so readers never observe the intermediate
    /// physical batches.
    pub fn remove_origin_batch(&self, seq: u64, origin: &str, limit: usize) -> (Self, usize) {
        self.remove_origin_batch_visiting(seq, origin, limit, || {})
    }

    fn remove_origin_batch_visiting(
        &self,
        seq: u64,
        origin: &str,
        limit: usize,
        mut visit: impl FnMut(),
    ) -> (Self, usize) {
        let start = RowKey::new(origin, "");
        let mut visited = 0;
        let keys: Vec<_> = self
            .by_id
            .range::<_, RowKey>((Included(&start), Unbounded))
            .take_while(|(key, _)| {
                visit();
                if key.origin.as_ref() != origin || visited >= limit {
                    return false;
                }
                visited += 1;
                true
            })
            .map(|(key, _)| key.clone())
            .collect();
        if keys.is_empty() {
            return (self.finish_origin_removal(origin), 0);
        }
        let mut next = self.clone();
        for key in &keys {
            if let Some(old) = next.by_id.remove(key) {
                next.ordered.remove(&SortKey::of(&old));
                next.kin.remove(&old);
            }
            next.shadowed.insert(key.clone());
        }
        next.seq = next.seq.max(seq);
        if !next.has_origin_rows(origin) {
            next.leaving.remove(origin);
        }
        (next, keys.len())
    }

    pub fn advance_seq(&self, seq: u64) -> Self {
        let mut next = self.clone();
        next.seq = next.seq.max(seq);
        next
    }

    pub fn remove_ephemeral(&self, key: &RowKey) -> Self {
        let mut next = self.clone();
        if let Some(old) = next.by_id.remove(key) {
            next.ordered.remove(&SortKey::of(&old));
            next.kin.remove(&old);
        }
        next
    }

    /// The kin/folder tables contain only rows present in the hot overlay.
    pub fn kin(&self) -> &KinTables {
        &self.kin
    }

    pub fn hydrate(&self, row: Arc<Summary>, now: u64) -> Self {
        if !Self::contributes_to_index(&row)
            || self.shadowed.contains(&row.key())
            || self.is_origin_removed(row.origin.as_str())
            || self.is_snapshot_origin_hidden(row.origin.as_str())
            || !row.is_hot_at(now)
        {
            return self.clone();
        }
        let mut next = self.clone();
        let key = row.key();
        let old = next.by_id.get(&key).cloned();
        if let Some(old) = old.as_ref() {
            next.ordered.remove(&SortKey::of(old));
            next.live_ordered.remove(&SortKey::of(old));
        }
        next.by_id.insert(key, row.clone());
        next.ordered.insert(SortKey::of(&row), row.clone());
        if row.is_live() {
            next.live_ordered.insert(SortKey::of(&row), row.clone());
        }
        next.kin = next.kin.replace(old.as_deref(), Some(&row));
        next
    }

    pub fn seq(&self) -> u64 {
        self.seq
    }

    pub fn len(&self) -> usize {
        self.by_id.len()
    }

    pub fn is_empty(&self) -> bool {
        self.by_id.is_empty()
    }

    pub fn get(&self, chat_id: &str) -> Option<Arc<Summary>> {
        self.get_row(&RowKey::new("local", chat_id))
    }

    pub fn get_row(&self, key: &RowKey) -> Option<Arc<Summary>> {
        if self.is_origin_removed(key.origin.as_ref()) {
            return None;
        }
        self.by_id.get(key).cloned()
    }

    pub(crate) fn contributes_to_index(summary: &Summary) -> bool {
        summary.origin == "local" || summary.is_live()
    }

    /// Applies one summary without walking the rest of the index.
    pub fn apply(&self, seq: u64, summary: Summary) -> Self {
        let summary = Arc::new(summary.bounded());
        let old = self.by_id.get(&summary.key()).cloned();
        if old.as_ref().is_some_and(|old| old.same_content(&summary)) {
            let mut next = self.clone();
            next.seq = next.seq.max(seq);
            return next;
        }
        let mut by_id = self.by_id.clone();
        let mut ordered = self.ordered.clone();
        let mut live_ordered = self.live_ordered.clone();
        let key = summary.key();
        if let Some(old) = by_id.get(&key) {
            ordered.remove(&SortKey::of(old));
            live_ordered.remove(&SortKey::of(old));
        }
        let sort_key = SortKey::of(&summary);
        ordered.insert(sort_key.clone(), summary.clone());
        if summary.is_live() {
            live_ordered.insert(sort_key, summary.clone());
        }
        by_id.insert(key.clone(), summary.clone());
        let mut shadowed = self.shadowed.clone();
        if self.disk.is_some() {
            shadowed.insert(key);
        }
        let mut next =
            Self { seq: self.seq.max(seq), by_id, ordered, live_ordered, shadowed, ..self.clone() };
        next.kin = self.kin.replace(old.as_deref(), Some(&summary));
        next
    }

    /// Apply the durable summary rule shared by the writer and replay. Remote
    /// origins contribute live rows only; a closed remote summary advances the
    /// sequence and remains in the log/history, but is not retained in the
    /// index.
    pub fn apply_summary(&self, seq: u64, summary: Summary) -> Self {
        let remote_closed = !Self::contributes_to_index(&summary);
        let key = summary.key();
        let next = self.apply(seq, summary);
        if remote_closed { next.remove_ephemeral(&key) } else { next }
    }

    /// Test/telemetry hook: applying one summary records the number of
    /// summaries touched by the operation. It stays one for a 20-chat and an
    /// 11k-chat index alike; the persistent maps do the logarithmic path copy.
    pub fn apply_counted(&self, seq: u64, summary: Summary, visited: &AtomicUsize) -> Self {
        visited.fetch_add(1, AtomicOrdering::Relaxed);
        self.apply(seq, summary)
    }

    /// Returns summaries newest first. The iterator borrows the persistent
    /// snapshot; collecting it is a caller-owned page operation.
    pub fn iter(&self) -> impl Iterator<Item = &Arc<Summary>> {
        self.ordered.values().filter(|summary| {
            Self::contributes_to_index(summary) && !self.is_origin_removed(&summary.origin)
        })
    }

    pub fn page(&self, start: usize, limit: usize) -> Vec<Arc<Summary>> {
        self.iter().skip(start).take(limit).cloned().collect()
    }

    /// The published live view, ordered identically to the all-chat view.
    pub fn live_after(&self, key: Option<&SortKey>, limit: usize) -> Vec<Arc<Summary>> {
        let lower = key.map_or(Unbounded, Excluded);
        self.live_ordered
            .range::<_, SortKey>((lower, Unbounded))
            .take(limit)
            .map(|(_, row)| row.clone())
            .collect()
    }

    pub fn live_before(&self, key: &SortKey, limit: usize) -> Vec<Arc<Summary>> {
        let mut rows: Vec<_> = self
            .live_ordered
            .range::<_, SortKey>((Unbounded, Excluded(key)))
            .rev()
            .take(limit)
            .map(|(_, row)| row.clone())
            .collect();
        rows.reverse();
        rows
    }

    /// Exclusive keyset seek: tree search plus only the requested rows.
    pub fn after(&self, key: Option<&SortKey>, limit: usize) -> Vec<Arc<Summary>> {
        self.after_candidates(key, limit).into_iter().filter_map(|(_, row)| row).collect()
    }

    pub(crate) fn after_candidates(
        &self,
        key: Option<&SortKey>,
        limit: usize,
    ) -> Vec<(SortKey, Option<Arc<Summary>>)> {
        let lower = key.map_or(Unbounded, Excluded);
        self.ordered
            .range::<_, SortKey>((lower, Unbounded))
            .take(limit)
            .map(|(key, row)| {
                let visible =
                    Self::contributes_to_index(row) && !self.is_origin_removed(&row.origin);
                (key.clone(), visible.then(|| row.clone()))
            })
            .collect()
    }

    pub fn before(&self, key: &SortKey, limit: usize) -> Vec<Arc<Summary>> {
        self.before_candidates(key, limit).into_iter().filter_map(|(_, row)| row).collect()
    }

    pub(crate) fn before_candidates(
        &self,
        key: &SortKey,
        limit: usize,
    ) -> Vec<(SortKey, Option<Arc<Summary>>)> {
        let mut rows: Vec<_> = self
            .ordered
            .range::<_, SortKey>((Unbounded, Excluded(key)))
            .rev()
            .take(limit)
            .map(|(key, row)| {
                let visible =
                    Self::contributes_to_index(row) && !self.is_origin_removed(&row.origin);
                (key.clone(), visible.then(|| row.clone()))
            })
            .collect();
        rows.reverse();
        rows
    }

    pub fn page_after_key(&self, key: Option<(&u64, &str)>, limit: usize) -> Vec<Arc<Summary>> {
        self.after(
            key.map(|(at, id)| SortKey { last_activity: *at, row: RowKey::new("local", id) })
                .as_ref(),
            limit,
        )
    }

    pub fn page_before_key(&self, key: (&u64, &str), limit: usize) -> Vec<Arc<Summary>> {
        self.before(&SortKey { last_activity: *key.0, row: RowKey::new("local", key.1) }, limit)
    }

    pub fn summaries(&self) -> Vec<Summary> {
        self.iter().map(|summary| summary.as_ref().clone()).collect()
    }

    pub fn remove(&self, seq: u64, chat_id: &str) -> Option<Self> {
        self.remove_row(seq, &RowKey::new("local", chat_id))
    }

    pub fn remove_row(&self, seq: u64, key: &RowKey) -> Option<Self> {
        let old = self.by_id.get(key);
        if old.is_none() && self.disk.is_none() {
            return None;
        }
        let mut by_id = self.by_id.clone();
        let mut ordered = self.ordered.clone();
        let mut live_ordered = self.live_ordered.clone();
        by_id.remove(key);
        if let Some(old) = old {
            ordered.remove(&SortKey::of(old));
            live_ordered.remove(&SortKey::of(old));
        }
        let mut shadowed = self.shadowed.clone();
        if self.disk.is_some() {
            shadowed.insert(key.clone());
        }
        let mut next =
            Self { seq: self.seq.max(seq), by_id, ordered, live_ordered, shadowed, ..self.clone() };
        next.kin = self.kin.replace(old.map(Arc::as_ref), None);
        Some(next)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::OpenOptions;
    use std::io::Write;
    use tempfile::tempdir;

    fn summary(id: &str, at: u64, extra: &str) -> Summary {
        let mut summary = Summary::new(id);
        summary.last_activity = at;
        summary.extra = RawValue::from_string(extra.to_owned()).unwrap();
        summary
    }

    #[test]
    fn every_session_state_uses_the_same_live_rule() {
        for state in ["running", "ready", "waiting", "idle", "disconnected"] {
            let mut row = Summary::new(state);
            row.state = state.to_owned();
            assert!(row.is_live(), "{state} should remain in the live view");
        }
        let mut closed = Summary::new("closed");
        closed.state = "closed".to_owned();
        assert!(!closed.is_live());
    }

    #[test]
    fn listed_under_matches_v1_root_and_archive_rules() {
        let mut parent = Summary::new("parent");
        let mut child = Summary::new("child");
        child.parent = Some(parent.key());
        assert!(Summary::listed_under(&child, Some(&parent)));
        assert!(!Summary::listed_under(&child, None));

        let mut nested = Summary::new("nested");
        nested.parent = Some(parent.key());
        parent.parent = Some(RowKey::new("local", "root"));
        assert!(!Summary::listed_under(&nested, Some(&parent)));

        parent.parent = None;
        parent.extra = RawValue::from_string("{\"tags\":{\"archived\":true}}".to_owned()).unwrap();
        assert!(!Summary::listed_under(&child, Some(&parent)));

        parent.extra =
            RawValue::from_string("{\"tags\":{\"archived\":\"reason\"}}".to_owned()).unwrap();
        assert!(!Summary::listed_under(&child, Some(&parent)));
        assert!(!Summary::listed_under(&parent, Some(&parent)));

        parent.extra = RawValue::from_string("{\"tags\":{}}".to_owned()).unwrap();
        child.parent = Some(RowKey::new("local", "other"));
        assert!(!Summary::listed_under(&child, Some(&parent)));
    }

    #[test]
    fn live_pages_use_the_live_ordered_set() {
        let mut running = summary("running", 3, "{}");
        running.state = "running".to_owned();
        let mut closed = summary("closed", 2, "{}");
        closed.state = "closed".to_owned();
        let mut waiting = summary("waiting", 1, "{}");
        waiting.state = "waiting".to_owned();
        let index = SummaryIndex::new().apply(1, running).apply(2, closed).apply(3, waiting);
        let page = index.read_live_page(None, ReadSide::After, false, 10, 64 * 1024, None).unwrap();
        assert_eq!(
            page.rows.iter().map(|row| row.chat_id.as_str()).collect::<Vec<_>>(),
            ["running", "waiting"]
        );
        let mut closed_again = Summary::new("closed");
        closed_again.state = "closed".to_owned();
        let closed = index.apply(4, closed_again);
        let page =
            closed.read_live_page(None, ReadSide::After, false, 10, 64 * 1024, None).unwrap();
        assert_eq!(
            page.rows.iter().map(|row| row.chat_id.as_str()).collect::<Vec<_>>(),
            ["running", "waiting"]
        );
    }

    #[test]
    fn live_pages_match_an_index_containing_only_live_rows() {
        let mut index = SummaryIndex::new();
        let mut live = SummaryIndex::new();
        for n in 0..30 {
            let mut row = summary(&format!("row-{n:02}"), 30 - n, "{}");
            row.state = if n % 3 == 0 { "closed" } else { "running" }.into();
            row.workspace = Some(format!("workspace-{}", n % 2));
            row.origin = if n % 2 == 0 { "local" } else { "peer" }.into();
            if row.is_live() {
                live = live.apply(n + 1, row.clone());
            }
            index = index.apply(n + 1, row);
        }
        let anchors = std::iter::once(None)
            .chain(index.iter().map(|row| Some(SortKey::of(row))))
            .collect::<Vec<_>>();
        let filters = [
            None,
            Some(ListFilter { workspace: Some("workspace-0".into()), ..Default::default() }),
            Some(ListFilter { origin: Some("peer".into()), ..Default::default() }),
            Some(ListFilter { state: Some("waiting".into()), ..Default::default() }),
        ];
        for anchor in &anchors {
            for side in [ReadSide::Before, ReadSide::After, ReadSide::Around] {
                for inclusive in [false, true] {
                    for limit in [1, 2, 7, 30] {
                        for bytes in [600, 8192] {
                            for filter in &filters {
                                let actual = index
                                    .read_live_page(
                                        anchor.as_ref(),
                                        side,
                                        inclusive,
                                        limit,
                                        bytes,
                                        filter.as_ref(),
                                    )
                                    .unwrap();
                                let expected = live
                                    .read_page(
                                        anchor.as_ref(),
                                        side,
                                        inclusive,
                                        limit,
                                        bytes,
                                        filter.as_ref(),
                                    )
                                    .unwrap();
                                assert_eq!(actual.before_key, expected.before_key);
                                assert_eq!(actual.after_key, expected.after_key);
                                assert_eq!(actual.has_before, expected.has_before);
                                assert_eq!(actual.has_after, expected.has_after);
                                assert_eq!(
                                    actual.rows.iter().map(|row| row.key()).collect::<Vec<_>>(),
                                    expected.rows.iter().map(|row| row.key()).collect::<Vec<_>>(),
                                );
                            }
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn a_thousand_state_changes_keep_live_pages_equal_to_the_ordered_filter() {
        let mut index = SummaryIndex::new();
        let mut random = 0x5c_143_u64;
        for seq in 1..=1000 {
            random ^= random << 13;
            random ^= random >> 7;
            random ^= random << 17;
            let mut row = Summary::new(format!("chat-{}", random % 53));
            row.origin = if random & 64 == 0 { "local" } else { "peer" }.into();
            row.state = match (random >> 8) % 5 {
                0 => "closed",
                1 => "running",
                2 => "waiting",
                3 => "idle",
                _ => "ready",
            }
            .into();
            // Ties and movement both exercise ordering across reopen/close.
            row.last_activity = (random >> 16) % 31;
            index = index.apply(seq, row);
            let expected = index
                .iter()
                .filter(|row| row.is_live())
                .map(|row| (SortKey::of(row), row.state.clone()))
                .collect::<Vec<_>>();
            let mut actual = Vec::new();
            let mut anchor = None;
            loop {
                let page = index
                    .read_live_page(anchor.as_ref(), ReadSide::After, false, 7, 8192, None)
                    .unwrap();
                actual.extend(page.rows.iter().map(|row| (SortKey::of(row), row.state.clone())));
                if !page.has_after {
                    break;
                }
                assert_ne!(page.after_key, anchor);
                anchor = page.after_key;
            }
            assert_eq!(actual, expected, "change {seq}");
        }
    }

    #[test]
    fn composite_identity_and_typed_edges_survive_log_snapshot_and_restart() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("index.log");
        let mut local = summary("same", 3, "{\"future\": true}");
        local.parent = Some(RowKey::new("local", "parent"));
        local.fork_of = Some(ForkOf { key: RowKey::new("peer", "fork"), seq: 91 });
        local.folder = Some("/work/project".to_owned());
        let mut peer = local.clone();
        peer.origin = "peer".to_owned();
        let mut log = IndexLog::open(&path).unwrap();
        log.append(local).unwrap();
        log.append(peer).unwrap();
        log.sync().unwrap();
        let index = replay_log(&path, SummaryIndex::new()).unwrap();
        assert_eq!(index.len(), 2);
        log.compact(dir.path().join("index.snap"), &index).unwrap();
        drop(log);
        let mut log = IndexLog::open(&path).unwrap();
        let restored = SortedSnapshot::read(dir.path().join("index.snap")).unwrap().unwrap();
        for origin in ["local", "peer"] {
            let row = restored.get_row(&RowKey::new(origin, "same")).unwrap();
            assert_eq!(row.parent, Some(RowKey::new("local", "parent")));
            assert_eq!(row.fork_of.as_ref().unwrap().seq, 91);
            assert_eq!(row.folder.as_deref(), Some("/work/project"));
        }
        log.append_gone(&RowKey::new("peer", "same")).unwrap();
        log.sync().unwrap();
        let restored = replay_log(log.path(), restored).unwrap();
        assert_eq!(restored.len(), 1);
        assert!(restored.get("same").is_some());
    }

    #[test]
    fn identities_are_never_cut_and_invalid_records_never_append() {
        let dir = tempdir().unwrap();
        let mut log = IndexLog::open(dir.path().join("index.log")).unwrap();
        let id = "x".repeat(257);
        let bounded = Summary::new(id.clone()).bounded();
        assert_eq!(bounded.chat_id, id);
        assert!(log.append(bounded).is_err());
        assert_eq!(log.next_seq(), 0);
        assert_eq!(log.offset(), 0);
        let mut escaped = Summary::new("\u{0001}".repeat(256));
        escaped.origin = "\u{0002}".repeat(256);
        assert!(log.append(escaped).is_ok());
    }

    #[test]
    fn applies_one_summary_and_keeps_opaque_extra_bytes() {
        let index = SummaryIndex::new().apply(1, summary("a", 2, "{\"future\": [1, 2]}"));
        assert_eq!(index.len(), 1);
        assert_eq!(index.get("a").unwrap().extra.get(), "{\"future\": [1, 2]}");
        let index = index.apply(2, summary("a", 3, "{\"new\":true}"));
        assert_eq!(index.len(), 1);
        assert_eq!(index.page(0, 2).first().map(|s| s.last_activity), Some(3));
    }

    #[test]
    fn summaries_are_bounded_without_parsing_extra() {
        let mut value = summary("a", 1, "{}");
        value.title = "é".repeat(MAX_TITLE_BYTES);
        value.extra =
            RawValue::from_string(format!("{{\"text\":\"{}\"}}", "x".repeat(8_000))).unwrap();
        let stored = SummaryIndex::new().apply(1, value).get("a").unwrap();
        assert!(stored.title.len() <= MAX_TITLE_BYTES);
        assert!(stored.encoded_len() <= MAX_SUMMARY_BYTES);
        assert!(stored.title.is_char_boundary(stored.title.len()));
    }

    fn origin_record(id: String, seq: u64, state: OriginState) -> OriginRecord {
        OriginRecord { seq, id, state, since: seq + 10, extra: None }
    }

    #[test]
    fn snapshot_origin_section_round_trips_and_rejects_bad_records() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("index.snap");
        let mut index = SummaryIndex::new();
        index = index.apply_origin(1, origin_record("peer".into(), 1, OriginState::Connected));
        SortedSnapshot::write(&path, &index).unwrap();
        let disk = DiskSnapshot::open(&path).unwrap().unwrap();
        assert_eq!(disk.origins().next().unwrap().since, 11);
        let rows = std::iter::empty::<io::Result<Arc<Summary>>>();
        let too_many =
            (0..257).map(|n| origin_record(format!("p{n}"), 1, OriginState::Connected)).collect();
        assert!(
            SortedSnapshot::write_stream_generation(&path, 1, 0, None, 0, too_many, rows).is_err()
        );
        let duplicate = vec![
            origin_record("p".into(), 1, OriginState::Connected),
            origin_record("p".into(), 1, OriginState::Down),
        ];
        let rows = std::iter::empty::<io::Result<Arc<Summary>>>();
        assert!(
            SortedSnapshot::write_stream_generation(&path, 1, 0, None, 0, duplicate, rows).is_err()
        );
    }

    #[test]
    fn removal_visits_only_its_prefix_batch_at_both_index_sizes() {
        for unrelated in [20, 11_000] {
            let mut index = SummaryIndex::new();
            for n in 0..unrelated {
                let row = summary(&format!("other-{n}"), n + 1, "{}");
                index = index.apply(index.seq() + 1, row);
            }
            for n in 0..500 {
                let mut row = summary(&format!("peer-{n}"), n + 1, "{}");
                row.origin = "peer".into();
                index = index.apply(index.seq() + 1, row);
            }
            let mut visited = 0;
            let (_, removed) =
                index.remove_origin_batch_visiting(index.seq(), "peer", 256, || visited += 1);
            assert_eq!(removed, 256);
            assert_eq!(visited, 257);
        }
    }

    #[test]
    fn removed_origin_hidden_candidates_progress_forward_and_backward() {
        let mut index = SummaryIndex::new();
        for n in 0..600 {
            let mut row = summary(&format!("gone-{n}"), 2_000 - n, "{}");
            row.origin = "peer".into();
            row.state = "running".into();
            index = index.apply(n + 1, row);
        }
        for n in 0..50 {
            let mut row = summary(&format!("keep-{n}"), 1_000 - n, "{}");
            row.origin = "other".into();
            row.state = "running".into();
            index = index.apply(700 + n, row);
        }
        index = index.apply_origin(800, origin_record("peer".into(), 800, OriginState::Removed));
        let mut anchor = None;
        let mut seen = Vec::new();
        let mut last = None;
        for turn in 0..20 {
            let page = index
                .read_page(anchor.as_ref(), ReadSide::After, false, 50, snapshot::PAGE_BYTES, None)
                .unwrap();
            assert!(page.rows.iter().all(|row| row.origin == "other"));
            seen.extend(page.rows.iter().map(|row| row.chat_id.clone()));
            if turn < 12 {
                assert!(page.rows.is_empty());
                assert!(page.has_after);
            }
            last = page.after_key.clone();
            if !page.has_after {
                break;
            }
            assert_ne!(anchor, page.after_key);
            anchor = page.after_key;
        }
        assert_eq!(seen.len(), 50);
        assert_eq!(index.len(), 650, "pagination does not wait for cleanup");
        anchor = last;
        let mut backwards = Vec::new();
        for turn in 0..20 {
            let page = index
                .read_page(
                    anchor.as_ref(),
                    ReadSide::Before,
                    turn == 0,
                    50,
                    snapshot::PAGE_BYTES,
                    None,
                )
                .unwrap();
            assert!(page.rows.iter().all(|row| row.origin == "other"));
            backwards.extend(page.rows.iter().map(|row| row.chat_id.clone()));
            if !page.has_before {
                break;
            }
            assert_ne!(anchor, page.before_key);
            anchor = page.before_key;
        }
        seen.sort();
        backwards.sort();
        assert_eq!(seen, backwards);
    }

    #[test]
    fn log_and_sorted_snapshot_replay() {
        let dir = tempdir().unwrap();
        let log_path = dir.path().join("index.log");
        let snap_path = dir.path().join("index.snap");
        let mut log = IndexLog::open(&log_path).unwrap();
        let first = log.append(summary("a", 2, "{\"x\":1}")).unwrap();
        let second = log.append(summary("b", 1, "null")).unwrap();
        log.sync().unwrap();
        let index =
            SummaryIndex::new().apply(first.seq, first.summary).apply(second.seq, second.summary);
        SortedSnapshot::write(&snap_path, &index).unwrap();
        let restored = SortedSnapshot::read(&snap_path).unwrap().unwrap();
        assert_eq!(restored.seq(), 2);
        assert_eq!(
            restored.page(0, 2).iter().map(|s| s.chat_id.as_str()).collect::<Vec<_>>(),
            ["a", "b"]
        );
        assert_eq!(replay_log(&log_path, SummaryIndex::new()).unwrap().len(), 2);
    }

    #[test]
    fn open_truncates_a_torn_tail_before_the_next_append() {
        let dir = tempdir().unwrap();
        let log_path = dir.path().join("index.log");
        let mut log = IndexLog::open(&log_path).unwrap();
        log.append(summary("a", 1, "{}")).unwrap();
        log.sync().unwrap();
        OpenOptions::new()
            .append(true)
            .open(&log_path)
            .unwrap()
            .write_all(br#"{"seq":99,"chatId":"torn""#)
            .unwrap();
        drop(log);
        let mut reopened = IndexLog::open(&log_path).unwrap();
        let record = reopened.append(summary("b", 2, "{}")).unwrap();
        assert_eq!(record.seq, 2);
        reopened.sync().unwrap();
        assert_eq!(replay_log(&log_path, SummaryIndex::new()).unwrap().len(), 2);
    }

    #[test]
    fn snapshot_carries_the_log_offset_and_compaction_starts_a_new_tail() {
        let dir = tempdir().unwrap();
        let log_path = dir.path().join("index.log");
        let snap_path = dir.path().join("index.snap");
        let mut log = IndexLog::open(&log_path).unwrap();
        let record = log.append(summary("a", 1, "{}")).unwrap();
        log.sync().unwrap();
        let index = SummaryIndex::new().apply(record.seq, record.summary);
        log.compact(&snap_path, &index).unwrap();
        let (restored, offset) = SortedSnapshot::read_with_offset(&snap_path).unwrap().unwrap();
        assert_eq!(offset, 0);
        assert_eq!(replay_log_from(&log_path, offset, restored).unwrap().len(), 1);
        drop(log);
        let mut reopened = IndexLog::open(&log_path).unwrap();
        let next = reopened.append(summary("b", 2, "{}")).unwrap();
        assert_eq!(next.seq, 2);
        reopened.sync().unwrap();
        let restored = SortedSnapshot::read(&snap_path).unwrap().unwrap();
        assert_eq!(replay_log_from(reopened.path(), 0, restored).unwrap().seq(), 2);
    }
}
