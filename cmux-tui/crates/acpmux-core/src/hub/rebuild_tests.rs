use super::*;
use crate::wire::Sub;
use acpmux_book::index::{SortedSnapshot, SummaryIndex};
use std::fs;
use std::path::Path;

fn row(id: impl Into<String>, activity: u64) -> Summary {
    let mut row = Summary::new(id);
    row.state = "closed".to_owned();
    row.last_activity = activity;
    row
}

fn fixture(path: &Path, count: usize) -> SummaryIndex {
    let mut index = SummaryIndex::new();
    for n in 0..count {
        index = index.apply(n as u64 + 1, row(format!("row-{n:04}"), count as u64 - n as u64));
    }
    SortedSnapshot::write(path.join("index.snap"), &index).unwrap();
    index
}

fn corrupt(path: &Path, at: usize) {
    let mut bytes = fs::read(path).unwrap();
    bytes[at] ^= 0xa5;
    fs::write(path, bytes).unwrap();
}

fn bad_entries(path: &Path) -> Vec<String> {
    fs::read_dir(path.join("index.bad"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect()
}

#[test]
fn damaged_snapshot_rebuilds_at_open_and_quarantines_one_set() {
    let dir = tempfile::tempdir().unwrap();
    let expected = fixture(dir.path(), 64);
    let (hub, _) = Hub::open(dir.path(), 11, || 73).unwrap();
    assert_eq!(hub.snapshot().len(), 0);
    drop(hub);
    corrupt(&dir.path().join("index.snap"), 0);

    let (hub, mut writer) = Hub::open(dir.path(), 11, || 73).unwrap();
    assert_eq!(hub.rebuild_count(), 1);
    assert_eq!(hub.snapshot().len(), 0);
    assert!(hub.snapshot().disk().is_none());
    assert_ne!(hub.snapshot().edition(), 1);
    assert!(bad_entries(dir.path()).iter().any(|name| name == "index.snap"));
    for item in expected.merged_rows() {
        writer.apply(item.unwrap().as_ref().clone()).unwrap();
    }
    writer.sync_batch().unwrap();
    assert_eq!(hub.snapshot().len(), expected.len());
}

#[test]
fn damaged_complete_log_frame_rebuilds_at_open() {
    let dir = tempfile::tempdir().unwrap();
    let (hub, mut writer) = Hub::open(dir.path(), 12, || 19).unwrap();
    writer.apply(row("one", 1)).unwrap();
    writer.sync_batch().unwrap();
    drop((hub, writer));
    corrupt(&dir.path().join("index.log"), 8);

    let (hub, _) = Hub::open(dir.path(), 12, || 19).unwrap();
    assert_eq!(hub.rebuild_count(), 1);
    assert_eq!(hub.snapshot().len(), 0);
    assert!(bad_entries(dir.path()).iter().any(|name| name == "index.log"));
}

#[tokio::test(flavor = "current_thread")]
async fn runtime_page_boundary_rebuild_keeps_sid_and_fences_one_window() {
    let dir = tempfile::tempdir().unwrap();
    fixture(dir.path(), 128);
    let (hub, mut writer) = Hub::open(dir.path(), 13, || 29).unwrap();
    writer.process_batch();
    hub.wait_hydrated().await.unwrap();
    let subscription = hub.subscribe(&Sub::new("sid", "list")).unwrap();
    let mut folders = Sub::new("folders", "list");
    folders.view = Some(crate::wire::ListView::Folders);
    let folder_subscription = hub.subscribe(&folders).unwrap();
    corrupt(&dir.path().join("index.snap"), 4096);

    assert!(hub.list_window(&Sub::new("page", "list")).is_err());
    writer.process_batch();
    assert_eq!(hub.rebuild_count(), 1);
    assert_eq!(hub.subscriber_count(), 2);
    hub.source_walk_finished(Source::Local, false);
    assert!(subscription.receiver.try_next_raw(None, 64 * 1024).is_none());
    assert!(folder_subscription.receiver.try_next_raw(None, 64 * 1024).is_none());
    let mut rebuilt = row("rebuilt", 1);
    rebuilt.folder = Some("/rebuild".into());
    writer.apply(rebuilt).unwrap();
    hub.source_walk_finished(Source::Local, true);
    assert!(matches!(subscription.receiver.try_next_raw(None, 64 * 1024), Some(RawRead::Lagged)));
    assert!(subscription.receiver.try_next_raw(None, 64 * 1024).is_none());
    assert!(matches!(
        folder_subscription.receiver.try_next_raw(None, 64 * 1024),
        Some(RawRead::Lagged)
    ));
    let folder_window: crate::wire::FolderWindow =
        hub.list_window(&folders).unwrap().decode_json().unwrap();
    assert!(folder_window.rows.iter().any(|row| row.folder.as_ref() == "/rebuild"));
}

#[test]
fn repeated_open_rebuilds_leave_one_bad_set() {
    let dir = tempfile::tempdir().unwrap();
    fixture(dir.path(), 16);
    let (hub, _) = Hub::open(dir.path(), 14, || 31).unwrap();
    drop(hub);
    corrupt(&dir.path().join("index.snap"), 0);
    let (hub, _) = Hub::open(dir.path(), 14, || 31).unwrap();
    assert_eq!(hub.rebuild_count(), 1);
    drop(hub);
    SortedSnapshot::write(
        dir.path().join("index.snap"),
        &SummaryIndex::new().apply(1, row("new", 1)),
    )
    .unwrap();
    corrupt(&dir.path().join("index.snap"), 0);
    let (hub, _) = Hub::open(dir.path(), 14, || 31).unwrap();
    assert_eq!(hub.rebuild_count(), 1);
    let names = bad_entries(dir.path());
    assert_eq!(names.iter().filter(|name| name.ends_with(".snap")).count(), 1);
}
