//! A plan approval's Approve and auto-accept edits (`PLAN_ACCEPT_EDITS`): offered on
//! ExitPlanMode only, it allows the plan and sets Claude Code's mode to Accept edits, and the
//! status line that names the new mode moves the chat's mode.

use super::*;

fn ask(rid: &str, tool: &str, input: Value) -> Value {
    json!({"type": "control_request", "request_id": rid, "request": {
        "subtype": "can_use_tool", "tool_name": tool, "tool_use_id": format!("toolu_{rid}"),
        "input": input, "requires_user_interaction": tool == "ExitPlanMode"
    }})
}

/// The permission request the translator raised for `line`: its ACP id and params.
async fn asked(t: &Translator, line: &Value) -> (Id, Value) {
    t.inbound(line)
        .await
        .into_iter()
        .find_map(|m| match m {
            Message::Request { id, method: m, params }
                if m == method::SESSION_REQUEST_PERMISSION =>
            {
                Some((id, params.unwrap_or(Value::Null)))
            }
            _ => None,
        })
        .expect("a permission request")
}

async fn answer(t: &Translator, id: Id, option: &str) -> Value {
    let reply = Message::Response {
        id,
        result: Some(json!({"outcome": {"outcome": "selected", "optionId": option}})),
        error: None,
    };
    let Outbound::Lines(lines) = t.outbound(&reply).await else { panic!("expected lines") };
    lines.into_iter().next().expect("a control response")["response"]["response"].clone()
}

fn option_ids(params: &Value) -> Vec<String> {
    params["options"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|o| o["optionId"].as_str().map(str::to_owned))
        .collect()
}

#[tokio::test]
async fn a_plan_approval_offers_approve_and_auto_accept_edits() {
    let t = Translator::new("acp-1".into(), "plan", "haiku", "default");
    let (_, params) = asked(&t, &ask("p1", "ExitPlanMode", json!({"plan": "## Plan"}))).await;
    assert_eq!(option_ids(&params), ["allow_once", PLAN_ACCEPT_EDITS, "reject_once"]);
    let accept = &params["options"][1];
    assert_eq!(accept["kind"], "allow_once");
    assert_eq!(accept["name"], "Approve and auto-accept edits");
}

#[tokio::test]
async fn another_ask_does_not_offer_it() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let input = json!({"file_path": "/repo/a.md", "content": "a\n"});
    let (_, params) = asked(&t, &ask("w1", "Write", input)).await;
    assert!(!option_ids(&params).iter().any(|id| id == PLAN_ACCEPT_EDITS), "{params}");
}

#[tokio::test]
async fn approve_and_auto_accept_edits_allows_the_plan_and_sets_accept_edits() {
    let t = Translator::new("acp-1".into(), "plan", "haiku", "default");
    let input = json!({"plan": "## Plan"});
    let (id, _) = asked(&t, &ask("p1", "ExitPlanMode", input.clone())).await;
    let response = answer(&t, id, PLAN_ACCEPT_EDITS).await;
    assert_eq!(response["behavior"], "allow");
    assert_eq!(response["updatedInput"], input);
    assert_eq!(
        response["updatedPermissions"],
        json!([{"type": "setMode", "mode": "acceptEdits", "destination": "session"}])
    );
}

#[tokio::test]
async fn approve_plan_alone_leaves_the_mode_to_claude_code() {
    let t = Translator::new("acp-1".into(), "plan", "haiku", "default");
    let (id, _) = asked(&t, &ask("p1", "ExitPlanMode", json!({"plan": "## Plan"}))).await;
    let response = answer(&t, id, "allow_once").await;
    assert_eq!(response["behavior"], "allow");
    assert!(response.get("updatedPermissions").is_none(), "{response}");
}

/// Only an ask that offered it may take it: the same option id on any other ask denies.
#[tokio::test]
async fn the_option_on_another_ask_denies() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let input = json!({"file_path": "/repo/a.md", "content": "a\n"});
    let (id, _) = asked(&t, &ask("w1", "Write", input)).await;
    let response = answer(&t, id, PLAN_ACCEPT_EDITS).await;
    assert_eq!(response["behavior"], "deny");
    assert!(response.get("updatedPermissions").is_none(), "{response}");
}

/// A withdrawn plan approval forgets it offered the option.
#[tokio::test]
async fn a_withdrawn_plan_approval_forgets_the_option() {
    let t = Translator::new("acp-1".into(), "plan", "haiku", "default");
    let (_, _) = asked(&t, &ask("p1", "ExitPlanMode", json!({"plan": "## Plan"}))).await;
    t.inbound(&json!({"type": "control_cancel_request", "request_id": "p1"})).await;
    assert!(t.plan_asks.lock().await.is_empty());
}

fn status(mode: &str) -> Value {
    json!({"type": "system", "subtype": "status", "status": null, "permissionMode": mode, "session_id": "c1"})
}

fn mode_updates(out: &[Message]) -> Vec<String> {
    out.iter()
        .filter_map(|m| match m {
            Message::Notification { params, .. } => params
                .as_ref()
                .and_then(|p| p.pointer("/update"))
                .filter(|u| u["sessionUpdate"] == "current_mode_update")
                .and_then(|u| u["currentModeId"].as_str().map(str::to_owned)),
            _ => None,
        })
        .collect()
}

/// The `mode` config option a `config_option_update` carries, if any.
fn mode_options(out: &[Message]) -> Vec<String> {
    out.iter()
        .filter_map(|m| match m {
            Message::Notification { params, .. } => params
                .as_ref()
                .and_then(|p| p.pointer("/update"))
                .filter(|u| u["sessionUpdate"] == "config_option_update")
                .and_then(|u| u["configOptions"].as_array())
                .and_then(|o| o.iter().find(|o| o["id"] == "mode"))
                .and_then(|o| o["currentValue"].as_str().map(str::to_owned)),
            _ => None,
        })
        .collect()
}

#[tokio::test]
async fn a_status_line_naming_a_new_mode_moves_the_chats_mode_once() {
    let t = Translator::new("acp-1".into(), "plan", "haiku", "default");
    let out = t.inbound(&status("acceptEdits")).await;
    assert_eq!(mode_updates(&out), ["acceptEdits"]);
    // The `mode` option moves with it, so a restore that replays options keeps Accept edits.
    assert_eq!(mode_options(&out), ["acceptEdits"]);
    assert_eq!(*t.mode.lock().await, "acceptEdits");
    // The same mode again says nothing new.
    let again = t.inbound(&status("acceptEdits")).await;
    assert!(mode_updates(&again).is_empty() && mode_options(&again).is_empty());
}
