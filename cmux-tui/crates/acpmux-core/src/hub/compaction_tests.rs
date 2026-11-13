use super::*;
use acpmux_book::index::{IndexRecord, SortedSnapshot};
use std::time::Instant;

#[tokio::test(flavor = "current_thread")]
async fn changes_during_rotation_survive_install_and_restart_without_duplicate_rows() {
    let dir = tempfile::tempdir().unwrap();
    let mut initial = SummaryIndex::new();
    for n in 0..1000 {
        let mut row = Summary::new(format!("row-{n:04}"));
        row.last_activity = 1000 - n;
        row.state = "closed".into();
        initial = initial.apply(n + 1, row);
    }
    SortedSnapshot::write(dir.path().join("index.snap"), &initial).unwrap();
    let (hub, mut writer) = Hub::open(dir.path(), 101, || 7).unwrap();
    // Retry deadline forces the same rotation path without a megabyte fixture.
    writer.next_compaction = Some(Instant::now());
    writer = tokio::task::spawn_blocking(move || {
        writer.maybe_compact();
        writer
    })
    .await
    .unwrap();
    assert!(writer.compaction.is_some());
    writer = tokio::task::spawn_blocking(move || {
        for n in 0..50 {
            writer.apply_remove(&RowKey::new("local", format!("row-{n:04}"))).unwrap();
        }
        for n in 50..100 {
            let mut row = Summary::new(format!("row-{n:04}"));
            row.last_activity = 3000 + n;
            writer.apply(row).unwrap();
        }
        writer.sync_batch().unwrap();
        writer
    })
    .await
    .unwrap();
    writer.finish_compaction(true).await;
    assert_eq!(hub.compaction_stats().failed, 0);
    assert_eq!(hub.compaction_stats().completed, 1);
    let expected: Vec<_> =
        hub.snapshot().merged_rows().map(|row| row.unwrap().chat_id.clone()).collect();
    assert_eq!(expected.len(), 950);
    let unique: std::collections::HashSet<_> = expected.iter().collect();
    assert_eq!(unique.len(), 950);
    drop((hub, writer));
    let (hub, _) = Hub::open(dir.path(), 101, || 7).unwrap();
    let actual: Vec<_> =
        hub.snapshot().merged_rows().map(|row| row.unwrap().chat_id.clone()).collect();
    assert_eq!(actual, expected);
}

#[test]
fn failed_log_append_keeps_latest_summary_and_retries_without_losing_order() {
    let dir = tempfile::tempdir().unwrap();
    let (hub, mut writer) = Hub::open(dir.path(), 101, || 7).unwrap();
    let mut first = Summary::new("a");
    first.last_activity = 10;
    // Seed the retry path as if an earlier append failed. The next live change
    // must remain visible and must supersede this same-chat buffered record.
    writer.retry_log.insert(
        first.key(),
        IndexRecord {
            seq: 1,
            origin: first.origin.clone(),
            chat_id: first.chat_id.clone(),
            summary: first,
            gone: false,
        },
    );
    let mut next = Summary::new("a");
    next.last_activity = 20;
    writer.apply(next).unwrap();
    assert_eq!(hub.snapshot().get("a").unwrap().last_activity, 20);
    writer.sync_batch().unwrap();
    assert!(writer.retry_log.is_empty());
    drop((hub, writer));
    let (restored, _) = Hub::open(dir.path(), 101, || 7).unwrap();
    assert_eq!(restored.snapshot().get("a").unwrap().last_activity, 20);
}
