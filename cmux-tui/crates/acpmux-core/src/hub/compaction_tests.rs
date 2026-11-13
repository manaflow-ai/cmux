use super::*;
use acpmux_book::index::{IndexRecord, SortedSnapshot};
use std::time::Instant;

#[tokio::test(flavor = "current_thread")]
async fn interrupted_rotation_restarts_compaction_without_new_submissions() {
    let dir = tempfile::tempdir().unwrap();
    let (hub, mut writer) = Hub::open(dir.path(), 101, || 7).unwrap();
    writer.apply(Summary::new("before-crash")).unwrap();
    let _interrupted = writer.log.as_mut().unwrap().rotate(1).unwrap();
    drop((hub, writer));

    let (hub, mut writer) = Hub::open(dir.path(), 101, || 7).unwrap();
    let deadline = writer.next_compaction.unwrap();
    assert!(deadline <= Instant::now());
    assert_eq!(writer.log.as_ref().unwrap().offset(), 0);
    assert!(writer.log.as_ref().unwrap().retained_bytes() > 0);
    writer = tokio::task::spawn_blocking(move || {
        writer.process_batch();
        writer
    })
    .await
    .unwrap();
    assert!(writer.compaction.is_some());
    writer.finish_compaction(true).await;
    writer = tokio::task::spawn_blocking(move || {
        writer.process_batch();
        writer
    })
    .await
    .unwrap();
    assert_eq!(hub.compaction_stats().completed, 1);
    assert_eq!(writer.log.as_ref().unwrap().retained_bytes(), 0);
    drop((hub, writer));
    let (restored, _) = Hub::open(dir.path(), 101, || 7).unwrap();
    let rows: Vec<_> = restored.snapshot().merged_rows().map(Result::unwrap).collect();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows.first().unwrap().chat_id, "before-crash");
}

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
    writer = tokio::task::spawn_blocking(move || {
        writer.process_batch();
        writer
    })
    .await
    .unwrap();
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
    // Seed an unwritten version. A successful newer update supersedes it;
    // replay must never put the old buffered version over that update.
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

#[tokio::test(flavor = "current_thread")]
async fn install_evicts_old_rows_but_keeps_changes_and_removals_since_capture() {
    let dir = tempfile::tempdir().unwrap();
    let (hub, mut writer) = Hub::open(dir.path(), 101, || 7).unwrap();
    writer = tokio::task::spawn_blocking(move || {
        for n in 0..11_000 {
            let mut row = Summary::new(format!("row-{n:05}"));
            row.state = "closed".into();
            row.last_activity = 1;
            writer.apply(row).unwrap();
        }
        writer.process_batch();
        writer
    })
    .await
    .unwrap();
    assert_eq!(hub.snapshot().len(), 11_000);
    assert!(writer.compaction.is_some());
    writer = tokio::task::spawn_blocking(move || {
        let mut changed = Summary::new("row-00000");
        changed.state = "closed".into();
        changed.last_activity = 2;
        changed.title = "after capture".into();
        writer.apply(changed).unwrap();
        writer.remove("local", "row-00001").unwrap();
        writer.sync_batch().unwrap();
        writer
    })
    .await
    .unwrap();
    writer.finish_compaction(true).await;
    writer = tokio::task::spawn_blocking(move || {
        writer.process_batch();
        writer
    })
    .await
    .unwrap();
    assert_eq!(hub.snapshot().len(), 1);
    assert_eq!(hub.snapshot().get("row-00000").unwrap().title, "after capture");
    assert!(hub.snapshot().get("row-00001").is_none());
    assert_eq!(hub.snapshot().merged_rows().map(Result::unwrap).count(), 10_999);
    assert!(writer.hydration.is_none());
    drop((hub, writer));
    let (restored, _) = Hub::open(dir.path(), 101, || 7).unwrap();
    assert_eq!(restored.snapshot().get("row-00000").unwrap().title, "after capture");
    assert_eq!(restored.snapshot().merged_rows().map(Result::unwrap).count(), 10_999);
}

#[tokio::test(flavor = "current_thread")]
async fn install_retains_hot_snapshot_rows_beyond_unfinished_startup_hydration() {
    let dir = tempfile::tempdir().unwrap();
    let mut index = SummaryIndex::new();
    for n in 0..1000 {
        let mut row = Summary::new(format!("row-{n:04}"));
        row.state = if n == 999 { "running" } else { "closed" }.into();
        row.last_activity = 1000 - n;
        index = index.apply(n + 1, row);
    }
    SortedSnapshot::write(dir.path().join("index.snap"), &index).unwrap();
    let (hub, mut writer) = Hub::open(dir.path(), 101, || 7).unwrap();
    writer.start_hydration();
    writer.next_compaction = Some(Instant::now());
    writer = tokio::task::spawn_blocking(move || {
        writer.process_batch();
        writer
    })
    .await
    .unwrap();
    assert!(writer.hydration.is_some());
    assert_eq!(hub.snapshot().len(), 0);
    writer.finish_compaction(true).await;
    writer = tokio::task::spawn_blocking(move || {
        writer.process_batch();
        writer
    })
    .await
    .unwrap();
    assert!(writer.hydration.is_none());
    assert_eq!(hub.snapshot().len(), 1);
    assert!(hub.snapshot().get("row-0999").is_some());
}
