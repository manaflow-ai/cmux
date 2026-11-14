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
pub use kin::{ChildSet, FolderKey, KinTables};
pub use log::{IndexLog, replay_generation_logs, replay_log, replay_log_from};
pub use snapshot::{
    DiskSnapshot, FatalSnapshotRead, SnapshotRows, SortedSnapshot, is_corrupt_snapshot_row,
    is_fatal_snapshot_read,
};

use std::io;

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};

use acpmux_list_types::KIN_DEPTH_STOPS;
#[cfg(test)]
pub(crate) use acpmux_list_types::MAX_FIELD_BYTES;
pub(super) use acpmux_list_types::MAX_KIN_DEPTH;
pub use acpmux_list_types::{
    ForkOf, HOT_WINDOW_MS, MAX_SUMMARY_BYTES, MAX_TITLE_BYTES, OriginState, RowKey, Summary,
    SummaryRecord, cut_fields, empty_extras, is_live_state, kin_depth_stops, omitted_folders,
    rejected_keys,
};

/// Text JSON plus three raw row keys, a folder, fork seq, and fixed framing.
pub const MAX_INDEX_RECORD_BYTES: usize = MAX_SUMMARY_BYTES + 3 * (4 + 512) + 1026 + 8 + 32;

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
    folders: folders::Folders,
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
            folders: folders::Folders::new(),
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

    /// An empty derived view for a rebuild. Sequence numbers remain monotonic
    /// with the writer's published history while the old disk generation is
    /// absent, so new source-walk rows can be appended immediately.
    pub fn empty_for_rebuild(&self) -> Self {
        let mut next = self.clone();
        next.disk = None;
        next.shadowed = OrdSet::new();
        next.removed_snapshot_seq = OrdMap::new();
        next
    }

    /// Constructs a first-start index with an explicit edition fence.
    pub fn empty_with_edition(edition: u32) -> Self {
        let mut index = Self::new();
        index.edition = edition;
        index
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
                            if is_corrupt_snapshot_row(&error) {
                                return Some(Err(error));
                            }
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
            self.kin.remove_with_rows(&row, &self.by_id);
            self.folders =
                Self::refresh_folders(&self.folders, &self.kin, &self.by_id, Some(&row), None);
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
                self.kin.insert_arc(row, &self.by_id);
                self.folders =
                    Self::refresh_folders(&self.folders, &self.kin, &self.by_id, None, Some(row));
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
                next.live_ordered.remove(&SortKey::of(&old));
                next.kin.remove_with_rows(&old, &next.by_id);
                next.folders =
                    Self::refresh_folders(&next.folders, &next.kin, &next.by_id, Some(&old), None);
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
            next.live_ordered.remove(&SortKey::of(&old));
            next.kin.remove_with_rows(&old, &next.by_id);
            next.folders =
                Self::refresh_folders(&next.folders, &next.kin, &next.by_id, Some(&old), None);
        }
        next
    }

    /// The kin/folder tables contain only rows present in the hot overlay.
    pub fn kin(&self) -> &KinTables {
        &self.kin
    }

    /// The persistent folder projection published with the hot index.
    pub fn folders(&self) -> &folders::Folders {
        &self.folders
    }

    /// Returns the folder operations caused by one hot-row replacement. The
    /// caller supplies the previous published index and the row pair that was
    /// replaced, so this examines at most the old and new folder paths.
    pub fn folder_changes(
        &self,
        previous: &Self,
        old: Option<&Summary>,
        new: Option<&Summary>,
    ) -> Vec<folders::FolderOp> {
        let old_folder = old.and_then(FolderKey::of);
        let new_folder = new.and_then(FolderKey::of);
        let mut changes = Vec::with_capacity(2);
        let mut check = |folder: &FolderKey| {
            let key = folders::FolderKey::new(folder.origin.clone(), folder.folder.clone());
            let before = previous.folders.get(&key);
            let after = self.folders.get(&key);
            if before == after {
                return;
            }
            match after {
                Some(row) => changes.push(folders::FolderOp::Folder(row)),
                None if before.is_some() => changes.push(folders::FolderOp::Gone(key)),
                None => {}
            }
        };
        if let Some(folder) = old_folder.as_ref() {
            check(folder);
        }
        if let Some(folder) =
            new_folder.as_ref().filter(|folder| old_folder.as_ref() != Some(*folder))
        {
            check(folder);
        }
        changes
    }

    fn refresh_folders(
        base: &folders::Folders,
        kin: &KinTables,
        rows: &OrdMap<RowKey, Arc<Summary>>,
        old: Option<&Summary>,
        new: Option<&Summary>,
    ) -> folders::Folders {
        let old_folder = old.and_then(FolderKey::of);
        let new_folder = new.and_then(FolderKey::of);
        let mut next = base.clone();
        let mut refresh = |folder: &FolderKey| {
            let key = folders::FolderKey::new(folder.origin.clone(), folder.folder.clone());
            let entry = kin
                .folder_entry(folder, rows)
                .map(|entry| {
                    folders::FolderEntry::new(
                        key.origin.clone(),
                        key.folder.clone(),
                        entry.newest,
                        entry.at,
                        entry.count,
                    )
                })
                .unwrap_or_else(|| {
                    folders::FolderEntry::new(key.origin.clone(), key.folder.clone(), None, 0, 0)
                });
            next = next.apply_validated(entry).0;
        };
        if let Some(folder) = old_folder.as_ref() {
            refresh(folder);
        }
        if let Some(folder) =
            new_folder.as_ref().filter(|folder| old_folder.as_ref() != Some(*folder))
        {
            refresh(folder);
        }
        next
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
        next.kin = next.kin.replace_arc(old.as_ref(), Some(&row), &next.by_id);
        next.folders = Self::refresh_folders(
            &next.folders,
            &next.kin,
            &next.by_id,
            old.as_deref(),
            Some(&row),
        );
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
        let kin = self.kin.replace_arc(old.as_ref(), Some(&summary), &by_id);
        let mut next =
            Self { seq: self.seq.max(seq), by_id, ordered, live_ordered, shadowed, ..self.clone() };
        next.kin = kin;
        next.folders = Self::refresh_folders(
            &self.folders,
            &next.kin,
            &next.by_id,
            old.as_deref(),
            Some(&summary),
        );
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
        next.kin = self.kin.replace_arc(old, None, &next.by_id);
        next.folders = Self::refresh_folders(
            &self.folders,
            &next.kin,
            &next.by_id,
            old.map(Arc::as_ref),
            None,
        );
        Some(next)
    }
}

#[cfg(test)]
mod tests;
