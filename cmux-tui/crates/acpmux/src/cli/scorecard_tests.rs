use super::*;

#[test]
fn params_name_the_range_and_the_steer_window() {
    let args = ScorecardArgs {
        since: Some("2d".into()),
        by: "feature".into(),
        steer_window: Some(30),
        limit: 5,
        home: None,
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
