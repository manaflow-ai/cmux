//! Persistent hot-row indexes for chat kin and folders.
//!
//! The summary index is ordered by activity, while these views answer the two
//! queries that otherwise make callers walk the complete list.  Each update
//! clones only the path in the persistent maps; the published `SummaryIndex`
//! therefore exposes rows and these views from one immutable snapshot.

use super::{RowKey, SortKey, Summary};
use imbl::{OrdMap, OrdSet};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};

/// A folder is scoped by origin.  Two machines may use the same folder name
/// without sharing a view.
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

    pub fn of(summary: &Summary) -> Option<Self> {
        summary.folder.as_ref().map(|folder| Self::new(summary.origin.as_str(), folder.as_str()))
    }
}

/// The two edges a summary contributes to the kin view.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct KinTables {
    /// Parent -> direct children, ordered by stable row key.
    children: OrdMap<RowKey, OrdSet<RowKey>>,
    /// Forked chat -> forks.  The value is the fork sequence from the source.
    forks: OrdMap<RowKey, OrdMap<RowKey, u64>>,
    /// (origin, folder) -> rows ordered by the same activity key as `all`.
    folders: OrdMap<FolderKey, OrdMap<SortKey, RowKey>>,
}

impl KinTables {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn child_count(&self) -> usize {
        self.children.values().map(OrdSet::len).sum()
    }

    pub fn folder_entry_count(&self) -> usize {
        self.folders.values().map(OrdMap::len).sum()
    }

    pub fn parent_count(&self) -> usize {
        self.children.len()
    }

    pub fn folder_count(&self) -> usize {
        self.folders.len()
    }

    /// Replace one hot row, mutating only the tables whose indexed relation
    /// changed. A title or other non-indexed field update writes no table path.
    pub fn replace(&self, old: Option<&Summary>, new: Option<&Summary>) -> Self {
        let mut next = self.clone();
        next.mutate(old, new, None);
        next
    }

    /// Replace one row while counting changed table roots.
    pub fn replace_counted(
        &self,
        old: Option<&Summary>,
        new: Option<&Summary>,
        writes: &AtomicUsize,
    ) -> Self {
        let mut next = self.clone();
        next.mutate(old, new, Some(writes));
        next
    }

    pub fn insert(&mut self, summary: &Summary) {
        self.mutate(None, Some(summary), None);
    }

    pub fn remove(&mut self, summary: &Summary) {
        self.mutate(Some(summary), None, None);
    }

    fn mutate(
        &mut self,
        old: Option<&Summary>,
        new: Option<&Summary>,
        writes: Option<&AtomicUsize>,
    ) {
        let old_parent = old.map(|row| (row.parent.clone(), row.key()));
        let new_parent = new.map(|row| (row.parent.clone(), row.key()));
        if old_parent != new_parent {
            if let Some((Some(parent), key)) = old_parent.as_ref() {
                self.remove_child(parent, key, writes);
            }
            if let Some((Some(parent), key)) = new_parent.as_ref() {
                self.insert_child(parent, key, writes);
            }
        }

        let old_fork =
            old.map(|row| row.fork_of.as_ref().map(|fork| (fork.key.clone(), fork.seq, row.key())));
        let new_fork =
            new.map(|row| row.fork_of.as_ref().map(|fork| (fork.key.clone(), fork.seq, row.key())));
        if old_fork != new_fork {
            if let Some(Some((parent, _seq, key))) = old_fork.as_ref() {
                self.remove_fork(parent, key, writes);
            }
            if let Some(Some((parent, seq, key))) = new_fork.as_ref() {
                self.insert_fork(parent, key, *seq, writes);
            }
        }

        let old_folder =
            old.map(|row| FolderKey::of(row).map(|folder| (folder, SortKey::of(row), row.key())));
        let new_folder =
            new.map(|row| FolderKey::of(row).map(|folder| (folder, SortKey::of(row), row.key())));
        if old_folder != new_folder {
            if let Some(Some((folder, sort, key))) = old_folder.as_ref() {
                self.remove_folder(folder, sort, key, writes);
            }
            if let Some(Some((folder, sort, key))) = new_folder.as_ref() {
                self.insert_folder(folder, sort, key, writes);
            }
        }
    }

    fn count(writes: Option<&AtomicUsize>) {
        if let Some(writes) = writes {
            writes.fetch_add(1, AtomicOrdering::Relaxed);
        }
    }

    fn insert_child(&mut self, parent: &RowKey, key: &RowKey, writes: Option<&AtomicUsize>) {
        let mut children = self.children.get(parent).cloned().unwrap_or_default();
        if children.insert(key.clone()).is_none() {
            self.children.insert(parent.clone(), children);
            Self::count(writes);
        }
    }

    fn remove_child(&mut self, parent: &RowKey, key: &RowKey, writes: Option<&AtomicUsize>) {
        let Some(mut children) = self.children.get(parent).cloned() else { return };
        if children.remove(key).is_some() {
            if children.is_empty() {
                self.children.remove(parent);
            } else {
                self.children.insert(parent.clone(), children);
            }
            Self::count(writes);
        }
    }

    fn insert_fork(
        &mut self,
        parent: &RowKey,
        key: &RowKey,
        seq: u64,
        writes: Option<&AtomicUsize>,
    ) {
        let mut forks = self.forks.get(parent).cloned().unwrap_or_default();
        if forks.get(key).copied() != Some(seq) {
            forks.insert(key.clone(), seq);
            self.forks.insert(parent.clone(), forks);
            Self::count(writes);
        }
    }

    fn remove_fork(&mut self, parent: &RowKey, key: &RowKey, writes: Option<&AtomicUsize>) {
        let Some(mut forks) = self.forks.get(parent).cloned() else { return };
        if forks.remove(key).is_some() {
            if forks.is_empty() {
                self.forks.remove(parent);
            } else {
                self.forks.insert(parent.clone(), forks);
            }
            Self::count(writes);
        }
    }

    fn insert_folder(
        &mut self,
        folder: &FolderKey,
        sort: &SortKey,
        key: &RowKey,
        writes: Option<&AtomicUsize>,
    ) {
        let mut rows = self.folders.get(folder).cloned().unwrap_or_default();
        if rows.get(sort) != Some(key) {
            rows.insert(sort.clone(), key.clone());
            self.folders.insert(folder.clone(), rows);
            Self::count(writes);
        }
    }

    fn remove_folder(
        &mut self,
        folder: &FolderKey,
        sort: &SortKey,
        key: &RowKey,
        writes: Option<&AtomicUsize>,
    ) {
        let Some(mut rows) = self.folders.get(folder).cloned() else { return };
        if rows.get(sort) != Some(key) {
            return;
        }
        rows.remove(sort);
        if rows.is_empty() {
            self.folders.remove(folder);
        } else {
            self.folders.insert(folder.clone(), rows);
        }
        Self::count(writes);
    }

    pub fn children(&self, parent: &RowKey) -> Option<&OrdSet<RowKey>> {
        self.children.get(parent)
    }

    pub fn forks(&self, parent: &RowKey) -> Option<&OrdMap<RowKey, u64>> {
        self.forks.get(parent)
    }

    pub fn folder_rows(&self, folder: &FolderKey) -> Option<&OrdMap<SortKey, RowKey>> {
        self.folders.get(folder)
    }

    /// Returns the folder table's current head and count without walking any
    /// other folder. The caller supplies the hot row map so the table remains
    /// a compact relation of keys while the published projection carries the
    /// row payload.
    pub fn folder_entry(
        &self,
        folder: &FolderKey,
        rows: &OrdMap<RowKey, Arc<Summary>>,
    ) -> Option<super::folders::FolderEntry> {
        let table = self.folders.get(folder)?;
        let (sort, key) = table.iter().next()?;
        let _row = rows.get(key)?;
        Some(super::folders::FolderEntry::new(
            folder.origin.clone(),
            folder.folder.clone(),
            Some(key.clone()),
            sort.last_activity,
            table.len() as u32,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: &str, at: u64) -> Summary {
        let mut row = Summary::new(id);
        row.last_activity = at;
        row
    }

    #[test]
    fn replacement_only_writes_changed_paths() {
        let mut first = row("chat", 1);
        first.origin = "machine".to_owned();
        first.folder = Some("one".to_owned());
        let mut second = first.clone();
        second.last_activity = 2;
        second.folder = Some("two".to_owned());
        let mut tables = KinTables::new();
        tables.insert(&first);
        let writes = AtomicUsize::new(0);
        let moved = tables.replace_counted(Some(&first), Some(&second), &writes);
        assert_eq!(writes.load(AtomicOrdering::Relaxed), 2);
        assert!(moved.folder_rows(&FolderKey::new("machine", "one")).is_none());
        assert_eq!(moved.folder_rows(&FolderKey::new("machine", "two")).unwrap().len(), 1);

        let mut title = second.clone();
        title.title.push('!');
        let writes = AtomicUsize::new(0);
        let unchanged = moved.replace_counted(Some(&second), Some(&title), &writes);
        assert_eq!(writes.load(AtomicOrdering::Relaxed), 0);
        assert_eq!(unchanged, moved);
    }

    #[test]
    fn randomized_lifecycle_rebuild_has_no_empty_sets() {
        let mut seed = 0x5e_u64;
        let mut rows = std::collections::BTreeMap::new();
        let mut tables = KinTables::new();
        for step in 0..10_000 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
            let id = format!("chat-{}", (seed >> 32) as usize % 64);
            let old = rows.get(&id).cloned();
            let writes = AtomicUsize::new(0);
            if seed & 7 == 0 {
                if let Some(old) = old.as_ref() {
                    tables = tables.replace_counted(Some(old), None, &writes);
                    rows.remove(&id);
                }
            } else {
                let mut next = old.clone().unwrap_or_else(|| row(&id, step));
                next.title = format!("title-{step}");
                next.last_activity = seed;
                next.parent =
                    (seed & 3 != 0).then(|| RowKey::new("local", format!("parent-{}", seed % 8)));
                next.fork_of = (seed & 7 == 1).then(|| super::super::ForkOf {
                    key: RowKey::new("local", format!("fork-{}", seed % 8)),
                    seq: seed,
                });
                next.folder = (seed & 3 == 1).then(|| format!("folder-{}", seed % 4));
                tables = tables.replace_counted(old.as_ref(), Some(&next), &writes);
                rows.insert(id, next);
            }
            let mut rebuilt = KinTables::new();
            for row in rows.values() {
                rebuilt.insert(row);
            }
            assert_eq!(tables, rebuilt, "step {step}");
            assert!(tables.children.values().all(|set| !set.is_empty()));
            assert!(tables.forks.values().all(|map| !map.is_empty()));
            assert!(tables.folders.values().all(|map| !map.is_empty()));
        }
    }
}
