use super::*;

fn shown(args: Value) -> Value {
    check(&args).unwrap().0
}

#[test]
fn a_recap_with_an_ask_and_two_answers_is_shown() {
    let (got, notes) = check(&json!({"recap": " Done. ", "ask": "Open a PR?", "actions": ["Yes, open PR", "Not now"]}))
        .unwrap();
    assert_eq!(
        got,
        json!({"recap": "Done.", "ask": "Open a PR?", "actions": ["Yes, open PR", "Not now"]})
    );
    assert!(notes.is_empty());
    assert_eq!(shown(json!({"recap": "Done."}))["ask"], Value::Null);
}

#[test]
fn a_missing_recap_answers_without_a_question_or_wrong_types_are_refused() {
    for bad in [
        json!({}),
        json!({"recap": "  "}),
        json!({"recap": "Done.", "actions": ["Yes"]}),
        json!({"recap": "Done.", "ask": "Open?", "actions": "Yes"}),
        json!({"recap": "Done.", "learned": "Use pnpm."}),
    ] {
        assert!(check(&bad).is_err(), "{bad}");
    }
}

/// Length is never a refusal (tool-call bounces, 2026-11-21): a recap up to the ceiling is
/// kept whole, a longer one is cut at a sentence end, and the result says so in one line.
#[test]
fn a_long_recap_is_kept_whole_or_cut_at_a_sentence_and_said_so() {
    let long = "This sentence is forty characters long. ".repeat(20);
    let long = long.trim_end();
    assert!(long.chars().count() > MAX_RECAP && long.chars().count() <= RECAP_CEILING);
    let (got, notes) = check(&json!({"recap": long})).unwrap();
    assert_eq!((got["recap"].as_str().unwrap(), notes.len()), (long, 0));
    let longer = "This sentence is forty characters long. ".repeat(40);
    let result = call(&json!({"recap": longer}));
    assert_eq!(result["isError"], false, "{result}");
    let recap = result["structuredContent"]["recap"].as_str().unwrap();
    assert!(recap.ends_with("long.") && recap.chars().count() <= RECAP_CEILING, "{recap}");
    let text = result["content"][0]["text"].as_str().unwrap();
    let note = format!(
        "recap trimmed from {} to {} characters",
        longer.trim().chars().count(),
        recap.chars().count()
    );
    assert!(text.ends_with(&format!("{note}.")), "{text}");
    // One unbroken run of words is cut at a space, with an ellipsis.
    let words = "word ".repeat(400);
    let recap = shown(json!({"recap": words}))["recap"].as_str().unwrap().to_owned();
    assert!(recap.ends_with("word…") && recap.chars().count() <= RECAP_CEILING, "{recap}");
}

/// Every other bound cuts too: a long ask or answer, a third answer, a long or two-line
/// fact, a fourth fact; each cut is named.
#[test]
fn long_asks_answers_and_facts_are_cut_and_named() {
    let (got, notes) = check(&json!({
        "recap": "Done.",
        "ask": format!("Open {}?", "a PR ".repeat(60)),
        "actions": ["x".repeat(MAX_ACTION + 5), "Not now", "Later"],
        "learned": ["Use pnpm.\nAlso yarn.", "f".repeat(MAX_FACT + 1), "c", "d"],
    }))
    .unwrap();
    assert!(got["ask"].as_str().unwrap().chars().count() <= MAX_ASK);
    assert_eq!(got["actions"].as_array().unwrap().len(), MAX_ACTIONS);
    assert!(got["actions"][0].as_str().unwrap().chars().count() <= MAX_ACTION);
    assert_eq!(got["learned"][0], "Use pnpm.");
    assert!(got["learned"][1].as_str().unwrap().chars().count() <= MAX_FACT);
    assert_eq!(got["learned"].as_array().unwrap().len(), MAX_LEARNED);
    let said = notes.join("; ");
    for part in [
        "ask trimmed from",
        "3 actions given; the first 2 kept",
        "action 1 trimmed from 85 to",
        "4 learned facts given; the first 3 kept",
        "learned fact 1 cut to its first line",
        "learned fact 2 trimmed from 201 to",
    ] {
        assert!(said.contains(part), "{part}: {said}");
    }
    assert_eq!(got["trimmed"], json!(notes));
}

#[test]
fn learned_facts_are_kept_trimmed_and_left_out_when_empty() {
    let kept = shown(json!({"recap": "Done.", "learned": [" Use pnpm, not npm. "]}));
    assert_eq!(kept["learned"], json!(["Use pnpm, not npm."]));
    assert!(shown(json!({"recap": "Done.", "learned": []})).get("learned").is_none());
}

/// The schema says each bound in words and carries no maxLength or maxItems, so no harness
/// refuses a call the tool would take.
#[test]
fn the_schema_says_every_bound_and_enforces_none() {
    let tool = tool();
    let props = &tool["inputSchema"]["properties"];
    for (key, max) in
        [("recap", MAX_RECAP), ("ask", MAX_ASK), ("actions", MAX_ACTION), ("learned", MAX_FACT)]
    {
        let said = props[key]["description"].as_str().unwrap();
        assert!(said.contains(&format!("at most {max} characters")), "{key}: {said}");
        assert!(props[key].get("maxLength").is_none() && props[key].get("maxItems").is_none());
        assert!(props[key]["items"].get("maxLength").is_none(), "{key}");
    }
    let at = "x".repeat(RECAP_CEILING);
    assert_eq!(shown(json!({"recap": at}))["recap"], at);
}

/// cmuxterm-hq#18786: the refused call of 2026-11-21T15:24Z sent `summary`, not `recap`.
#[test]
fn summary_and_other_aliases_are_taken_as_their_field_and_said_so() {
    let summary = "The scheduler grant works end to end. In smoke run 44913484985, both Mac jobs ran on cmux18 under per-run labels the scheduler granted.";
    let result = call(&json!({"summary": summary}));
    assert_eq!(result["isError"], false, "{result}");
    assert_eq!(result["structuredContent"]["recap"], summary);
    assert!(result["structuredContent"].get("trimmed").is_none());
    let text = result["content"][0]["text"].as_str().unwrap();
    assert!(text.contains("summary taken as recap"), "{text}");
    assert_eq!(
        shown(
            json!({"message": "Done.", "question": "Open a PR?", "options": ["Yes", "No"], "lessons": ["Use pnpm."]})
        ),
        json!({"recap": "Done.", "ask": "Open a PR?", "actions": ["Yes", "No"], "learned": ["Use pnpm."]})
    );
    // The field itself wins over an alias sent beside it.
    assert_eq!(shown(json!({"recap": "Done.", "summary": "Other."}))["recap"], "Done.");
    assert!(check(&json!({"summary": "  "})).is_err());
}

#[test]
fn the_call_answers_with_what_it_showed() {
    let result = call(&json!({"recap": "Done.", "ask": "Open a PR?"}));
    assert_eq!(result["isError"], false);
    assert_eq!(result["structuredContent"]["ask"], "Open a PR?");
    assert!(result["content"][0]["text"].as_str().unwrap().contains("End your turn now"));
    assert_eq!(call(&json!({}))["isError"], true);
}
