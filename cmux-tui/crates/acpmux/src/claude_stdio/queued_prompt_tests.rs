//! A prompt written while Claude Code runs a turn of its own (a task notification, a loop tick, a
//! hook) waits in Claude Code's queue: Claude Code says so with `command_lifecycle` `queued` for the
//! line's uuid, ends its own turn with a `result`, and only then starts the prompt (`started`, the
//! echo, the prompt's own output and result). The result before `started` is not the prompt's.
//! Lines as Claude Code wrote them in an acpmux chat log (2026-11-10): `queued` at seq 44208, the
//! other turn's result at 44209, `started` at 44216, the echo at 44223, the prompt's result at 44246.

use super::*;

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

fn lifecycle(line: &Value, state: &str) -> Value {
    json!({"type": "command_lifecycle", "command_uuid": line["uuid"], "state": state,
           "uuid": format!("lc-{state}")})
}

fn said(id: &str, text: &str) -> Value {
    json!({"type": "assistant", "message": {"id": id, "role": "assistant",
           "content": [{"type": "text", "text": text}]}})
}

fn result(text: &str, turns: u64) -> Value {
    json!({"type": "result", "subtype": "success", "is_error": false, "num_turns": turns,
           "duration_api_ms": 800, "result": text})
}

fn answer(msgs: &[Message], want: i64) -> Option<&Message> {
    msgs.iter().find(|m| matches!(m, Message::Response { id, .. } if *id == want))
}

/// Runs prompt 1 to its end, so the process has echoed a prompt before.
async fn first_turn(t: &Translator) {
    let Outbound::Lines(first) = t.outbound(&prompt(1, "hello")).await else { panic!() };
    t.inbound(&lifecycle(&first[0], "queued")).await;
    t.inbound(&lifecycle(&first[0], "started")).await;
    t.inbound(&echo(&first[0])).await;
    t.inbound(&said("a1", "hi")).await;
    let msgs = t.inbound(&result("hi", 1)).await;
    assert!(answer(&msgs, 1).is_some(), "prompt 1 never ended: {msgs:?}");
    t.inbound(&lifecycle(&first[0], "completed")).await;
}

#[tokio::test]
async fn a_result_before_a_queued_prompt_starts_is_not_that_prompts() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    first_turn(&t).await;
    // Claude Code's own turn: a background task ended.
    t.inbound(&json!({"type": "system", "subtype": "task_notification", "task_id": "b1",
                      "status": "completed"}))
        .await;
    t.inbound(&json!({"type": "system", "subtype": "init", "session_id": "s"})).await;
    t.inbound(&said("bg", "The build finished.")).await;
    // The person's prompt goes out while that turn runs: Claude Code queues it.
    let Outbound::Lines(second) = t.outbound(&prompt(2, "name three fruits")).await else {
        panic!()
    };
    let mut msgs = t.inbound(&lifecycle(&second[0], "queued")).await;
    msgs.extend(t.inbound(&result("The build finished.", 3)).await);
    assert!(
        answer(&msgs, 2).is_none(),
        "the result of Claude Code's own turn answered the queued prompt: {msgs:?}"
    );
    // Now Claude Code starts the prompt, and its own result answers it.
    t.inbound(&lifecycle(&second[0], "started")).await;
    t.inbound(&echo(&second[0])).await;
    t.inbound(&said("a2", "apple, pear, plum")).await;
    let msgs = t.inbound(&result("apple, pear, plum", 1)).await;
    let Some(Message::Response { result: Some(r), .. }) = answer(&msgs, 2) else {
        panic!("the prompt's own result did not end it: {msgs:?}")
    };
    assert_eq!(r["stopReason"], "end_turn");
}

/// The steer written into the queued prompt's turn is not failed (and so not run twice) by the
/// other turn's result: Claude Code still reads it in the prompt's turn.
#[tokio::test]
async fn a_steer_into_a_queued_prompt_survives_the_earlier_turns_result() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    first_turn(&t).await;
    t.inbound(&json!({"type": "system", "subtype": "init", "session_id": "s"})).await;
    t.inbound(&said("bg", "Loop tick.")).await;
    let Outbound::Lines(second) = t.outbound(&prompt(2, "run the tests")).await else { panic!() };
    t.inbound(&lifecycle(&second[0], "queued")).await;
    let steer = Message::request(
        3,
        method::SESSION_PROMPT,
        json!({"sessionId": "acp-1", "prompt": [{"type": "text", "text": "and lint"}], "_meta": {"steer": true}}),
    );
    let Outbound::Lines(steered) = t.outbound(&steer).await else { panic!() };
    let msgs = t.inbound(&result("Loop tick.", 1)).await;
    assert!(answer(&msgs, 3).is_none(), "the other turn's result failed the steer: {msgs:?}");
    assert!(answer(&msgs, 2).is_none(), "the other turn's result ended the prompt: {msgs:?}");
    t.inbound(&lifecycle(&second[0], "started")).await;
    t.inbound(&echo(&second[0])).await;
    let msgs = t.inbound(&echo(&steered[0])).await;
    let Some(Message::Response { result: Some(r), .. }) = answer(&msgs, 3) else {
        panic!("the steer was not read into the prompt's turn: {msgs:?}")
    };
    assert_eq!(r["stopReason"], "steered");
    t.inbound(&said("a2", "tests and lint pass")).await;
    let msgs = t.inbound(&result("tests and lint pass", 2)).await;
    assert!(answer(&msgs, 2).is_some(), "the prompt's own result did not end it: {msgs:?}");
}

/// A Stop while the prompt still waits in Claude Code's queue ends it with the interrupted
/// turn's result, as before: nothing waits for a start that a stopped chat never asks for.
#[tokio::test]
async fn a_stop_while_the_prompt_is_queued_still_ends_it() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    first_turn(&t).await;
    t.inbound(&json!({"type": "system", "subtype": "init", "session_id": "s"})).await;
    t.inbound(&said("bg", "working")).await;
    let Outbound::Lines(second) = t.outbound(&prompt(2, "name three fruits")).await else {
        panic!()
    };
    t.inbound(&lifecycle(&second[0], "queued")).await;
    let Outbound::Lines(_) = t
        .outbound(&Message::notification(method::SESSION_CANCEL, json!({"sessionId": "acp-1"})))
        .await
    else {
        panic!()
    };
    let msgs = t
        .inbound(&json!({"type": "result", "subtype": "error_during_execution", "is_error": true,
                         "result": null, "num_turns": 1, "duration_api_ms": 300}))
        .await;
    let Some(Message::Response { result: Some(r), .. }) = answer(&msgs, 2) else {
        panic!("a stopped queued prompt stayed open: {msgs:?}")
    };
    assert_eq!(r["stopReason"], "cancelled");
}

/// A local command's result (no model turn) is never held: it has no other turn to belong to.
#[tokio::test]
async fn a_local_command_result_is_never_held() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    first_turn(&t).await;
    let Outbound::Lines(second) = t.outbound(&prompt(2, "/clear")).await else { panic!() };
    t.inbound(&lifecycle(&second[0], "queued")).await;
    t.inbound(&json!({"type": "system", "subtype": "conversation_reset"})).await;
    let msgs = t
        .inbound(&json!({"type": "result", "subtype": "success", "is_error": false, "num_turns": 0,
                         "duration_api_ms": 0, "local_command": "clear", "result": ""}))
        .await;
    assert!(answer(&msgs, 2).is_some(), "/clear left its prompt open: {msgs:?}");
}
