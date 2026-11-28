//! Rows a list drops from memory wait on disk and come back newest page first, in order.
//! Mirrors RowSpillTests.swift.

use super::*;

fn spill(dir: &tempfile::TempDir, page_size: u32, max_rows: u32) -> Arc<RowSpillPages> {
    RowSpillPages::new(dir.path().join("spill").to_string_lossy().into_owned(), page_size, max_rows)
}

fn rows(ids: impl Iterator<Item = u32>) -> Vec<Vec<u8>> {
    ids.map(|id| id.to_string().into_bytes()).collect()
}

fn ids(rows: Vec<Vec<u8>>) -> Vec<u32> {
    rows.into_iter().map(|r| String::from_utf8(r).unwrap().parse().unwrap()).collect()
}

#[test]
fn pages_come_back_newest_first_in_order() {
    let dir = tempfile::tempdir().unwrap();
    let spill = spill(&dir, 10, 1000);
    // A list evicts its oldest rows first: 0..<25 (newest first), then 25..<40 above them.
    spill.push(rows((0..25).rev()));
    spill.push(rows((25..40).rev()));
    assert_eq!(spill.stored_count(), 40);
    let mut back = Vec::new();
    loop {
        let page = spill.pop();
        if page.is_empty() {
            break;
        }
        assert!(page.len() <= 10);
        back.extend(ids(page));
    }
    assert_eq!(back, (0..40).rev().collect::<Vec<_>>());
    assert_eq!(spill.stored_count(), 0);
}

/// One row at a time writes whole pages; the newest rows short of a page wait in memory and
/// come back first.
#[test]
fn single_row_evictions_fill_pages() {
    let dir = tempfile::tempdir().unwrap();
    let spill = spill(&dir, 5, 1000);
    for id in 0..12 {
        spill.push(rows(std::iter::once(id)));
    }
    assert_eq!(spill.stored_count(), 12);
    assert_eq!(fs::read_dir(dir.path().join("spill")).unwrap().count(), 2);
    assert_eq!(ids(spill.rows_in_memory()), vec![11, 10]);
    assert_eq!(ids(spill.pop()), vec![11, 10]);
    assert_eq!(ids(spill.pop()), vec![9, 8, 7, 6, 5]);
}

/// Past its cap the spill drops its oldest pages, as the list did before it had one.
#[test]
fn cap_drops_the_oldest_pages() {
    let dir = tempfile::tempdir().unwrap();
    let spill = spill(&dir, 10, 30);
    spill.push(rows((0..100).rev()));
    assert_eq!(spill.stored_count(), 30);
    assert_eq!(ids(spill.pop()).first(), Some(&99));
}

#[test]
fn reset_empties_it() {
    let dir = tempfile::tempdir().unwrap();
    let spill = spill(&dir, 10, 1000);
    spill.push(rows(0..20));
    spill.push(rows(std::iter::once(1)));
    spill.reset();
    assert!(spill.pop().is_empty());
    assert!(!dir.path().join("spill").exists());
}

/// Any bytes round-trip, empty rows too; a page cut short reads as nothing.
#[test]
fn pages_keep_rows_whole() {
    let dir = tempfile::tempdir().unwrap();
    let spill = spill(&dir, 3, 1000);
    let page = vec![b"{\"a\":null}".to_vec(), Vec::new(), vec![0, 255, 7]];
    spill.push(page.clone());
    assert_eq!(spill.pop(), page);
    let cut = dir.path().join("cut.page");
    fs::write(&cut, [9, 0, 0, 0, 1]).unwrap();
    assert_eq!(load(&cut), None);
}

#[test]
fn folder_names_are_safe() {
    assert_eq!(row_spill_folder_name("acct-1/chat:2".into()), "acct-1_chat_2");
    assert_eq!(row_spill_folder_name(String::new()), "default");
    assert_eq!(row_spill_folder_name("..".into()), "__");
}

#[test]
fn purge_keeps_this_run_only() {
    let dir = tempfile::tempdir().unwrap();
    for run in ["old-a", "old-b", "this"] {
        fs::create_dir_all(dir.path().join(run).join("scope")).unwrap();
    }
    row_spill_purge_runs(dir.path().to_string_lossy().into_owned(), "this".into());
    let left: Vec<_> = fs::read_dir(dir.path()).unwrap().flatten().map(|e| e.file_name()).collect();
    assert_eq!(left, vec![std::ffi::OsString::from("this")]);
    row_spill_purge_runs(dir.path().join("missing").to_string_lossy().into_owned(), "x".into());
}
