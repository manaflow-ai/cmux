//! The heights a chat's rows were measured at, kept by row: its id, its content's
//! fingerprint, its disclosures and the column width. A transcript page that is built
//! again (a top-bar swipe back to a tab, the app opened again) asks for its rows'
//! heights in one keyed diff: a row whose key is unchanged since it was measured draws
//! at that height at once, so nothing below it moves when its cell measures it. Only a
//! changed or new row starts at an estimate.
//!
//! One object for the app, called on the main actor; a mutex keeps it `Sync` for
//! uniffi and is held only for the call. Bounded: past `capacity` rows the least
//! recently used quarter goes, so the cost of a call stays constant as chats grow.

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Mutex, MutexGuard, PoisonError};

/// A row as a page lays it out now.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RowLayoutKey {
    /// The row's id, stable for the life of the row.
    pub id: String,
    /// `row_layout_fingerprint` of what the row draws.
    pub content: u64,
    /// Which of its disclosures are open.
    pub fold: u32,
}

/// A row against the heights kept for it.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Enum)]
pub enum RowLayoutDiff {
    /// Same id, content, disclosures and width as when it was measured: its height.
    Unchanged { height: f64 },
    /// Measured before with other content, disclosures or width: its cell measures it.
    Changed,
    /// Never measured.
    New,
}

/// Heights kept and how the last diffs went (the probe's log and tests).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, uniffi::Record)]
pub struct RowLayoutStats {
    pub rows: u64,
    pub unchanged: u64,
    pub changed: u64,
    pub new: u64,
}

/// A stable 64-bit FNV-1a fingerprint of `text`: the same on every launch, so a kept
/// height is found again after the app opens again.
#[uniffi::export]
pub fn row_layout_fingerprint(text: String) -> u64 {
    fingerprint(text.as_bytes())
}

fn fingerprint(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    hash
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct Kept {
    content: u64,
    fold: u32,
    /// Column width in half points.
    width: i64,
    height: f64,
    used: u64,
}

#[derive(Default)]
struct Inner {
    /// scope -> row id -> its newest measurement.
    rows: HashMap<String, HashMap<String, Kept>>,
    count: usize,
    clock: u64,
    stats: RowLayoutStats,
}

fn half_points(width: f64) -> i64 {
    if width.is_finite() { (width * 2.0).round() as i64 } else { 0 }
}

impl Inner {
    fn diff(&mut self, scope: &str, width: i64, key: &RowLayoutKey) -> RowLayoutDiff {
        self.clock += 1;
        let clock = self.clock;
        let Some(kept) = self.rows.get_mut(scope).and_then(|rows| rows.get_mut(&key.id)) else {
            self.stats.new += 1;
            return RowLayoutDiff::New;
        };
        if kept.content == key.content && kept.fold == key.fold && kept.width == width {
            kept.used = clock;
            self.stats.unchanged += 1;
            RowLayoutDiff::Unchanged { height: kept.height }
        } else {
            self.stats.changed += 1;
            RowLayoutDiff::Changed
        }
    }

    fn record(&mut self, scope: &str, width: i64, key: &RowLayoutKey, height: f64, capacity: usize) {
        if !height.is_finite() || height <= 0.0 {
            return;
        }
        self.clock += 1;
        let kept = Kept { content: key.content, fold: key.fold, width, height, used: self.clock };
        let rows = self.rows.entry(scope.to_owned()).or_default();
        if rows.insert(key.id.clone(), kept).is_none() {
            self.count += 1;
        }
        if self.count > capacity {
            self.evict(capacity - capacity / 4);
        }
    }

    /// Keeps the `keep` most recently used rows.
    fn evict(&mut self, keep: usize) {
        let mut used: Vec<u64> =
            self.rows.values().flat_map(|rows| rows.values().map(|kept| kept.used)).collect();
        if used.len() <= keep {
            return;
        }
        let cut = used.len() - keep;
        used.select_nth_unstable(cut - 1);
        let oldest_kept = used[cut - 1];
        for rows in self.rows.values_mut() {
            rows.retain(|_, kept| kept.used > oldest_kept);
        }
        self.rows.retain(|_, rows| !rows.is_empty());
        self.count = self.rows.values().map(HashMap::len).sum();
    }
}

#[derive(uniffi::Object)]
pub struct RowLayoutMemory {
    inner: Mutex<Inner>,
    capacity: usize,
}

impl RowLayoutMemory {
    fn inner(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[uniffi::export]
impl RowLayoutMemory {
    /// Keeps at most `capacity` rows (at least 64).
    #[uniffi::constructor]
    pub fn new(capacity: u32) -> Self {
        Self { inner: Mutex::new(Inner::default()), capacity: (capacity as usize).max(64) }
    }

    /// The keyed diff of a page's rows in `scope` (a chat, at a text size) at column `width`
    /// against the heights kept: one answer per key, in order.
    pub fn diff(&self, scope: String, width: f64, keys: Vec<RowLayoutKey>) -> Vec<RowLayoutDiff> {
        let width = half_points(width);
        let mut inner = self.inner();
        keys.iter().map(|key| inner.diff(&scope, width, key)).collect()
    }

    /// A cell measured row `key` at `height` in a column `width` wide.
    pub fn record(&self, scope: String, width: f64, key: RowLayoutKey, height: f64) {
        let capacity = self.capacity;
        self.inner().record(&scope, half_points(width), &key, height, capacity);
    }

    /// Drops every height kept in `scope`.
    pub fn forget(&self, scope: String) {
        let mut inner = self.inner();
        if let Some(rows) = inner.rows.remove(&scope) {
            inner.count -= rows.len();
        }
    }

    pub fn stats(&self) -> RowLayoutStats {
        let inner = self.inner();
        RowLayoutStats { rows: inner.count as u64, ..inner.stats }
    }

    /// Writes the heights to `path` (one row per line), for the next launch. Whether it was written.
    pub fn save(&self, path: String) -> bool {
        let text = {
            let inner = self.inner();
            let mut text = String::with_capacity(inner.count * 64);
            for (scope, rows) in &inner.rows {
                for (id, kept) in rows {
                    if scope.contains(['\t', '\n']) || id.contains(['\t', '\n']) {
                        continue;
                    }
                    text.push_str(&format!(
                        "{scope}\t{id}\t{}\t{}\t{}\t{}\t{}\n",
                        kept.content, kept.fold, kept.width, kept.height, kept.used
                    ));
                }
            }
            text
        };
        let path = Path::new(&path);
        let temporary = path.with_extension("tmp");
        std::fs::write(&temporary, text).and_then(|()| std::fs::rename(&temporary, path)).is_ok()
    }

    /// Adds the heights written by `save` at `path`; rows measured since are kept over them.
    /// How many rows it read.
    pub fn load(&self, path: String) -> u32 {
        let Ok(text) = std::fs::read_to_string(path) else { return 0 };
        let capacity = self.capacity;
        let mut inner = self.inner();
        let mut read = 0;
        for line in text.lines() {
            let fields: Vec<&str> = line.split('\t').collect();
            let [scope, id, content, fold, width, height, used] = fields[..] else { continue };
            let (Ok(content), Ok(fold), Ok(width), Ok(height), Ok(used)) =
                (content.parse(), fold.parse(), width.parse(), height.parse::<f64>(), used.parse::<u64>())
            else {
                continue;
            };
            if !height.is_finite() || height <= 0.0 {
                continue;
            }
            inner.clock = inner.clock.max(used);
            let rows = inner.rows.entry(scope.to_owned()).or_default();
            if rows.contains_key(id) {
                continue;
            }
            rows.insert(id.to_owned(), Kept { content, fold, width, height, used });
            inner.count += 1;
            read += 1;
        }
        if inner.count > capacity {
            inner.evict(capacity - capacity / 4);
        }
        read
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(id: &str, content: &str, fold: u32) -> RowLayoutKey {
        RowLayoutKey { id: id.into(), content: row_layout_fingerprint(content.into()), fold }
    }

    #[test]
    fn a_measured_row_is_unchanged_until_its_content_fold_or_width_changes() {
        let memory = RowLayoutMemory::new(64);
        let scope = "chat|L".to_string();
        assert_eq!(memory.diff(scope.clone(), 390.0, vec![key("a", "hello", 0)]), vec![RowLayoutDiff::New]);
        memory.record(scope.clone(), 390.0, key("a", "hello", 0), 44.5);
        assert_eq!(
            memory.diff(scope.clone(), 390.0, vec![key("a", "hello", 0), key("b", "x", 0)]),
            vec![RowLayoutDiff::Unchanged { height: 44.5 }, RowLayoutDiff::New]
        );
        assert_eq!(
            memory.diff(scope.clone(), 390.0, vec![key("a", "hello!", 0)]),
            vec![RowLayoutDiff::Changed]
        );
        assert_eq!(
            memory.diff(scope.clone(), 390.0, vec![key("a", "hello", 1)]),
            vec![RowLayoutDiff::Changed]
        );
        assert_eq!(
            memory.diff(scope.clone(), 320.0, vec![key("a", "hello", 0)]),
            vec![RowLayoutDiff::Changed]
        );
        assert_eq!(memory.diff("other".into(), 390.0, vec![key("a", "hello", 0)]), vec![RowLayoutDiff::New]);
        memory.forget(scope.clone());
        assert_eq!(memory.diff(scope, 390.0, vec![key("a", "hello", 0)]), vec![RowLayoutDiff::New]);
        assert_eq!(memory.stats().rows, 0);
    }

    #[test]
    fn the_fingerprint_is_stable_across_launches() {
        assert_eq!(row_layout_fingerprint(String::new()), 0xcbf2_9ce4_8422_2325);
        assert_eq!(row_layout_fingerprint("a".into()), 0xaf63_dc4c_8601_ec8c);
    }

    #[test]
    fn past_capacity_the_least_recently_used_rows_go() {
        let memory = RowLayoutMemory::new(64);
        for row in 0..64 {
            memory.record("s".into(), 390.0, key(&format!("r{row}"), "c", 0), 20.0);
        }
        // r0 is used again, so it outlives the rows after it.
        assert!(matches!(
            memory.diff("s".into(), 390.0, vec![key("r0", "c", 0)])[0],
            RowLayoutDiff::Unchanged { .. }
        ));
        memory.record("s".into(), 390.0, key("r64", "c", 0), 20.0);
        assert_eq!(memory.stats().rows, 48);
        assert!(matches!(
            memory.diff("s".into(), 390.0, vec![key("r0", "c", 0)])[0],
            RowLayoutDiff::Unchanged { .. }
        ));
        assert!(matches!(
            memory.diff("s".into(), 390.0, vec![key("r64", "c", 0)])[0],
            RowLayoutDiff::Unchanged { .. }
        ));
        assert_eq!(memory.diff("s".into(), 390.0, vec![key("r1", "c", 0)]), vec![RowLayoutDiff::New]);
    }

    #[test]
    fn heights_survive_a_save_and_load() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("rows.tsv").to_string_lossy().into_owned();
        let memory = RowLayoutMemory::new(64);
        memory.record("chat|L".into(), 390.0, key("a", "hello", 2), 61.0);
        assert!(memory.save(path.clone()));
        let next = RowLayoutMemory::new(64);
        assert_eq!(next.load(path), 1);
        assert_eq!(
            next.diff("chat|L".into(), 390.0, vec![key("a", "hello", 2)]),
            vec![RowLayoutDiff::Unchanged { height: 61.0 }]
        );
    }

    #[test]
    fn a_bad_height_is_not_kept() {
        let memory = RowLayoutMemory::new(64);
        memory.record("s".into(), 390.0, key("a", "c", 0), f64::NAN);
        memory.record("s".into(), 390.0, key("b", "c", 0), 0.0);
        assert_eq!(memory.stats().rows, 0);
    }
}
