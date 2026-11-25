use super::*;
use acpmux_book::index::folders::FolderOp;
use acpmux_book::index::{ChangedRows, SortedSnapshot};

#[test]
fn eviction_batch_coalesces_folders_without_advancing_durable_cursors() {
    let dir = tempfile::tempdir().unwrap();
    let (hub, mut writer) = Hub::open(dir.path(), 1, || 7).unwrap();
    for n in 0..40 {
        let mut row = Summary::new(format!("chat-{n}"));
        row.folder = Some(if n < 20 { "/a" } else { "/b" }.into());
        row.last_activity = n;
        writer.apply(row).unwrap();
    }
    let current = hub.snapshot();
    let snapshot_path = dir.path().join("index.snap");
    SortedSnapshot::write(&snapshot_path, &current).unwrap();
    let snapshot = DiskSnapshot::open(&snapshot_path).unwrap().unwrap();
    let (next, _) = current.with_compacted_snapshot(snapshot, ChangedRows::new());
    writer.publish_folder_index(next, &[]);
    let mut sub = Sub::new("folders", "list");
    sub.view = Some(crate::wire::ListView::Folders);
    let subscription = hub.subscribe(&sub).unwrap();
    let list_seq = hub.snapshot().seq();
    let log_seq = writer.log.as_ref().unwrap().next_seq();
    let last_history = writer.history.lock().unwrap().last_seq();
    writer.maintenance = Some(Maintenance {
        cold_keys: current
            .iter()
            .filter(|row| row.chat_id != "chat-39")
            .map(|row| row.key())
            .collect(),
        missing_hot: VecDeque::new(),
        retired_shadow: None,
        evicted_rows: 0,
        started: Instant::now(),
        cleanup_complete: false,
    });
    writer.maintain_compaction();
    assert_eq!(hub.snapshot().seq(), list_seq);
    assert_eq!(writer.log.as_ref().unwrap().next_seq(), log_seq);
    assert_eq!(writer.history.lock().unwrap().last_seq(), last_history);
    let Some(ListItem::Folders { seq, ops }) = subscription.receiver.try_next() else {
        panic!("one folder frame")
    };
    assert_eq!(seq, subscription.cursor + 1);
    assert_eq!(ops.len(), 2);
    assert!(ops.iter().any(|op| matches!(op, FolderOp::Gone(key) if key.folder.as_ref() == "/a")));
    assert!(ops.iter().any(
        |op| matches!(op, FolderOp::Folder(row) if row.folder.as_ref() == "/b" && row.count == 1)
    ));
    assert!(subscription.receiver.try_next().is_none());
}
