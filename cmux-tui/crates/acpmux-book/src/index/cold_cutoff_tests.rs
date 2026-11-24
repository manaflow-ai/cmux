//! The cold partition is a publication property, not a per-read clock.

use super::*;
use std::sync::Arc;

fn row(chat_id: &str, last_activity: u64) -> Summary {
    let mut row = Summary::new(chat_id);
    row.last_activity = last_activity;
    row.state = "closed".to_owned();
    row
}

#[test]
fn cold_before_survives_snapshot_and_residency_lifecycle() {
    let directory = tempfile::tempdir().unwrap();
    let mut index = SummaryIndex::new()
        .apply(1, row("below", 900))
        .apply(2, row("at", 1_000))
        .apply(3, row("above", 1_100));

    let first_path = directory.path().join("first.snap");
    SortedSnapshot::write(&first_path, &index).unwrap();
    let first = DiskSnapshot::open(&first_path).unwrap().unwrap();
    let (next, _) = index.with_compacted_snapshot(first, Default::default());
    index = next;
    assert_eq!(index.cold_before(), 0);

    index.raise_cold_before(1_000);
    assert_eq!(index.cold_before(), 1_000);
    index.raise_cold_before(999);
    assert_eq!(index.cold_before(), 1_000);
    index.raise_cold_before(2_000);
    assert_eq!(index.cold_before(), 2_000);

    let evicted = RowKey::new("local", "below");
    assert!(index.evict_compacted(&evicted));
    assert_eq!(index.cold_before(), 2_000);
    index.hydrate_compacted(Arc::new(row("below", 900)));
    assert!(index.get_row(&evicted).is_some());
    assert_eq!(index.cold_before(), 2_000);

    let second_path = directory.path().join("second.snap");
    SortedSnapshot::write(&second_path, &index).unwrap();
    let second = DiskSnapshot::open(&second_path).unwrap().unwrap();
    let (replaced, _) = index.with_compacted_snapshot(second, Default::default());
    assert_eq!(replaced.cold_before(), 2_000);
}
