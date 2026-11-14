use super::cgroup_is_in_sessions_scope;

#[test]
fn daemon_scope_escape_matches_only_an_exact_session_slice_component() {
    assert!(cgroup_is_in_sessions_scope(
        "0::/user.slice/user-1000.slice/user@1000.service/acpmuxsessions.slice/run-a.scope\n"
    ));
    assert!(!cgroup_is_in_sessions_scope(
        "0::/user.slice/user-1000.slice/user@1000.service/app.slice/run-a.scope\n"
    ));
    assert!(!cgroup_is_in_sessions_scope(
        "0::/user.slice/acpmuxsessions.slice.backup/run-a.scope\n"
    ));
    assert!(cgroup_is_in_sessions_scope(
        "1:name=systemd:/user.slice/acpmuxsessions.slice/run-a.scope\n"
    ));
}
