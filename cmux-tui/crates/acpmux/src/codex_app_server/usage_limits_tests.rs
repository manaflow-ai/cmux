//! Codex's plan usage limits as acpmux's `usageLimits` (`usage_limits.rs`). Snapshots as
//! `codex app-server` sends them in `account/rateLimits/updated` (cmux-codex-acp passes them on
//! as `_meta.codexAppServer.rateLimits`): `usedPercent` is 0-100 and `resetsAt` unix seconds.

use super::usage_limits::{read_usage_limits, usage_limits};
use serde_json::json;

#[test]
fn a_pro_plan_names_its_five_hour_and_weekly_windows_and_its_credits() {
    let snapshot = json!({
        "limitId": "codex",
        "limitName": null,
        "primary": {"usedPercent": 22, "windowDurationMins": 300, "resetsAt": 1_790_000_000},
        "secondary": {"usedPercent": 90.5, "windowDurationMins": 10080, "resetsAt": 1_790_500_000},
        "credits": {"hasCredits": true, "unlimited": false, "balance": "56766"},
        "planType": "pro",
    });
    assert_eq!(
        usage_limits(&snapshot),
        Some(json!({
            "windows": [
                {"id": "session", "usedPercent": 22.0, "windowMins": 300, "resetsAt": 1_790_000_000},
                {"id": "weekly", "usedPercent": 90.5, "windowMins": 10080, "resetsAt": 1_790_500_000},
            ],
            "plan": "pro",
            "credits": {"balance": "56766"},
        }))
    );
}

#[test]
fn a_weekly_only_plan_and_unlimited_credits() {
    // Codex's Plus plan reports its weekly window as the primary one.
    let snapshot = json!({
        "primary": {"usedPercent": 140, "windowDurationMins": 10080},
        "secondary": null,
        "credits": {"hasCredits": true, "unlimited": true, "balance": null},
        "planType": "plus",
    });
    assert_eq!(
        usage_limits(&snapshot),
        Some(json!({
            "windows": [{"id": "weekly", "usedPercent": 100.0, "windowMins": 10080}],
            "plan": "plus",
            "credits": {"unlimited": true},
        }))
    );
}

#[test]
fn other_windows_keep_their_length_and_unnamed_ones_their_slot() {
    let snapshot = json!({
        "primary": {"usedPercent": 5, "windowDurationMins": 60},
        "secondary": {"usedPercent": 6},
    });
    assert_eq!(
        usage_limits(&snapshot),
        Some(json!({"windows": [
            {"id": "60m", "usedPercent": 5.0, "windowMins": 60},
            {"id": "secondary", "usedPercent": 6.0},
        ]}))
    );
}

#[test]
fn nothing_reported_is_nothing_never_a_zero() {
    for snapshot in [
        json!(null),
        json!("limits"),
        json!({}),
        json!({"primary": null, "secondary": null}),
        json!({"primary": {"windowDurationMins": 300}}),
        json!({"primary": {"usedPercent": "half"}}),
        // No credits held and none unlimited is no credit line, and a plan alone is no limit.
        json!({"credits": {"hasCredits": false, "unlimited": false, "balance": "0"}, "planType": "pro"}),
        // Another limit than Codex's own (a model's): its windows are not the plan's.
        json!({"limitId": "codex_other", "primary": {"usedPercent": 50, "windowDurationMins": 300}}),
    ] {
        assert_eq!(usage_limits(&snapshot), None, "{snapshot}");
    }
}

#[test]
fn credits_alone_are_reported() {
    let snapshot = json!({"credits": {"hasCredits": true, "unlimited": false, "balance": "12.5"}});
    assert_eq!(
        usage_limits(&snapshot),
        Some(json!({"windows": [], "credits": {"balance": "12.5"}}))
    );
}

#[test]
fn only_the_plans_own_snapshot_replaces_the_saved_limits() {
    use super::usage_limits::is_plan_snapshot;
    // An empty plan snapshot is the plan's: it clears what was saved (`hub/permissions.rs`).
    assert!(is_plan_snapshot(&json!({})));
    assert!(is_plan_snapshot(&json!({"limitId": "codex", "primary": null})));
    assert!(!is_plan_snapshot(&json!({"limitId": "codex_other"})));
    assert!(!is_plan_snapshot(&json!(null)));
}

/// `account/rateLimits/read` at rest (Settings, `_acpmux/account/usage`): the plan's snapshot maps
/// as an update's; the keyed `codex` one wins over `rateLimits`, another limit's is never the plan's.
#[test]
fn a_rate_limits_read_maps_the_plans_own_snapshot() {
    let pro = json!({
        "limitId": "codex",
        "primary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": null},
        "secondary": {"usedPercent": 60, "windowDurationMins": 10080, "resetsAt": 1_790_500_000},
        "credits": null,
        "planType": "pro",
    });
    let expected = json!({
        "windows": [
            {"id": "session", "usedPercent": 25.0, "windowMins": 300},
            {"id": "weekly", "usedPercent": 60.0, "windowMins": 10080, "resetsAt": 1_790_500_000},
        ],
        "plan": "pro",
    });
    let reply = json!({"rateLimits": pro, "rateLimitsByLimitId": null});
    assert_eq!(read_usage_limits(&reply), Some(expected.clone()));
    let model =
        json!({"limitId": "gpt-6-sol", "primary": {"usedPercent": 99, "windowDurationMins": 300}});
    let keyed =
        json!({"rateLimits": model, "rateLimitsByLimitId": {"codex": pro, "gpt-6-sol": model}});
    assert_eq!(read_usage_limits(&keyed), Some(expected));
    assert_eq!(read_usage_limits(&json!({"rateLimits": model})), None, "a model's limit");
    assert_eq!(read_usage_limits(&json!({"rateLimits": {"planType": "pro"}})), None, "no window");
    assert_eq!(read_usage_limits(&json!({})), None);
}
