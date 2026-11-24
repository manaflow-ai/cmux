use super::*;

#[test]
fn race_start_repeats_one_model_for_its_attempts() {
    let (m, params) = request(
        "race_start",
        &json!({"prompt": "fix it", "models": ["codex"], "attempts": 4, "reviewer": "claude/opus"}),
    )
    .unwrap();
    assert_eq!(m, method::MUX_RACE_START);
    assert_eq!(params["candidates"].as_array().unwrap().len(), 4);
    assert_eq!(params["reviewer"], json!({"harness": "claude", "model": "opus"}));
    assert!(params.get("parent").is_none(), "the daemon derives the parent from the token");
}

#[test]
fn race_start_refuses_one_candidate_and_bad_attempts() {
    for args in [
        json!({"prompt": "t", "models": ["codex"], "reviewer": "claude"}),
        json!({"prompt": "t", "models": ["codex"], "attempts": 0, "reviewer": "claude"}),
        json!({"prompt": "t", "models": ["codex"], "attempts": 99, "reviewer": "claude"}),
        json!({"prompt": " ", "models": ["codex", "claude"], "reviewer": "claude"}),
        json!({"prompt": "t", "models": ["codex", "claude"]}),
    ] {
        assert!(request("race_start", &args).is_err(), "accepted {args}");
    }
}

#[test]
fn race_show_reads_one_race_or_lists() {
    assert_eq!(
        request("race_show", &json!({"race_id": "r1"})).unwrap(),
        (method::MUX_RACE_GET, json!({"raceId": "r1"}))
    );
    assert_eq!(request("race_show", &json!({})).unwrap().0, method::MUX_RACE_LIST);
}
