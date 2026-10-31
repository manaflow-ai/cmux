//! The plan usage limits from Claude Code's `rate_limit_event` (`usage_limits.rs`). Lines as
//! Claude Code 2.1.307 writes them: `utilization` is a 0-1 fraction.

use super::*;

/// The `usageLimits` of each update a line made.
async fn limits(t: &Translator, line: Value) -> Vec<Value> {
    t.inbound(&line)
        .await
        .iter()
        .filter_map(|m| match m {
            Message::Notification { params, .. } => {
                params.as_ref()?.pointer("/update/_meta/acpmux/usageLimits").cloned()
            }
            _ => None,
        })
        .collect()
}

fn event(info: Value) -> Value {
    json!({"type": "rate_limit_event", "rate_limit_info": info, "uuid": "u-1", "session_id": "s-1"})
}

#[tokio::test]
async fn a_rate_limit_event_names_each_window_in_percent() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let got = limits(
        &t,
        event(json!({
            "status": "allowed_warning",
            "rateLimitType": "seven_day_opus",
            "utilization": 0.815,
            "resetsAt": 1_790_000_000,
            "unifiedWindows": {
                "five_hour": {"utilization": 0.07, "resetsAt": 1_789_000_000},
                "seven_day": {"utilization": 0.4, "resetsAt": 1_790_500_000},
                "seven_day_overage_included": {"utilization": 0.1, "resetsAt": 1_790_500_000},
            },
            "isUsingOverage": false,
        })),
    )
    .await;
    assert_eq!(
        got,
        vec![json!({"windows": [
            {"id": "session", "usedPercent": 7.0, "resetsAt": 1_789_000_000},
            {"id": "weekly", "usedPercent": 40.0, "resetsAt": 1_790_500_000},
            {"id": "weekly_opus", "usedPercent": 81.5, "resetsAt": 1_790_000_000},
        ]})]
    );
}

#[tokio::test]
async fn a_later_event_updates_only_its_window() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let both = json!({"status": "allowed", "unifiedWindows": {
        "five_hour": {"utilization": 0.2, "resetsAt": 100},
        "seven_day": {"utilization": 0.3, "resetsAt": 200},
    }});
    limits(&t, event(both)).await;
    // The limiting window alone, past its cap (utilization above 1 reads 100), no reset time.
    let got = limits(
        &t,
        event(json!({"status": "rejected", "rateLimitType": "five_hour", "utilization": 1.25})),
    )
    .await;
    assert_eq!(
        got,
        vec![json!({"windows": [
            {"id": "session", "usedPercent": 100.0},
            {"id": "weekly", "usedPercent": 30.0, "resetsAt": 200},
        ]})]
    );
}

#[tokio::test]
async fn a_malformed_or_overage_only_event_sends_nothing() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    for line in [
        json!({"type": "rate_limit_event"}),
        event(json!("allowed")),
        event(json!({"status": "allowed"})),
        event(json!({"status": "allowed", "rateLimitType": "five_hour"})),
        event(json!({"status": "allowed", "rateLimitType": "five_hour", "utilization": "half"})),
        event(json!({"status": "allowed", "rateLimitType": "overage", "utilization": 0.5})),
        event(json!({"status": "allowed", "unifiedWindows": [1, 2]})),
        event(json!({"status": "allowed", "unifiedWindows": {"seven_day": "full"}})),
        event(json!({"status": "allowed", "unifiedWindows": {
            "seven_day_overage_included": {"utilization": 0.5, "resetsAt": 1},
        }})),
    ] {
        assert!(t.inbound(&line).await.is_empty(), "{line}");
    }
    // A later good event is not mixed with anything from those.
    let got = limits(
        &t,
        event(json!({"status": "allowed", "rateLimitType": "seven_day_sonnet",
        "utilization": 0, "resetsAt": "soon"})),
    )
    .await;
    assert_eq!(got, vec![json!({"windows": [{"id": "weekly_sonnet", "usedPercent": 0.0}]})]);
}

#[test]
fn saved_limits_keep_the_windows_a_newer_one_does_not_name() {
    let saved = json!({"plan": "max", "windows": [
        {"id": "session", "usedPercent": 10.0, "resetsAt": 1},
        {"id": "weekly", "usedPercent": 20.0, "resetsAt": 2},
    ]});
    let newer = json!({"windows": [
        {"id": "weekly", "usedPercent": 25.0, "resetsAt": 2},
        {"id": "weekly_opus", "usedPercent": 5.0},
    ]});
    assert_eq!(
        merge_usage_limits(Some(&saved), &newer),
        json!({"plan": "max", "windows": [
            {"id": "session", "usedPercent": 10.0, "resetsAt": 1},
            {"id": "weekly", "usedPercent": 25.0, "resetsAt": 2},
            {"id": "weekly_opus", "usedPercent": 5.0},
        ]})
    );
    assert_eq!(merge_usage_limits(None, &newer), newer);
}
