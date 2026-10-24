//! Taking back a steer Claude Code has not read (Leo, 2026-10-21: "THERE'S A CANCEL AND EDIT BY
//! CLICKING THE X BUTTON ON THE SENT MESSAGES TO CLAUDE.. THEY'RE STEERS BUT THEY HAVENT BEEN SENT
//! SOMETIMES WITH THE TOOL CALLS AND WHATNOT WAITING"). A steered line waits in Claude Code's
//! command queue until its current step ends; `cancel_async_message` drops it from there by its
//! uuid (`MUX_STEER_WITHDRAW`). The steer's own prompt then answers `STEER_WITHDRAWN`, never
//! `steered`, and a steer Claude Code already read is not taken back.

use super::*;

fn prompt(id: i64, text: &str, meta: Value) -> Message {
    Message::request(
        id,
        method::SESSION_PROMPT,
        json!({"sessionId": "acp-1", "prompt": [{"type": "text", "text": text}], "_meta": meta}),
    )
}

fn echo(line: &Value) -> Value {
    json!({"type": "user", "isReplay": true, "uuid": line["uuid"], "message": line["message"]})
}

fn withdraw(id: i64, prompt_id: &str) -> Message {
    Message::request(
        id,
        method::MUX_STEER_WITHDRAW,
        json!({"sessionId": "acp-1", "promptId": prompt_id}),
    )
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

/// A turn running, and steer 2 (`p-steer`) written and not read yet; returns the steer's line.
async fn waiting_steer(t: &Translator) -> Value {
    let Outbound::Lines(first) = t.outbound(&prompt(1, "run sleep 25", json!({}))).await else {
        panic!()
    };
    t.inbound(&echo(&first[0])).await;
    let meta = json!({"steer": true, "promptId": "p-steer"});
    let Outbound::Lines(written) = t.outbound(&prompt(2, "actually, use Rust", meta)).await else {
        panic!()
    };
    written[0].clone()
}

fn cancel_answer(request: &Value, cancelled: bool) -> Value {
    json!({"type": "control_response", "response": {"subtype": "success", "request_id": request["request_id"], "response": {"cancelled": cancelled}}})
}

#[tokio::test]
async fn an_unread_steer_is_dropped_from_claude_codes_queue_and_answers_withdrawn() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let steer = waiting_steer(&t).await;
    let Outbound::Lines(asked) = t.outbound(&withdraw(9, "p-steer")).await else {
        panic!("nothing asked Claude Code to drop it")
    };
    assert_eq!(asked.len(), 1, "{asked:?}");
    assert_eq!(asked[0]["type"], "control_request");
    assert_eq!(asked[0]["request"]["subtype"], "cancel_async_message");
    assert_eq!(asked[0]["request"]["message_uuid"], steer["uuid"]);
    let msgs = t.inbound(&cancel_answer(&asked[0], true)).await;
    assert_eq!(result_of(&msgs, 9).unwrap().unwrap()["withdrawn"], true, "{msgs:?}");
    let steer_answer = result_of(&msgs, 2).expect("the steer's prompt never answered");
    assert!(steer_answer.unwrap_err().starts_with(STEER_WITHDRAWN), "{msgs:?}");
    // It no longer waits: Send now finds nothing to hurry.
    let now = Message::request(10, method::MUX_STEP_NOW, json!({"sessionId": "acp-1"}));
    let Outbound::Reply(reply) = t.outbound(&now).await else { panic!("it stopped the step") };
    assert_eq!(result_of(&[reply], 10).unwrap().unwrap()["interrupted"], false);
}

/// Claude Code read the steer before the drop reached it: the steer stands, answered `steered`.
#[tokio::test]
async fn a_steer_read_first_is_not_taken_back() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let steer = waiting_steer(&t).await;
    let Outbound::Lines(asked) = t.outbound(&withdraw(9, "p-steer")).await else { panic!() };
    let read = t.inbound(&echo(&steer)).await;
    assert_eq!(result_of(&read, 2).unwrap().unwrap()["stopReason"], "steered", "{read:?}");
    let msgs = t.inbound(&cancel_answer(&asked[0], false)).await;
    assert_eq!(result_of(&msgs, 9).unwrap().unwrap()["withdrawn"], false, "{msgs:?}");
    assert!(result_of(&msgs, 2).is_none(), "the read steer answered twice: {msgs:?}");
}

/// No steer of that id waits (read already, or never sent): nothing is asked of Claude Code.
#[tokio::test]
async fn a_steer_not_waiting_asks_claude_code_nothing() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let steer = waiting_steer(&t).await;
    t.inbound(&echo(&steer)).await;
    for prompt_id in ["p-steer", "p-other"] {
        let Outbound::Reply(reply) = t.outbound(&withdraw(9, prompt_id)).await else {
            panic!("{prompt_id}: it asked Claude Code to drop a steer that does not wait")
        };
        assert_eq!(result_of(&[reply], 9).unwrap().unwrap()["withdrawn"], false, "{prompt_id}");
    }
}

/// A Claude Code without `cancel_async_message` refuses it: the steer stays, and waits as before.
#[tokio::test]
async fn a_refused_drop_leaves_the_steer_waiting() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let steer = waiting_steer(&t).await;
    let Outbound::Lines(asked) = t.outbound(&withdraw(9, "p-steer")).await else { panic!() };
    let refused = json!({"type": "control_response", "response": {"subtype": "error", "request_id": asked[0]["request_id"], "error": "Unsupported control request subtype: cancel_async_message"}});
    let msgs = t.inbound(&refused).await;
    assert_eq!(result_of(&msgs, 9).unwrap().unwrap()["withdrawn"], false, "{msgs:?}");
    assert!(result_of(&msgs, 2).is_none(), "{msgs:?}");
    let read = t.inbound(&echo(&steer)).await;
    assert_eq!(result_of(&read, 2).unwrap().unwrap()["stopReason"], "steered", "{read:?}");
}

/// The steer's prompt was answered while the drop was on its way (its answers failed, the turn
/// ended): it is not reported withdrawn, and neither it nor the withdraw is answered twice.
#[tokio::test]
async fn a_steer_answered_meanwhile_is_not_reported_withdrawn() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    waiting_steer(&t).await;
    let Outbound::Lines(asked) = t.outbound(&withdraw(9, "p-steer")).await else { panic!() };
    let failed = t.fail_pending("the agent's answer was too large").await;
    assert!(result_of(&failed, 2).unwrap().is_err(), "{failed:?}");
    // The withdraw is answered too, so the X does not wait on an answer that is lost.
    assert!(result_of(&failed, 9).unwrap().is_err(), "{failed:?}");
    let msgs = t.inbound(&cancel_answer(&asked[0], true)).await;
    assert!(result_of(&msgs, 9).is_none(), "the withdraw answered twice: {msgs:?}");
    assert!(result_of(&msgs, 2).is_none(), "the steer answered twice: {msgs:?}");
}

/// A lost Claude answer and a withdrawal reply can race without holding the translator's
/// `pending` and `steers` locks in opposite order.
#[tokio::test]
async fn a_lost_answer_and_withdrawal_reply_complete_together() {
    let t = std::sync::Arc::new(Translator::new("acp-1".into(), "default", "haiku", "default"));
    let steer = waiting_steer(&t).await;
    let Outbound::Lines(asked) = t.outbound(&withdraw(9, "p-steer")).await else { panic!() };
    let failed_t = std::sync::Arc::clone(&t);
    let reply_t = std::sync::Arc::clone(&t);
    let failed =
        tokio::spawn(
            async move { failed_t.fail_pending("the agent's answer was too large").await },
        );
    let replied =
        tokio::spawn(async move { reply_t.inbound(&cancel_answer(&asked[0], true)).await });
    let (failed, replied) = tokio::time::timeout(std::time::Duration::from_secs(1), async {
        tokio::join!(failed, replied)
    })
    .await
    .expect("lost answer and withdrawal reply deadlocked");
    let failed = failed.expect("fail_pending task panicked");
    let replied = replied.expect("withdrawal task panicked");
    assert!(
        result_of(&failed, 2).is_some() || result_of(&replied, 2).is_some(),
        "{failed:?} {replied:?}"
    );
    assert!(
        result_of(&failed, 9).is_some() || result_of(&replied, 9).is_some(),
        "{failed:?} {replied:?}"
    );
    let _ = steer;
}
