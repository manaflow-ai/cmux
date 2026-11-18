use super::*;

#[test]
fn a_recap_with_an_ask_and_two_answers_is_shown() {
    let shown = check(
        &json!({"recap": " Done. ", "ask": "Open a PR?", "actions": ["Yes, open PR", "Not now"]}),
    )
    .unwrap();
    assert_eq!(
        shown,
        json!({"recap": "Done.", "ask": "Open a PR?", "actions": ["Yes, open PR", "Not now"]})
    );
    assert_eq!(check(&json!({"recap": "Done."})).unwrap()["ask"], Value::Null);
}

#[test]
fn a_missing_recap_extra_answers_or_answers_without_a_question_are_refused() {
    for bad in [
        json!({}),
        json!({"recap": "  "}),
        json!({"recap": "Done.", "ask": "Open?", "actions": ["a", "b", "c"]}),
        json!({"recap": "Done.", "actions": ["Yes"]}),
        json!({"recap": "Done.", "ask": "Open?", "actions": "Yes"}),
        json!({"recap": "x".repeat(MAX_RECAP + 1)}),
        json!({"recap": "Done.", "learned": ["a", "b", "c", "d"]}),
        json!({"recap": "Done.", "learned": ["two\nlines"]}),
        json!({"recap": "Done.", "learned": "Use pnpm."}),
    ] {
        assert!(check(&bad).is_err(), "{bad}");
    }
}

#[test]
fn learned_facts_are_kept_trimmed_and_left_out_when_empty() {
    let shown = check(&json!({"recap": "Done.", "learned": [" Use pnpm, not npm. "]})).unwrap();
    assert_eq!(shown["learned"], json!(["Use pnpm, not npm."]));
    assert!(check(&json!({"recap": "Done.", "learned": []})).unwrap().get("learned").is_none());
}

#[test]
fn the_call_answers_with_what_it_showed() {
    let result = call(&json!({"recap": "Done.", "ask": "Open a PR?"}));
    assert_eq!(result["isError"], false);
    assert_eq!(result["structuredContent"]["ask"], "Open a PR?");
    assert!(result["content"][0]["text"].as_str().unwrap().contains("End your turn now"));
    assert_eq!(call(&json!({}))["isError"], true);
}
