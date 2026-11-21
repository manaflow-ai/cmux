//! A renamed session's running Claude Code takes the new name (`live_name.rs`), so its peer list
//! and a held message's "From:" follow `acpmux ls` (Leo: "it's kinda weird how it's called
//! projects-34 but it's named differnetly in cmux-next"). The lines are Claude Code 2.1.310's own
//! for `/rename probe-renamed` under `-p --input-format stream-json`.

use super::*;

/// A translator whose Claude Code lists `/rename` among its commands, as 2.1.310's `initialize` does.
async fn translator() -> Arc<Translator> {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    *t.slash_commands.lock().await = vec![json!({"name": "compact"}), json!({"name": "rename"})];
    t
}

fn rename(id: i64, name: &str) -> Message {
    Message::request(id, RENAME, json!({"sessionId": "acp-1", "name": name}))
}

fn prompt(id: i64, text: &str) -> Message {
    Message::request(
        id,
        method::SESSION_PROMPT,
        json!({"sessionId": "acp-1", "prompt": [{"type": "text", "text": text}]}),
    )
}

fn echo(line: &Value) -> Value {
    json!({"type": "user", "isReplay": true, "uuid": line["uuid"], "message": line["message"]})
}

/// What Claude Code writes after it read `/rename <name>`, its echo first.
fn renamed_lines(line: &Value, name: &str) -> Vec<Value> {
    let said = format!("Session renamed to: {name}");
    vec![
        echo(line),
        json!({"type": "system", "subtype": "session_title_changed", "title": name, "uuid": "5245b09e-7cc1-413d-ad23-97b37151ae2d", "session_id": "c1"}),
        json!({"type": "assistant", "message": {"id": "906c15ea", "model": "<synthetic>", "role": "assistant", "stop_reason": "end_turn", "type": "message", "content": [{"type": "text", "text": said}]}, "parent_tool_use_id": null, "local_command_source": format!("<local-command-stdout>{said}</local-command-stdout>"), "session_id": "c1", "uuid": "8f8653e9-0621-4b4e-be77-d0aabd8ae8e2", "local_command_run": {"command": "rename", "args": name}}),
        json!({"type": "result", "subtype": "success", "is_error": false, "duration_api_ms": 0, "num_turns": 0, "session_id": "c1", "total_cost_usd": 0, "result": said, "local_command": "rename", "uuid": "85adf778-dbf8-44fe-b55d-8630d9fba81d"}),
    ]
}

fn result_of(msgs: &[Message], want: i64) -> Option<Result<Value, String>> {
    msgs.iter().find_map(|m| match m {
        Message::Response { id, result, error, .. } if *id == want => Some(match error {
            Some(e) => Err(e.message.clone()),
            None => Ok(result.clone().unwrap_or(Value::Null)),
        }),
        _ => None,
    })
}

async fn written(t: &Translator, msg: &Message) -> Vec<Value> {
    match t.outbound(msg).await {
        Outbound::Lines(lines) => lines,
        Outbound::Reply(reply) => panic!("answered at once: {reply:?}"),
    }
}

#[tokio::test]
async fn an_idle_claude_code_is_renamed_and_the_chat_sees_none_of_it() {
    let t = translator().await;
    let lines = written(&t, &rename(7, " reviewer ")).await;
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert_eq!(lines[0]["type"], "user");
    assert_eq!(lines[0]["message"]["content"], "/rename reviewer");
    let mut out = Vec::new();
    for line in renamed_lines(&lines[0], "reviewer") {
        out.extend(t.inbound(&line).await);
    }
    assert_eq!(out.len(), 1, "the chat saw the rename: {out:?}");
    assert_eq!(result_of(&out, 7).unwrap().unwrap()["renamed"], true);
    // The next prompt is a turn as before.
    let next = written(&t, &prompt(8, "hi")).await;
    assert_eq!(next[0]["message"]["content"][0]["text"], "hi");
}

#[tokio::test]
async fn a_rename_waits_for_the_turn_to_end() {
    let t = translator().await;
    let _ = written(&t, &prompt(1, "run sleep 25")).await;
    let Outbound::Reply(reply) = t.outbound(&rename(2, "reviewer")).await else {
        panic!("wrote a rename into a running turn")
    };
    assert_eq!(result_of(&[reply], 2).unwrap().unwrap_err(), RENAME_BUSY);
}

#[tokio::test]
async fn one_rename_at_a_time_and_only_a_one_line_name() {
    let t = translator().await;
    for bad in ["", "  ", "two\nlines"] {
        let Outbound::Reply(reply) = t.outbound(&rename(3, bad)).await else {
            panic!("wrote a rename for {bad:?}")
        };
        assert!(result_of(&[reply], 3).unwrap().is_err());
    }
    let _ = written(&t, &rename(4, "reviewer")).await;
    let Outbound::Reply(reply) = t.outbound(&rename(5, "other")).await else {
        panic!("wrote a second rename before the first was answered")
    };
    assert_eq!(result_of(&[reply], 5).unwrap().unwrap_err(), RENAME_IN_FLIGHT);
}

/// The hub's prompt went out before Claude Code answered the rename: Claude Code reads its
/// stdin in order, so the rename's lines come first, and the prompt's turn is untouched.
#[tokio::test]
async fn a_prompt_written_behind_the_rename_keeps_its_own_turn() {
    let t = translator().await;
    let renamed = written(&t, &rename(4, "reviewer")).await;
    let asked = written(&t, &prompt(5, "hi")).await;
    let mut out = Vec::new();
    for line in renamed_lines(&renamed[0], "reviewer") {
        out.extend(t.inbound(&line).await);
    }
    assert_eq!(out.len(), 1, "{out:?}");
    assert!(result_of(&out, 4).unwrap().is_ok());
    assert!(result_of(&out, 5).is_none(), "the rename's result ended the prompt: {out:?}");
    out.clear();
    for line in [
        echo(&asked[0]),
        json!({"type": "assistant", "message": {"id": "m1", "role": "assistant", "model": "haiku", "content": [{"type": "text", "text": "hello"}]}, "parent_tool_use_id": null, "session_id": "c1"}),
        json!({"type": "result", "subtype": "success", "is_error": false, "num_turns": 1, "duration_api_ms": 900, "result": "hello", "session_id": "c1"}),
    ] {
        out.extend(t.inbound(&line).await);
    }
    assert!(result_of(&out, 5).is_some_and(|r| r.is_ok()), "{out:?}");
}

/// A `/rename` the person typed is their own turn, shown as before.
#[tokio::test]
async fn a_rename_the_person_typed_is_their_turn() {
    let t = translator().await;
    let asked = written(&t, &prompt(6, "/rename mine")).await;
    let mut out = Vec::new();
    for line in renamed_lines(&asked[0], "mine") {
        out.extend(t.inbound(&line).await);
    }
    assert!(result_of(&out, 6).is_some_and(|r| r.is_ok()), "{out:?}");
}

/// A Claude Code whose commands list no `/rename` is never written one: the line would be a prompt.
#[tokio::test]
async fn a_claude_code_without_rename_is_not_asked() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let Outbound::Reply(reply) = t.outbound(&rename(2, "reviewer")).await else {
        panic!("wrote /rename to a Claude Code that lists no such command")
    };
    assert_eq!(result_of(&[reply], 2).unwrap().unwrap_err(), RENAME_UNSUPPORTED);
}

/// A `/rename` that never got its result (the process stalled, the hub stopped waiting) does not
/// refuse every later rename: after `STALE` the next one is written.
#[tokio::test]
async fn a_rename_with_no_result_does_not_block_the_next_one() {
    let t = translator().await;
    let _ = written(&t, &rename(4, "reviewer")).await;
    let long_ago =
        std::time::Instant::now().checked_sub(std::time::Duration::from_secs(31)).unwrap();
    t.renaming.lock().await.front_mut().unwrap().at = long_ago;
    let lines = written(&t, &rename(5, "lead")).await;
    assert_eq!(lines[0]["message"]["content"], "/rename lead");
}

/// Gives up on the `/rename` ahead (`STALE`), then writes the next: the lines each produced.
async fn given_up_then_next(t: &Translator) -> (Value, Value) {
    let first = written(t, &rename(4, "reviewer")).await.remove(0);
    let long_ago =
        std::time::Instant::now().checked_sub(std::time::Duration::from_secs(31)).unwrap();
    t.renaming.lock().await.front_mut().unwrap().at = long_ago;
    let next = written(t, &rename(5, "lead")).await.remove(0);
    (first, next)
}

/// A given-up rename's late lines answer nothing and never the newer rename, which gets its own
/// result; none of it reaches the chat.
#[tokio::test]
async fn a_given_up_renames_late_lines_answer_nothing() {
    let t = translator().await;
    let (first, next) = given_up_then_next(&t).await;
    let mut out = Vec::new();
    for line in renamed_lines(&first, "reviewer") {
        out.extend(t.inbound(&line).await);
    }
    assert!(out.is_empty(), "the late rename answered or reached the chat: {out:?}");
    for line in renamed_lines(&next, "lead") {
        out.extend(t.inbound(&line).await);
    }
    assert_eq!(out.len(), 1, "{out:?}");
    assert!(result_of(&out, 5).unwrap().is_ok());
}

/// A rename Claude Code never echoed does not hide the next one's lines.
#[tokio::test]
async fn a_rename_claude_code_never_read_does_not_hide_the_next() {
    let t = translator().await;
    let (_, next) = given_up_then_next(&t).await;
    let mut out = Vec::new();
    for line in renamed_lines(&next, "lead") {
        out.extend(t.inbound(&line).await);
    }
    assert_eq!(out.len(), 1, "{out:?}");
    assert!(result_of(&out, 5).unwrap().is_ok());
}

/// A `/rename` the person typed while acpmux's is unanswered is still their turn: its lines follow
/// their echo, not acpmux's, and answer their prompt.
#[tokio::test]
async fn a_rename_the_person_typed_behind_an_unanswered_one_is_theirs() {
    let t = translator().await;
    let _ = written(&t, &rename(4, "reviewer")).await;
    let asked = written(&t, &prompt(6, "/rename mine")).await;
    let mut out = Vec::new();
    for line in renamed_lines(&asked[0], "mine") {
        out.extend(t.inbound(&line).await);
    }
    assert!(result_of(&out, 6).is_some_and(|r| r.is_ok()), "{out:?}");
    assert!(result_of(&out, 4).is_none(), "their result answered acpmux's rename: {out:?}");
}
