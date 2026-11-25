//! ACP `initialize` is answered as it is written to Claude Code, never after Claude Code boots
//! (`outbound.rs`): every start's `session/new` waited out that boot (0.7 to 6.5 s; a production
//! Cloud start never took less than 533 ms).

use super::*;

#[tokio::test]
async fn initialize_is_answered_at_once_and_claude_code_still_asked() {
    let t = Translator::new("acp-1".into(), "default", "opus", "default");
    let out = t.outbound(&Message::request(7, method::INITIALIZE, json!({}))).await;
    let Outbound::LinesThenReply(
        lines,
        Message::Response { id, result: Some(answer), error: None },
    ) = out
    else {
        panic!("initialize answers at once");
    };
    assert_eq!(id, json!(7));
    assert_eq!(lines[0]["request_id"], "init-7", "{lines:?}");
    assert_eq!(lines[0]["request"]["subtype"], "initialize", "{lines:?}");
    assert!(steers_by_info(answer.get("agentInfo")), "{answer}");
    assert_eq!(answer["agentCapabilities"]["loadSession"], true, "{answer}");
    assert_eq!(answer["_meta"]["steering"]["supported"], true, "{answer}");
}

#[tokio::test]
async fn claude_codes_late_answer_brings_its_commands_and_no_second_answer() {
    let t = Translator::new("acp-1".into(), "default", "opus", "default");
    let _ = t.outbound(&Message::request(7, method::INITIALIZE, json!({}))).await;
    let out = t
        .inbound(&json!({"type": "control_response", "response": {"subtype": "success",
            "request_id": "init-7", "response": {"version": "2.1.319",
            "commands": [{"name": "review", "description": "Review a PR", "argumentHint": ""}]}}}))
        .await;
    assert!(!out.iter().any(|m| matches!(m, Message::Response { .. })), "{out:?}");
    assert_eq!(t.slash_commands.lock().await.len(), 1);
    // A failed answer answers nothing either: the hub's `initialize` was answered.
    let failed = t
        .inbound(&json!({"type": "control_response", "response": {"subtype": "error",
            "request_id": "init-8", "error": "boom"}}))
        .await;
    assert!(failed.is_empty(), "{failed:?}");
}

/// The `availableCommands` of the last commands update in `out`, as (name, tagged a skill).
fn commands_sent(out: &[Message]) -> Vec<(String, bool)> {
    let update = out
        .iter()
        .rev()
        .find_map(|m| match m {
            Message::Notification { params: Some(p), .. } => {
                let update = p.get("update")?;
                (update["sessionUpdate"] == "available_commands_update").then(|| update.clone())
            }
            _ => None,
        })
        .expect("a commands update");
    update["availableCommands"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| (c["name"].as_str().unwrap().to_owned(), c["_meta"]["kind"] == "skill"))
        .collect()
}

#[tokio::test]
async fn before_the_first_turn_every_command_not_builtin_is_a_skill_then_the_init_decides() {
    let t = Translator::new("acp-1".into(), "default", "opus", "default");
    let _ = t.outbound(&Message::request(7, method::INITIALIZE, json!({}))).await;
    // Claude Code's real answer marks its own commands, bundled skills too, `builtin`; the person's,
    // a project's and a plugin's skills carry no mark. A chat with no turn has no system/init yet
    // (the New Tab's deferred chat), so its skills are tagged from this answer: the menu lists them
    // mid-prompt.
    let out = t
        .inbound(&json!({"type": "control_response", "response": {"subtype": "success",
            "request_id": "init-7", "response": {"commands": [
                {"name": "compact", "description": "Free up context", "argumentHint": "", "builtin": true},
                {"name": "dataviz", "description": "Charts", "argumentHint": "", "builtin": true},
                {"name": "emil-color", "description": "OKLCH (user)", "argumentHint": ""},
                {"name": "vercel:deploy", "description": "Deploy", "argumentHint": ""}]}}}))
        .await;
    assert_eq!(
        commands_sent(&out),
        [
            ("compact".to_owned(), false),
            ("dataviz".to_owned(), false),
            ("emil-color".to_owned(), true),
            ("vercel:deploy".to_owned(), true)
        ]
    );
    // The first turn's system/init names the skills: that list decides from then on.
    let out = t
        .inbound(&json!({"type": "system", "subtype": "init", "session_id": "claude-1",
            "skills": ["dataviz", "emil-color", "vercel:deploy"]}))
        .await;
    assert_eq!(
        commands_sent(&out),
        [
            ("compact".to_owned(), false),
            ("dataviz".to_owned(), true),
            ("emil-color".to_owned(), true),
            ("vercel:deploy".to_owned(), true)
        ]
    );
    // A turn that names no skills leaves none tagged.
    let out = t
        .inbound(
            &json!({"type": "system", "subtype": "init", "session_id": "claude-1", "skills": []}),
        )
        .await;
    assert!(commands_sent(&out).iter().all(|(_, skill)| !skill), "{out:?}");
}
