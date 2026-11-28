//! Enrollment from settings, the policy, the owner-wins gate, and the report's wire shape.

use super::*;
use serde_json::json;

fn enrolled(idle_secs: u64, hours: Option<Hours>) -> Enrollment {
    Enrollment {
        enabled: true,
        policy: Policy { teams: vec!["team_a".into()], agents: vec![], hours },
        idle_secs,
    }
}

fn mac_caps() -> Vec<String> {
    vec!["arm64".into(), "macos".into(), "xcode".into()]
}

/// Off unless the owner set it: missing, false, a string or an object without `enabled: true`.
#[test]
fn enrollment_is_off_unless_the_owner_sets_it() {
    for doc in [
        json!({}),
        json!({"cloud": {"autoCloud": true}}),
        json!({"cloud": {"autoCloudEnroll": false}}),
        json!({"cloud": {"autoCloudEnroll": "true"}}),
        json!({"cloud": {"autoCloudEnroll": {"teams": ["t"]}}}),
        json!({"cloud": {"autoCloudEnroll": {"enabled": true, "teams": "t"}}}),
    ] {
        assert!(!Enrollment::from_doc(&doc).enabled, "{doc}");
    }
    let on = Enrollment::from_doc(&json!({"cloud.autoCloudEnroll": true}));
    assert_eq!(on, Enrollment { enabled: true, ..Enrollment::default() });
    let full = Enrollment::from_doc(&json!({"cloud": {"autoCloudEnroll": {
        "enabled": true, "teams": ["team_a"], "agents": ["claude"],
        "hours": {"from": 20, "to": 8}, "idleSecs": 120}}}));
    assert_eq!(full.policy.teams, vec!["team_a"]);
    assert_eq!(full.policy.agents, vec!["claude"]);
    assert_eq!(full.policy.hours, Some(Hours { from: 20, to: 8 }));
    assert_eq!(full.idle_secs, 120);
}

#[test]
fn hours_wrap_midnight() {
    let night = Hours { from: 20, to: 8 };
    assert!(night.contains(23) && night.contains(0) && night.contains(7));
    assert!(!night.contains(8) && !night.contains(12) && !night.contains(19));
    let day = Hours { from: 9, to: 17 };
    assert!(day.contains(9) && !day.contains(17));
    assert!(Hours { from: 5, to: 5 }.contains(13));
}

/// The owner's own work always; a team's only when listed; agents when listed.
#[test]
fn policy_allows_the_owner_and_listed_teams_only() {
    let p = Policy { teams: vec!["team_a".into()], agents: vec![], hours: None };
    assert!(p.allows(None, Some("codex")));
    assert!(p.allows(Some("team_a"), None));
    assert!(!p.allows(Some("team_b"), None), "another team's work never runs here");
    let only_claude = Policy { agents: vec!["claude".into()], ..Policy::default() };
    assert!(only_claude.allows(None, Some("Claude")));
    assert!(!only_claude.allows(None, Some("codex")));
    assert!(!only_claude.allows(None, None));
    assert!(!Policy::default().allows(Some("team_a"), None));
}

/// The owner wins: active, unread presence or outside hours is not accepting.
#[test]
fn accepting_needs_owner_away_and_inside_hours() {
    let e = enrolled(600, Some(Hours { from: 20, to: 8 }));
    let away = report(&e, Some(900.0), 22, mac_caps());
    assert!(away.accepting, "{away:?}");
    assert_eq!(away.owner_idle, Some(true));
    let active = report(&e, Some(30.0), 22, mac_caps());
    assert!(!active.accepting);
    assert_eq!(active.owner_idle, Some(false));
    assert!(active.why.starts_with("owner active"), "{}", active.why);
    let unread = report(&e, None, 22, mac_caps());
    assert!(!unread.accepting, "an unread presence is never idle");
    assert_eq!(unread.owner_idle, None);
    let daytime = report(&e, Some(900.0), 12, mac_caps());
    assert!(!daytime.accepting);
    assert_eq!(daytime.why, "outside its hours");
    let headless = report(&enrolled(0, None), None, 12, vec!["linux".into()]);
    assert!(headless.accepting, "idleSecs 0: a headless box with no owner at a keyboard");
    let off = report(&Enrollment::default(), Some(9999.0), 12, mac_caps());
    assert!(!off.enrolled && !off.accepting);
}

/// The block's wire shape, and an older machine's health (no block) reads as not enrolled.
#[test]
fn report_wire_shape_and_old_health() {
    let r = report(&enrolled(600, None), Some(700.4), 3, mac_caps());
    let v = serde_json::to_value(&r).unwrap();
    assert_eq!(v["v"], 1);
    assert_eq!(v["ownerIdleSecs"], 700);
    assert_eq!(v["ownerIdle"], true);
    assert_eq!(v["inHours"], true);
    assert_eq!(v["policy"]["teams"], json!(["team_a"]));
    assert_eq!(Report::of_health(&json!({"autoCloud": v})), r);
    let old = Report::of_health(&json!({"os": "macos", "cpus": 10}));
    assert!(!old.enrolled && !old.accepting);
    // A newer block with fields this build does not know still reads.
    let newer = Report::of_health(&json!({"autoCloud": {"v": 2, "enrolled": true,
        "accepting": true, "caps": ["macos"], "futureField": {"x": 1}}}));
    assert!(newer.accepting && newer.fits(&["MacOS".into()]));
    assert!(!newer.fits(&["xcode".into()]));
}
