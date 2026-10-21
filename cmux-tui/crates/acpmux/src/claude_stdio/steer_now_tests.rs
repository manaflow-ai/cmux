//! Send now for a steer (Leo, 2026-10-20): Claude Code reads a steered line when its current step
//! ends; Send now stops that step so it reads the line at once. The prompt's turn runs on and
//! ends as the agent ends it, not as stopped. The lines are Claude Code's, in the order it wrote
//! them (cosmic-gray, 2026-10-20): the interrupted step's result comes before it reads the steer.

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

fn is_interrupt(line: &Value) -> bool {
    line["type"] == "control_request" && line["request"]["subtype"] == "interrupt"
}

fn answer(msgs: &[Message], want: i64) -> Option<Value> {
    msgs.iter().find_map(|m| match m {
        Message::Response { id, result, .. } if *id == Value::from(want) => result.clone(),
        _ => None,
    })
}

const INTERRUPTED: &str = r#"{"type": "result", "subtype": "error_during_execution", "is_error": true, "result": null, "num_turns": 1}"#;
const DONE: &str = r#"{"type": "result", "subtype": "success", "is_error": false, "num_turns": 2, "result": "PINEAPPLE"}"#;

/// Runs a prompt whose step `stop` stops while steer 2 waits unread, then Claude Code's lines
/// to the turn's end; returns the turn prompt's answer.
async fn steered_turn(
    t: &Translator,
    steer_meta: Value,
    stop: Option<Message>,
) -> (Vec<Value>, Value) {
    let Outbound::Lines(first) = t.outbound(&prompt(1, "run sleep 25", json!({}))).await else {
        panic!()
    };
    t.inbound(&echo(&first[0])).await;
    let Outbound::Lines(mut written) = t.outbound(&prompt(2, "reply PINEAPPLE", steer_meta)).await
    else {
        panic!()
    };
    let steer = written[0].clone();
    if let Some(stop) = stop {
        let Outbound::Lines(more) = t.outbound(&stop).await else { panic!() };
        written.extend(more);
    }
    let mut msgs = t.inbound(&serde_json::from_str(INTERRUPTED).unwrap()).await;
    assert!(answer(&msgs, 1).is_none(), "the interrupted step ended the turn: {msgs:?}");
    msgs.extend(t.inbound(&echo(&steer)).await);
    assert_eq!(answer(&msgs, 2).unwrap()["stopReason"], "steered");
    written.extend(t.take_stdin_replies().await);
    msgs.extend(t.inbound(&serde_json::from_str(DONE).unwrap()).await);
    (written, answer(&msgs, 1).expect("the turn never ended"))
}

#[tokio::test]
async fn a_steer_sent_now_stops_the_step_and_the_turn_runs_on() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let (written, turn) = steered_turn(&t, json!({"steer": true, "interrupt": true}), None).await;
    assert_eq!(written.iter().filter(|l| is_interrupt(l)).count(), 1, "{written:?}");
    assert_eq!(turn["stopReason"], "end_turn", "{turn}");
}

#[tokio::test]
async fn send_now_for_a_waiting_steer_stops_only_the_step() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let now = Message::notification(
        method::SESSION_CANCEL,
        json!({"sessionId": "acp-1", "_meta": {"steerNow": true}}),
    );
    let (written, turn) = steered_turn(&t, json!({"steer": true}), Some(now)).await;
    assert_eq!(written.iter().filter(|l| is_interrupt(l)).count(), 1, "{written:?}");
    assert_eq!(turn["stopReason"], "end_turn", "{turn}");
}

#[tokio::test]
async fn send_now_with_no_steer_waiting_stops_nothing() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let Outbound::Lines(first) = t.outbound(&prompt(1, "run sleep 25", json!({}))).await else {
        panic!()
    };
    t.inbound(&echo(&first[0])).await;
    let now = Message::notification(
        method::SESSION_CANCEL,
        json!({"sessionId": "acp-1", "_meta": {"steerNow": true}}),
    );
    let Outbound::Lines(written) = t.outbound(&now).await else { panic!() };
    assert!(written.is_empty(), "{written:?}");
}

/// Stop stays a Stop: the steer it finds unread runs as one more turn, and that is stopped too.
#[tokio::test]
async fn stop_with_a_steer_waiting_still_ends_the_turn_stopped() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let stop = Message::notification(method::SESSION_CANCEL, json!({"sessionId": "acp-1"}));
    let (written, turn) = steered_turn(&t, json!({"steer": true}), Some(stop)).await;
    assert_eq!(written.iter().filter(|l| is_interrupt(l)).count(), 2, "{written:?}");
    assert_eq!(turn["stopReason"], "cancelled", "{turn}");
}
