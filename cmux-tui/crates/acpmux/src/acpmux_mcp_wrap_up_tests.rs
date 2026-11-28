use super::*;

fn shown(args: Value) -> Value {
    check(&args).unwrap().0
}

#[test]
fn a_recap_with_an_ask_and_two_answers_is_shown() {
    let (got, notes) = check(
        &json!({"recap": " Done. ", "ask": "Open a PR?", "actions": ["Yes, open PR", "Not now"]}),
    )
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
        json!({"recap": "Done.", "learned": 3}),
        json!({"recap": "Done.", "ask": "Open?", "actions": {"a": "Yes"}}),
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
    let drawn = box_of(&json!({"recap": longer})).unwrap();
    let recap = drawn["recap"].as_str().unwrap();
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

/// https://github.com/manaflow-ai/cmux/issues/52766: an agent woken by background-command
/// notices ended seven turns on the same "Can you click the dev build tab in my right split"
/// ask. The ask's description rules out both: a request to click a tab, and asking again.
#[test]
fn the_ask_rules_out_clicking_tabs_and_asking_again() {
    let tool = tool();
    let said = tool["inputSchema"]["properties"]["ask"]["description"].as_str().unwrap();
    for phrase in ["Never ask them to click", "focus or capture it yourself", "do not ask it again"]
    {
        assert!(said.contains(phrase), "{phrase}: {said}");
    }
}

/// The census of 2026-11-23 (cmuxterm-hq docs/findings/2026-11-23-mcp-tool-error-census.md):
/// 54 wrap_up calls in 48 h on one VM sent `learned` as one string and were refused "learned
/// is a list". A string is a list of it (of its lines, or the list a JSON string spells), and
/// the result says so.
#[test]
fn a_string_where_a_list_goes_is_read_as_a_list_and_said_so() {
    let one = call(&json!({"recap": "Done.", "learned": "Use pnpm, not npm."}));
    assert_eq!(one["isError"], false, "{one}");
    assert_eq!(one["structuredContent"]["facts"], 1, "{one}");
    assert_eq!(
        shown(json!({"recap": "Done.", "learned": "Use pnpm, not npm."}))["learned"],
        json!(["Use pnpm, not npm."])
    );
    let text = one["content"][0]["text"].as_str().unwrap();
    assert!(text.contains("learned given as one string; read as a list of it"), "{text}");
    let lines = shown(json!({"recap": "Done.", "learned": "Use pnpm.\n\n  Rebase first.\n"}));
    assert_eq!(lines["learned"], json!(["Use pnpm.", "Rebase first."]));
    let spelled = shown(json!({"recap": "Done.", "learned": "[\"a\", \"b\"]"}));
    assert_eq!(spelled["learned"], json!(["a", "b"]));
    let asked = shown(json!({"recap": "Done.", "ask": "Merge?", "actions": "Yes"}));
    assert_eq!(asked["actions"], json!(["Yes"]));
    assert!(shown(json!({"recap": "Done.", "learned": "  "})).get("learned").is_none());
}

/// cmuxterm-hq#18786: the refused call of 2026-11-21T15:24Z sent `summary`, not `recap`.
#[test]
fn summary_and_other_aliases_are_taken_as_their_field_and_said_so() {
    let summary = "The scheduler grant works end to end. In smoke run 44913484985, both Mac jobs ran on cmux18 under per-run labels the scheduler granted.";
    let result = call(&json!({"summary": summary}));
    assert_eq!(result["isError"], false, "{result}");
    assert_eq!(box_of(&json!({"summary": summary})).unwrap()["recap"], summary);
    assert!(shown(json!({"summary": summary})).get("trimmed").is_none());
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

/// RFD 0087 (cmuxterm-hq#22593), measured over 2,884 wrap_up calls: 91% of the answer's bytes
/// were a copy of the call's own input. The answer says the box was drawn and with what in it,
/// and carries not one word of the recap, ask, actions or facts back to the agent; `box_of`
/// still builds the whole box for the one drawer that reads a result (`code_mode.rs`).
#[test]
fn the_answer_says_the_box_was_drawn_and_echoes_none_of_it() {
    let recap = "Landed the echo cut. The suite is green; the row on hq#15832 is not posted yet.";
    let ask = "Post the row now?";
    let args = json!({
        "recap": recap,
        "ask": ask,
        "actions": ["Yes, post it", "Not now"],
        "learned": ["A wrap-up answer echoed its own input."],
    });
    let result = call(&args);
    assert_eq!(result["isError"], false, "{result}");
    assert_eq!(
        result["structuredContent"],
        json!({"drawn": true, "question": true, "answers": 2, "facts": 1})
    );
    let answer = result.to_string();
    for echoed in [recap, ask, "Yes, post it", "A wrap-up answer echoed its own input."] {
        assert!(!answer.contains(echoed), "echoed {echoed}: {answer}");
    }
    // The cut is in the structured answer — the part a session's context keeps — and its
    // cost is now constant: a 4-field receipt that does not grow with the input. (The
    // `content` sentence is the same fixed text either way, so for a very short call the
    // whole answer can still outweigh the call; what used to scale with the input no longer
    // does.)
    let structured = result["structuredContent"].to_string();
    assert!(structured.len() < 64, "{structured}");
    let bigger = call(&json!({
        "recap": format!("{recap} {}", recap.repeat(6)),
        "ask": ask,
        "actions": ["Yes, post it", "Not now"],
        "learned": ["A wrap-up answer echoed its own input."],
    }));
    assert_eq!(
        bigger["structuredContent"].to_string(),
        structured,
        "the receipt grew with the input"
    );
    assert!(result["content"][0]["text"].as_str().unwrap().contains("End your turn now"));
    // Without an ask the answer says so, and a refusal still refuses.
    let plain = call(&json!({"recap": "Done."}));
    assert_eq!(
        plain["structuredContent"],
        json!({"drawn": true, "question": false, "answers": 0, "facts": 0})
    );
    assert_eq!(call(&json!({}))["isError"], true);
    // The box itself is whole for `code_mode.rs`, aliases and trims applied.
    assert_eq!(
        box_of(&json!({"summary": " Done. ", "question": "Open?", "options": ["Yes"]})).unwrap(),
        json!({"recap": "Done.", "ask": "Open?", "actions": ["Yes"]})
    );
    assert!(box_of(&json!({})).is_none());
}

#[test]
fn typed_actions_are_kept_checked_and_labelled() {
    let got = shown(json!({
        "recap": "Built it.",
        "ask": "Try it on?",
        "actions": [
            {"label": "Try it on", "run": {"customize": "try", "target": "pr:51234", "minutes": 15, "extra": 1}},
            "Not now",
        ],
    }));
    assert_eq!(
        got["actions"],
        json!([
            {"label": "Try it on", "run": {"customize": "try", "target": "pr:51234", "minutes": 15}},
            "Not now"
        ])
    );
    // No label: the verb's own. Keep and revert take no target.
    let got = shown(
        json!({"recap": "x", "ask": "Keep?", "actions": [{"run": {"customize": "keep"}}, {"run": {"customize": "revert"}}]}),
    );
    assert_eq!(got["actions"][0], json!({"label": "Keep", "run": {"customize": "keep"}}));
    assert_eq!(got["actions"][1]["label"], "Revert");
}

#[test]
fn a_run_outside_the_allowlist_is_dropped_and_said_so() {
    let (got, notes) = check(&json!({
        "recap": "x", "ask": "Go?",
        "actions": [{"label": "Do it", "run": {"customize": "try", "target": "--help"}}, {"run": {"customize": "apply"}}],
    }))
    .unwrap();
    assert_eq!(got["actions"], json!(["Do it"]));
    let said = notes.join("; ");
    assert!(
        said.contains("action 1 run dropped") && said.contains("action 2 has no label"),
        "{said}"
    );
}

#[test]
fn the_schema_says_what_a_typed_action_is() {
    let tool = tool();
    let items = &tool["inputSchema"]["properties"]["actions"]["items"]["anyOf"];
    assert_eq!(items[0]["type"], "string");
    assert_eq!(
        items[1]["properties"]["run"]["properties"]["customize"]["enum"],
        json!(["try", "keep", "revert"])
    );
    assert!(
        tool["inputSchema"]["properties"]["actions"]["description"]
            .as_str()
            .unwrap()
            .contains("customize")
    );
}
