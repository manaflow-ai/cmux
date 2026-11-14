use super::*;
use std::os::fd::AsRawFd;

#[test]
fn a_held_lock_is_alive_a_free_one_is_dead_and_none_is_no_proof() {
    let dir = tempfile::tempdir().unwrap();
    let dirs = vec![dir.path().join("pool"), dir.path().to_path_buf()];
    assert!(!dead_now_in(&dirs, "s1", "n1"), "no lock file is no proof");
    let host = std::fs::File::create(live_path(dir.path(), "s1", "n1")).unwrap();
    // SAFETY: an exclusive lock on the descriptor this test owns, as a host takes its own.
    assert_eq!(unsafe { libc::flock(host.as_raw_fd(), libc::LOCK_EX) }, 0);
    assert!(!dead_now_in(&dirs, "s1", "n1"), "a held lock is a live host");
    assert!(!dead_now_in(&dirs, "s1", "n1"), "a probe leaves a held lock held");
    // The host lets go with an explicit unlock, not only by closing its descriptor: a test
    // on another thread that starts a process copies every open descriptor into the child
    // until its exec closes them, and a close here then left that copy holding the lock.
    // SAFETY: same descriptor.
    assert_eq!(unsafe { libc::flock(host.as_raw_fd(), libc::LOCK_UN) }, 0);
    drop(host);
    assert!(dead_now_in(&dirs, "s1", "n1"), "a free lock is a dead host");
    assert!(dead_now_in(&dirs, "s1", "n1"), "a probe releases what it took");
}
