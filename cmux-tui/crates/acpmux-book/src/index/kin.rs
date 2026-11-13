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

/// One item in a family walk.  The row itself carries `fork_of.seq`; depth is
/// response metadata and is never persisted in either table.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FamilyItem {
    pub key: RowKey,
    pub depth: u16,
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

    /// Replace one hot row.  The old row is removed from all three views first
    /// and the new row is then inserted, so a move touches only its old/new
    /// paths and never scans sibling sets.
    pub fn replace(&self, old: Option<&Summary>, new: Option<&Summary>) -> Self {
        let mut next = self.clone();
        if let Some(old) = old {
            next.remove_row(old);
        }
        if let Some(new) = new {
            next.insert_row(new);
        }
        next
    }

    pub fn insert(&mut self, summary: &Summary) {
        self.insert_row(summary);
    }

    pub fn remove(&mut self, summary: &Summary) {
        self.remove_row(summary);
    }

    fn insert_row(&mut self, summary: &Summary) {
        let key = summary.key();
        if let Some(parent) = summary.parent.as_ref() {
            let mut children = self.children.get(parent).cloned().unwrap_or_default();
            children.insert(key.clone());
            self.children.insert(parent.clone(), children);
        }
        if let Some(fork) = summary.fork_of.as_ref() {
            let mut forks = self.forks.get(&fork.key).cloned().unwrap_or_default();
            forks.insert(key.clone(), fork.seq);
            self.forks.insert(fork.key.clone(), forks);
        }
        if let Some(folder) = FolderKey::of(summary) {
            let mut rows = self.folders.get(&folder).cloned().unwrap_or_default();
            rows.insert(SortKey::of(summary), key);
            self.folders.insert(folder, rows);
        }
    }

    fn remove_row(&mut self, summary: &Summary) {
        let key = summary.key();
        if let Some(parent) = summary.parent.as_ref()
            && let Some(mut children) = self.children.get(parent).cloned()
        {
            children.remove(&key);
            if children.is_empty() {
                self.children.remove(parent);
            } else {
                self.children.insert(parent.clone(), children);
            }
        }
        if let Some(fork) = summary.fork_of.as_ref()
            && let Some(mut forks) = self.forks.get(&fork.key).cloned()
        {
            forks.remove(&key);
            if forks.is_empty() {
                self.forks.remove(&fork.key);
            } else {
                self.forks.insert(fork.key.clone(), forks);
            }
        }
        if let Some(folder) = FolderKey::of(summary)
            && let Some(mut rows) = self.folders.get(&folder).cloned()
        {
            rows.remove(&SortKey::of(summary));
            if rows.is_empty() {
                self.folders.remove(&folder);
            } else {
                self.folders.insert(folder, rows);
            }
        }
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

    /// Breadth-first descendants followed by direct forks.  A visited set is
    /// mandatory: malformed parent data must terminate rather than loop.
    pub fn family(&self, root: &RowKey) -> Vec<FamilyItem> {
        let mut result = Vec::new();
        let mut seen = OrdSet::new();
        seen.insert(root.clone());
        let mut frontier = vec![(root.clone(), 0u16)];
        while !frontier.is_empty() {
            let mut next = Vec::new();
            for (parent, depth) in frontier.drain(..) {
                let Some(children) = self.children.get(&parent) else { continue };
                for child in children {
                    if seen.insert(child.clone()).is_none() {
                        let child_depth = depth.saturating_add(1);
                        result.push(FamilyItem { key: child.clone(), depth: child_depth });
                        next.push((child.clone(), child_depth));
                    }
                }
            }
            frontier = next;
        }
        if let Some(forks) = self.forks.get(root) {
            for key in forks.keys() {
                if seen.insert(key.clone()).is_none() {
                    result.push(FamilyItem { key: key.clone(), depth: 1 });
                }
            }
        }
        result
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
    fn family_is_breadth_first_then_forks_and_stops_on_cycles() {
        let root = row("root", 5);
        let mut child = row("child", 4);
        child.parent = Some(root.key());
        let mut sibling = row("sibling", 3);
        sibling.parent = Some(root.key());
        let mut grandchild = row("grandchild", 2);
        grandchild.parent = Some(child.key());
        let mut fork = row("fork", 1);
        fork.fork_of = Some(super::super::ForkOf { key: root.key(), seq: 8 });
        let mut cycle = row("cycle", 0);
        cycle.parent = Some(grandchild.key());
        let mut root = root;
        root.parent = Some(cycle.key());
        let mut tables = KinTables::new();
        for row in [&root, &child, &sibling, &grandchild, &fork, &cycle] {
            tables.insert(row);
        }
        let got = tables.family(&root.key());
        assert_eq!(
            got.iter().map(|item| item.key.chat_id.as_ref()).collect::<Vec<_>>(),
            ["child", "sibling", "grandchild", "cycle", "fork"]
        );
        assert_eq!(got[0].depth, 1);
        assert_eq!(got[2].depth, 2);
    }

    #[test]
    fn replacing_a_row_moves_only_its_old_and_new_paths() {
        let mut first = row("chat", 1);
        first.origin = "machine".to_owned();
        first.folder = Some("one".to_owned());
        let mut second = first.clone();
        second.last_activity = 2;
        second.folder = Some("two".to_owned());
        let mut tables = KinTables::new();
        tables.insert(&first);
        let moved = tables.replace(Some(&first), Some(&second));
        assert!(moved.folder_rows(&FolderKey::new("machine", "one")).is_none());
        assert_eq!(moved.folder_rows(&FolderKey::new("machine", "two")).unwrap().len(), 1);
    }
}
