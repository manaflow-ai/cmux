use super::DirWatch;
use std::sync::mpsc;
use std::time::Duration;

#[test]
fn identity_watch_ignores_sibling_activity_but_reports_ancestor_rename() {
    let dir = tempfile::tempdir().unwrap();
    let ancestor = dir.path().join("ancestor");
    let home = ancestor.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let (tx, rx) = mpsc::channel();
    let _watch = DirWatch::start_identities(
        &[dir.path().to_path_buf(), ancestor.clone(), home],
        move || {
            let _ = tx.send(());
            false
        },
    )
    .expect("identity watch starts");
    // These would wake a directory-entry watcher, even if a later callback discards them.
    let sibling = dir.path().join("unrelated");
    std::fs::create_dir(&sibling).unwrap();
    std::fs::write(sibling.join("file"), "unrelated write").unwrap();
    std::fs::rename(&sibling, dir.path().join("other")).unwrap();
    std::fs::remove_dir_all(dir.path().join("other")).unwrap();
    assert_eq!(rx.recv_timeout(Duration::from_millis(200)), Err(mpsc::RecvTimeoutError::Timeout));
    std::fs::rename(&ancestor, dir.path().join("moved")).unwrap();
    rx.recv_timeout(Duration::from_secs(5)).expect("ancestor rename wakes the watch");
}

#[test]
fn identity_watch_reports_a_symlink_replacement_and_a_lock_removal() {
    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("target");
    std::fs::create_dir(&target).unwrap();
    let link = dir.path().join("link");
    std::os::unix::fs::symlink(&target, &link).unwrap();
    let (tx, rx) = mpsc::channel();
    let _watch = DirWatch::start_identities(std::slice::from_ref(&link), move || {
        let _ = tx.send(());
        true
    })
    .expect("symlink watch starts");
    let replacement = dir.path().join("replacement");
    std::os::unix::fs::symlink(dir.path(), &replacement).unwrap();
    std::fs::rename(replacement, link).unwrap();
    rx.recv_timeout(Duration::from_secs(5)).expect("symlink replacement wakes the watch");

    let lock = target.join("lock");
    std::fs::write(&lock, "held").unwrap();
    let _held_lock = std::fs::File::open(&lock).unwrap();
    let (tx, rx) = mpsc::channel();
    let _watch = DirWatch::start_identities(std::slice::from_ref(&lock), move || {
        let _ = tx.send(());
        true
    })
    .expect("lock watch starts");
    std::fs::remove_file(lock).unwrap();
    rx.recv_timeout(Duration::from_secs(5)).expect("lock removal wakes the watch");
}
