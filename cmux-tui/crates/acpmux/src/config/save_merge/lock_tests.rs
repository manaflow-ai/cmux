use super::*;

/// A save lets go of the config lock, also while a child the daemon forked meanwhile has the
/// descriptor: else the next save (daemon or CLI) waits, and past 1 s saves without the lock.
#[test]
fn a_dropped_config_lock_is_free_while_a_forked_child_keeps_its_descriptor() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("config.json");
    let held = lock(&path).expect("a free config lock");
    let keeper = crate::fork_tests::Keeper::fork();
    drop(held);
    let free = crate::fork_tests::free(&dir.path().join("config.json.lock"));
    drop(keeper);
    assert!(free, "a dropped config lock stayed held through a forked child's copy");
}
