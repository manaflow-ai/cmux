use std::time::Duration;

use optchat_chief::gateway::{GatewayEvent, GatewayFallback, GatewayHealth, GatewayRoute};

#[test]
fn refusals_share_threshold_backoff_and_one_notice() {
    let health = GatewayHealth::new(
        "sr2-gateway.tail137216.ts.net:4016",
        3,
        GatewayFallback::Harness("codex".into()),
    );

    assert_eq!(
        health.record_refusal("a1", "ECONNREFUSED"),
        GatewayEvent::Observed {
            refusals: 1,
            backoff: Duration::from_secs(1),
        }
    );
    assert_eq!(
        health.record_refusal("a2", "connection refused"),
        GatewayEvent::Observed {
            refusals: 2,
            backoff: Duration::from_secs(2),
        }
    );
    assert_eq!(
        health.record_refusal("a3", "connection refused"),
        GatewayEvent::EnteredFallback {
            refusals: 3,
            route: GatewayRoute::Harness("codex".into()),
        }
    );
    assert_eq!(health.route(), GatewayRoute::Harness("codex".into()));
    assert!(health.take_notice().is_some());
    assert!(health.take_notice().is_none());

    let next = health.record_refusal("a4", "connection refused");
    assert!(matches!(next, GatewayEvent::Fallback { .. }));
    assert_eq!(health.route(), GatewayRoute::Harness("codex".into()));
}

#[test]
fn a_healthy_probe_switches_new_work_back_to_the_gateway() {
    let health = GatewayHealth::new("sr2:4016", 2, GatewayFallback::DirectAnthropic);
    health.record_refusal("a1", "connection refused");
    health.record_refusal("a2", "connection refused");
    assert_eq!(health.route(), GatewayRoute::DirectAnthropic);

    health.mark_healthy();
    assert_eq!(health.route(), GatewayRoute::Primary);
    assert_eq!(health.refusals(), 0);
}

#[test]
fn one_session_retry_does_not_count_as_a_gateway_wide_outage() {
    let health = GatewayHealth::new("sr2:4016", 3, GatewayFallback::Harness("codex".into()));

    for _ in 0..3 {
        health.record_refusal("same-session", "connection refused");
    }

    assert_eq!(health.route(), GatewayRoute::Primary);
    assert_eq!(health.refusals(), 1);
}
