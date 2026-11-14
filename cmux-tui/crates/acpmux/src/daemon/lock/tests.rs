use super::*;

#[test]
fn daemon_lock_refuses_a_symlink() {
    let dir = std::env::temp_dir().join(format!(
        "acpmux-lock-link-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let target = dir.join("outside");
    let lock = dir.join("daemon.lock");
    std::fs::write(&target, "outside").unwrap();
    std::os::unix::fs::symlink(&target, &lock).unwrap();

    assert!(acquire_lock(&lock).is_err(), "the daemon locked through a symlink");
    assert_eq!(std::fs::read_to_string(&target).unwrap(), "outside");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A second daemon on a home names the one that holds its lock, by pid,
/// and the command that shows it on that home; it never suggests
/// removing the lock or the socket (ergo-walk, 2026-10-25).
#[test]
fn a_held_lock_names_its_daemon_and_how_to_see_it() {
    let dir = std::env::temp_dir().join(format!(
        "acpmux-lock-held-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let lock = dir.join("daemon.lock");
    let held = acquire_lock(&lock).unwrap();
    let why = acquire_lock(&lock).err().expect("the lock is held").to_string();
    // The start every handover matches on stays.
    assert!(why.starts_with(&format!("another acpmux daemon holds {}", lock.display())));
    assert!(why.contains(&format!("pid {}", std::process::id())), "{why}");
    assert!(why.contains(&format!("ACPMUX_HOME={} acpmux daemon status", dir.display())), "{why}");
    for removal in ["rm ", "delete", "remove"] {
        assert!(!why.contains(removal), "{why}");
    }
    assert!(
        !lock_released(&crate::config::private_state_rw(&lock).unwrap()).unwrap(),
        "a held daemon lock read released"
    );
    // A pid the file still records from a daemon that is gone is not named.
    std::fs::write(&lock, format!("{}\n", i32::MAX)).unwrap();
    let why = acquire_lock(&lock).err().expect("the lock is held").to_string();
    assert!(!why.contains("pid "), "{why}");
    assert!(why.contains("acpmux daemon status"), "{why}");
    drop(held);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A look that finds the daemon lock free leaves no lock behind, also while the description it
/// looked through stays open: a child that another thread forked during the look keeps a copy
/// until it execs, and a lock the look took and only closed stays held through that copy. The
/// next daemon start (an update's handover waits here first) is then refused "another acpmux
/// daemon holds" with no daemon running (LOCK-AUDIT daemon/lock.rs:254).
#[test]
fn a_release_look_leaves_no_lock_while_its_description_stays_open() {
    let dir = std::env::temp_dir().join(format!(
        "acpmux-lock-look-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let lock = dir.join("daemon.lock");
    // The look's description stays open, as a forked child's copy of it does.
    let looked = crate::config::private_state_rw(&lock).unwrap();
    let released = lock_released(&looked).unwrap();
    let next = acquire_lock(&lock).map(drop).map_err(|e| e.to_string());
    drop(looked);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(released, "a free daemon lock read held");
    next.expect("a look at a free daemon lock left it held");
}
