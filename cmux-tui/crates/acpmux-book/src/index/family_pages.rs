//! A bounded preorder walk over hot parent edges (decisions 137 and 140).

use super::{IndexPage, ListFilter, RowKey, SortKey, Summary, SummaryIndex};
use std::io;
use std::ops::Bound::{Excluded, Unbounded};
use std::sync::Arc;

const MAX_DEPTH: usize = 64;

#[derive(Debug)]
pub struct CursorGone;

impl std::fmt::Display for CursorGone {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("cursor_gone")
    }
}

impl std::error::Error for CursorGone {}

impl SummaryIndex {
    fn first_child(
        &self,
        root: &RowKey,
        parent: &RowKey,
        after: Option<&RowKey>,
    ) -> Option<RowKey> {
        self.kin()
            .children(parent)?
            .range((after.map_or(Unbounded, Excluded), Unbounded))
            .find(|key| *key != root)
            .cloned()
    }

    /// Build only the cursor's ancestor path, never the rest of its family.
    fn family_path(
        &self,
        root: &RowKey,
        key: &RowKey,
        steps: &mut usize,
    ) -> Option<Vec<Arc<Summary>>> {
        if key == root {
            return None;
        }
        let mut path = Vec::new();
        let mut key = key.clone();
        for _ in 0..MAX_DEPTH {
            *steps += 1;
            let row = self.get_row(&key)?;
            let parent = row.parent.clone()?;
            path.push(row);
            if &parent == root {
                path.reverse();
                return Some(path);
            }
            key = parent;
        }
        None
    }

    /// A piece boundary cannot change membership. Only hot ancestors are read.
    pub(super) fn cold_descendant(&self, row: &Summary, root: &RowKey, steps: &mut usize) -> bool {
        if row.key() == *root {
            return false;
        }
        let Some(mut parent) = row.parent.clone() else {
            return false;
        };
        for _ in 0..MAX_DEPTH {
            if &parent == root {
                return true;
            }
            *steps += 1;
            let Some(row) = self.get_row(&parent) else {
                return false;
            };
            let Some(next) = row.parent.clone() else {
                return false;
            };
            parent = next;
        }
        &parent == root
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn read_family_page(
        &self,
        root: &RowKey,
        inclusive: bool,
        limit: usize,
        max_bytes: usize,
        anchor: Option<&SortKey>,
        filter: &ListFilter,
    ) -> io::Result<IndexPage> {
        let mut parent_steps = 0;
        let path = if let Some(anchor) = anchor {
            self.family_path(root, &anchor.row, &mut parent_steps)
                .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, CursorGone))?
        } else {
            Vec::new()
        };
        let has_before = anchor.is_some_and(|anchor| {
            !inclusive
                || path.len() != 1
                || self.first_child(root, root, None).as_ref() != Some(&anchor.row)
        });
        let mut pending = if inclusive { path.last().cloned() } else { None };
        let mut walk = FamilyWalk { index: self, root, path, started: anchor.is_some() };
        let mut rows = Vec::new();
        let mut before_key = None;
        let mut after_key = None;
        let mut bytes = 0usize;
        let mut consumed = 0;
        let mut rows_read = 0;
        let has_after = loop {
            let row = match pending.take() {
                Some(row) => Some(row),
                None => walk.next(&mut rows_read)?,
            };
            let Some(row) = row else {
                break false;
            };
            if consumed == limit {
                break true;
            }
            let visible = filter.matches(&row);
            let size = if visible { row.encoded_len() + 1 } else { 0 };
            if bytes.saturating_add(size) > max_bytes {
                if consumed == 0 {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "page byte budget cannot fit the next row",
                    ));
                }
                break true;
            }
            bytes += size;
            consumed += 1;
            let key = SortKey::of(&row);
            before_key.get_or_insert_with(|| key.clone());
            after_key = Some(key);
            if visible {
                rows.push(row);
            }
        };
        Ok(IndexPage {
            rows,
            has_before,
            has_after,
            before_key,
            after_key,
            bytes_read: 0,
            cold_unread: !has_after && self.disk().is_some_and(|disk| !disk.is_empty()),
            rows_read,
            parent_steps,
        })
    }
}

struct FamilyWalk<'a> {
    index: &'a SummaryIndex,
    root: &'a RowKey,
    path: Vec<Arc<Summary>>,
    started: bool,
}

impl FamilyWalk<'_> {
    fn load(&mut self, key: RowKey, reads: &mut usize) -> io::Result<Option<Arc<Summary>>> {
        *reads += 1;
        let row = self.index.get_row(&key).ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, "kin table names a missing hot row")
        })?;
        self.path.push(row.clone());
        Ok(Some(row))
    }

    fn next(&mut self, reads: &mut usize) -> io::Result<Option<Arc<Summary>>> {
        if !self.started {
            self.started = true;
            return match self.index.first_child(self.root, self.root, None) {
                Some(key) => self.load(key, reads),
                None => Ok(None),
            };
        }
        if self.path.len() < MAX_DEPTH
            && let Some(current) = self.path.last()
            && let Some(key) = self.index.first_child(self.root, &current.key(), None)
        {
            return self.load(key, reads);
        }
        while let Some(current) = self.path.pop() {
            let parent = self.path.last().map_or_else(|| self.root.clone(), |row| row.key());
            if let Some(key) = self.index.first_child(self.root, &parent, Some(&current.key())) {
                return self.load(key, reads);
            }
        }
        Ok(None)
    }
}
