use super::RecordWatch;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::time::Duration;

/// Writes `path` as a host record is written: a temporary file renamed over it.
fn write_by_rename(path: &Path, text: &str) {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, text).unwrap();
    std::fs::rename(&tmp, path).unwrap();
}

/// A watch on `own`, present while it holds "mine"; how often it asked, and its end.
fn watch(dir: &Path, own: &Path) -> (Option<RecordWatch>, Arc<AtomicUsize>, mpsc::Receiver<()>) {
    let asked = Arc::new(AtomicUsize::new(0));
    let (tx, rx) = mpsc::channel();
    let (file, read, count) = (own.to_path_buf(), own.to_path_buf(), asked.clone());
    let watch = RecordWatch::start(
        vec![dir.to_path_buf()],
        move || std::iter::once(file.clone()).filter(|f| f.exists()).collect::<Vec<PathBuf>>(),
        move || {
            count.fetch_add(1, Ordering::SeqCst);
            std::fs::read_to_string(&read).is_ok_and(|text| text == "mine")
        },
        move || {
            let _ = tx.send(());
        },
    );
    (watch, asked, rx)
}

/// CMUX-571: every agent host watched the whole hosts directory, so each record another
/// host or the daemon wrote, renamed or removed there woke every host: N hosts, O(N)
/// wakeups per change, O(N^2) for a burst (1000 chats: ~4000 wakeups/s while they settle).
/// Other records never wake this one's watch.
#[test]
fn a_record_watch_sleeps_through_other_hosts_records() {
    let dir = tempfile::tempdir().unwrap();
    let own = dir.path().join("own.json");
    write_by_rename(&own, "mine");
    let (watch, asked, gone) = watch(dir.path(), &own);
    assert!(watch.is_some(), "the record watch starts");
    std::thread::sleep(Duration::from_millis(100));
    let before = asked.load(Ordering::SeqCst);
    for i in 0..100 {
        write_by_rename(&dir.path().join(format!("other-{i}.json")), "theirs");
        std::thread::sleep(Duration::from_millis(1));
    }
    for i in 0..100 {
        std::fs::remove_file(dir.path().join(format!("other-{i}.json"))).unwrap();
    }
    std::thread::sleep(Duration::from_millis(300));
    let woken = asked.load(Ordering::SeqCst) - before;
    eprintln!("record watch: 200 changes to other records asked the record {woken} times");
    assert_eq!(woken, 0, "changes to other records woke this record's watch");
    std::fs::remove_file(&own).unwrap();
    gone.recv_timeout(Duration::from_secs(5)).expect("its own record's removal ends it");
}

/// The record rewritten by rename (a new file each time) stays watched: a later rewrite
/// that no longer names its owner, its removal, or its directory moved away still ends it.
#[test]
fn a_record_watch_follows_its_record_through_rewrites() {
    let dir = tempfile::tempdir().unwrap();
    let own = dir.path().join("own.json");
    write_by_rename(&own, "mine");
    let (_watch, _asked, gone) = watch(dir.path(), &own);
    for _ in 0..3 {
        write_by_rename(&own, "mine");
        std::thread::sleep(Duration::from_millis(50));
    }
    std::thread::sleep(Duration::from_millis(200));
    assert!(gone.try_recv().is_err(), "a rewrite that still names its owner ended it");
    write_by_rename(&own, "a newer host");
    gone.recv_timeout(Duration::from_secs(5)).expect("a record naming another host ends it");

    let second = tempfile::tempdir().unwrap();
    let home = second.path().join("hosts");
    std::fs::create_dir(&home).unwrap();
    let own = home.join("own.json");
    write_by_rename(&own, "mine");
    let (_watch, _asked, gone) = watch(&home, &own);
    write_by_rename(&own, "mine");
    std::thread::sleep(Duration::from_millis(100));
    std::fs::remove_file(&own).unwrap();
    gone.recv_timeout(Duration::from_secs(5)).expect("removal after a rewrite ends it");

    write_by_rename(&own, "mine");
    let (_watch, _asked, gone) = watch(&home, &own);
    std::fs::rename(&home, second.path().join("moved")).unwrap();
    gone.recv_timeout(Duration::from_secs(5)).expect("its directory moved away ends it");
}

/// A record missing at the start ends it at once.
#[test]
fn a_record_watch_on_a_missing_record_ends_at_once() {
    let dir = tempfile::tempdir().unwrap();
    let own = dir.path().join("own.json");
    let (_watch, _asked, gone) = watch(dir.path(), &own);
    gone.recv_timeout(Duration::from_secs(1)).expect("a missing record ends it at once");
}
