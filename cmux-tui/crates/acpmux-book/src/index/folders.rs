//! Persistent view of the folders used by hot chats.
//!
//! The folder table is owned by the index writer (PR 5e). This module keeps a
//! second, immutable projection over that table: one row per `(origin,
//! folder)` whose entry has a hot chat. Applying an entry copies only the two
//! persistent-map paths touched by that folder, and returns the one operation a
//! subscriber needs to observe.

#[cfg(test)]
use super::MAX_FIELD_BYTES;
use super::{ListFilter, RowKey};
use imbl::OrdMap;
use std::cmp::Ordering;
use std::io;
use std::ops::Bound::{Excluded, Included, Unbounded};
use std::sync::Arc;

pub use acpmux_list_types::folders::{FolderKey, MAX_FOLDER_BYTES};

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

pub use acpmux_list_types::folders::FolderRow;

fn from_entry(entry: &FolderEntry) -> Option<FolderRow> {
    Some(FolderRow {
        origin: entry.key.origin.clone(),
        folder: entry.key.folder.clone(),
        newest: entry.newest.clone()?,
        at: entry.at,
        count: entry.count,
    })
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
        let Some(row) = from_entry(&entry).map(Arc::new) else {
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
        self.read_page_visible(cursor, side, inclusive, (limit, max_bytes), filter, |_| true)
    }

    /// Reads a page while applying an additional visibility predicate to each
    /// candidate. Hidden rows consume the candidate bound and continuation but
    /// no response bytes, matching the list's origin-removal rule. `bounds`
    /// contains the candidate limit and encoded row byte budget.
    pub fn read_page_visible(
        &self,
        cursor: Option<&FolderCursor>,
        side: FolderReadSide,
        inclusive: bool,
        bounds: (usize, usize),
        filter: Option<&ListFilter>,
        visible: impl Fn(&FolderRow) -> bool,
    ) -> io::Result<FolderPage> {
        self.read_page_accounted(cursor, side, inclusive, bounds, filter, (visible, |_| 0))
    }

    /// Like `read_page_visible`, but also reserves each continuation's encoded
    /// cost. Both hidden and returned candidates carry a continuation; a key
    /// that would exceed the budget is left for the next page.
    pub fn read_page_accounted(
        &self,
        cursor: Option<&FolderCursor>,
        side: FolderReadSide,
        inclusive: bool,
        bounds: (usize, usize),
        filter: Option<&ListFilter>,
        predicates: (impl Fn(&FolderRow) -> bool, impl Fn(&FolderRow) -> usize),
    ) -> io::Result<FolderPage> {
        let (visible, cursor_bytes) = predicates;
        let (limit, max_bytes) = bounds;
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
        let mut first_cursor_bytes: Option<usize> = None;
        for row in candidates.take(limit) {
            let row_bytes = if matches(row) { row.encoded_len().saturating_add(1) } else { 0 };
            let key_bytes = cursor_bytes(row);
            let cursors = first_cursor_bytes.unwrap_or(key_bytes).saturating_add(key_bytes);
            if bytes_read.saturating_add(row_bytes).saturating_add(cursors) > max_bytes {
                if visited.is_empty() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "folders page byte budget cannot fit the next candidate",
                    ));
                }
                byte_limited = true;
                break;
            }
            first_cursor_bytes.get_or_insert(key_bytes);
            visited.push(row.clone());
            bytes_read = bytes_read.saturating_add(row_bytes);
            if row_bytes != 0 {
                rows.push(row.clone());
            }
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
#[path = "folders_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "folders_release_gates_tests.rs"]
mod release_gates;
