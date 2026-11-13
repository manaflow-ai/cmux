use super::*;
use acpmux_book::index::SortedSnapshot;

fn closed(id: &str) -> Summary {
    let mut row = Summary::new(id);
    row.state = "closed".into();
    row.last_activity = 1;
    row
}

fn assert_no_delta(subscription: &ListSubscription) {
    assert!(subscription.receiver.subscriber.state.lock().unwrap().pending.is_empty());
}

#[test]
fn equal_hot_and_cold_summaries_write_and_publish_nothing() {
    for cold in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        let row = closed("same");
        if cold {
            let index = SummaryIndex::new().apply(1, row.clone());
            SortedSnapshot::write(dir.path().join("index.snap"), &index).unwrap();
        }
        let (hub, mut writer) = Hub::open(dir.path(), 101, || 7).unwrap();
        if !cold {
            writer.apply(row.clone()).unwrap();
        }
        let sub = hub.subscribe(&Sub::new("equal", "list")).unwrap();
        let seq = hub.snapshot().seq();
        let bytes = writer.log.as_ref().unwrap().offset();
        let history = writer.history.lock().unwrap().len();
        writer.apply(row).unwrap();
        writer.sync_batch().unwrap();
        assert_eq!(hub.snapshot().seq(), seq);
        assert_eq!(writer.log.as_ref().unwrap().offset(), bytes);
        assert_eq!(writer.history.lock().unwrap().len(), history);
        assert_eq!(hub.snapshot().len(), usize::from(!cold));
        assert_no_delta(&sub);
    }
}

#[test]
fn repeated_removal_is_one_tombstone_and_missing_without_snapshot_is_none() {
    for disk in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        if disk {
            let index = SummaryIndex::new().apply(1, closed("elsewhere"));
            SortedSnapshot::write(dir.path().join("index.snap"), &index).unwrap();
        }
        let (hub, mut writer) = Hub::open(dir.path(), 101, || 7).unwrap();
        assert_eq!(writer.remove("local", "absent").unwrap(), disk);
        let seq = hub.snapshot().seq();
        let bytes = writer.log.as_ref().unwrap().offset();
        let sub = hub.subscribe(&Sub::new("gone", "list")).unwrap();
        assert!(!writer.remove("local", "absent").unwrap());
        assert_eq!(hub.snapshot().seq(), seq);
        assert_eq!(writer.log.as_ref().unwrap().offset(), bytes);
        assert_eq!(writer.history.lock().unwrap().len(), usize::from(disk));
        assert_no_delta(&sub);
        assert_eq!(bytes == 0, !disk);
    }
}

#[cfg(target_os = "linux")]
#[test]
fn unwritten_changes_never_escape_before_a_same_boot_restart() {
    const CHILD: &str = "V2_APPEND_FAILURE_FIXTURE";
    if let Some(directory) = std::env::var_os(CHILD) {
        let directory = std::path::Path::new(&directory);
        let (hub, mut writer) = Hub::open(directory, 101, || 7).unwrap();
        let sub = hub.subscribe(&Sub::new("durable", "list")).unwrap();
        let window: Window<Summary> = sub.window.decode_json().unwrap();
        assert_eq!(window.cursor, 1);
        assert_eq!(window.rows.len(), 1);
        assert_eq!(window.rows.first().unwrap().chat_id, "written");
        let edition = hub.snapshot().edition();
        // Real write failures: the child has RLIMIT_FSIZE=0, and SIGXFSZ is
        // ignored so write_all returns an error. No process-global test hook.
        assert!(writer.apply(closed("pending")).is_err());
        assert!(writer.apply(closed("another")).is_err());
        let mut latest = closed("pending");
        latest.title = "latest".into();
        assert!(writer.apply(latest).is_err());
        assert_eq!(writer.retry_log.len(), 2);
        assert_eq!(
            writer.retry_log.get(&RowKey::new("local", "pending")).unwrap().summary.title,
            "latest"
        );
        assert!(writer.log_errors() >= 3);
        assert_eq!(hub.snapshot().seq(), window.cursor);
        assert!(writer.history.lock().unwrap().is_empty());
        assert_no_delta(&sub);
        drop((sub, hub, writer));
        let (reopened, _) = Hub::open(directory, 101, || 7).unwrap();
        assert_eq!(reopened.snapshot().edition(), edition);
        assert_eq!(reopened.snapshot().seq(), window.cursor);
        assert!(reopened.snapshot().get("written").is_some());
        assert!(reopened.snapshot().get("pending").is_none());
        assert!(reopened.snapshot().get("another").is_none());
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let (hub, mut writer) = Hub::open(dir.path(), 101, || 7).unwrap();
    writer.apply(closed("written")).unwrap();
    writer.sync_batch().unwrap();
    drop((hub, writer));
    let status = std::process::Command::new("bash")
        .args(["-c", "trap '' XFSZ; ulimit -f 0; exec \"$@\"", "append-failure"])
        .arg(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "hub::writer_tests::unwritten_changes_never_escape_before_a_same_boot_restart",
            "--nocapture",
        ])
        .env(CHILD, dir.path())
        .status()
        .unwrap();
    assert!(status.success(), "append failure child: {status}");
}
