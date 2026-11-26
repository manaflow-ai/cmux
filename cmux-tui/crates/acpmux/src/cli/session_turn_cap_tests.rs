use super::*;

#[test]
fn each_change_is_one_request_shape() {
    assert_eq!(params("s", Change::Show), json!({"sessionId": "s"}));
    assert_eq!(params("s", Change::Minutes(20))["turnCapMs"], 1_200_000);
    assert_eq!(params("s", Change::Off)["turnCapMs"], 0);
    assert!(params("s", Change::Clear)["turnCapMs"].is_null());
}

#[test]
fn describe_names_the_cap_and_where_it_comes_from() {
    let r = |own: Value, eff: Value| json!({"turnCapMs": own, "effectiveTurnCapMs": eff});
    assert_eq!(describe(&r(Value::Null, Value::Null)), "no turn cap");
    assert_eq!(describe(&r(json!(0), Value::Null)), "no turn cap (turned off for this session)");
    assert_eq!(describe(&r(json!(600_000), json!(600_000))), "turn cap 10 min (this session's)");
    assert_eq!(describe(&r(Value::Null, json!(1_200_000))), "turn cap 20 min (default)");
}
