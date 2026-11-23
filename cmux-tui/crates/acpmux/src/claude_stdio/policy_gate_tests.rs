//! Claude Code's PreToolUse policy gate (`policy_gate.rs`): a tool call that can act outside
//! Claude Code asks the hub, and the hub's answer becomes the hook's (W5-L: under deny-all and
//! review a `claude-sr2` chat in `auto` ran a `touch` and a Write with no prompt and no deny).

use super::*;

fn hook(rid: &str, tool: &str, input: Value) -> Value {
    json!({"type": "control_request", "request_id": rid, "request": {
        "subtype": "hook_callback", "callback_id": policy_gate::GATE_CALLBACK, "tool_use_id": "toolu_1",
        "input": {"session_id": "s", "cwd": "/work", "hook_event_name": "PreToolUse",
                  "tool_name": tool, "tool_input": input, "tool_use_id": "toolu_1"}}})
}

/// The request the hook sent the hub, and its id.
async fn asked(t: &Translator, line: &Value) -> Option<(Id, Value)> {
    t.inbound(line).await.into_iter().find_map(|m| match m {
        Message::Request { id, method: m, params: Some(p) } if m == TOOL_GATE => Some((id, p)),
        _ => None,
    })
}

/// The line Claude Code reads for the hub's `answer` to request `id`.
async fn answered(t: &Translator, id: Id, answer: Result<Value, RpcError>) -> Vec<Value> {
    let msg = match answer {
        Ok(result) => Message::ok(id, result),
        Err(e) => Message::err(id, e),
    };
    match t.outbound(&msg).await {
        Outbound::Lines(lines) => lines,
        _ => panic!("expected lines for Claude Code"),
    }
}

fn decision(line: &Value) -> Option<&str> {
    line.pointer("/response/response/hookSpecificOutput/permissionDecision").and_then(Value::as_str)
}

/// The backend says it has the gate, so the hub knows the policy holds (`has_tool_gate`).
#[tokio::test]
async fn the_backend_reports_its_gate_in_its_agent_info() {
    let t = Translator::new("acp-1".into(), "auto", "haiku", "default");
    let out = t
        .inbound(&json!({"type": "control_response", "response": {"subtype": "success",
            "request_id": "init-1", "response": {"commands": [], "version": "2.1.319"}}}))
        .await;
    let info = out
        .iter()
        .find_map(|m| match m {
            Message::Response { result: Some(r), .. } => r.get("agentInfo").cloned(),
            _ => None,
        })
        .expect("the initialize answer");
    assert_eq!(has_tool_gate(Some(&info)), cfg!(unix), "{info}");
    assert!(!has_tool_gate(Some(&json!({"name": AGENT_NAME, "title": "Claude Code"}))));
}

#[tokio::test]
async fn the_gate_asks_the_hub_and_obeys_its_answer() {
    let t = Translator::new("acp-1".into(), "auto", "haiku", "default");
    let (id, params) =
        asked(&t, &hook("w1", "Write", json!({"file_path": "/work/a", "content": "x"})))
            .await
            .expect("a Write asks the hub");
    assert!(t.take_stdin_replies().await.is_empty(), "nothing for Claude Code before the answer");
    assert_eq!(params["toolCall"]["kind"], "edit", "{params}");
    assert_eq!(params["toolCall"]["_meta"]["claude"]["tool"], "Write", "{params}");
    assert_eq!(params["sessionId"], "acp-1", "{params}");
    let lines =
        answered(&t, id, Ok(json!({"decision": "deny", "reason": "review refuses it"}))).await;
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert_eq!(lines[0]["response"]["request_id"], "w1");
    assert_eq!(decision(&lines[0]), Some("deny"));
    assert_eq!(
        lines[0].pointer("/response/response/hookSpecificOutput/permissionDecisionReason"),
        Some(&json!("review refuses it"))
    );
    for (rid, answer, want) in [
        ("b1", json!({"decision": "allow"}), Some("allow")),
        ("b2", json!({"decision": "ask"}), Some("ask")),
        ("b3", json!({"decision": "none"}), None),
        ("b4", json!({"decision": "maybe"}), Some("deny")),
        ("b5", json!({}), Some("deny")),
    ] {
        let (id, _) =
            asked(&t, &hook(rid, "Bash", json!({"command": "git status"}))).await.unwrap();
        let lines = answered(&t, id, Ok(answer.clone())).await;
        assert_eq!(lines[0]["response"]["request_id"], rid, "{answer}");
        assert_eq!(decision(&lines[0]), want, "{answer}");
        if want.is_none() {
            assert_eq!(lines[0]["response"]["response"], json!({}), "{answer}");
        }
    }
    // A hub that fails the request: denied, never run unchecked.
    let (id, _) = asked(&t, &hook("e1", "Bash", json!({"command": "touch x"}))).await.unwrap();
    let lines = answered(&t, id, Err(RpcError::internal("gone"))).await;
    assert_eq!(decision(&lines[0]), Some("deny"));
}

/// A tool that acts on nothing outside Claude Code (its task list) is never sent to the hub; a
/// skill or a slash command, whose text can run shell commands, is.
#[tokio::test]
async fn claude_codes_own_tools_pass_the_gate_without_asking() {
    let t = Translator::new("acp-1".into(), "auto", "haiku", "default");
    assert!(asked(&t, &hook("t1", "TodoWrite", json!({"todos": []}))).await.is_none());
    assert_eq!(t.take_stdin_replies().await, vec![policy_gate::hook_reply("t1", json!({}))]);
    for tool in ["Skill", "SlashCommand"] {
        assert!(asked(&t, &hook("s1", tool, json!({"skill": "x"}))).await.is_some(), "{tool}");
    }
    assert!(t.take_stdin_replies().await.is_empty());
}

/// Claude Code stopped waiting (the turn was stopped): the late answer writes nothing.
#[tokio::test]
async fn a_withdrawn_gate_hook_drops_its_late_answer() {
    let t = Translator::new("acp-1".into(), "auto", "haiku", "default");
    let (id, _) = asked(&t, &hook("c1", "Bash", json!({"command": "touch x"}))).await.unwrap();
    let out = t.inbound(&json!({"type": "control_cancel_request", "request_id": "c1"})).await;
    assert!(out.is_empty(), "the hub is not told: {out:?}");
    assert!(answered(&t, id, Ok(json!({"decision": "allow"}))).await.is_empty());
}

/// Registered at initialize for every tool, apart from the repository sync, with a failure that
/// blocks the call.
#[cfg(unix)]
#[test]
fn the_gate_is_registered_for_every_tool_and_fails_closed() {
    let request = outbound::initialize_request(false);
    let gate = request["hooks"]["PreToolUse"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["hookCallbackIds"][0] == policy_gate::GATE_CALLBACK)
        .cloned()
        .expect("the gate's matcher");
    assert_eq!(gate["matcher"], "*");
    assert_eq!(gate["onFailure"], "block");
    assert_eq!(gate["timeout"], policy_gate::GATE_TIMEOUT_S);
}
