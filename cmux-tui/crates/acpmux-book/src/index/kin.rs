//! Persistent hot-row indexes for chat kin and folders.
//!
//! The summary index is ordered by activity, while these views answer the two
//! queries that otherwise make callers walk the complete list.  Each update
//! clones only the path in the persistent maps; the published `SummaryIndex`
//! therefore exposes rows and these views from one immutable snapshot.

use super::{MAX_KIN_DEPTH, RowKey, SortKey, Summary};
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

/// A parent's direct children, carrying each child's own child set.
///
/// The recursive handle lets a family walk move from a parent frame to a
/// child frame without a second table lookup.  Each update path-copies only
/// the changed child set and the parent entries that point at it.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ChildSet {
    entries: OrdMap<RowKey, Arc<ChildSet>>,
}

impl ChildSet {
    pub(super) fn len(&self) -> usize {
        self.entries.len()
    }

    pub(super) fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub(super) fn get(&self, key: &RowKey) -> Option<&Arc<ChildSet>> {
        self.entries.get(key)
    }

    pub(super) fn next_key(&self, root: &RowKey, after: Option<&RowKey>) -> Option<RowKey> {
        use std::ops::Bound::{Excluded, Unbounded};
        self.entries
            .range::<_, RowKey>((after.map_or(Unbounded, Excluded), Unbounded))
            .find(|(key, _)| *key != root)
            .map(|(key, _)| key.clone())
    }

    fn insert(&self, key: RowKey, children: Arc<ChildSet>) -> Self {
        let mut next = self.entries.clone();
        next.insert(key, children);
        Self { entries: next }
    }

    fn remove(&self, key: &RowKey) -> Self {
        let mut next = self.entries.clone();
        next.remove(key);
        Self { entries: next }
    }
}

/// The two edges a summary contributes to the kin view.
#[derive(Clone, Debug, Default)]
pub struct KinTables {
    /// Parent -> direct children and each child's own child-set handle.
    children: OrdMap<RowKey, Arc<ChildSet>>,
    /// Forked chat -> forks.  The value is the fork sequence from the source.
    forks: OrdMap<RowKey, OrdMap<RowKey, u64>>,
    /// (origin, folder) -> rows ordered by the same activity key as `all`.
    /// Folder pages can return these rows directly without a second index lookup.
    folders: OrdMap<FolderKey, OrdMap<SortKey, Arc<Summary>>>,
}

impl PartialEq for KinTables {
    fn eq(&self, other: &Self) -> bool {
        if self.children != other.children
            || self.forks != other.forks
            || self.folders.len() != other.folders.len()
        {
            return false;
        }
        self.folders.iter().all(|(folder, rows)| {
            let Some(other_rows) = other.folders.get(folder) else { return false };
            rows.len() == other_rows.len()
                && rows.iter().all(|(sort, row)| {
                    other_rows.get(sort).is_some_and(|other| row.as_ref().same_content(other))
                })
        })
    }
}

impl Eq for KinTables {}

impl KinTables {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn child_count(&self) -> usize {
        self.children.values().map(|set| set.len()).sum()
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
    #[cfg(test)]
    pub fn replace(&self, old: Option<&Summary>, new: Option<&Summary>) -> Self {
        let mut next = self.clone();
        next.mutate(old, new, None, None, None);
        next
    }

    pub fn replace_arc(
        &self,
        old: Option<&Arc<Summary>>,
        new: Option<&Arc<Summary>>,
        rows: &OrdMap<RowKey, Arc<Summary>>,
    ) -> Self {
        let mut next = self.clone();
        next.mutate(old.map(Arc::as_ref), new.map(Arc::as_ref), new, Some(rows), None);
        next
    }

    /// Replace one row while counting changed table roots.
    #[cfg(test)]
    pub fn replace_counted(
        &self,
        old: Option<&Summary>,
        new: Option<&Summary>,
        writes: &AtomicUsize,
    ) -> Self {
        let mut next = self.clone();
        next.mutate(old, new, None, None, Some(writes));
        next
    }

    pub fn replace_counted_with_rows(
        &self,
        old: Option<&Summary>,
        new: Option<&Summary>,
        rows: &OrdMap<RowKey, Arc<Summary>>,
        writes: &AtomicUsize,
    ) -> Self {
        let mut next = self.clone();
        next.mutate(old, new, None, Some(rows), Some(writes));
        next
    }

    #[cfg(test)]
    pub fn insert(&mut self, summary: &Summary) {
        self.mutate(None, Some(summary), None, None, None);
    }

    pub fn insert_arc(&mut self, summary: &Arc<Summary>, rows: &OrdMap<RowKey, Arc<Summary>>) {
        self.mutate(None, Some(summary), Some(summary), Some(rows), None);
    }

    #[cfg(test)]
    pub fn remove(&mut self, summary: &Summary) {
        self.mutate(Some(summary), None, None, None, None);
    }

    pub fn remove_with_rows(&mut self, summary: &Summary, rows: &OrdMap<RowKey, Arc<Summary>>) {
        self.mutate(Some(summary), None, None, Some(rows), None);
    }

    fn mutate(
        &mut self,
        old: Option<&Summary>,
        new: Option<&Summary>,
        new_arc: Option<&Arc<Summary>>,
        rows: Option<&OrdMap<RowKey, Arc<Summary>>>,
        writes: Option<&AtomicUsize>,
    ) {
        let old_parent = old.map(|row| (row.parent.clone(), row.key()));
        let new_parent = new.map(|row| (row.parent.clone(), row.key()));
        if old_parent != new_parent {
            if let Some((Some(parent), key)) = old_parent.as_ref() {
                self.remove_child(parent, key, rows, writes);
            }
            if let Some((Some(parent), key)) = new_parent.as_ref() {
                self.insert_child(parent, key, rows, writes);
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
        let folder_content_changed = match (old, new) {
            (Some(old), Some(new)) => {
                FolderKey::of(old) == FolderKey::of(new)
                    && SortKey::of(old) == SortKey::of(new)
                    && old.key() == new.key()
                    && !old.same_content(new)
            }
            _ => false,
        };
        if old_folder != new_folder || folder_content_changed {
            if let Some(Some((folder, sort, _key))) = old_folder.as_ref() {
                if folder_content_changed {
                    if let Some(replacement) =
                        new_arc.cloned().or_else(|| new.map(|row| Arc::new(row.clone())))
                    {
                        self.insert_folder(folder, sort, &replacement, writes);
                    }
                } else {
                    self.remove_folder(folder, sort, writes);
                }
            }
            if !folder_content_changed
                && let Some(Some((folder, sort, key))) = new_folder.as_ref()
                && let Some(row) = new
                && &row.key() == key
            {
                let replacement = new_arc.cloned().unwrap_or_else(|| Arc::new(row.clone()));
                self.insert_folder(folder, sort, &replacement, writes);
            }
        }
    }

    fn count(writes: Option<&AtomicUsize>) {
        if let Some(writes) = writes {
            writes.fetch_add(1, AtomicOrdering::Relaxed);
        }
    }

    fn insert_child(
        &mut self,
        parent: &RowKey,
        key: &RowKey,
        rows: Option<&OrdMap<RowKey, Arc<Summary>>>,
        writes: Option<&AtomicUsize>,
    ) {
        let child_set =
            self.children.get(key).cloned().unwrap_or_else(|| Arc::new(ChildSet::default()));
        let parent_set =
            self.children.get(parent).cloned().unwrap_or_else(|| Arc::new(ChildSet::default()));
        if parent_set.get(key).is_some_and(|old| old.as_ref() == child_set.as_ref()) {
            return;
        }
        let updated = Arc::new(parent_set.insert(key.clone(), child_set));
        self.set_children(parent, Some(updated), rows, writes);
    }

    fn remove_child(
        &mut self,
        parent: &RowKey,
        key: &RowKey,
        rows: Option<&OrdMap<RowKey, Arc<Summary>>>,
        writes: Option<&AtomicUsize>,
    ) {
        let Some(parent_set) = self.children.get(parent).cloned() else { return };
        if parent_set.get(key).is_none() {
            return;
        }
        let updated = parent_set.remove(key);
        self.set_children(parent, (!updated.is_empty()).then(|| Arc::new(updated)), rows, writes);
    }

    fn set_children(
        &mut self,
        parent: &RowKey,
        children: Option<Arc<ChildSet>>,
        rows: Option<&OrdMap<RowKey, Arc<Summary>>>,
        writes: Option<&AtomicUsize>,
    ) {
        let mut current = parent.clone();
        let mut value = children;
        let mut visited = OrdSet::new();
        let mut stopped_at_bound = true;
        for _ in 0..=MAX_KIN_DEPTH {
            if !visited.insert(current.clone()) {
                stopped_at_bound = false;
                break;
            }
            match value.take() {
                Some(next) => {
                    self.children.insert(current.clone(), next.clone());
                    value = Some(next);
                }
                None => {
                    self.children.remove(&current);
                }
            }
            Self::count(writes);
            let Some(rows) = rows else {
                stopped_at_bound = false;
                break;
            };
            let Some(row) = rows.get(&current) else {
                stopped_at_bound = false;
                break;
            };
            let Some(grandparent) = row.parent.as_ref() else {
                stopped_at_bound = false;
                break;
            };
            let Some(parent_set) = self.children.get(grandparent).cloned() else {
                stopped_at_bound = false;
                break;
            };
            let Some(child_set) = value.as_ref() else {
                if parent_set.get(&current).is_none() {
                    stopped_at_bound = false;
                    break;
                }
                let empty = Arc::new(ChildSet::default());
                if parent_set.get(&current).is_some_and(|old| old.as_ref() == empty.as_ref()) {
                    stopped_at_bound = false;
                    break;
                }
                let updated = parent_set.insert(current.clone(), empty);
                current = grandparent.clone();
                value = Some(Arc::new(updated));
                continue;
            };
            if parent_set.get(&current).is_some_and(|old| old.as_ref() == child_set.as_ref()) {
                stopped_at_bound = false;
                break;
            }
            let updated = parent_set.insert(current.clone(), child_set.clone());
            current = grandparent.clone();
            value = Some(Arc::new(updated));
        }
        if stopped_at_bound {
            super::KIN_DEPTH_STOPS.fetch_add(1, AtomicOrdering::Relaxed);
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
        row: &Arc<Summary>,
        writes: Option<&AtomicUsize>,
    ) {
        let mut rows = self.folders.get(folder).cloned().unwrap_or_default();
        let changed = rows.get(sort).is_none_or(|existing| !existing.as_ref().same_content(row));
        if changed {
            rows.insert(sort.clone(), row.clone());
            self.folders.insert(folder.clone(), rows);
            Self::count(writes);
        }
    }

    fn remove_folder(&mut self, folder: &FolderKey, sort: &SortKey, writes: Option<&AtomicUsize>) {
        let Some(mut rows) = self.folders.get(folder).cloned() else { return };
        rows.remove(sort);
        if rows.is_empty() {
            self.folders.remove(folder);
        } else {
            self.folders.insert(folder.clone(), rows);
        }
        Self::count(writes);
    }

    pub fn children(&self, parent: &RowKey) -> Option<&ChildSet> {
        self.children.get(parent).map(Arc::as_ref)
    }

    pub fn child_set(&self, parent: &RowKey, child: &RowKey) -> Option<&ChildSet> {
        self.children(parent)?.get(child).map(Arc::as_ref)
    }

    pub fn from_rows<'a>(rows: impl IntoIterator<Item = &'a Arc<Summary>>) -> Self {
        let rows = rows.into_iter().cloned().fold(OrdMap::new(), |mut map, row| {
            map.insert(row.key(), row);
            map
        });
        rows.values().fold(Self::new(), |tables, row| tables.replace_arc(None, Some(row), &rows))
    }

    pub fn forks(&self, parent: &RowKey) -> Option<&OrdMap<RowKey, u64>> {
        self.forks.get(parent)
    }

    pub fn folder_rows(&self, folder: &FolderKey) -> Option<&OrdMap<SortKey, Arc<Summary>>> {
        self.folders.get(folder)
    }

    /// Returns the folder table's current head and count without walking any
    /// other folder. The caller supplies the hot row map to confirm that the
    /// table's head belongs to the same published hot index.
    pub fn folder_entry(
        &self,
        folder: &FolderKey,
        rows: &OrdMap<RowKey, Arc<Summary>>,
    ) -> Option<super::folders::FolderEntry> {
        let table = self.folders.get(folder)?;
        let (sort, row) = table.iter().next()?;
        let key = row.key();
        let _row = rows.get(&key)?;
        Some(super::folders::FolderEntry::new(
            folder.origin.clone(),
            folder.folder.clone(),
            Some(key),
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
        assert_eq!(writes.load(AtomicOrdering::Relaxed), 1);
        assert_eq!(
            unchanged
                .folder_rows(&FolderKey::new("machine", "two"))
                .unwrap()
                .get(&SortKey::of(&title))
                .unwrap()
                .title,
            title.title
        );
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
            let row_map = rows.values().fold(OrdMap::new(), |mut map, row| {
                let arc = Arc::new(row.clone());
                map.insert(arc.key(), arc);
                map
            });
            let rebuilt = KinTables::from_rows(row_map.values());
            assert_eq!(tables, rebuilt, "step {step}");
            assert!(tables.children.values().all(|set| !set.is_empty()));
            assert!(tables.forks.values().all(|map| !map.is_empty()));
            assert!(tables.folders.values().all(|map| !map.is_empty()));
        }
    }

    #[test]
    fn parent_handle_copy_stops_at_depth_and_does_not_copy_siblings() {
        let mut rows = OrdMap::new();
        let mut parent = Arc::new(row("root", 0));
        rows.insert(parent.key(), parent.clone());
        for depth in 0..65 {
            let mut child = row(format!("chain-{depth:02}"), depth + 1);
            child.parent = Some(parent.key());
            parent = Arc::new(child);
            rows.insert(parent.key(), parent.clone());
        }
        let tables = KinTables::from_rows(rows.values());
        let mut leaf = row("new-leaf", 100);
        leaf.parent = Some(parent.key());
        let mut with_leaf = rows.clone();
        let leaf = Arc::new(leaf);
        with_leaf.insert(leaf.key(), leaf.clone());
        let writes = AtomicUsize::new(0);
        let stops_before = super::super::kin_depth_stops();
        let updated =
            tables.replace_counted_with_rows(None, Some(leaf.as_ref()), &with_leaf, &writes);
        assert_eq!(writes.load(AtomicOrdering::Relaxed), MAX_KIN_DEPTH + 1);
        assert_eq!(super::super::kin_depth_stops(), stops_before + 1);
        assert!(updated.children(&parent.key()).is_some_and(|set| set.get(&leaf.key()).is_some()));

        for sibling_count in [10, 10_000] {
            let parent = Arc::new(row(format!("siblings-{sibling_count}"), 0));
            let mut rows = OrdMap::new();
            rows.insert(parent.key(), parent.clone());
            for n in 0..sibling_count {
                let mut child = row(format!("sibling-{sibling_count}-{n}"), n as u64 + 1);
                child.parent = Some(parent.key());
                let child = Arc::new(child);
                rows.insert(child.key(), child);
            }
            let tables = KinTables::from_rows(rows.values());
            let mut next = row(format!("sibling-new-{sibling_count}"), sibling_count as u64 + 1);
            next.parent = Some(parent.key());
            let writes = AtomicUsize::new(0);
            let _ = tables.replace_counted_with_rows(None, Some(&next), &rows, &writes);
            assert_eq!(writes.load(AtomicOrdering::Relaxed), 1);
        }
    }
}
