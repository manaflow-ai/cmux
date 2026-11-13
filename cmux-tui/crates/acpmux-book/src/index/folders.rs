//! Persistent view of the folders used by hot chats.
//!
//! The folder table is owned by the index writer (PR 5e). This module keeps a
//! second, immutable projection over that table: one row per `(origin,
//! folder)` whose entry has a hot chat. Applying an entry copies only the two
//! persistent-map paths touched by that folder, and returns the one operation a
//! subscriber needs to observe.

use super::{MAX_FIELD_BYTES, RowKey};
use imbl::OrdMap;
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::io;
use std::ops::Bound::{Excluded, Unbounded};
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
pub const MAX_FOLDER_PAGE_BYTES: usize = 256 * 1024;

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
        let mut next = self.clone();
        let old = self.by_key.get(&entry.key).cloned();
        let Some(row) = FolderRow::from_entry(&entry).map(Arc::new) else {
            if let Some(old) = old {
                next.by_key.remove(&entry.key);
                next.ordered.remove(&FolderSortKey { at: old.at, key: entry.key.clone() });
                return Ok((next, Some(FolderOp::Gone(entry.key))));
            }
            return Ok((self.clone(), None));
        };
        if old.as_ref().is_some_and(|old| old.as_ref() == row.as_ref()) {
            return Ok((self.clone(), None));
        }
        if let Some(old) = old {
            next.ordered.remove(&FolderSortKey { at: old.at, key: entry.key.clone() });
        }
        next.ordered.insert(FolderSortKey { at: row.at, key: entry.key.clone() }, row.clone());
        next.by_key.insert(entry.key, row.clone());
        Ok((next, Some(FolderOp::Folder(row))))
    }

    pub fn window(&self, limit: usize, max_bytes: usize) -> io::Result<FolderPage> {
        self.read_page(None, FolderReadSide::After, false, limit, max_bytes)
    }

    pub fn page_after(
        &self,
        cursor: Option<&FolderCursor>,
        limit: usize,
        max_bytes: usize,
    ) -> io::Result<FolderPage> {
        self.read_page(cursor, FolderReadSide::After, false, limit, max_bytes)
    }

    pub fn page_before(
        &self,
        cursor: &FolderCursor,
        limit: usize,
        max_bytes: usize,
    ) -> io::Result<FolderPage> {
        self.read_page(Some(cursor), FolderReadSide::Before, false, limit, max_bytes)
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
    ) -> io::Result<FolderPage> {
        if limit == 0
            || limit > MAX_FOLDER_ROWS
            || max_bytes == 0
            || max_bytes > MAX_FOLDER_PAGE_BYTES
        {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid folders page bound"));
        }
        let anchor = cursor.map(FolderCursor::sort_key);
        let (start, end) = match (anchor.as_ref(), side) {
            (Some(anchor), FolderReadSide::After) => (Excluded(anchor), Unbounded),
            (Some(anchor), FolderReadSide::Before) => (Unbounded, Excluded(anchor)),
            (None, _) => (Unbounded, Unbounded),
        };
        let mut candidates: Vec<(FolderSortKey, Arc<FolderRow>)> = self
            .ordered
            .range::<_, FolderSortKey>((start, end))
            .map(|(key, row)| (key.clone(), row.clone()))
            .collect();
        if inclusive
            && let Some(anchor) = anchor.as_ref()
            && let Some(row) = self.ordered.get(anchor)
        {
            candidates.push((anchor.clone(), row.clone()));
            candidates.sort_by(|left, right| left.0.cmp(&right.0));
        }
        if side == FolderReadSide::Before {
            candidates.reverse();
        }
        let mut rows = Vec::new();
        let mut bytes_read = 0usize;
        for (_, row) in candidates.iter().take(limit) {
            let row_bytes = row.encoded_len();
            if bytes_read.saturating_add(row_bytes) > max_bytes {
                if rows.is_empty() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "folders page byte budget cannot fit the next row",
                    ));
                }
                break;
            }
            bytes_read = bytes_read.saturating_add(row_bytes);
            rows.push(row.clone());
        }
        if side == FolderReadSide::Before {
            rows.reverse();
        }
        let before_key = rows.first().map(|row| FolderCursor::new(row.at, row.key()));
        let after_key = rows.last().map(|row| FolderCursor::new(row.at, row.key()));
        let has_before = before_key.as_ref().is_some_and(|key| {
            self.ordered
                .range::<_, FolderSortKey>((Unbounded, Excluded(&key.sort_key())))
                .next()
                .is_some()
        });
        let has_after = after_key.as_ref().is_some_and(|key| {
            self.ordered
                .range::<_, FolderSortKey>((Excluded(&key.sort_key()), Unbounded))
                .next()
                .is_some()
        });
        Ok(FolderPage { rows, has_before, has_after, before_key, after_key, bytes_read })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
    use std::time::Instant;

    const ROUNDS: usize = 5;
    const SAMPLES: usize = 200;

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

    fn fixture(count: usize) -> Folders {
        (0..count).fold(Folders::new(), |folders, n| {
            folders
                .apply(FolderEntry::new(
                    "local",
                    format!("/folder-{n:04}"),
                    Some(RowKey::new("local", format!("chat-{n:05}"))),
                    (count - n) as u64,
                    1,
                ))
                .expect("fixture entry")
                .0
        })
    }

    fn apply_newest(folders: &Folders) -> u128 {
        let started = Instant::now();
        let next = folders
            .apply(FolderEntry::new(
                "local",
                "/folder-0000",
                Some(RowKey::new("local", "chat-newest")),
                10_000,
                1,
            ))
            .expect("newest update")
            .0;
        black_box(next);
        started.elapsed().as_nanos().max(1)
    }

    fn apply_move(folders: &Folders) -> u128 {
        let started = Instant::now();
        let (next, _) = folders
            .apply(FolderEntry::new("local", "/folder-0000", None, 0, 0))
            .expect("old folder removal");
        let next = next
            .apply(FolderEntry::new(
                "local",
                "/folder-moved",
                Some(RowKey::new("local", "chat-0000")),
                10_000,
                1,
            ))
            .expect("new folder insert")
            .0;
        black_box(next);
        started.elapsed().as_nanos().max(1)
    }

    fn page_window(folders: &Folders) -> u128 {
        let started = Instant::now();
        let first = folders.window(20, MAX_FOLDER_PAGE_BYTES).expect("first window");
        black_box(first);
        started.elapsed().as_nanos().max(1)
    }

    fn deep_page(folders: &Folders, cursor: &FolderCursor) -> u128 {
        let started = Instant::now();
        let page = folders.page_after(Some(cursor), 20, MAX_FOLDER_PAGE_BYTES).expect("deep page");
        black_box(page);
        started.elapsed().as_nanos().max(1)
    }

    fn encoded_bytes(folders: &Folders) -> usize {
        folders.iter().map(|row| row.encoded_len()).sum()
    }

    #[test]
    #[ignore = "PR5f release gate; run in release with --ignored --nocapture"]
    fn pr05f_apply_newest_and_move() {
        let small = fixture(5);
        let god = fixture(2_000);
        let (small_newest, _) = timed(|| apply_newest(&small));
        let (god_newest, god_newest_all) = timed(|| apply_newest(&god));
        let (small_move, _) = timed(|| apply_move(&small));
        let (god_move, god_move_all) = timed(|| apply_move(&god));
        eprintln!(
            "PR5f apply_newest small_p95_ns={small_newest} god_p95_ns={god_newest} god_p95_all_ns={god_newest_all}"
        );
        eprintln!(
            "PR5f apply_move small_p95_ns={small_move} god_p95_ns={god_move} god_p95_all_ns={god_move_all}"
        );
        gate(
            "v2.pr05f.apply_update",
            small_newest.max(small_move),
            god_newest.max(god_move),
            god_newest_all.max(god_move_all),
            "ns",
        );
    }

    #[test]
    #[ignore = "PR5f release gate; run in release with --ignored --nocapture"]
    fn pr05f_window_and_deep_page() {
        let small = fixture(5);
        let god = fixture(2_000);
        let small_cursor = small
            .iter()
            .nth(2)
            .map(|row| FolderCursor::new(row.at, row.key()))
            .expect("small cursor");
        let god_cursor = god
            .iter()
            .nth(1_000)
            .map(|row| FolderCursor::new(row.at, row.key()))
            .expect("deep cursor");
        let (small_window, _) = timed(|| page_window(&small));
        let (god_window, god_window_all) = timed(|| page_window(&god));
        let (small_page, _) = timed(|| deep_page(&small, &small_cursor));
        let (god_page, god_page_all) = timed(|| deep_page(&god, &god_cursor));
        gate(
            "v2.pr05f.window_page",
            small_window.max(small_page),
            god_window.max(god_page),
            god_window_all.max(god_page_all),
            "ns",
        );
    }

    #[test]
    #[ignore = "PR5f release gate; run in release with --ignored --nocapture"]
    fn pr05f_published_bytes_and_path_copy() {
        let small = fixture(5);
        let god = fixture(2_000);
        let small_bytes = encoded_bytes(&small);
        let god_bytes = encoded_bytes(&god);
        assert!(god_bytes < 1_024 * 1_024, "published folder rows exceed 1 MB: {god_bytes}");
        let old_len = god.len();
        let started = Instant::now();
        let next = god
            .apply(FolderEntry::new(
                "local",
                "/folder-extra",
                Some(RowKey::new("local", "chat-extra")),
                20_000,
                1,
            ))
            .expect("path-copy insert")
            .0;
        let path_copy_ns = started.elapsed().as_nanos().max(1);
        assert_eq!(god.len(), old_len);
        assert_eq!(next.len(), old_len + 1);
        eprintln!(
            "PR5f published_bytes small={small_bytes} god={god_bytes} path_copy_ns={path_copy_ns}"
        );
        gate(
            "v2.pr05f.published_bytes_path_copy",
            small_bytes as u128,
            god_bytes as u128,
            god_bytes as u128,
            "bytes",
        );
    }

    #[test]
    #[ignore = "PR5f release gate; run in release with --ignored --nocapture"]
    fn pr05f_folder_key_bound() {
        let folder = "f".repeat(MAX_FOLDER_BYTES);
        let (folders, _) = Folders::new()
            .apply(FolderEntry::new(
                "local",
                folder.clone(),
                Some(RowKey::new("local", "chat-bound")),
                1,
                1,
            ))
            .expect("bounded folder");
        let row = folders.iter().next().expect("bounded row");
        assert_eq!(row.folder.len(), MAX_FOLDER_BYTES);
        assert_eq!(row.key().folder.as_ref(), folder);
        gate(
            "v2.pr05f.folder_key_bound",
            row.folder.len() as u128,
            row.folder.len() as u128,
            row.folder.len() as u128,
            "bytes",
        );
    }
}
