use super::*;
use std::collections::VecDeque;

/// Answers each read with the next scripted result (the last one repeats)
/// and records what it was asked.
struct Script {
    results: VecDeque<Result<Value, String>>,
    asked: Vec<Value>,
    abandoned: bool,
    hang: bool,
}

impl Script {
    fn new(results: Vec<Result<Value, String>>) -> Script {
        Script { results: results.into(), asked: Vec::new(), abandoned: false, hang: false }
    }
}

impl TreeReader for Script {
    async fn read(&mut self, arguments: Value) -> Result<Value, String> {
        self.asked.push(arguments);
        if self.hang {
            std::future::pending::<()>().await;
        }
        if self.results.len() > 1 {
            self.results.pop_front().unwrap()
        } else {
            self.results.front().cloned().unwrap()
        }
    }

    fn abandon(&mut self) {
        self.abandoned = true;
    }
}

/// A `get_window_state` result with these elements.
fn state(elements: Value) -> Result<Value, String> {
    Ok(json!({
        "content": [{"type": "text", "text": "window_id=4 pid=123"}],
        "structuredContent": {"pid": 123, "window_id": 4, "elements": elements},
    }))
}

fn save_button() -> Value {
    json!({"element_index": 7, "element_token": "s00000003:7", "role": "AXButton", "label": "Save", "depth": 2})
}

fn wait(arguments: Value) -> Wait {
    Wait::parse(&arguments).unwrap()
}

#[tokio::test(start_paused = true)]
async fn waits_until_the_element_appears_and_returns_it_from_the_newest_snapshot() {
    let mut reader =
        Script::new(vec![state(json!([])), state(json!([])), state(json!([save_button()]))]);
    let started = Instant::now();
    let result =
        run(&wait(json!({"pid": 123, "window_id": 4, "query": "Save"})), &mut reader).await;
    let structured = &result["structuredContent"];
    assert_eq!(result.get("isError"), None, "{result}");
    assert_eq!(structured["timed_out"], false);
    assert_eq!(structured["count"], 1);
    assert_eq!(structured["checks"], 3);
    assert_eq!(structured["elements"], json!([save_button()]));
    assert_eq!(structured["window_id"], 4);
    // Two pauses of the default interval, nothing more.
    assert_eq!(started.elapsed(), Duration::from_millis(2 * DEFAULT_INTERVAL_MS));
    assert!(result["content"][0]["text"].as_str().unwrap().contains("element_token=s00000003:7"));
    // AX tree only: every check skips the screenshot and passes the query on.
    for asked in &reader.asked {
        assert_eq!(
            asked,
            &json!({"pid": 123, "window_id": 4, "query": "Save", "include_screenshot": false})
        );
    }
}

#[tokio::test(start_paused = true)]
async fn a_wait_that_runs_out_says_timed_out_with_the_last_count() {
    let mut reader = Script::new(vec![state(json!([]))]);
    let started = Instant::now();
    let result = run(
        &wait(json!({"pid": 123, "window_id": 4, "query": "Save", "timeout_ms": 1000})),
        &mut reader,
    )
    .await;
    let structured = &result["structuredContent"];
    assert_eq!(result["isError"], true);
    assert_eq!(structured["timed_out"], true);
    assert_eq!(structured["count"], 0);
    assert_eq!(structured["timeout_ms"], 1000);
    // Checks at 0, 200, ... 1000 ms: the last one is at the deadline.
    assert_eq!(structured["checks"], 6);
    assert_eq!(started.elapsed(), Duration::from_millis(1000));
    let text = result["content"][0]["text"].as_str().unwrap();
    assert!(text.starts_with("timed_out:"), "{text}");
    assert!(text.contains("Next: get_window_state"), "{text}");
    assert_eq!(structured["last_check_unanswered"], false);
}

#[tokio::test(start_paused = true)]
async fn gone_waits_until_nothing_matches() {
    let mut reader = Script::new(vec![
        state(json!([save_button()])),
        state(json!([save_button()])),
        state(json!([])),
    ]);
    let result =
        run(&wait(json!({"pid": 123, "window_id": 4, "query": "Save", "gone": true})), &mut reader)
            .await;
    let structured = &result["structuredContent"];
    assert_eq!(structured["timed_out"], false);
    assert_eq!(structured["gone"], true);
    assert_eq!(structured["count"], 0);
    assert_eq!(structured["checks"], 3);
}

#[tokio::test(start_paused = true)]
async fn gone_that_runs_out_lists_what_is_still_there() {
    let mut reader = Script::new(vec![state(json!([save_button()]))]);
    let result = run(
        &wait(
            json!({"pid": 123, "window_id": 4, "role": "button", "gone": true, "timeout_ms": 300}),
        ),
        &mut reader,
    )
    .await;
    assert_eq!(result["structuredContent"]["timed_out"], true);
    assert_eq!(result["structuredContent"]["count"], 1);
    assert_eq!(result["structuredContent"]["elements"], json!([save_button()]));
}

#[tokio::test(start_paused = true)]
async fn a_failed_read_ends_the_wait_at_once_with_its_text() {
    let mut reader = Script::new(vec![Ok(json!({
        "content": [{"type": "text", "text": "window 4 not found; call list_windows"}],
        "isError": true,
    }))]);
    let result =
        run(&wait(json!({"pid": 123, "window_id": 4, "query": "Save"})), &mut reader).await;
    assert_eq!(result["isError"], true);
    assert_eq!(result["structuredContent"]["timed_out"], false);
    assert_eq!(result["structuredContent"]["checks"], 1);
    assert!(result["content"][0]["text"].as_str().unwrap().contains("call list_windows"));

    let mut refused = Script::new(vec![Err("consent_required".to_owned())]);
    let result =
        run(&wait(json!({"pid": 123, "window_id": 4, "query": "Save"})), &mut refused).await;
    assert_eq!(result["isError"], true);
    assert!(result["content"][0]["text"].as_str().unwrap().ends_with("consent_required"));
}

#[tokio::test(start_paused = true)]
async fn a_read_that_never_answers_still_ends_and_drops_the_connection() {
    let mut reader = Script::new(vec![state(json!([]))]);
    reader.hang = true;
    let started = Instant::now();
    let result = run(
        &wait(json!({"pid": 123, "window_id": 4, "query": "Save", "timeout_ms": 1000})),
        &mut reader,
    )
    .await;
    assert_eq!(result["structuredContent"]["timed_out"], true);
    assert_eq!(result["structuredContent"]["checks"], 0);
    assert_eq!(result["structuredContent"]["last_check_unanswered"], true);
    assert!(reader.abandoned);
    assert_eq!(started.elapsed(), CHECK_GRACE);
}

#[test]
fn ancestors_the_query_kept_are_not_matches() {
    // get_window_state's query keeps the matching row and its ancestors.
    let projected = json!({"elements": [
        {"element_index": 0, "role": "AXWindow", "label": "Untitled", "depth": 0},
        {"element_index": 3, "role": "AXGroup", "identifier": "save-row", "depth": 1},
        save_button(),
        {"element_index": 9, "role": "AXGroup", "label": "Save options", "depth": 1},
        {"element_index": 10, "role": "AXCheckBox", "label": "Save a copy", "depth": 2},
    ]});
    let indices = |found: Vec<Value>| -> Vec<u64> {
        found.iter().map(|e| e["element_index"].as_u64().unwrap()).collect()
    };
    assert_eq!(indices(matching(&projected, Some("save"), None, true)), vec![7, 9, 10]);
    assert_eq!(indices(matching(&projected, Some("save"), Some("button"), true)), vec![7]);
    assert_eq!(indices(matching(&projected, Some("save"), Some("AXCheckBox"), true)), vec![10]);
    // Without a query the tree is whole: role alone picks.
    assert_eq!(indices(matching(&projected, None, Some("group"), true)), vec![3, 9]);
    assert!(matching(&json!({}), Some("save"), None, true).is_empty());
}

#[test]
fn arguments_are_checked_and_bounded() {
    let parsed = wait(json!({"pid": 1, "window_id": 2, "role": "button", "timeout_ms": 600_000,
        "interval_ms": 5, "max_depth": 80, "ignored": true}));
    assert_eq!(parsed.timeout, Duration::from_millis(MAX_TIMEOUT_MS));
    assert_eq!(parsed.interval, Duration::from_millis(MIN_INTERVAL_MS));
    assert_eq!(
        parsed.read_arguments(),
        &json!({"pid": 1, "window_id": 2, "max_depth": 80, "include_screenshot": false})
    );
    assert_eq!(
        wait(json!({"pid": 1, "window_id": 2, "query": "x"})).timeout,
        Duration::from_millis(DEFAULT_TIMEOUT_MS)
    );
    for (arguments, says) in [
        (json!({"window_id": 2, "query": "x"}), "needs pid"),
        (json!({"pid": 1, "query": "x"}), "needs window_id"),
        (json!({"pid": 1, "window_id": 2}), "needs query, role or both"),
        (json!({"pid": 1, "window_id": 2, "query": " "}), "needs query, role or both"),
        (json!({"pid": 1, "window_id": 2, "query": "x", "timeout_ms": -1}), "timeout_ms"),
        (json!({"pid": 1, "window_id": 2, "query": "x", "gone": "yes"}), "gone"),
        (json!({"pid": 1, "window_id": 2, "query": "x", "actionable": 1}), "actionable"),
        (json!([]), "takes an object"),
    ] {
        let error = Wait::parse(&arguments).unwrap_err();
        assert!(error.starts_with("invalid_arguments: wait_for_element"), "{error}");
        assert!(error.contains(says), "{arguments}: {error}");
    }
}

#[test]
fn the_tool_is_listed_only_beside_get_window_state() {
    let listed =
        with_definition(json!({"tools": [{"name": "get_window_state"}, {"name": "click"}]}));
    let names: Vec<&str> =
        listed["tools"].as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["get_window_state", "click", TOOL]);
    assert_eq!(listed["tools"][2]["annotations"]["readOnlyHint"], true);
    // Listing twice adds nothing.
    assert_eq!(with_definition(listed.clone()), listed);
    let without = json!({"tools": [{"name": "click"}]});
    assert_eq!(with_definition(without.clone()), without);
}

#[test]
fn a_helper_tool_of_the_same_name_is_replaced_by_the_one_that_runs() {
    // The bridge answers every call of this name, so the helper's own
    // definition (its schema could differ) must not be what is listed.
    let helper_own =
        json!({"name": TOOL, "inputSchema": {"type": "object", "required": ["selector"]}});
    let listed = with_definition(
        json!({"tools": [{"name": "get_window_state"}, helper_own.clone(), {"name": "click"}]}),
    );
    assert_eq!(
        listed["tools"],
        json!([{"name": "get_window_state"}, {"name": "click"}, definition()])
    );
    // Without get_window_state the bridge cannot serve it: nothing of this name is listed.
    let alone = with_definition(json!({"tools": [helper_own, {"name": "click"}]}));
    assert_eq!(alone["tools"], json!([{"name": "click"}]));
}

/// A `get_window_state` result whose structured side carries these extra fields.
fn state_with(elements: Value, extra: Value) -> Result<Value, String> {
    let mut structured = json!({"pid": 123, "window_id": 4, "elements": elements});
    if let (Some(into), Some(from)) = (structured.as_object_mut(), extra.as_object()) {
        into.extend(from.clone());
    }
    Ok(
        json!({"content": [{"type": "text", "text": "window_id=4 pid=123"}], "structuredContent": structured}),
    )
}

#[tokio::test(start_paused = true)]
async fn gone_in_a_bounded_tree_reads_the_whole_tree_before_saying_gone() {
    // max_elements cut the walk before the Save button: the first check sees
    // no match, but the button is still there in the whole tree.
    let mut reader =
        Script::new(vec![state(json!([])), state(json!([save_button()])), state(json!([]))]);
    let result = run(
        &wait(json!({"pid": 123, "window_id": 4, "query": "Save", "gone": true,
            "max_elements": 5, "max_depth": 3})),
        &mut reader,
    )
    .await;
    let structured = &result["structuredContent"];
    assert_eq!(result.get("isError"), None, "{result}");
    assert_eq!(structured["gone"], true);
    assert_eq!(structured["checks"], 3, "{result}");
    assert_eq!(structured["widened"], true);
    assert_eq!(reader.asked[0]["max_elements"], 5);
    // Every check after the first reads the whole tree.
    for asked in reader.asked.iter().skip(1) {
        assert_eq!(
            asked,
            &json!({"pid": 123, "window_id": 4, "query": "Save", "include_screenshot": false})
        );
    }
}

#[tokio::test(start_paused = true)]
async fn gone_trusts_a_bounded_tree_the_helper_says_is_whole() {
    let mut reader = Script::new(vec![state_with(json!([]), json!({"truncated": false}))]);
    let result = run(
        &wait(
            json!({"pid": 123, "window_id": 4, "query": "Save", "gone": true, "max_elements": 5}),
        ),
        &mut reader,
    )
    .await;
    assert_eq!(result.get("isError"), None, "{result}");
    assert_eq!(result["structuredContent"]["checks"], 1);
    assert_eq!(result["structuredContent"]["widened"], false);
}

#[tokio::test(start_paused = true)]
async fn a_truncated_tree_never_counts_as_gone() {
    let mut reader = Script::new(vec![state_with(
        json!([]),
        json!({"truncated": true, "truncation_reason": "max_elements"}),
    )]);
    let result = run(
        &wait(
            json!({"pid": 123, "window_id": 4, "query": "Save", "gone": true, "timeout_ms": 400}),
        ),
        &mut reader,
    )
    .await;
    let structured = &result["structuredContent"];
    assert_eq!(result["isError"], true, "{result}");
    assert_eq!(structured["timed_out"], true);
    assert_eq!(structured["gone_unconfirmed"], true);
    assert_eq!(structured["count"], 0);
    let text = result["content"][0]["text"].as_str().unwrap();
    assert!(text.contains("gone is not confirmed"), "{text}");
}

#[tokio::test(start_paused = true)]
async fn a_wait_to_appear_matches_only_rows_an_agent_can_act_on() {
    // A role-only wait: a display-only row and a disabled button are not
    // what the agent is waiting to click.
    let display_only =
        json!({"role": "AXButton", "label": "Save", "depth": 2, "display_only": true});
    let disabled = json!({"element_index": 7, "element_token": "s00000002:7", "role": "AXButton",
        "label": "Save", "depth": 2, "enabled": false});
    let mut reader = Script::new(vec![
        state(json!([display_only.clone()])),
        state(json!([disabled.clone()])),
        state(json!([save_button()])),
    ]);
    let result =
        run(&wait(json!({"pid": 123, "window_id": 4, "role": "button"})), &mut reader).await;
    let structured = &result["structuredContent"];
    assert_eq!(result.get("isError"), None, "{result}");
    assert_eq!(structured["checks"], 3, "{result}");
    assert_eq!(structured["elements"], json!([save_button()]));

    // actionable: false waits for any row of that role.
    let mut any = Script::new(vec![state(json!([display_only.clone()]))]);
    let result = run(
        &wait(json!({"pid": 123, "window_id": 4, "role": "button", "actionable": false})),
        &mut any,
    )
    .await;
    assert_eq!(result["structuredContent"]["checks"], 1, "{result}");

    // A gone wait counts any row by default: a disabled button is still there.
    let mut still = Script::new(vec![state(json!([disabled]))]);
    let result = run(
        &wait(json!({"pid": 123, "window_id": 4, "role": "button", "gone": true, "timeout_ms": 0})),
        &mut still,
    )
    .await;
    assert_eq!(result["structuredContent"]["timed_out"], true, "{result}");
}
