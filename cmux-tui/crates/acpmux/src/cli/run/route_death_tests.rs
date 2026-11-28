use super::*;
use std::future::pending;

#[tokio::test(start_paused = true)]
async fn silent_hub_reads_share_one_recovery_budget() {
    let start = Instant::now();
    let deadline = start + HUB_READ_BUDGET;
    let peers = hub_read(deadline, "peers", async {
        tokio::time::sleep(Duration::from_secs(2)).await;
        Ok(json!({"peers": [{"name": "vm-a", "connected": false, "downSince": 0}]}))
    })
    .await
    .unwrap();
    let snapshot = hub_read(deadline, "snapshot", pending::<Result<Value>>()).await;
    assert!(snapshot.is_none());
    assert_eq!(Instant::now() - start, HUB_READ_BUDGET);

    // Preserve the peer observation and let caller facts decide even without the snapshot.
    let seen = crate::death_route::observe::observe("vm-a/lane", &peers, snapshot.as_ref(), 5000);
    let facts = crate::death_route::observe::merge(seen, json!({"dead_seconds": 7200.0}));
    assert_eq!(facts["host_down"], true);
    assert_eq!(facts["dead_seconds"], 7200.0);

    // A later optional read cannot renew the exhausted budget.
    assert!(hub_read(deadline, "later read", pending::<Result<Value>>()).await.is_none());
    assert_eq!(Instant::now() - start, HUB_READ_BUDGET);
}

#[tokio::test(start_paused = true)]
async fn silent_connection_cannot_hold_recovery() {
    let start = Instant::now();
    assert!(
        hub_read(start + HUB_READ_BUDGET, "connect", pending::<Result<Value>>()).await.is_none()
    );
    assert_eq!(Instant::now() - start, HUB_READ_BUDGET);
}

#[tokio::test(start_paused = true)]
async fn failed_hub_read_preserves_time_for_remaining_observations() {
    let start = Instant::now();
    let deadline = start + HUB_READ_BUDGET;
    assert!(
        hub_read::<Value>(deadline, "peers", async { Err(anyhow!("disconnected")) })
            .await
            .is_none()
    );
    assert_eq!(
        hub_read(deadline, "snapshot", async { Ok(json!({"events": []})) }).await,
        Some(json!({"events": []}))
    );
    assert_eq!(Instant::now(), start);
}
