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
async fn a_fresh_relay_listing_is_kept_and_served_stale_when_the_next_one_stalls() {
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

    let stale =
        start_with(Some(stalled_relay()), cache.clone(), None, FAR_BUDGET).finish().await.relay;
    let stale = stale.unwrap();
    let RemoteState::Stale { as_of_ms } = stale.state else { panic!("{:?}", stale.state) };
    assert_eq!(stale.rows.len(), 1);
    assert_eq!(stale.rows[0]["sessionId"], "r-1");
    assert_eq!(stale.rows[0]["stale"], true);
    assert_eq!(stale.rows[0]["asOfMs"], as_of_ms);
    let line = stale.line(as_of_ms + 180_000).unwrap();
    assert_eq!(
        line,
        "acpmux: other machines' sessions through sh: not read within 1.5s; listed as of 3m ago"
    );
    let remote = stale.json(as_of_ms + 1);
    assert_eq!(remote["state"], "stale");
    assert_eq!(remote["asOfMs"], as_of_ms);
    assert_eq!(remote["source"], "sh");
}

#[tokio::test]
async fn a_failing_relay_serves_the_cache_and_names_the_failure() {
    let dir = tempfile::tempdir().unwrap();
    let cache = dir.path().join(CACHE_FILE);
    write_cache(&cache, "sh", &[serde_json::json!({"peer": "p", "sessionId": "s"})], 1_000);
    // The listing is a day and more old: not served.
    assert!(read_cache(&cache, 1_000 + CACHE_MAX_AGE_MS + 1).is_none());
    let now = crate::store::now_ms();
    write_cache(&cache, "sh", &[serde_json::json!({"peer": "p", "sessionId": "s"})], now);
    let relay =
        start_with(Some(sh_relay("exit 3")), cache, None, FAR_BUDGET).finish().await.relay.unwrap();
    assert_eq!(relay.state, RemoteState::Stale { as_of_ms: now });
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
