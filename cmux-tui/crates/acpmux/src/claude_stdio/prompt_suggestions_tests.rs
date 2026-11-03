//! Claude Code's prompt suggestions (`prompt_suggestions.rs`). Lines as Claude Code 2.1.310
//! writes them: `{"type": "prompt_suggestion", "suggestion", "uuid", "session_id"}` after a
//! turn's result, from the second turn on.

use super::*;

fn suggestion_line(text: Value) -> Value {
    json!({"type": "prompt_suggestion", "suggestion": text, "uuid": "u-1", "session_id": "claude-1"})
}

fn updates(msgs: &[Message]) -> Vec<Value> {
    msgs.iter()
        .filter_map(|m| match m {
            Message::Notification { params, .. } => params.as_ref()?.get("update").cloned(),
            _ => None,
        })
        .filter(|u| u["sessionUpdate"] == "prompt_suggestion")
        .collect()
}

fn offered(chat_on: bool) -> Arc<Translator> {
    let t = Translator::new("acp-1".into(), "default", "sonnet", "default");
    t.prompt_suggestions.store(chat_on, Ordering::SeqCst);
    let pause = t.suggestion_init(&json!(1), true);
    assert_eq!(pause.is_some(), !chat_on, "{pause:?}");
    t
}

#[test]
fn initialize_asks_for_suggestions_only_when_the_setting_is_on() {
    assert_eq!(outbound::initialize_request(true)["promptSuggestions"], true);
    assert!(outbound::initialize_request(false).get("promptSuggestions").is_none());
}

#[tokio::test]
async fn a_suggestion_after_the_turn_is_a_prompt_suggestion_update() {
    let t = offered(true);
    let out = t.inbound(&suggestion_line(json!("  show me a working version "))).await;
    assert_eq!(
        updates(&out),
        [json!({"sessionUpdate": "prompt_suggestion", "suggestion": "show me a working version"})]
    );
}

/// The line is internal in Claude Code's schema: a changed or missing field drops it, and the
/// line never fails or ends anything.
#[tokio::test]
async fn a_suggestion_line_without_a_usable_text_is_dropped() {
    let t = offered(true);
    for bad in [
        json!(null),
        json!(""),
        json!("   "),
        json!(42),
        json!({"text": "x"}),
        json!("x".repeat(2_001)),
    ] {
        let out = t.inbound(&suggestion_line(bad.clone())).await;
        assert!(out.is_empty(), "{bad}: {out:?}");
    }
    let out = t.inbound(&json!({"type": "prompt_suggestion"})).await;
    assert!(out.is_empty(), "{out:?}");
    // A subagent's line is not the chat's next prompt.
    let mut line = suggestion_line(json!("go on"));
    line["parent_tool_use_id"] = json!("toolu_1");
    assert!(updates(&t.inbound(&line).await).is_empty());
}

#[tokio::test]
async fn suggestions_are_dropped_when_the_setting_or_the_chat_has_them_off() {
    // The setting off: never asked for, so whatever comes is dropped and the chat has no option.
    let t = Translator::new("acp-1".into(), "default", "sonnet", "default");
    assert!(t.suggestion_init(&json!(1), false).is_none());
    assert!(t.inbound(&suggestion_line(json!("go on"))).await.is_empty());
    let options = t.config_options_value().await;
    assert!(
        !options.as_array().unwrap().iter().any(|o| o["id"] == prompt_suggestions::OPTION),
        "{options}"
    );

    // The chat off: paused at start, and any that still comes is dropped.
    let t = offered(false);
    assert!(t.inbound(&suggestion_line(json!("go on"))).await.is_empty());
}

#[tokio::test]
async fn a_chat_off_at_start_is_paused_right_after_initialize() {
    let t = Translator::new("acp-1".into(), "default", "sonnet", "default");
    t.prompt_suggestions.store(false, Ordering::SeqCst);
    let pause = t.suggestion_init(&json!(7), true).expect("a pause");
    assert_eq!(pause["request_id"], "boot-psp-7");
    assert_eq!(
        pause["request"],
        json!({"subtype": "set_prompt_suggestions_paused", "paused": true})
    );
}

#[tokio::test]
async fn the_chat_option_turns_suggestions_off_and_on() {
    let t = offered(true);
    let option = |opts: &Value| {
        opts.as_array().unwrap().iter().find(|o| o["id"] == prompt_suggestions::OPTION).cloned()
    };
    assert_eq!(option(&t.config_options_value().await).expect("the option")["currentValue"], "on");

    let off = Message::request(
        5,
        method::SESSION_SET_CONFIG_OPTION,
        json!({"sessionId": "acp-1", "configId": "prompt-suggestions", "value": "off"}),
    );
    let Outbound::Lines(lines) = t.outbound(&off).await else { panic!("a pause line") };
    assert_eq!(
        lines[0]["request"],
        json!({"subtype": "set_prompt_suggestions_paused", "paused": true})
    );
    // Off at once: a suggestion already on its way is dropped.
    assert!(t.inbound(&suggestion_line(json!("go on"))).await.is_empty());
    // An older Claude Code answers an unknown-subtype error: the pick still holds, the shown
    // suggestion is cleared, and the option says off.
    let rid = lines[0]["request_id"].clone();
    let out = t
        .inbound(&json!({"type": "control_response", "response": {"subtype": "error", "request_id": rid, "error": "unknown subtype"}}))
        .await;
    assert_eq!(updates(&out), [json!({"sessionUpdate": "prompt_suggestion", "suggestion": null})]);
    let reply = out.iter().find_map(|m| match m {
        Message::Response { result: Some(r), .. } => Some(r.clone()),
        _ => None,
    });
    let reply = reply.unwrap_or_else(|| panic!("an ok reply: {out:?}"));
    assert_eq!(option(&reply["configOptions"]).unwrap()["currentValue"], "off");

    let on = Message::request(
        6,
        method::SESSION_SET_CONFIG_OPTION,
        json!({"sessionId": "acp-1", "configId": "prompt-suggestions", "value": "on"}),
    );
    let Outbound::Lines(lines) = t.outbound(&on).await else { panic!("an unpause line") };
    assert_eq!(lines[0]["request"]["paused"], false);
    assert_eq!(updates(&t.inbound(&suggestion_line(json!("go on"))).await).len(), 1);
}

#[tokio::test]
async fn the_chat_option_is_refused_when_the_setting_is_off_or_the_value_is_unknown() {
    let t = Translator::new("acp-1".into(), "default", "sonnet", "default");
    t.suggestion_init(&json!(1), false);
    let req = |v: &str| {
        Message::request(
            9,
            method::SESSION_SET_CONFIG_OPTION,
            json!({"sessionId": "acp-1", "configId": "prompt-suggestions", "value": v}),
        )
    };
    assert!(matches!(
        t.outbound(&req("on")).await,
        Outbound::Reply(Message::Response { error: Some(_), .. })
    ));
    let t = offered(true);
    assert!(matches!(
        t.outbound(&req("maybe")).await,
        Outbound::Reply(Message::Response { error: Some(_), .. })
    ));
}

#[test]
fn a_saved_chat_pick_is_on_unless_it_says_off() {
    assert!(prompt_suggestions::chat_pick(None));
    assert!(prompt_suggestions::chat_pick(Some("on".into())));
    assert!(!prompt_suggestions::chat_pick(Some("off".into())));
}
