use super::*;

#[test]
fn a_launchd_daemon_job_stands_by() {
    assert!(stands_by(Some("com.acpmux.daemon"), 1, false));
    assert!(stands_by(Some("com.cmux.acpmux.daemon.077f602dcb3c3936"), 1, false));
}

#[test]
fn every_other_start_keeps_the_prompt_refusal() {
    // A take-over start asks the holder instead.
    assert!(!stands_by(Some("com.acpmux.daemon"), 1, true));
    // Not launchd's direct child: a shell, the app, `daemon start`.
    assert!(!stands_by(Some("com.acpmux.daemon"), 4242, false));
    // Terminal sets XPC_SERVICE_NAME=0; an app's children inherit its own label.
    assert!(!stands_by(Some("0"), 1, false));
    assert!(!stands_by(Some("application.com.cmuxterm.app.nightly.123"), 1, false));
    assert!(!stands_by(None, 1, false));
}
