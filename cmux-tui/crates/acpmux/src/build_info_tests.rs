use super::lags;

// 2026-11-22: cmux16 (a NIGHTLY Mac, b653865c3 2026-11-22) could move none of its idle chats with
// `session move --host auto`: both cloud peers (bb5e29da6 2026-11-22) were passed over as
// "outdated peer build (stale disk copy)", since any other build counted as outdated.
#[test]
fn a_newer_or_same_day_peer_build_does_not_lag() {
    assert!(!lags("bb5e29da6 2026-11-22", "b653865c3 2026-11-22"));
    assert!(!lags("bb5e29da6 2026-11-23", "b653865c3 2026-11-22"));
    assert!(!lags("b653865c3 2026-11-22", "b653865c3 2026-11-22"));
}

#[test]
fn an_older_peer_build_lags() {
    assert!(lags("a1143d5cc 2026-11-21", "b653865c3 2026-11-22"));
    assert!(lags("a1143d5cc 2026-10-30", "b653865c3 2026-11-02"));
}

#[test]
fn a_build_without_a_date_lags_when_it_differs() {
    assert!(lags("unstamped", "b653865c3 2026-11-22"));
    assert!(lags("b653865c3 2026-11-22", "unstamped"));
    assert!(!lags("unstamped", "unstamped"));
    assert!(lags("bb5e29da6 not-a-date", "b653865c3 2026-11-22"));
}
