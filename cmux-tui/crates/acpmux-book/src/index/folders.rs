//! Persistent view of the folders used by hot chats.
//!
//! The folder table is owned by the index writer (PR 5e). This module keeps a
//! second, immutable projection over that table: one row per `(origin,
//! folder)` whose entry has a hot chat. Applying an entry copies only the two
//! persistent-map paths touched by that folder, and returns the one operation a
//! subscriber needs to observe.

use super::{ListFilter, MAX_FIELD_BYTES, RowKey};
use imbl::OrdMap;
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::io;
use std::ops::Bound::{Excluded, Included, Unbounded};
use std::sync::Arc;

/// A folder's stable identity. The folder itself is bounded to 1,024 bytes by
/// the index record contract; origins use the ordinary 256-byte row-key bound.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderKey {
    pub origin: Arc<str>,
    pub folder: Arc<str>,
}

impl FolderKey {
    pub fn new(origin: impl Into<Arc<str>>, folder: impl Into<Arc<str>>) -> Self {
        Self { origin: origin.into(), folder: folder.into() }
    }

    pub fn validate(&self) -> io::Result<()> {
        if self.origin.len() > MAX_FIELD_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "folder origin exceeds 256 bytes",
            ));
        }
        if self.folder.len() > MAX_FOLDER_BYTES {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "folder exceeds 1024 bytes"));
        }
        Ok(())
    }
}

pub const MAX_FOLDER_BYTES: usize = 1024;
pub const MAX_FOLDER_ROWS: usize = 400;
pub const MAX_FOLDER_PAGE_BYTES: usize = super::snapshot::PAGE_BYTES;

/// The newest hot chat and count supplied by the writer's folder table.
/// `newest: None` means the last hot chat left and removes the row.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FolderEntry {
    pub key: FolderKey,
    pub newest: Option<RowKey>,
    pub at: u64,
    pub count: u32,
}

impl FolderEntry {
    pub fn new(
        origin: impl Into<Arc<str>>,
        folder: impl Into<Arc<str>>,
        newest: Option<RowKey>,
        at: u64,
        count: u32,
    ) -> Self {
        Self { key: FolderKey::new(origin, folder), newest, at, count }
    }

    pub fn validate(&self) -> io::Result<()> {
        self.key.validate()?;
        match (&self.newest, self.count) {
            (Some(newest), 1..) => {
                newest.validate()?;
                if newest.origin != self.key.origin {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "folder newest row has a different origin",
                    ));
                }
            }
            (Some(_), 0) => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "folder newest row requires a positive count",
                ));
            }
            (None, 0) => {}
            (None, _) => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "folder count without a newest row",
                ));
            }
        }
        Ok(())
    }
}

/// One row in the folders view.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderRow {
    pub origin: Arc<str>,
    pub folder: Arc<str>,
    pub newest: RowKey,
    pub at: u64,
    pub count: u32,
}

impl FolderRow {
    fn from_entry(entry: &FolderEntry) -> Option<Self> {
        Some(Self {
            origin: entry.key.origin.clone(),
            folder: entry.key.folder.clone(),
            newest: entry.newest.clone()?,
            at: entry.at,
            count: entry.count,
        })
    }

    pub fn key(&self) -> FolderKey {
        FolderKey::new(self.origin.clone(), self.folder.clone())
    }

    pub fn encoded_len(&self) -> usize {
        serde_json::to_vec(self).map_or(0, |bytes| bytes.len())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum FolderOp {
    Folder(Arc<FolderRow>),
    Gone(FolderKey),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FolderCursor {
    pub at: u64,
    pub key: FolderKey,
}

impl FolderCursor {
    pub fn new(at: u64, key: FolderKey) -> Self {
        Self { at, key }
    }

    fn sort_key(&self) -> FolderSortKey {
        FolderSortKey { at: self.at, key: self.key.clone() }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct FolderSortKey {
    at: u64,
    key: FolderKey,
}

impl Ord for FolderSortKey {
    fn cmp(&self, other: &Self) -> Ordering {
        other.at.cmp(&self.at).then_with(|| self.key.cmp(&other.key))
    }
}

impl PartialOrd for FolderSortKey {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FolderReadSide {
    Before,
    After,
}

#[derive(Clone, Debug)]
pub struct FolderPage {
    pub rows: Vec<Arc<FolderRow>>,
    pub has_before: bool,
    pub has_after: bool,
    pub before_key: Option<FolderCursor>,
    pub after_key: Option<FolderCursor>,
    pub bytes_read: usize,
}

/// Immutable, persistent folders projection. The writer publishes a new value
/// after each entry update; readers can retain the old value without a lock.
#[derive(Clone, Debug, Default)]
pub struct Folders {
    by_key: OrdMap<FolderKey, Arc<FolderRow>>,
    ordered: OrdMap<FolderSortKey, Arc<FolderRow>>,
}

impl Folders {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn len(&self) -> usize {
        self.by_key.len()
    }

    pub fn is_empty(&self) -> bool {
        self.by_key.is_empty()
    }

    pub fn get(&self, key: &FolderKey) -> Option<Arc<FolderRow>> {
        self.by_key.get(key).cloned()
    }

    pub fn iter(&self) -> impl Iterator<Item = &Arc<FolderRow>> {
        self.ordered.values()
    }

    /// Applies one folder-table entry and returns the one subscriber operation.
    /// Equal rows are intentionally a no-op, including equal newest/count
    /// values arriving from a text chunk or status-only update.
    pub fn apply(&self, entry: FolderEntry) -> io::Result<(Self, Option<FolderOp>)> {
        entry.validate()?;
        Ok(self.apply_validated(entry))
    }

    pub(crate) fn apply_validated(&self, entry: FolderEntry) -> (Self, Option<FolderOp>) {
        let mut next = self.clone();
        let old = self.by_key.get(&entry.key).cloned();
        let Some(row) = FolderRow::from_entry(&entry).map(Arc::new) else {
            if let Some(old) = old {
                next.by_key.remove(&entry.key);
                next.ordered.remove(&FolderSortKey { at: old.at, key: entry.key.clone() });
                return (next, Some(FolderOp::Gone(entry.key)));
            }
            return (self.clone(), None);
        };
        if old.as_ref().is_some_and(|old| old.as_ref() == row.as_ref()) {
            return (self.clone(), None);
        }
        if let Some(old) = old {
            next.ordered.remove(&FolderSortKey { at: old.at, key: entry.key.clone() });
        }
        next.ordered.insert(FolderSortKey { at: row.at, key: entry.key.clone() }, row.clone());
        next.by_key.insert(entry.key, row.clone());
        (next, Some(FolderOp::Folder(row)))
    }

    pub fn window(&self, limit: usize, max_bytes: usize) -> io::Result<FolderPage> {
        self.read_page(None, FolderReadSide::After, false, limit, max_bytes, None)
    }

    pub fn page_after(
        &self,
        cursor: Option<&FolderCursor>,
        limit: usize,
        max_bytes: usize,
    ) -> io::Result<FolderPage> {
        self.read_page(cursor, FolderReadSide::After, false, limit, max_bytes, None)
    }

    pub fn page_before(
        &self,
        cursor: &FolderCursor,
        limit: usize,
        max_bytes: usize,
    ) -> io::Result<FolderPage> {
        self.read_page(Some(cursor), FolderReadSide::Before, false, limit, max_bytes, None)
    }

    pub fn validate_page_bound(limit: usize, max_bytes: usize) -> io::Result<()> {
        if limit == 0
            || limit > MAX_FOLDER_ROWS
            || max_bytes == 0
            || max_bytes > MAX_FOLDER_PAGE_BYTES
        {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid folders page bound"));
        }
        Ok(())
    }

    /// Reads a bounded keyset page. `bytes_read` counts encoded row bytes, the
    /// same cost unit used by the list page gates.
    pub fn read_page(
        &self,
        cursor: Option<&FolderCursor>,
        side: FolderReadSide,
        inclusive: bool,
        limit: usize,
        max_bytes: usize,
        filter: Option<&ListFilter>,
    ) -> io::Result<FolderPage> {
        self.read_page_visible(cursor, side, inclusive, limit, max_bytes, filter, |_| true)
    }

    /// Reads a page while applying an additional visibility predicate to each
    /// candidate. Hidden rows consume the candidate bound and continuation but
    /// no response bytes, matching the list's origin-removal rule.
    pub fn read_page_visible(
        &self,
        cursor: Option<&FolderCursor>,
        side: FolderReadSide,
        inclusive: bool,
        limit: usize,
        max_bytes: usize,
        filter: Option<&ListFilter>,
        visible: impl Fn(&FolderRow) -> bool,
    ) -> io::Result<FolderPage> {
        Self::validate_page_bound(limit, max_bytes)?;
        let anchor = cursor.map(FolderCursor::sort_key);
        let (start, end) = match (anchor.as_ref(), side) {
            (Some(anchor), FolderReadSide::After) => {
                (if inclusive { Included(anchor) } else { Excluded(anchor) }, Unbounded)
            }
            (Some(anchor), FolderReadSide::Before) => {
                (Unbounded, if inclusive { Included(anchor) } else { Excluded(anchor) })
            }
            (None, _) => (Unbounded, Unbounded),
        };
        // The list contract bounds the number of candidates visited, including
        // rows hidden by a filter. A continuation is answered by one seek past
        // the last candidate, rather than consuming an extra row just for the
        // flag (which could falsely claim work remains).
        let candidates: Box<dyn Iterator<Item = &Arc<FolderRow>> + '_> = match side {
            FolderReadSide::After => {
                Box::new(self.ordered.range::<_, FolderSortKey>((start, end)).map(|(_, row)| row))
            }
            FolderReadSide::Before => Box::new(
                self.ordered.range::<_, FolderSortKey>((start, end)).rev().map(|(_, row)| row),
            ),
        };
        let matches = |row: &FolderRow| {
            visible(row)
                && filter.is_none_or(|filter| {
                    filter.origin.as_ref().is_none_or(|origin| row.origin.as_ref() == origin)
                })
        };
        let mut visited = Vec::with_capacity(limit);
        let mut rows = Vec::new();
        let mut bytes_read = 0usize;
        let mut byte_limited = false;
        for row in candidates.take(limit) {
            if rows.len() == limit {
                break;
            }
            if !matches(row) {
                visited.push(row.clone());
                continue;
            }
            let row_bytes = row.encoded_len().saturating_add(1);
            if bytes_read.saturating_add(row_bytes) > max_bytes {
                if visited.is_empty() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "folders page byte budget cannot fit the next row",
                    ));
                }
                byte_limited = true;
                break;
            }
            visited.push(row.clone());
            bytes_read = bytes_read.saturating_add(row_bytes);
            rows.push(row.clone());
        }
        if side == FolderReadSide::Before {
            rows.reverse();
        }
        let candidate_first = match side {
            FolderReadSide::After => visited.first(),
            FolderReadSide::Before => visited.last(),
        };
        let candidate_last = match side {
            FolderReadSide::After => visited.last(),
            FolderReadSide::Before => visited.first(),
        };
        let before_key = candidate_first.map(|row| FolderCursor::new(row.at, row.key()));
        let after_key = candidate_last.map(|row| FolderCursor::new(row.at, row.key()));
        let has_before = match side {
            FolderReadSide::Before => {
                before_key.as_ref().is_some_and(|key| {
                    self.ordered
                        .range::<_, FolderSortKey>((Unbounded, Excluded(&key.sort_key())))
                        .next()
                        .is_some()
                }) || byte_limited
            }
            FolderReadSide::After => before_key.as_ref().is_some_and(|key| {
                self.ordered
                    .range::<_, FolderSortKey>((Unbounded, Excluded(&key.sort_key())))
                    .next()
                    .is_some()
            }),
        };
        let has_after = match side {
            FolderReadSide::After => {
                after_key.as_ref().is_some_and(|key| {
                    self.ordered
                        .range::<_, FolderSortKey>((Excluded(&key.sort_key()), Unbounded))
                        .next()
                        .is_some()
                }) || byte_limited
            }
            FolderReadSide::Before => after_key.as_ref().is_some_and(|key| {
                self.ordered
                    .range::<_, FolderSortKey>((Excluded(&key.sort_key()), Unbounded))
                    .next()
                    .is_some()
            }),
        };
        Ok(FolderPage { rows, has_before, has_after, before_key, after_key, bytes_read })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn row(origin: &str, chat: &str) -> RowKey {
        RowKey::new(origin, chat)
    }

    fn entry(origin: &str, folder: &str, chat: &str, at: u64, count: u32) -> FolderEntry {
        FolderEntry::new(origin, folder, Some(row(origin, chat)), at, count)
    }

    #[test]
    fn newest_first_and_equal_update_is_silent() {
        let folders = Folders::new();
        let (folders, first) = folders.apply(entry("local", "/a", "one", 2, 1)).unwrap();
        assert!(matches!(first, Some(FolderOp::Folder(_))));
        let (_, equal) = folders.apply(entry("local", "/a", "one", 2, 1)).unwrap();
        assert!(equal.is_none());
        let (folders, _) = folders.apply(entry("local", "/b", "two", 4, 1)).unwrap();
        let page = folders.window(10, MAX_FOLDER_PAGE_BYTES).unwrap();
        assert_eq!(
            page.rows.iter().map(|row| row.folder.as_ref()).collect::<Vec<_>>(),
            ["/b", "/a"]
        );
    }

    #[test]
    fn moving_newest_updates_order_and_leaving_emits_gone() {
        let (folders, _) = Folders::new().apply(entry("local", "/a", "one", 2, 1)).unwrap();
        let (folders, op) = folders.apply(entry("local", "/a", "two", 3, 2)).unwrap();
        assert!(matches!(op, Some(FolderOp::Folder(_))));
        let (folders, gone) = folders.apply(FolderEntry::new("local", "/a", None, 0, 0)).unwrap();
        assert!(matches!(gone, Some(FolderOp::Gone(_))));
        assert!(folders.is_empty());
    }

    #[test]
    fn cursor_pages_are_stable_and_bounded() {
        let (folders, _) = Folders::new().apply(entry("local", "/a", "one", 3, 1)).unwrap();
        let (folders, _) = folders.apply(entry("local", "/b", "two", 2, 1)).unwrap();
        let first = folders.window(1, MAX_FOLDER_PAGE_BYTES).unwrap();
        assert!(first.has_after);
        let next = folders.page_after(first.after_key.as_ref(), 1, MAX_FOLDER_PAGE_BYTES).unwrap();
        assert_eq!(next.rows.len(), 1);
        assert!(!next.has_after);
        assert!(next.has_before);
    }

    #[test]
    fn origin_filter_and_inclusive_anchor_follow_list_rules() {
        let (folders, _) = Folders::new().apply(entry("local", "/a", "one", 3, 1)).unwrap();
        let (folders, _) = folders.apply(entry("peer", "/b", "two", 2, 1)).unwrap();
        let filter = ListFilter { origin: Some("peer".into()), ..ListFilter::default() };
        let page = folders
            .read_page(None, FolderReadSide::After, false, 10, MAX_FOLDER_PAGE_BYTES, Some(&filter))
            .unwrap();
        assert_eq!(page.rows.len(), 1);
        assert_eq!(page.rows[0].origin.as_ref(), "peer");
        let anchor = FolderCursor::new(2, page.rows[0].key());
        let inclusive = folders
            .read_page(
                Some(&anchor),
                FolderReadSide::After,
                true,
                1,
                MAX_FOLDER_PAGE_BYTES,
                Some(&filter),
            )
            .unwrap();
        assert_eq!(inclusive.rows[0].key(), anchor.key);
    }

    #[test]
    fn page_bounds_and_byte_budget_are_refused() {
        let (folders, _) = Folders::new().apply(entry("local", "/a", "one", 1, 1)).unwrap();
        assert!(folders.window(MAX_FOLDER_ROWS + 1, MAX_FOLDER_PAGE_BYTES).is_err());
        assert!(folders.window(1, 1).is_err());
    }

    #[test]
    fn ties_page_in_both_directions_and_byte_budget_stops_after_one() {
        let (folders, _) = Folders::new().apply(entry("local", "/a", "a", 7, 1)).unwrap();
        let (folders, _) = folders.apply(entry("local", "/b", "b", 7, 1)).unwrap();
        let (folders, _) = folders.apply(entry("local", "/c", "c", 7, 1)).unwrap();
        let first = folders.window(1, MAX_FOLDER_PAGE_BYTES).unwrap();
        let second =
            folders.page_after(first.after_key.as_ref(), 1, MAX_FOLDER_PAGE_BYTES).unwrap();
        let before = folders
            .page_before(second.before_key.as_ref().unwrap(), 1, MAX_FOLDER_PAGE_BYTES)
            .unwrap();
        assert_eq!(before.rows[0].key(), first.rows[0].key());
        let row_bytes = first.rows[0].encoded_len() + 1;
        let bounded = folders.window(3, row_bytes).unwrap();
        assert_eq!(bounded.rows.len(), 1);
        assert!(bounded.has_after);
    }

    #[test]
    fn oversized_keys_and_invalid_counts_are_refused() {
        assert!(
            Folders::new()
                .apply(FolderEntry::new(
                    "o".repeat(MAX_FIELD_BYTES + 1),
                    "/f",
                    Some(row("o", "c")),
                    1,
                    1
                ))
                .is_err()
        );
        assert!(
            Folders::new()
                .apply(FolderEntry::new(
                    "local",
                    &*"f".repeat(MAX_FOLDER_BYTES + 1),
                    Some(row("local", "c")),
                    1,
                    1
                ))
                .is_err()
        );
        assert!(Folders::new().apply(FolderEntry::new("local", "/f", None, 1, 1)).is_err());
        assert!(
            Folders::new()
                .apply(FolderEntry::new("local", "/f", Some(row("local", "c")), 1, 0))
                .is_err()
        );
    }

    #[test]
    fn before_cursor_whose_row_left_still_reads_prior_candidates() {
        let (folders, _) = Folders::new().apply(entry("local", "/a", "a", 3, 1)).unwrap();
        let (folders, _) = folders.apply(entry("local", "/b", "b", 2, 1)).unwrap();
        let cursor = FolderCursor::new(2, FolderKey::new("local", "/b"));
        let (folders, _) = folders.apply(FolderEntry::new("local", "/b", None, 0, 0)).unwrap();
        let page = folders.page_before(&cursor, 1, MAX_FOLDER_PAGE_BYTES).unwrap();
        assert_eq!(page.rows[0].folder.as_ref(), "/a");
    }

    #[test]
    fn filtered_candidates_consume_limit_and_keep_continuation() {
        let folders = (0..2_000).fold(Folders::new(), |folders, n| {
            folders
                .apply(entry("local", &format!("/folder-{n:04}"), "chat", n as u64 + 1, 1))
                .unwrap()
                .0
        });
        let filter = ListFilter { origin: Some("peer".into()), ..ListFilter::default() };
        let page = folders
            .read_page(None, FolderReadSide::After, false, 20, MAX_FOLDER_PAGE_BYTES, Some(&filter))
            .unwrap();
        assert!(page.rows.is_empty());
        assert_eq!(page.bytes_read, 0);
        assert!(page.after_key.is_some());
        assert!(page.has_after);
    }

    #[test]
    fn ten_thousand_random_updates_match_rebuild_from_entries() {
        let mut seed = 0x5f_u64;
        let mut folders = Folders::new();
        let mut model = BTreeMap::<FolderKey, FolderEntry>::new();
        for step in 0..10_000 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
            let origin = if seed & 1 == 0 { "local" } else { "peer" };
            let folder = format!("/folder-{}", (seed >> 8) % 17);
            let key = FolderKey::new(origin, folder.clone());
            let entry = if seed & 8 == 0 {
                FolderEntry::new(origin, folder, None, 0, 0)
            } else {
                FolderEntry::new(
                    origin,
                    folder,
                    Some(RowKey::new(origin, format!("chat-{}", (seed >> 16) % 41))),
                    step as u64 + 1,
                    ((seed >> 24) % 5 + 1) as u32,
                )
            };
            folders = folders.apply(entry.clone()).unwrap().0;
            if entry.newest.is_some() {
                model.insert(key, entry);
            } else {
                model.remove(&key);
            }
            let rebuilt = model
                .values()
                .cloned()
                .try_fold(Folders::new(), |view, entry| view.apply(entry).map(|(view, _)| view))
                .unwrap();
            let actual =
                folders.iter().map(|row| (row.key(), row.as_ref().clone())).collect::<Vec<_>>();
            let expected =
                rebuilt.iter().map(|row| (row.key(), row.as_ref().clone())).collect::<Vec<_>>();
            assert_eq!(actual, expected, "mismatch at random step {step}");
        }
    }

    #[test]
    fn folder_bound_is_kept_whole() {
        let folder = "f".repeat(MAX_FOLDER_BYTES);
        let (folders, op) = Folders::new().apply(entry("local", &folder, "one", 1, 1)).unwrap();
        assert!(op.is_some());
        let row = folders.iter().next().expect("row");
        assert_eq!(row.folder.len(), MAX_FOLDER_BYTES);
    }
}

#[cfg(test)]
mod release_gates {
    use super::*;
    use std::fs::OpenOptions;
    use std::hint::black_box;
    use std::io::Write;
    use std::process::Command;
    use std::time::Instant;

    const ROUNDS: usize = 5;
    const SAMPLES: usize = 200;
    const HELD_VERSIONS: usize = 1_000;

    fn p95(samples: &[u128]) -> u128 {
        let mut values = samples.to_vec();
        values.sort_unstable();
        values[((values.len() * 95).saturating_add(99) / 100).saturating_sub(1)]
    }

    fn timed<F: FnMut() -> u128>(mut sample: F) -> (u128, u128) {
        let mut rounds = Vec::with_capacity(ROUNDS * SAMPLES);
        for _ in 0..ROUNDS {
            for _ in 0..SAMPLES {
                rounds.push(sample());
            }
        }
        let best = rounds.chunks_exact(SAMPLES).map(p95).min().unwrap_or(1);
        (best, p95(&rounds))
    }

    fn gate(name: &str, small: u128, god: u128, god_all: u128, unit: &str) {
        let line = format!(
            "{{\"name\":\"{name}\",\"small_p95\":{small},\"god_p95\":{god},\"god_p95_all\":{god_all},\"unit\":\"{unit}\"}}"
        );
        eprintln!("{line}");
        if let Ok(path) = std::env::var("V2_GATE_OUT")
            && let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path)
        {
            let _ = writeln!(file, "{line}");
        }
    }

    fn fixture_entries(count: usize) -> Vec<FolderEntry> {
        (0..count)
            .map(|n| {
                FolderEntry::new(
                    "local",
                    format!("/folder-{n:04}"),
                    Some(RowKey::new("local", format!("chat-{n:05}"))),
                    (count - n) as u64,
                    1,
                )
            })
            .collect()
    }

    fn build_view(entries: &[FolderEntry]) -> Folders {
        entries
            .iter()
            .cloned()
            .try_fold(Folders::new(), |folders, entry| {
                folders.apply(entry).map(|(folders, _)| folders)
            })
            .expect("fixture entry")
    }

    fn fixture(count: usize) -> Folders {
        build_view(&fixture_entries(count))
    }

    fn apply_newest(folders: &Folders, entry: FolderEntry) -> u128 {
        let started = Instant::now();
        let next = folders.apply(entry).expect("newest update").0;
        black_box(next);
        started.elapsed().as_nanos().max(1)
    }

    fn apply_move(folders: &Folders, remove: FolderEntry, insert: FolderEntry) -> u128 {
        let started = Instant::now();
        let (next, _) = folders.apply(remove).expect("old folder removal");
        let next = next.apply(insert).expect("new folder insert").0;
        black_box(next);
        started.elapsed().as_nanos().max(1)
    }

    fn page_window(folders: &Folders) -> u128 {
        let started = Instant::now();
        let first = folders.window(3, MAX_FOLDER_PAGE_BYTES).expect("first window");
        black_box(first);
        started.elapsed().as_nanos().max(1)
    }

    fn deep_page(folders: &Folders, cursor: &FolderCursor) -> u128 {
        let started = Instant::now();
        let page = folders.page_after(Some(cursor), 3, MAX_FOLDER_PAGE_BYTES).expect("deep page");
        black_box(page);
        started.elapsed().as_nanos().max(1)
    }

    fn resident_kib() -> Option<u64> {
        let status = std::fs::read_to_string("/proc/self/status").ok()?;
        status
            .lines()
            .find(|line| line.starts_with("VmRSS:"))?
            .split_whitespace()
            .nth(1)?
            .parse()
            .ok()
    }

    fn resident_probe(count: usize) -> Option<(u64, u64, usize)> {
        let output = Command::new(std::env::current_exe().ok()?)
            .args([
                "index::folders::release_gates::resident_probe_entry",
                "--exact",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("FOLDERS_RSS_COUNT", count.to_string())
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let stdout = String::from_utf8_lossy(&output.stdout);
        let line = stdout
            .lines()
            .find_map(|line| line.split_once("folders_rss ").map(|(_, rest)| rest))?;
        let mut values = line.split_whitespace();
        let view = values.next()?.strip_prefix("view_kib=")?.parse().ok()?;
        let held = values.next()?.strip_prefix("held_kib=")?.parse().ok()?;
        let encoded = values.next()?.strip_prefix("encoded_bytes=")?.parse().ok()?;
        Some((view, held, encoded))
    }

    #[test]
    fn resident_probe_entry() {
        let Ok(count) = std::env::var("FOLDERS_RSS_COUNT")
            .and_then(|value| value.parse::<usize>().map_err(|_| std::env::VarError::NotPresent))
        else {
            return;
        };
        let entries = fixture_entries(count);
        let before = resident_kib().unwrap_or_default();
        let view = build_view(&entries);
        black_box(&view);
        let after = resident_kib().unwrap_or_default();
        let view_rise = after.saturating_sub(before);
        let mut held = Vec::with_capacity(HELD_VERSIONS);
        held.push(view.clone());
        let held_before = resident_kib().unwrap_or_default();
        for n in 0..HELD_VERSIONS {
            let entry = FolderEntry::new(
                "local",
                format!("/held-{n:04}"),
                Some(RowKey::new("local", format!("held-chat-{n:04}"))),
                20_000 + n as u64,
                1,
            );
            let next = held.last().expect("held view").apply(entry).expect("held update").0;
            held.push(next);
        }
        black_box(&held);
        let held_after = resident_kib().unwrap_or_default();
        let held_rise = held_after.saturating_sub(held_before);
        let encoded: usize = view.iter().map(|row| row.encoded_len() + 1).sum();
        println!("folders_rss view_kib={view_rise} held_kib={held_rise} encoded_bytes={encoded}");
    }

    #[test]
    #[ignore = "PR5f release gate; run in release with --ignored --nocapture"]
    fn pr05f_apply_newest() {
        let small = fixture(5);
        let god = fixture(2_000);
        let small_entry = FolderEntry::new(
            "local",
            "/folder-0000",
            Some(RowKey::new("local", "chat-newest")),
            10_000,
            1,
        );
        let god_entry = small_entry.clone();
        let (small_p95, _) = timed(|| apply_newest(&small, small_entry.clone()));
        let (god_p95, god_p95_all) = timed(|| apply_newest(&god, god_entry.clone()));
        gate("v2.pr05f.apply_newest", small_p95, god_p95, god_p95_all, "ns");
    }

    #[test]
    #[ignore = "PR5f release gate; run in release with --ignored --nocapture"]
    fn pr05f_apply_move() {
        let small = fixture(5);
        let god = fixture(2_000);
        let remove = FolderEntry::new("local", "/folder-0000", None, 0, 0);
        let insert = FolderEntry::new(
            "local",
            "/folder-moved",
            Some(RowKey::new("local", "chat-0000")),
            10_000,
            1,
        );
        let (small_p95, _) = timed(|| apply_move(&small, remove.clone(), insert.clone()));
        let (god_p95, god_p95_all) = timed(|| apply_move(&god, remove.clone(), insert.clone()));
        gate("v2.pr05f.apply_move", small_p95, god_p95, god_p95_all, "ns");
    }

    #[test]
    #[ignore = "PR5f release gate; run in release with --ignored --nocapture"]
    fn pr05f_first_window() {
        let small = fixture(5);
        let god = fixture(2_000);
        let (small_p95, _) = timed(|| page_window(&small));
        let (god_p95, god_p95_all) = timed(|| page_window(&god));
        gate("v2.pr05f.first_window", small_p95, god_p95, god_p95_all, "ns");
    }

    #[test]
    #[ignore = "PR5f release gate; run in release with --ignored --nocapture"]
    fn pr05f_deep_page() {
        let small = fixture(5);
        let god = fixture(2_000);
        let cursor = god
            .iter()
            .nth(1_000)
            .map(|row| FolderCursor::new(row.at, row.key()))
            .expect("deep cursor");
        let small_cursor = small
            .iter()
            .next()
            .map(|row| FolderCursor::new(row.at, row.key()))
            .expect("small cursor");
        let (small_p95, _) = timed(|| deep_page(&small, &small_cursor));
        let (god_p95, god_p95_all) = timed(|| deep_page(&god, &cursor));
        gate("v2.pr05f.deep_page", small_p95, god_p95, god_p95_all, "ns");
    }

    #[test]
    #[ignore = "PR5f release gate; run in release with --ignored --nocapture"]
    fn pr05f_equal_entry() {
        let small = fixture(5);
        let god = fixture(2_000);
        let equal_small = FolderEntry::new(
            "local",
            "/folder-0000",
            Some(RowKey::new("local", "chat-00000")),
            5,
            1,
        );
        let equal_god = FolderEntry::new(
            "local",
            "/folder-0000",
            Some(RowKey::new("local", "chat-00000")),
            2_000,
            1,
        );
        assert!(small.apply(equal_small).expect("equal small").1.is_none());
        assert!(god.apply(equal_god).expect("equal god").1.is_none());
        gate("v2.pr05f.equal_entry", 0, 0, 0, "ops");
    }

    #[test]
    #[ignore = "PR5f release gate; run in release with --ignored --nocapture"]
    fn pr05f_resident_rss() {
        let (small_rise, _, _) = resident_probe(5).expect("small resident probe");
        let (god_rise, held_rise, encoded) = resident_probe(2_000).expect("god resident probe");
        assert!(encoded < 1_024 * 1_024, "published folder rows exceed 1 MB: {encoded}");
        assert!(god_rise <= 1_024, "folders view resident rise {god_rise} KiB exceeds 1 MB");
        let view_kib = god_rise.max(1);
        let per_version_rise = held_rise / HELD_VERSIONS as u64;
        assert!(
            per_version_rise <= view_kib.saturating_mul(2) / 100 + 1,
            "each held version resident rise {per_version_rise} KiB exceeds 2% of view rise {view_kib} KiB"
        );
        eprintln!(
            "PR5f resident small_rise_kib={small_rise} god_rise_kib={god_rise} held_rise_kib={held_rise} encoded_bytes={encoded}"
        );
    }
}
