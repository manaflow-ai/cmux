use super::*;

#[test]
fn cursor_probe_cache_expires_and_can_be_refreshed_at_login() {
    use std::time::Instant;

    let cache = CursorProbeCache(StdMutex::new(None));
    let start = Instant::now();
    assert!(!cache.check(false, || start, || false));
    let before_expiry = start + Duration::from_secs(29);
    assert!(!cache.check(false, || before_expiry, || panic!("probed before expiry")));
    let expiry = start + Duration::from_secs(30);
    assert!(cache.check(false, || expiry, || true));
    assert!(!cache.check(true, || expiry, || false));
    assert!(!cache.check(false, || expiry, || panic!("did not cache the refreshed result")));
}

#[cfg(unix)]
#[test]
fn cursor_probe_times_out_a_stalled_child() {
    let now = std::time::Instant::now();
    let mut child = Command::new("/bin/sh");
    child.args(["-c", "exec sleep 30"]);
    assert!(!probe_status(&mut child, Duration::from_millis(30)));
    assert!(now.elapsed() < Duration::from_secs(3));
    assert!(probe_status(
        Command::new("/bin/sh").args(["-c", "exit 0"]),
        Duration::from_secs(1)
    ));
}
