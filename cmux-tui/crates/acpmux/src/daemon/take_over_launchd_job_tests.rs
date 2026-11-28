/// Only this user's `com.acpmux.daemon` job waits for the lock, and only on macOS.
#[test]
fn only_the_acpmux_launch_agent_waits_for_the_home() {
    assert_eq!(super::launchd_job(Some("com.acpmux.daemon")), cfg!(target_os = "macos"));
    assert!(!super::launchd_job(Some("com.cmuxterm.app.nightly.keepalive")));
    assert!(!super::launchd_job(Some("application.com.cmuxterm.app.nightly.1.2")));
    assert!(!super::launchd_job(None));
}

/// The per-home job a command starts waits too, so a `KeepAlive` copy of it never loops on
/// exit 75 while a take-over start serves the home (cmuxterm-hq #22842).
#[test]
fn the_per_home_job_waits_for_the_home() {
    let mac = cfg!(target_os = "macos");
    assert_eq!(super::launchd_job(Some("com.cmux.acpmux.daemon.077f602dcb3c3936")), mac);
    assert!(!super::launchd_job(Some("com.cmux.acpmux.daemon.")));
    assert!(!super::launchd_job(Some("com.cmux.acpmux.daemonx")));
}
