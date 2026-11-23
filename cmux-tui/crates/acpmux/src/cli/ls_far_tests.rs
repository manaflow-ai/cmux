//! The far reads' budget and stale cache (`ls_far.rs`), with stub relay programs.

use super::*;

/// A relay whose listing runs `script` in `sh`.
pub(crate) fn sh_relay(script: &str) -> SendRelay {
    SendRelay {
        argv: vec!["sh".into(), "-c".into(), "exit 1".into()],
        ls_argv: Some(vec!["sh".into(), "-c".into(), script.into()]),
    }
}

/// A relay that stalls: sleeps 30 s.
pub(crate) fn stalled_relay() -> SendRelay {
    sh_relay("sleep 30")
}

const ONE_ROW: &str = r#"printf '%s' '{"sessions":[{"peer":"relayed-vm","sessionId":"r-1","name":"relayed-vm/worker","status":"idle","updatedAt":5}]}'"#;

#[tokio::test]
async fn a_stalled_relay_misses_its_budget_and_is_not_listed_without_a_cache() {
    let dir = tempfile::tempdir().unwrap();
    let cache = dir.path().join(CACHE_FILE);
    let started = std::time::Instant::now();
    let far = start_with(Some(stalled_relay()), cache, None, FAR_BUDGET).finish().await;
    let took = started.elapsed();
    assert!(took < Duration::from_secs(2), "the far read took {took:?}");
    let relay = far.relay.expect("a relay is configured");
    assert_eq!(relay.state, RemoteState::Missing);
    assert!(relay.rows.is_empty());
    assert_eq!(
        relay.line(0).as_deref(),
        Some("acpmux: other machines' sessions through sh: not read within 1.5s; not listed")
    );
    assert_eq!(relay.json(7)["state"], "missing");
}

#[tokio::test]
async fn a_relay_that_never_answers_is_waited_on_once_then_listed_as_unknown_at_once() {
    let dir = tempfile::tempdir().unwrap();
    let cache = dir.path().join(CACHE_FILE);
    let first = start_with(Some(stalled_relay()), cache.clone(), None, FAR_BUDGET).finish().await;
    assert_eq!(first.relay.unwrap().state, RemoteState::Missing);
    for _ in 0..3 {
        let started = std::time::Instant::now();
        let far = start_with(Some(stalled_relay()), cache.clone(), None, FAR_BUDGET).finish().await;
        let took = started.elapsed();
        assert!(took < Duration::from_millis(100), "a known slow relay was waited on: {took:?}");
        let relay = far.relay.unwrap();
        assert_eq!(relay.state, RemoteState::Missing);
        assert!(relay.rows.is_empty());
        assert_eq!(
            relay.line(0).as_deref(),
            Some(
                "acpmux: other machines' sessions through sh: no answer yet, refreshing; not listed"
            )
        );
    }
    // Its first answer is kept and retires the miss: the next ls lists those rows with their asOfMs.
    write_cache(&cache, "sh", &[json!({"sessionId": "r-1"})], crate::store::now_ms());
    let far = start_with(Some(stalled_relay()), cache, None, FAR_BUDGET).finish().await;
    let relay = far.relay.unwrap();
    assert!(matches!(relay.state, RemoteState::Stale { .. }));
    assert!(relay.rows[0].get("stale").is_none(), "a kept row is not a down peer's");
}

#[tokio::test]
async fn a_fresh_relay_listing_is_kept_and_the_next_ls_serves_it_without_waiting() {
    let dir = tempfile::tempdir().unwrap();
    let cache = dir.path().join(CACHE_FILE);
    let fresh = start_with(Some(sh_relay(ONE_ROW)), cache.clone(), None, Duration::from_secs(10))
        .finish()
        .await
        .relay
        .unwrap();
    assert_eq!(fresh.state, RemoteState::Fresh);
    assert_eq!(fresh.rows.len(), 1);
    assert_eq!(fresh.rows[0]["via"], send_relay::VIA);
    assert!(fresh.line(0).is_none());
    assert!(cache.exists(), "the good listing is kept");

    let started = std::time::Instant::now();
    let stale =
        start_with(Some(stalled_relay()), cache.clone(), None, FAR_BUDGET).finish().await.relay;
    let took = started.elapsed();
    assert!(took < Duration::from_millis(200), "a kept listing waited on the relay: {took:?}");
    let stale = stale.unwrap();
    let RemoteState::Stale { as_of_ms } = stale.state else { panic!("{:?}", stale.state) };
    assert_eq!(stale.rows.len(), 1);
    assert_eq!(stale.rows[0]["sessionId"], "r-1");
    assert!(stale.rows[0].get("stale").is_none());
    assert_eq!(stale.rows[0]["asOfMs"], as_of_ms);
    let line = stale.line(as_of_ms + 180_000).unwrap();
    assert_eq!(
        line,
        "acpmux: other machines' sessions through sh: from the last listing, refreshing; listed as of 3m ago"
    );
    // A listing kept under a minute ago reads as good as fresh in the text view.
    assert!(stale.line(as_of_ms + 59_000).is_none());
    let remote = stale.json(as_of_ms + 1);
    assert_eq!(remote["state"], "stale");
    assert_eq!(remote["asOfMs"], as_of_ms);
    assert_eq!(remote["source"], "sh");
}

/// A kept listing older than [`FRESH_AGE_MS`] is as old as the caller's last `ls`: the relay is
/// read for it, by [`KEPT_WAIT`], and the kept rows listed only when that misses (cmuxterm-hq
/// `docs/findings/2026-11-23-acpmux-ls-serves-idle-gap.md`).
#[tokio::test]
async fn an_old_kept_listing_is_read_again_and_kept_only_when_the_relay_misses() {
    let dir = tempfile::tempdir().unwrap();
    let cache = dir.path().join(CACHE_FILE);
    let old = crate::store::now_ms() - 60_000;
    let kept_row = serde_json::json!({"peer": "p", "sessionId": "old"});
    write_cache(&cache, "sh", std::slice::from_ref(&kept_row), old);

    // A healthy relay: the fresh rows, not the kept ones, and they are kept in turn.
    let fresh = start_with(Some(sh_relay(ONE_ROW)), cache.clone(), None, FAR_BUDGET)
        .finish()
        .await
        .relay
        .unwrap();
    assert_eq!(fresh.state, RemoteState::Fresh);
    assert_eq!(fresh.rows[0]["sessionId"], "r-1");
    assert!(read_cache(&cache, crate::store::now_ms()).unwrap().0 > old);

    // A stalled relay with no refresh running: read by KEPT_WAIT, then the kept rows.
    write_cache(&cache, "sh", std::slice::from_ref(&kept_row), old);
    let started = std::time::Instant::now();
    let kept =
        start_with(Some(stalled_relay()), cache.clone(), None, FAR_BUDGET).finish().await.relay;
    let took = started.elapsed();
    assert!(took >= KEPT_WAIT && took < KEPT_WAIT * 2, "the old kept listing took {took:?}");
    let kept = kept.unwrap();
    assert_eq!(kept.state, RemoteState::Stale { as_of_ms: old });
    assert_eq!(kept.rows[0]["sessionId"], "old");
    assert!(cache.with_file_name(REFRESH_MARK).exists(), "the miss starts a refresh");

    // While that refresh runs, the next ls lists the kept rows at once.
    let started = std::time::Instant::now();
    let kept =
        start_with(Some(stalled_relay()), cache, None, FAR_BUDGET).finish().await.relay.unwrap();
    let took = started.elapsed();
    assert!(took < Duration::from_millis(200), "a running refresh was waited on: {took:?}");
    assert_eq!(kept.state, RemoteState::Stale { as_of_ms: old });
}

#[tokio::test]
async fn a_failing_relay_without_a_kept_listing_names_the_failure() {
    let dir = tempfile::tempdir().unwrap();
    let cache = dir.path().join(CACHE_FILE);
    write_cache(&cache, "sh", &[serde_json::json!({"peer": "p", "sessionId": "s"})], 1_000);
    // The listing is a day and more old: not served, so the relay is read.
    assert!(read_cache(&cache, 1_000 + CACHE_MAX_AGE_MS + 1).is_none());
    let relay =
        start_with(Some(sh_relay("exit 3")), cache, None, FAR_BUDGET).finish().await.relay.unwrap();
    assert_eq!(relay.state, RemoteState::Missing);
    assert!(relay.missed.as_deref().unwrap().starts_with("failed ("), "{:?}", relay.missed);
}

#[tokio::test]
async fn no_relay_no_remote() {
    let dir = tempfile::tempdir().unwrap();
    let far = start_with(None, dir.path().join(CACHE_FILE), None, FAR_BUDGET).finish().await;
    assert!(far.relay.is_none() && far.ssh_hosts.is_empty() && far.ssh_rows.is_empty());
}

#[test]
fn budgets_read_as_seconds() {
    assert_eq!(seconds(FAR_BUDGET), "1.5s");
    assert_eq!(seconds(Duration::from_secs(2)), "2s");
}
