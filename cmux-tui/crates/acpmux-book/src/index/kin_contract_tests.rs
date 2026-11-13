//! Behavioral regressions for the held kin/folder pager implementation.
//! These assertions describe the contract, not the current incorrect output.

use super::*;
use std::sync::Arc;

fn row(id: &str, activity: u64) -> Summary {
    let mut row = Summary::new(id);
    row.last_activity = activity;
    row
}

fn cold(rows: &[Summary]) -> (tempfile::TempDir, SummaryIndex) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("index.snap");
    let mut full = SummaryIndex::new();
    for (n, row) in rows.iter().enumerate() {
        full = full.apply(n as u64 + 1, row.clone());
    }
    SortedSnapshot::write(&path, &full).unwrap();
    let disk = Arc::new(DiskSnapshot::open(&path).unwrap().unwrap());
    (dir, SummaryIndex::from_disk(Some(disk), 1))
}

fn ids(page: &IndexPage) -> Vec<&str> {
    page.rows.iter().map(|row| row.chat_id.as_str()).collect()
}

#[test]
fn family_breadth_first_order_is_independent_of_activity() {
    let root = row("root", 1);
    let mut child = row("child", 10);
    child.parent = Some(root.key());
    let mut grandchild = row("grandchild", 100);
    grandchild.parent = Some(child.key());
    let index = SummaryIndex::new().apply(1, child).apply(2, grandchild);
    let page = index
        .read_page(
            None,
            ReadSide::After,
            false,
            10,
            256 * 1024,
            Some(&ListFilter::family(root.key())),
        )
        .unwrap();
    assert_eq!(ids(&page), ["child", "grandchild"]);
}

#[test]
fn cold_grandchild_resolves_a_hot_parent() {
    let root = row("root", 1);
    let mut child = row("child", 100);
    child.parent = Some(root.key());
    let mut grandchild = row("grandchild", 10);
    grandchild.parent = Some(child.key());
    let (_dir, index) = cold(&[grandchild]);
    let index = index.apply(2, child);
    let page = index
        .read_page(
            None,
            ReadSide::After,
            false,
            10,
            256 * 1024,
            Some(&ListFilter::family(root.key())),
        )
        .unwrap();
    assert_eq!(ids(&page), ["child", "grandchild"]);
    assert_eq!(page.rows.last().unwrap().depth, Some(2));
}

fn scan(index: &SummaryIndex, filter: &ListFilter) -> Vec<String> {
    let mut anchor = None;
    let mut found = Vec::new();
    for _ in 0..10 {
        let page = index
            .read_page(anchor.as_ref(), ReadSide::After, false, 1, 256 * 1024, Some(filter))
            .unwrap();
        assert!(page.bytes_read <= 256 * 1024);
        found.extend(page.rows.iter().map(|row| row.chat_id.clone()));
        if !page.has_after {
            return found;
        }
        let next = page.after_key.expect("an unread piece needs a physical continuation");
        assert_ne!(anchor.as_ref(), Some(&next), "continuation must make progress");
        anchor = Some(next);
    }
    panic!("a two-row snapshot did not finish within ten pieces");
}

#[test]
fn cold_family_membership_can_depend_on_an_unread_piece() {
    let root = row("root", 1);
    let mut parent = row("parent", 10);
    parent.parent = Some(root.key());
    let mut grandchild = row("grandchild", 100);
    grandchild.parent = Some(parent.key());
    let (_related_dir, related) = cold(&[grandchild.clone(), parent.clone()]);
    parent.parent = Some(row("peer", 1).key());
    let (_unrelated_dir, unrelated) = cold(&[grandchild, parent]);
    // The first physical piece is identical. Only the parent's later piece
    // tells a reader whether this grandchild belongs to root's family.
    let left =
        related.disk().unwrap().read_piece(None, ReadSide::After, false, 1, 256 * 1024).unwrap();
    let right =
        unrelated.disk().unwrap().read_piece(None, ReadSide::After, false, 1, 256 * 1024).unwrap();
    assert_eq!(left.rows.len(), 1);
    assert_eq!(right.rows.len(), 1);
    assert_eq!(
        serde_json::to_value(left.rows.first().unwrap()).unwrap(),
        serde_json::to_value(right.rows.first().unwrap()).unwrap()
    );
    assert!(left.has_after && right.has_after);
    let filter = ListFilter::family(root.key());
    assert!(scan(&unrelated, &filter).is_empty());
    let mut found = scan(&related, &filter);
    found.sort();
    assert_eq!(found, ["grandchild", "parent"]);
}

fn exclusive_boundary_flags(filter: ListFilter, only: Summary) {
    let anchor = SortKey::of(&only);
    let index = SummaryIndex::new().apply(1, only);
    let before = index
        .read_page(Some(&anchor), ReadSide::Before, false, 1, 256 * 1024, Some(&filter))
        .unwrap();
    assert!(before.rows.is_empty());
    assert!(!before.has_before);
    assert!(before.has_after, "the excluded anchor is on the after side");
    let after = index
        .read_page(Some(&anchor), ReadSide::After, false, 1, 256 * 1024, Some(&filter))
        .unwrap();
    assert!(after.rows.is_empty());
    assert!(after.has_before, "the excluded anchor is on the before side");
    assert!(!after.has_after);
}

#[test]
fn family_exclusive_boundaries_keep_the_opposite_side() {
    let root = row("root", 1);
    let mut child = row("child", 2);
    child.parent = Some(root.key());
    exclusive_boundary_flags(ListFilter::family(root.key()), child);
}

#[test]
fn folder_exclusive_boundaries_keep_the_opposite_side() {
    let mut only = row("only", 2);
    only.folder = Some("one".to_owned());
    exclusive_boundary_flags(ListFilter::folder(FolderKey::new("local", "one")), only);
}

#[test]
fn folder_hot_candidate_cannot_skip_an_unread_cold_match() {
    let unrelated = row("unrelated", 100);
    let mut older = row("cold-match", 50);
    older.folder = Some("one".to_owned());
    let mut oldest = row("hot-match", 10);
    oldest.folder = Some("one".to_owned());
    let (_dir, index) = cold(&[unrelated, older]);
    let index = index.apply(3, oldest);
    let found = scan(&index, &ListFilter::folder(FolderKey::new("local", "one")));
    assert_eq!(found, ["cold-match", "hot-match"]);
}
