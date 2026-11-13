use super::*;
use acpmux_book::index::SortedSnapshot;

fn fixture(path: &std::path::Path, count: u64) {
    let mut index = SummaryIndex::new();
    for n in 0..count {
        let mut row = Summary::new(format!("row-{n:05}"));
        row.state = "closed".into();
        row.last_activity = count - n;
        index = index.apply(n + 1, row);
    }
    SortedSnapshot::write(path.join("index.snap"), &index).unwrap();
}

#[test]
fn opener_serves_disk_before_hydration_and_keeps_cold_rows_off_heap() {
    let dir = tempfile::tempdir().unwrap();
    fixture(dir.path(), 11_000);
    let (hub, mut writer) = Hub::open(dir.path(), 101, || 7).unwrap();
    assert_eq!(hub.snapshot().len(), 0);
    let frame = hub.list_window(&Sub::new("first", "list")).unwrap();
    let window: Window<Summary> = frame.decode_json().unwrap();
    assert_eq!(window.rows.first().unwrap().chat_id, "row-00000");
    assert!(window.has_after);
    writer.start_hydration();
    let mut turns = 0;
    while writer.hydration.is_some() {
        writer.process_batch();
        turns += 1;
        assert_eq!(hub.snapshot().len(), 0);
        assert!(turns < 50);
    }
    assert!(turns > 1);
}

#[test]
fn hydration_does_not_restore_a_removed_or_moved_snapshot_row() {
    let dir = tempfile::tempdir().unwrap();
    let mut index = SummaryIndex::new();
    let mut row = Summary::new("live");
    row.state = "running".into();
    row.last_activity = 100;
    index = index.apply(1, row.clone());
    SortedSnapshot::write(dir.path().join("index.snap"), &index).unwrap();
    let (hub, mut writer) = Hub::open(dir.path(), 101, || 7).unwrap();
    writer.start_hydration();
    hub.remove("local", "live").unwrap();
    writer.process_batch();
    assert!(hub.snapshot().get("live").is_none());
    row.last_activity = 200;
    hub.submit(row).unwrap();
    writer.process_batch();
    let frame = hub.list_window(&Sub::new("first", "list")).unwrap();
    let window: Window<Summary> = frame.decode_json().unwrap();
    assert_eq!(window.rows.len(), 1);
    assert_eq!(window.rows.first().unwrap().last_activity, 200);
}

#[tokio::test(flavor = "current_thread")]
async fn closing_before_the_writer_starts_drains_submissions_and_finishes() {
    let dir = tempfile::tempdir().unwrap();
    let (hub, writer) = Hub::open(dir.path(), 101, || 7).unwrap();
    hub.submit(Summary::new("pending")).unwrap();
    hub.close();
    writer.run().await.unwrap();
    let (restored, _) = Hub::open(dir.path(), 101, || 7).unwrap();
    assert!(restored.snapshot().get("pending").is_some());
}

#[test]
fn a_new_boot_fences_a_cursor_before_any_new_summary_is_published() {
    let dir = tempfile::tempdir().unwrap();
    let (hub, mut writer) = Hub::open(dir.path(), 101, || 7).unwrap();
    hub.submit(Summary::new("first")).unwrap();
    writer.process_batch();
    let old_edition = hub.snapshot().edition();
    drop((hub, writer));
    let (hub, writer) = Hub::open(dir.path(), 102, || 7).unwrap();
    assert_ne!(hub.snapshot().edition(), old_edition);
    let mut sub = Sub::new("resume", "list").from_cursor(1);
    sub.edition = Some(old_edition);
    let subscribed = hub.subscribe(&sub).unwrap();
    let window: Window<Summary> = subscribed.window.decode_json().unwrap();
    assert_eq!(window.rows.len(), 1);
    assert_eq!(window.edition, hub.snapshot().edition());
    // Simulate stopping immediately after open, before the first publish.
    drop((subscribed, hub, writer));
    let (hub, _) = Hub::open(dir.path(), 102, || 7).unwrap();
    assert_ne!(hub.snapshot().edition(), old_edition);
}

#[test]
fn submit_rejects_long_keys_and_counts_omitted_folders() {
    use acpmux_book::index::{omitted_folders, rejected_keys};
    let (hub, _) = Hub::new(SummaryIndex::new());

    let before_keys = rejected_keys();
    assert!(hub.submit(Summary::new("x".repeat(257))).is_err());
    let mut origin = Summary::new("origin-too-long");
    origin.origin = "o".repeat(257);
    assert!(hub.submit(origin).is_err());
    assert!(rejected_keys() >= before_keys.saturating_add(2));

    let before_folders = omitted_folders();
    let mut folder = Summary::new("folder-too-long");
    folder.folder = Some("f".repeat(1_025));
    assert!(hub.submit(folder).is_ok());
    assert!(omitted_folders() > before_folders);
}

#[test]
fn open_recovers_when_initial_log_was_renamed_before_the_next_generation_exists() {
    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("index.log");
    let mut log = IndexLog::open(&log_path).unwrap();
    log.append(Summary::new("before-rename")).unwrap();
    log.sync().unwrap();
    drop(log);
    std::fs::rename(&log_path, dir.path().join("index.log.1")).unwrap();
    assert!(!log_path.exists());
    assert!(!dir.path().join("index.log.2").exists());

    let (hub, mut writer) = Hub::open(dir.path(), 71, || 19).unwrap();
    assert!(hub.snapshot().get("before-rename").is_some());
    writer.apply(Summary::new("after-open")).unwrap();
    writer.sync_batch().unwrap();
    drop((hub, writer));
    let (reopened, _) = Hub::open(dir.path(), 71, || 19).unwrap();
    assert!(reopened.snapshot().get("before-rename").is_some());
    assert!(reopened.snapshot().get("after-open").is_some());
}

#[test]
fn open_cleans_a_complete_staged_snapshot_and_replays_old_snapshot_tail() {
    use acpmux_book::index::SortedSnapshot;
    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("index.log");
    let snapshot_path = dir.path().join("index.snap");
    let first = Summary::new("first");
    let index = SummaryIndex::new().apply(1, first.clone());
    SortedSnapshot::write(&snapshot_path, &index).unwrap();
    let mut log = IndexLog::open(&log_path).unwrap();
    let second = log.append(Summary::new("second")).unwrap();
    log.sync().unwrap();
    let stage = dir.path().join("index.snap.stage.1");
    SortedSnapshot::write(&stage, &index).unwrap();
    assert!(stage.exists());
    drop(log);

    let (hub, _) = Hub::open(dir.path(), 72, || 19).unwrap();
    let window: Window<Summary> =
        hub.list_window(&Sub::new("recovered", "list")).unwrap().decode_json().unwrap();
    assert!(window.rows.iter().any(|row| row.chat_id == "first"));
    assert!(hub.snapshot().get("second").is_some());
    assert_eq!(hub.snapshot().seq(), second.seq);
    assert!(!stage.exists());
}
