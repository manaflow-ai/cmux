use super::*;

/// A `todo_write` call as DeepSeek Harness's ACP bridge sends it (`packages/acp/acp/src/updates.ts`).
fn call(id: &str, todos: Value) -> Value {
    json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": "todo_write", "kind": "other",
           "status": "in_progress", "rawInput": {"todos": todos}})
}

fn result(id: &str, status: &str) -> Value {
    json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "status": status, "content": []})
}

fn marked(update: &Value) -> bool {
    update.pointer("/_meta/acpmux/planTool") == Some(&json!(true))
}

#[test]
fn a_completed_todo_write_becomes_the_plan() {
    let mut watch = Watch::default();
    let mut start = call(
        "c1",
        json!([{"content": " Add retry ", "status": "completed"},
               {"content": "Cover it", "status": "in_progress"},
               {"content": "Update the docs", "status": "pending"}]),
    );
    assert_eq!(watch.observe(&mut start), None);
    assert!(marked(&start));
    let mut done = result("c1", "completed");
    let plan = watch.observe(&mut done).expect("a plan");
    assert!(marked(&done));
    assert_eq!(
        plan,
        json!({"sessionUpdate": "plan", "entries": [
            {"content": "Add retry", "priority": "medium", "status": "completed"},
            {"content": "Cover it", "priority": "medium", "status": "in_progress"},
            {"content": "Update the docs", "priority": "medium", "status": "pending"}]})
    );
    assert!(watch.calls.is_empty());
}

#[test]
fn an_empty_list_clears_the_plan() {
    let mut watch = Watch::default();
    watch.observe(&mut call("c1", json!([])));
    let plan = watch.observe(&mut result("c1", "completed"));
    assert_eq!(plan, Some(json!({"sessionUpdate": "plan", "entries": []})));
}

#[test]
fn a_failed_call_changes_nothing() {
    let mut watch = Watch::default();
    watch.observe(&mut call("c1", json!([{"content": "A", "status": "pending"}])));
    let mut failed = result("c1", "failed");
    assert_eq!(watch.observe(&mut failed), None);
    // Marked, so the pane shows its row again (hiddenTools.ts `isPlanToolCall`).
    assert!(marked(&failed));
    assert!(watch.calls.is_empty());
}

#[test]
fn other_tools_and_malformed_lists_pass_through() {
    let mut watch = Watch::default();
    let mut other = json!({"sessionUpdate": "tool_call", "toolCallId": "b", "title": "bash",
                           "rawInput": {"todos": []}});
    assert_eq!(watch.observe(&mut other), None);
    assert!(!marked(&other));
    for todos in [
        json!([{"content": "A", "status": "deleted"}]),
        json!([{"content": "", "status": "pending"}]),
        json!([{"text": "A", "status": "pending"}]),
        json!("not a list"),
    ] {
        let mut bad = call("c", todos);
        assert_eq!(watch.observe(&mut bad), None);
        assert!(!marked(&bad));
        assert_eq!(watch.observe(&mut result("c", "completed")), None);
    }
    assert!(watch.calls.is_empty());
}

#[test]
fn a_reused_id_is_a_new_call() {
    let mut watch = Watch::default();
    watch.observe(&mut call("c1", json!([{"content": "A", "status": "pending"}])));
    let mut reused = json!({"sessionUpdate": "tool_call", "toolCallId": "c1", "title": "bash"});
    assert_eq!(watch.observe(&mut reused), None);
    assert!(!marked(&reused));
    assert_eq!(watch.observe(&mut result("c1", "completed")), None);
}

#[test]
fn the_shared_watch_holds_a_chat_only_while_its_call_runs() {
    let session = "acp-todo-plan-test-session";
    assert_eq!(observe(session, &mut call("c1", json!([{"content": "A", "status": "pending"}]))), None);
    assert!(WATCHES.lock().unwrap().contains_key(session));
    assert!(observe(session, &mut result("c1", "completed")).is_some());
    assert!(!WATCHES.lock().unwrap().contains_key(session));
    // Another chat's result is not this chat's call.
    assert_eq!(observe("acp-todo-plan-other", &mut result("c1", "completed")), None);
}
