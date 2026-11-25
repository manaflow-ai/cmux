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

/// A value MDM or the team policy forces beats the settings file both ways; with nothing forced
/// the file decides, on when unset (review of cmux#33097: a forced off still started suggestions,
/// and the file could undo a forced on).
#[test]
fn a_forced_value_beats_the_file_and_nothing_forced_keeps_the_file() {
    for file in [None, Some(true), Some(false)] {
        assert!(!prompt_suggestions::effective(Some(false), file), "forced off, file {file:?}");
        assert!(prompt_suggestions::effective(Some(true), file), "forced on, file {file:?}");
    }
    assert!(prompt_suggestions::effective(None, None));
    assert!(prompt_suggestions::effective(None, Some(true)));
    assert!(!prompt_suggestions::effective(None, Some(false)));
}

/// The turn's prompt as the hub writes it: `personTurn` when a person's own prompt starts it
/// (`hub/prompt_sender.rs`), with no mark for another agent's message, a notice or a trigger.
fn turn_prompt(id: i64, by_person: bool) -> Message {
    let mut params = json!({"sessionId": "acp-1", "prompt": [{"type": "text", "text": "go"}]});
    if by_person {
        params["_meta"] = json!({"acpmux": {"personTurn": true}});
    } else {
        params["_meta"] = json!({"acpmux": {"sender": {"name": "lane-a"}}});
    }
    Message::request(id, method::SESSION_PROMPT, params)
}

/// The `set_prompt_suggestions_paused` value a prompt's lines carry before its user line, if any.
async fn pause_before(t: &Translator, prompt: &Message) -> Option<bool> {
    let Outbound::Lines(lines) = t.outbound(prompt).await else { panic!("lines") };
    assert_eq!(lines.last().unwrap()["type"], "user", "the prompt is the last line: {lines:?}");
    let pauses: Vec<_> = lines
        .iter()
        .filter(|l| l["request"]["subtype"] == "set_prompt_suggestions_paused")
        .map(|l| l["request"]["paused"].as_bool().unwrap())
        .collect();
    assert!(pauses.len() <= 1, "{lines:?}");
    pauses.first().copied()
}

/// No agent reads a predicted next prompt, and each costs a model call over the whole
/// conversation: 84% of them on the team gateway followed turns no person started (sr2 audit
/// 2026-11-20). So Claude Code is asked for one only after a person's own turn.
#[tokio::test]
async fn only_a_persons_own_turn_asks_for_a_suggestion() {
    let t = offered(true);
    assert_eq!(pause_before(&t, &turn_prompt(10, false)).await, Some(true), "agent: paused");
    assert_eq!(pause_before(&t, &turn_prompt(11, false)).await, None, "still paused: no line");
    assert_eq!(pause_before(&t, &turn_prompt(12, true)).await, Some(false), "person: resumed");
    assert_eq!(pause_before(&t, &turn_prompt(13, true)).await, None, "still on: no line");
    // A prompt with no mark at all (an internal one) is no person's.
    let bare = Message::request(
        14,
        method::SESSION_PROMPT,
        json!({"sessionId": "acp-1", "prompt": [{"type": "text", "text": "ready?"}]}),
    );
    assert_eq!(pause_before(&t, &bare).await, Some(true));
}

#[tokio::test]
async fn a_chat_with_suggestions_off_stays_paused_for_the_persons_turn() {
    let t = offered(false);
    assert_eq!(pause_before(&t, &turn_prompt(10, true)).await, None, "paused since boot");
    // Its pick on again resumes them; an agent's turn then pauses them once more.
    let on = Message::request(
        11,
        method::SESSION_SET_CONFIG_OPTION,
        json!({"sessionId": "acp-1", "configId": "prompt-suggestions", "value": "on"}),
    );
    t.outbound(&on).await;
    assert_eq!(pause_before(&t, &turn_prompt(12, true)).await, None, "already resumed");
    assert_eq!(pause_before(&t, &turn_prompt(13, false)).await, Some(true));
}

#[tokio::test]
async fn with_the_setting_off_no_prompt_carries_a_pause() {
    let t = Translator::new("acp-1".into(), "default", "sonnet", "default");
    t.suggestion_init(&json!(1), false);
    assert_eq!(pause_before(&t, &turn_prompt(10, false)).await, None);
    assert_eq!(pause_before(&t, &turn_prompt(11, true)).await, None);
}
