use super::*;

/// A display allocation lets go of the display lock, also while a child the daemon forked
/// meanwhile has the descriptor: else the next session start waits until that child execs.
#[test]
fn an_allocation_leaves_the_display_lock_free_while_a_forked_child_keeps_its_descriptor() {
    let home = tempfile::tempdir().unwrap();
    let dir = home.path().join("agent-displays");
    private_dir(&dir).unwrap();
    let lock = open_private(&dir.join("lock")).unwrap();
    let keeper = crate::fork_tests::Keeper::fork();
    let n = display_for_locked(lock, &dir, "w1".to_owned()).unwrap();
    let free = crate::fork_tests::free(&dir.join("lock"));
    drop(keeper);
    assert_eq!(n, BASE);
    assert!(free, "an allocation left the display lock held");
}
