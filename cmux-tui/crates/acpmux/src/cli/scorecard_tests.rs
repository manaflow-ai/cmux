use super::*;

#[test]
fn no_churn_fails_on_either_churn_counter() {
    let card = |hm: Value| json!({"totals": {"harnessMagic": hm}});
    assert!(no_churn(&card(json!({"cacheAlarm.observed": 9, "cacheAlarm.declared": 2}))).is_ok());
    assert!(no_churn(&json!({})).is_ok());
    let e = no_churn(&card(json!({"cacheAlarm.collapses": 1, "cacheAlarm.callChurn": 2})));
    assert!(e.unwrap_err().to_string().contains("3 prefix churn"));
}

#[test]
fn params_name_the_range_and_the_steer_window() {
    let args = ScorecardArgs {
        since: Some("2d".into()),
        by: "feature".into(),
        steer_window: Some(30),
        limit: 5,
        home: None,
        assert_no_churn: false,
        cmd: None,
    };
    let p = params(&args, 10 * 86_400_000).unwrap();
    assert_eq!(p["since"], 8 * 86_400_000u64);
    assert_eq!(p["steerWindowS"], 30);
    assert!(params(&ScorecardArgs { by: "colour".into(), ..args }, 0).is_err());
}

#[test]
fn text_says_when_no_feature_ran() {
    let args = ScorecardArgs { by: "feature".into(), ..ScorecardArgs::default() };
    let a = json!({"since": 1, "until": 2, "steerWindowS": 60,
        "totals": {"turns": 3, "sessions": 1, "steeringRate": 0.5, "ttfu": {}, "firstModel": {}},
        "byFeature": {}});
    let t = text(&args, &a);
    assert!(t.contains("every turn is the baseline"), "{t}");
    assert!(t.contains("0.500"), "{t}");
}

#[test]
fn text_shows_the_prefetch_hit_rate() {
    let args = ScorecardArgs { by: "feature".into(), ..ScorecardArgs::default() };
    let on = json!({"turns": 2, "ttfu": {}, "firstModel": {},
        "harnessMagic": {"prefetch.files": 4, "prefetch.hits": 3}});
    let a = json!({"since": 1, "until": 2, "steerWindowS": 60,
        "totals": {"turns": 3, "ttfu": {}, "firstModel": {}},
        "byFeature": {"prefetch": {"on": on, "off": {"turns": 1, "ttfu": {}, "firstModel": {}}}}});
    let t = text(&args, &a);
    assert!(t.contains("prefetch on"), "{t}");
    assert!(t.contains("prefetch.hitRate=0.75"), "{t}");
}

#[test]
fn scorecard_replay_text_names_each_violation() {
    let a = json!({"sessions": [{"session": "abc", "harness": "claude", "calls": 3, "inits": 1,
        "violations": [{"invariant": 5, "name": "cacheAgrees", "seq": 9, "detail": "collapsed"}]}],
        "missing": ["nope"], "violations": 1, "notYet": [{"invariant": 1}, {"invariant": 3}]});
    let t = replay_text(&a);
    assert!(t.contains("invariant 5 cacheAgrees at seq 9: collapsed"), "{t}");
    assert!(t.contains("nope: no such session"), "{t}");
    assert!(t.contains("1, 3 not yet"), "{t}");
}

#[test]
fn scorecard_replay_text_preserves_unicode_session_prefix() {
    let answer = json!({"sessions": [{"session": "abcdefghijké-more", "harness": "claude",
        "calls": 0, "inits": 0, "violations": []}], "missing": [], "violations": 0,
        "notYet": []});
    let text = replay_text(&answer);
    assert!(text.starts_with("abcdefghijké claude"), "{text}");
}
