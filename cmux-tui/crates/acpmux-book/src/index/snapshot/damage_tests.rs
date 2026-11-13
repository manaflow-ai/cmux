use super::{DiskSnapshot, PAGE_BYTES, SortedSnapshot};
use crate::index::{ReadSide, SortKey, Summary, SummaryIndex};
use std::fs;

fn row(id: &str, activity: u64) -> Summary {
    let mut row = Summary::new(id);
    row.last_activity = activity;
    row.state = "closed".to_owned();
    row
}

#[test]
fn first_page_skips_a_complete_bad_frame_and_keeps_physical_flags() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("index.snap");
    let mut index = SummaryIndex::new();
    for (id, activity) in [("first", 3), ("bad", 2), ("last", 1)] {
        index = index.apply(activity, row(id, activity));
    }
    SortedSnapshot::write(&path, &index).unwrap();

    let mut bytes = fs::read(&path).unwrap();
    let start = super::HEADER_BYTES;
    let first_body =
        u32::from_le_bytes(bytes.get(start..start + 4).unwrap().try_into().unwrap()) as usize;
    let first_frame = first_body + 12;
    let second = start + first_frame;
    *bytes.get_mut(second + 8).unwrap() ^= 1;
    fs::write(&path, bytes).unwrap();

    let snapshot = DiskSnapshot::open(&path).unwrap().unwrap();
    let page = snapshot.first_rows(2, PAGE_BYTES).unwrap();
    assert_eq!(
        page.rows.iter().map(|row| row.chat_id.as_str()).collect::<Vec<_>>(),
        ["first", "last"]
    );
    assert_eq!(page.first_ordinal, 0);
    assert!(!page.has_before);
    assert!(!page.has_after);
    assert_eq!(page.physical_count, 3);
    assert_eq!(page.next_ordinal, 3);
}

#[test]
fn around_page_flags_use_the_selected_physical_span() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("index.snap");
    let mut index = SummaryIndex::new();
    for n in 0..10 {
        index = index.apply(n + 1, row(&format!("row-{n}"), 10 - n));
    }
    SortedSnapshot::write(&path, &index).unwrap();
    let snapshot = DiskSnapshot::open(&path).unwrap().unwrap();
    let anchor = SortKey::of(&index.get("row-5").unwrap());
    let page = snapshot.read_piece(Some(&anchor), ReadSide::Around, true, 4, PAGE_BYTES).unwrap();
    assert_eq!(
        page.rows.iter().map(|row| row.chat_id.as_str()).collect::<Vec<_>>(),
        ["row-3", "row-4", "row-5", "row-6"]
    );
    assert!(page.has_before);
    assert!(page.has_after);
}
