use super::api_error::{failure, text};
use serde_json::json;

const REPEATED_529: &str = "API Error: Repeated 529 Overloaded errors · check status.claude.com";

fn error_line(said: &str) -> serde_json::Value {
    json!({"type": "assistant", "is_api_error_message": true, "error": "overloaded_error",
        "api_error_status": 529, "parent_tool_use_id": null,
        "message": {"model": "<synthetic>", "role": "assistant", "stop_reason": "stop_sequence",
            "content": [{"type": "text", "text": said}]}})
}

#[test]
fn claude_codes_own_error_line_is_read_as_one() {
    assert_eq!(text(&error_line(REPEATED_529)).as_deref(), Some(REPEATED_529));
    // Unflagged, but synthetic and saying it.
    let mut line = error_line(REPEATED_529);
    line.as_object_mut().unwrap().remove("is_api_error_message");
    assert_eq!(text(&line).as_deref(), Some(REPEATED_529));
    // Its text left out (acpmux's log trims bodies): its status and kind still say it.
    let bare = error_line("");
    assert_eq!(text(&bare).as_deref(), Some("API Error: 529 overloaded_error"));
}

#[test]
fn a_reply_a_local_command_or_a_subagent_is_not_an_error_line() {
    let reply = json!({"type": "assistant", "message": {"model": "claude-opus-5-5",
        "content": [{"type": "text", "text": "API Error handling is in turn_errors.rs"}]}});
    assert_eq!(text(&reply), None, "a model's words about API errors are a reply");
    let local = json!({"type": "assistant", "message": {"model": "<synthetic>",
        "content": [{"type": "text", "text": "Renamed the session"}]}});
    assert_eq!(text(&local), None);
    let mut sub = error_line(REPEATED_529);
    sub["parent_tool_use_id"] = json!("toolu_1");
    assert_eq!(text(&sub), None, "a subagent's error is its own turn's");
}

#[test]
fn a_success_result_after_an_error_line_fails_with_the_errors_text() {
    let ok =
        json!({"type": "result", "subtype": "success", "is_error": false, "result": REPEATED_529});
    assert_eq!(failure(&ok, Some(REPEATED_529.into())).as_deref(), Some(REPEATED_529));
    let empty = json!({"type": "result", "subtype": "success", "is_error": false, "result": ""});
    assert_eq!(failure(&empty, Some("API Error: 529".into())).as_deref(), Some("API Error: 529"));
    assert_eq!(failure(&ok, None), None, "no error line, no failure");
}

/// The whole turn as Claude Code prints it: the prompt's echo, its own error line, then a result
/// that says success. The prompt fails with the error's text, so the capacity resume continues the
/// chat; before, it ended `end_turn` and the chat sat idle. A later reply in the same turn (Claude
/// Code retried and got through) is the answer, as before.
#[tokio::test]
async fn a_turn_ended_as_success_on_claude_codes_api_error_fails() {
    use super::{Outbound, Translator};
    use crate::rpc::{Message, method};
    let t = Translator::new("acp-1".into(), "default", "opus", "default");
    let prompt = |id: i64| {
        Message::request(
            id,
            method::SESSION_PROMPT,
            json!({"sessionId": "acp-1", "prompt": [{"type": "text", "text": "go on"}]}),
        )
    };
    let echo = |lines: &[serde_json::Value]| json!({"type": "user", "isReplay": true, "uuid": lines[0]["uuid"], "message": lines[0]["message"]});
    let ok = json!({"type": "result", "subtype": "success", "is_error": false, "num_turns": 1,
        "duration_api_ms": 4000, "result": REPEATED_529});
    let answer = |msgs: &[Message], want: i64| {
        msgs.iter().find_map(|m| match m {
            Message::Response { id, result, error, .. } if *id == want => {
                Some((result.clone(), error.as_ref().map(|e| e.message.clone())))
            }
            _ => None,
        })
    };

    let Outbound::Lines(first) = t.outbound(&prompt(1)).await else { panic!() };
    t.inbound(&echo(&first)).await;
    t.inbound(&error_line(REPEATED_529)).await;
    let msgs = t.inbound(&ok).await;
    let (_, error) = answer(&msgs, 1).expect("the result ended the prompt");
    assert_eq!(error.as_deref(), Some(REPEATED_529), "{msgs:?}");

    let Outbound::Lines(second) = t.outbound(&prompt(2)).await else { panic!() };
    t.inbound(&echo(&second)).await;
    t.inbound(&error_line(REPEATED_529)).await;
    t.inbound(&json!({"type": "assistant", "message": {"id": "a2", "model": "claude-opus-5-5",
        "role": "assistant", "content": [{"type": "text", "text": "done"}]}}))
        .await;
    let done = json!({"type": "result", "subtype": "success", "is_error": false, "num_turns": 2,
        "duration_api_ms": 9000, "result": "done"});
    let msgs = t.inbound(&done).await;
    let (result, error) = answer(&msgs, 2).expect("the result ended the prompt");
    assert_eq!(error, None, "{msgs:?}");
    assert_eq!(result.unwrap()["stopReason"], "end_turn");
}
