use super::*;

fn exposed(phases: &mut MessagePhases) {
    phases
        .enrich(&json!({}), &mut vec![Out::Client(json!({"id": 1, "result": {"sessionId": "t"}}))]);
}

fn item(method: &str, thread: &str, phase: Value) -> Value {
    json!({"method": method, "params": {"threadId": thread, "item": {
        "type": "agentMessage", "id": "m", "phase": phase, "text": "The answer"
    }}})
}

#[test]
fn explicit_started_and_completed_phases_emit_no_duplicate_text() {
    let mut phases = MessagePhases::default();
    exposed(&mut phases);
    for method in ["item/started", "item/completed"] {
        for phase in ["commentary", "final_answer"] {
            let mut out = Vec::new();
            phases.enrich(&item(method, "t", json!(phase)), &mut out);
            let [Out::Client(message)] = out.as_slice() else {
                panic!("one phase update expected")
            };
            assert_eq!(message["params"]["sessionId"], "t");
            assert_eq!(message["params"]["update"]["messageId"], "m");
            assert_eq!(message["params"]["update"]["content"]["text"], "");
            assert_eq!(message["params"]["update"]["_meta"]["codex"]["phase"], phase);
        }
    }
}

#[test]
fn hidden_threads_unknown_phases_and_missing_ids_emit_nothing() {
    let mut phases = MessagePhases::default();
    exposed(&mut phases);
    let mut missing = item("item/started", "t", json!("final_answer"));
    missing["params"]["item"].as_object_mut().unwrap().remove("id");
    for raw in [
        item("item/started", "hidden", json!("final_answer")),
        item("item/started", "t", json!("future")),
        item("item/started", "t", Value::Null),
        missing,
    ] {
        let mut out = Vec::new();
        phases.enrich(&raw, &mut out);
        assert!(out.is_empty());
    }
}

#[test]
fn an_exposed_subagent_gets_its_phase_before_its_first_text_delta() {
    let mut phases = MessagePhases::default();
    exposed(&mut phases);
    let mut spawned = vec![Out::Client(json!({"method": "session/update", "params": {
        "sessionId": "t", "update": {"sessionUpdate": "subagent_spawned", "subagentSessionId": "child"}
    }}))];
    phases.enrich(&json!({}), &mut spawned);
    let mut out = Vec::new();
    phases.enrich(&item("item/started", "child", json!("final_answer")), &mut out);
    assert_eq!(out.len(), 1);
    let Out::Client(update) = &out[0] else { panic!("phase update expected") };
    assert_eq!(update["params"]["sessionId"], "child");
}

#[test]
fn history_phases_only_annotate_actual_replayed_messages_in_the_same_session() {
    let mut phases = MessagePhases::default();
    let raw = json!({"id": 2, "result": {"thread": {"id": "t", "turns": [{"items": [
        {"type": "agentMessage", "id": "m", "phase": "final_answer"},
        {"type": "agentMessage", "id": "unknown", "phase": "future"}
    ]}]}}});
    let chunk = |session: &str, id: &str| {
        Out::Client(json!({"method": "session/update", "params": {
            "sessionId": session, "update": {"sessionUpdate": "agent_message_chunk", "messageId": id,
                "content": {"type": "text", "text": "Answer"}}
        }}))
    };
    let mut out = vec![chunk("t", "m"), chunk("other", "m"), chunk("t", "unknown")];
    phases.enrich(&raw, &mut out);
    assert_eq!(out.len(), 3);
    let Out::Client(first) = &out[0] else { panic!("client chunk expected") };
    assert_eq!(first["params"]["update"]["_meta"]["codex"]["phase"], "final_answer");
    for other in &out[1..] {
        let Out::Client(other) = other else { panic!("client chunk expected") };
        assert!(other["params"]["update"].get("_meta").is_none());
    }
    let mut no_replay = Vec::new();
    phases.enrich(&raw, &mut no_replay);
    assert!(no_replay.is_empty());
}
