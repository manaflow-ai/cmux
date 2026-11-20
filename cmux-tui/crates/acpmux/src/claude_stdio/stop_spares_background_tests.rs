//! Stop interrupts only the turn: Claude Code's background shells and background subagents run
//! on (Leo, 2026-10-31: "WELL THAT STOP BUTTON STOPPED LITERALLY EVERYTHING").

use super::*;

/// The `initialize` acpmux sends Claude Code declares that it stops background tasks one by
/// one. Without `perTaskStopAffordance`, Claude Code's headless `interrupt` kills every running
/// background task and marks each subagent stopped by the user, never to be resumed.
#[tokio::test]
async fn initialize_declares_per_task_stop_so_an_interrupt_spares_background_tasks() {
    let t = Translator::new("acp-1".into(), "default", "sonnet", "default");
    let req = Message::request(1, method::INITIALIZE, json!({"protocolVersion": 1}));
    let Outbound::Lines(lines) = t.outbound(&req).await else {
        panic!("initialize answered at once")
    };
    let init = lines
        .iter()
        .find(|l| l.pointer("/request/subtype") == Some(&json!("initialize")))
        .expect("an initialize control request");
    assert_eq!(init["type"], "control_request", "{init}");
    assert_eq!(init["request"]["perTaskStopAffordance"], true, "{init}");
}

/// Stop (`session/cancel`) becomes Claude Code's `interrupt` and nothing else: no
/// `stop_task` for a background shell or subagent, and no `end_session`.
#[tokio::test]
async fn a_cancel_beside_background_work_is_one_interrupt_and_nothing_else() {
    let t = Translator::new("acp-1".into(), "default", "sonnet", "default");
    t.in_turn.store(true, Ordering::SeqCst);
    // A background subagent is running.
    t.background_subagents.lock().await.insert("toolu_agent".into());
    let cancel = Message::notification(method::SESSION_CANCEL, json!({"sessionId": "acp-1"}));
    let Outbound::Lines(lines) = t.outbound(&cancel).await else { panic!("expected lines") };
    let subtypes: Vec<&str> = lines
        .iter()
        .filter_map(|l| l.pointer("/request/subtype").and_then(Value::as_str))
        .collect();
    assert_eq!(subtypes, ["interrupt"], "{lines:?}");
    // The stopped turn's result leaves the background subagent running.
    t.subagents.lock().await.insert("toolu_agent".into(), "child-bg".into());
    let msgs = t
        .inbound(&json!({"type": "result", "subtype": "error_during_execution", "result": null}))
        .await;
    let cancelled_children: Vec<&Value> = msgs
        .iter()
        .filter_map(|m| match m {
            Message::Notification { params: Some(p), .. }
                if p.pointer("/update/sessionUpdate") == Some(&json!("subagent_state_update")) =>
            {
                Some(&p["update"]["subagentSessionId"])
            }
            _ => None,
        })
        .collect();
    assert!(
        cancelled_children.is_empty(),
        "a background subagent was ended: {cancelled_children:?}"
    );
    assert!(
        t.subagents.lock().await.contains_key("toolu_agent"),
        "the background subagent is forgotten"
    );
}
