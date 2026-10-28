/// A pooled host ends at the end of its wait only when no controller
/// ever said `Hello`; a session's host never ends this way.
#[test]
fn only_a_pooled_host_with_no_controller_yet_ends_after_its_wait() {
    assert!(super::pooled_without_owner(true, None));
    assert!(!super::pooled_without_owner(true, Some(1)));
    assert!(!super::pooled_without_owner(false, None));
}

/// The leader is waited for without being reaped: while it is a zombie
/// its process group id cannot be reused, so ending the group then can
/// never signal another process group.
#[test]
fn waiting_for_the_leader_leaves_it_unreaped() {
    let mut child = std::process::Command::new("/bin/sh").args(["-c", "exit 3"]).spawn().unwrap();
    let pid = child.id() as i32;
    assert!(super::wait_exit_unreaped(pid), "the wait failed");
    // SAFETY: signal 0 to this test's own child only checks existence.
    assert_eq!(unsafe { libc::kill(pid, 0) }, 0, "the leader was reaped by the wait");
    assert_eq!(child.wait().unwrap().code(), Some(3), "the exit status is kept for the reaper");
}
