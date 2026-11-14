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
#[cfg(test)]
mod mark_tests;
mod snapshot;
#[cfg(test)]
mod storage_tests;
pub use compaction::{Compaction, CompactionResult};
pub use edition::IndexEdition;
pub use kin::{ChildSet, FolderKey, KinTables};
pub use log::{IndexLog, replay_generation_logs, replay_log, replay_log_from};
pub use snapshot::{
    DiskSnapshot, FatalSnapshotRead, SnapshotMeta, SnapshotRows, SortedSnapshot,
    is_corrupt_snapshot_row, is_fatal_snapshot_read,
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

/// Where a mirrored origin's stream stands: the source's cursor and list
/// edition after the last unit written, and whether its first walk finished.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MirrorMark {
    pub cursor: u64,
    pub edition: u32,
    pub whole: bool,
}

/// The mirror's mark for one origin as the log carries it. `None` writes the
/// mark off: a replay after it gives no cursor.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MarkRecord {
    pub seq: u64,
    pub origin: String,
    pub mark: Option<MirrorMark>,
}

impl MarkRecord {
    /// The bytes this record adds to an append, its frame included.
    pub fn encoded_len(&self) -> u64 {
        20 + self.origin.len() as u64 + if self.mark.is_some() { 13 } else { 0 }
    }
}

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
    marks: OrdMap<Arc<str>, MirrorMark>,
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
            marks: OrdMap::new(),
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
        let marks = disk.as_ref().map_or_else(OrdMap::new, |disk| {
            disk.marks()
                .filter_map(|record| Some((Arc::<str>::from(record.origin.as_str()), record.mark?)))
                .collect()
        });
        Self {
            seq: disk.as_ref().map_or(0, |disk| disk.seq()),
            edition,
            disk,
            origins,
            marks,
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

    /// The mirror's mark for `origin`, if a unit wrote one and no takeover
    /// wrote it off since.
    pub fn mirror_mark(&self, origin: &str) -> Option<MirrorMark> {
        self.marks.get(origin).copied()
    }

    /// Every mark held, newest per origin; compaction writes these.
    pub fn mirror_marks(&self) -> impl Iterator<Item = MarkRecord> + '_ {
        self.marks.iter().map(|(origin, mark)| MarkRecord {
            seq: self.seq,
            origin: origin.to_string(),
            mark: Some(*mark),
        })
    }

    /// A mark changes no row and takes no sequence of its own: it carries the
    /// sequence of the last row its unit wrote (or the current one).
    pub fn apply_mark(&self, record: &MarkRecord) -> Self {
        let mut next = self.clone();
        match record.mark {
            Some(mark) => {
                next.marks.insert(record.origin.as_str().into(), mark);
            }
            None => {
                next.marks.remove(record.origin.as_str());
            }
        }
        next
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
            // A removed origin's stream starts over from a walk.
            next.marks.remove(&id);
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
        parent.archived = true;
        assert!(!Summary::listed_under(&child, Some(&parent)));

        parent.archived = true;
        parent.extra =
            RawValue::from_string("{\"tags\":{\"archived\":\"reason\"}}".to_owned()).unwrap();
        assert!(!Summary::listed_under(&child, Some(&parent)));
        assert!(!Summary::listed_under(&parent, Some(&parent)));

        parent.archived = false;
        parent.extra = RawValue::from_string("{\"tags\":{}}".to_owned()).unwrap();
        child.parent = Some(RowKey::new("local", "other"));
        assert!(!Summary::listed_under(&child, Some(&parent)));
    }

    #[test]
    fn archived_is_typed_through_bounds_and_codec_with_legacy_default() {
        let legacy: Summary = serde_json::from_str(
            r#"{"chatId":"legacy","title":"","harness":"","state":"closed","lastActivity":0,"unread":0,"workspace":null,"origin":"local","pinned":false,"extra":{}}"#,
        )
        .unwrap();
        assert!(!legacy.archived);

        let mut archived = Summary::new("archived");
        archived.archived = true;
        archived.extra =
            RawValue::from_string(format!("{{\"blob\":\"{}\"}}", "x".repeat(8_000))).unwrap();
        let index = SummaryIndex::new().apply(1, archived);
        let row = index.get("archived").unwrap();
        assert!(row.archived);
        assert_eq!(row.extra.get(), "{}");
        let mut child = Summary::new("child");
        child.parent = Some(row.key());
        assert!(!Summary::listed_under(&child, Some(&row)));

        let dir = tempdir().unwrap();
        let mut log = IndexLog::open(dir.path().join("index.log")).unwrap();
        log.append(row.as_ref().clone()).unwrap();
        log.sync().unwrap();
        let restored = replay_log(log.path(), SummaryIndex::new()).unwrap();
        assert!(restored.get("archived").unwrap().archived);
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
    fn every_index_mutator_keeps_live_pages_equal_to_the_ordered_filter() {
        fn assert_live_matches_filter(index: &SummaryIndex) {
            let expected = index
                .iter()
                .filter(|row| row.is_live() && !index.is_origin_removed(row.origin.as_str()))
                .map(|row| row.key())
                .collect::<Vec<_>>();
            let mut actual = Vec::new();
            let mut anchor = None;
            loop {
                let page = index
                    .read_live_page(anchor.as_ref(), ReadSide::After, false, 16, 64 * 1024, None)
                    .unwrap();
                actual.extend(page.rows.iter().map(|row| row.key()));
                if !page.has_after {
                    break;
                }
                anchor = page.after_key;
            }
            assert_eq!(actual, expected);
        }

        let mut peer = summary("peer", 20, "{}");
        peer.origin = "peer".into();
        peer.state = "running".into();
        let mut local = summary("local", 10, "{}");
        local.state = "running".into();
        let mut closed = summary("closed", 5, "{}");
        closed.state = "closed".into();
        let mut index = SummaryIndex::new().apply(1, peer.clone()).apply(2, local).apply(3, closed);
        assert_live_matches_filter(&index);

        let mut hydrated = peer.clone();
        hydrated.last_activity = 30;
        index = index.hydrate(Arc::new(hydrated), 100);
        assert_live_matches_filter(&index);

        let key = peer.key();
        let mut evicted = index;
        assert!(evicted.evict_compacted(&key));
        assert_live_matches_filter(&evicted);
        evicted.hydrate_compacted(Arc::new(peer.clone()));
        assert_live_matches_filter(&evicted);

        let mut removed =
            evicted.apply_origin(10, origin_record("peer".into(), 10, OriginState::Removed));
        assert_live_matches_filter(&removed);
        let (next, count) = removed.remove_origin_batch(10, "peer", 256);
        removed = next;
        assert_eq!(count, 1);
        assert_live_matches_filter(&removed);
        removed = removed.finish_origin_removal("peer");
        assert_live_matches_filter(&removed);

        removed =
            removed.apply_origin(11, origin_record("peer".into(), 11, OriginState::Connected));
        assert_live_matches_filter(&removed);

        let mut returned = peer.clone();
        returned.chat_id = "peer-returned".into();
        returned.last_activity = 40;
        removed = removed.apply(12, returned.clone());
        assert_live_matches_filter(&removed);
        removed = removed.remove_row(13, &returned.key()).unwrap();
        assert_live_matches_filter(&removed);
        removed = removed.remove_row(14, &RowKey::new("local", "local")).unwrap();
        assert_live_matches_filter(&removed);
        let mut ephemeral = peer;
        ephemeral.chat_id = "peer-ephemeral".into();
        ephemeral.last_activity = 50;
        let removed = removed.apply(15, ephemeral.clone());
        assert_live_matches_filter(&removed);
        let removed = removed.remove_ephemeral(&ephemeral.key());
        assert_live_matches_filter(&removed);

        let dir = tempdir().unwrap();
        let path = dir.path().join("index.snap");
        SortedSnapshot::write(&path, &removed).unwrap();
        let disk = DiskSnapshot::open(&path).unwrap().unwrap();
        let (compacted, _) = removed.with_compacted_snapshot(disk, Default::default());
        assert_live_matches_filter(&compacted);
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
        let too_many = (0..257)
            .map(|n| origin_record(format!("p{n}"), 1, OriginState::Connected))
            .collect::<Vec<_>>();
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
    fn live_pages_drop_removed_origin_rows_before_the_origin_returns() {
        fn live_keys(index: &SummaryIndex) -> Vec<RowKey> {
            index
                .read_live_page(None, ReadSide::After, false, 100, snapshot::PAGE_BYTES, None)
                .unwrap()
                .rows
                .iter()
                .map(|row| row.key())
                .collect()
        }

        fn filtered_keys(index: &SummaryIndex) -> Vec<RowKey> {
            index.iter().filter(|row| row.is_live()).map(|row| row.key()).collect()
        }

        let mut index = SummaryIndex::new();
        for (seq, (origin, id, activity)) in
            [("peer", "peer-live-a", 30), ("peer", "peer-live-b", 20), ("local", "local-live", 10)]
                .into_iter()
                .enumerate()
        {
            let mut row = summary(id, activity, "{}");
            row.origin = origin.to_owned();
            index = index.apply(seq as u64 + 1, row);
        }
        assert_eq!(live_keys(&index), filtered_keys(&index));

        index = index.apply_origin(10, origin_record("peer".into(), 10, OriginState::Removed));
        loop {
            let (next, removed) = index.remove_origin_batch(10, "peer", 256);
            index = next;
            if removed == 0 {
                break;
            }
        }
        assert_eq!(live_keys(&index), filtered_keys(&index));
        assert!(!live_keys(&index).iter().any(|key| key.origin.as_ref() == "peer"));

        index = index.apply_origin(11, origin_record("peer".into(), 11, OriginState::Connected));
        let mut returned = summary("peer-live-returned", 40, "{}");
        returned.origin = "peer".to_owned();
        index = index.apply(12, returned);
        assert_eq!(live_keys(&index), filtered_keys(&index));
        assert_eq!(live_keys(&index).iter().filter(|key| key.origin.as_ref() == "peer").count(), 1);
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

    #[test]
    fn folder_projection_matches_rebuild_after_ten_thousand_hot_updates() {
        use std::collections::BTreeMap;

        let mut index = SummaryIndex::new();
        let mut seed = 0x5f_u64;
        for seq in 1..=10_000 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
            let id = format!("chat-{}", (seed >> 32) % 64);
            let mut row = Summary::new(id);
            row.origin = if seed & 1 == 0 { "local" } else { "peer" }.into();
            row.state = if seed & 7 == 0 { "closed" } else { "running" }.into();
            row.last_activity = seed;
            row.folder = (seed & 3 != 0).then(|| format!("/folder-{}", (seed >> 8) % 17));
            index = index.apply_summary(seq, row);

            let mut model = BTreeMap::<folders::FolderKey, (SortKey, RowKey, u32)>::new();
            for hot in index.iter() {
                let Some(folder) = FolderKey::of(hot) else { continue };
                let key = folders::FolderKey::new(folder.origin.clone(), folder.folder.clone());
                let sort = SortKey::of(hot);
                let entry = model.entry(key).or_insert_with(|| (sort.clone(), hot.key(), 0));
                if sort < entry.0 {
                    entry.0 = sort.clone();
                    entry.1 = hot.key();
                }
                entry.2 += 1;
            }
            let rebuilt = model
                .into_iter()
                .try_fold(folders::Folders::new(), |view, (key, (sort, newest, count))| {
                    view.apply(folders::FolderEntry::new(
                        key.origin,
                        key.folder,
                        Some(newest),
                        sort.last_activity,
                        count,
                    ))
                    .map(|(view, _)| view)
                })
                .unwrap();
            let actual = index
                .folders()
                .iter()
                .map(|row| (row.key(), row.as_ref().clone()))
                .collect::<Vec<_>>();
            let expected =
                rebuilt.iter().map(|row| (row.key(), row.as_ref().clone())).collect::<Vec<_>>();
            assert_eq!(actual, expected, "folder projection mismatch at update {seq}");
        }
    }
}
