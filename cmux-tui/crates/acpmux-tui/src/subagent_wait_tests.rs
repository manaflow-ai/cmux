//! The working row names the turn's own running subagents and how long it has waited on them, as
//! the GUI's "Waiting on N subagents" does (cmux#48009).

use acpmux::transcript::Transcript;
use serde_json::{Value, json};

fn update(subagents: Value) -> Value {
    json!({"update": {"sessionUpdate": "tool_call_update", "toolCallId": "t"},
           "_meta": {"acpmux": {"subagents": subagents}}})
}

#[test]
fn counts_the_turns_own_running_subagents_with_the_waits_time() {
    let mut t = Transcript::default();
    assert_eq!(t.subagent_wait(1), None);
    t.apply_update(&update(json!([
        {"id": "a", "parent": null, "state": "running", "elapsedMs": 65_000},
        {"id": "b", "parent": null, "state": "running"},
        {"id": "bg", "parent": null, "state": "running", "background": true},
        {"id": "child", "parent": "a", "state": "running"}
    ])));
    let since = *t.subagents_running.values().min().unwrap();
    assert_eq!(t.subagent_wait(since + 65_000).as_deref(), Some("waiting on 2 subagents 1m 5s"));
    t.apply_update(&update(json!([{"id": "b", "parent": null, "state": "completed"}])));
    assert_eq!(t.subagent_wait(since + 500).as_deref(), Some("waiting on 1 subagent"));
    t.apply_update(&update(json!([{"id": "a", "parent": null, "state": "failed"}])));
    assert_eq!(t.subagent_wait(since + 500), None);
}

#[test]
fn a_turns_end_stops_the_wait() {
    let mut t = Transcript::default();
    t.apply_update(&update(json!([{"id": "a", "parent": null, "state": "running"}])));
    assert!(t.subagent_wait(u64::MAX).is_some());
    t.apply_event(&json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}));
    assert_eq!(t.subagent_wait(u64::MAX), None);
}
