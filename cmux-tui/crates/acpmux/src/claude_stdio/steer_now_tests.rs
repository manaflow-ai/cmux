//! Send now for a steer (Leo, 2026-10-20): Claude Code reads a steered line when its current step
//! ends; Send now stops that step so it reads the line at once. The prompt's turn runs on and
//! ends as the agent ends it, not as stopped. The lines are Claude Code's, in the order it wrote
//! them (cosmic-gray, 2026-10-20): the interrupted step's result comes before it reads the steer.
//! A steer comes sent now (`_meta.steerNow`, a queued prompt's Send now), or a waiting steer is
//! sent now later (`MUX_STEP_NOW`). Tests by steer-default (cmux/steer-now, ad34433a).

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
        Message::Response { id, result, .. } if *id == want => result.clone(),
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
        let Outbound::Lines(more) = t.outbound(&stop).await else { panic!("{stop:?}") };
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
    let (written, turn) = steered_turn(&t, json!({"steer": true, "steerNow": true}), None).await;
    assert_eq!(written.iter().filter(|l| is_interrupt(l)).count(), 1, "{written:?}");
    assert_eq!(turn["stopReason"], "end_turn", "{turn}");
}

/// A steer without `steerNow` (Return, or `interrupt` for an agent that cannot steer) waits for
/// the step to end: it stops nothing.
#[tokio::test]
async fn a_steer_waits_for_the_step() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let Outbound::Lines(first) = t.outbound(&prompt(1, "run sleep 25", json!({}))).await else {
        panic!()
    };
    t.inbound(&echo(&first[0])).await;
    let meta = json!({"steer": true, "interrupt": true});
    let Outbound::Lines(written) = t.outbound(&prompt(2, "reply PINEAPPLE", meta)).await else {
        panic!()
    };
    assert_eq!(written.len(), 1, "{written:?}");
}

#[tokio::test]
async fn send_now_for_a_waiting_steer_stops_only_the_step() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let now = Message::request(9, method::MUX_STEP_NOW, json!({"sessionId": "acp-1"}));
    let (written, turn) = steered_turn(&t, json!({"steer": true}), Some(now)).await;
    let stops: Vec<&Value> = written.iter().filter(|l| is_interrupt(l)).collect();
    assert_eq!(stops.len(), 1, "{written:?}");
    // Its ack answers the request.
    let ack = json!({"type": "control_response", "response": {"subtype": "success", "request_id": stops[0]["request_id"], "response": {}}});
    let answered = t.inbound(&ack).await;
    assert_eq!(answer(&answered, 9).unwrap()["interrupted"], true, "{answered:?}");
    assert_eq!(turn["stopReason"], "end_turn", "{turn}");
}

#[tokio::test]
async fn send_now_with_no_steer_waiting_stops_nothing() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let Outbound::Lines(first) = t.outbound(&prompt(1, "run sleep 25", json!({}))).await else {
        panic!()
    };
    t.inbound(&echo(&first[0])).await;
    let now = Message::request(9, method::MUX_STEP_NOW, json!({"sessionId": "acp-1"}));
    let Outbound::Reply(reply) = t.outbound(&now).await else { panic!("it stopped the step") };
    assert_eq!(answer(&[reply], 9).unwrap()["interrupted"], false);
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

/// Claude Code's `interrupt` ends more than the step: every running subagent, background ones
/// included, and every background shell (cosmic-gray, 2026-10-21: a Send now killed two
/// background subagents 17 and 4 minutes in). While one runs, Send now stops nothing; the steer
/// is read at the next tool boundary.
async fn turn_with(t: &Translator, work: Value) {
    let Outbound::Lines(first) = t.outbound(&prompt(1, "run sleep 25", json!({}))).await else {
        panic!()
    };
    t.inbound(&echo(&first[0])).await;
    t.inbound(&json!({"type": "assistant", "message": {"content": [work]}})).await;
}

fn agent(id: &str, background: bool) -> Value {
    json!({"type": "tool_use", "id": id, "name": "Agent", "input": {"description": "Review", "prompt": "review it", "run_in_background": background}})
}

fn shell(id: &str, background: bool) -> Value {
    json!({"type": "tool_use", "id": id, "name": "Bash", "input": {"command": "sleep 600", "run_in_background": background}})
}

#[tokio::test]
async fn a_steer_sent_now_never_stops_a_running_subagent_or_background_shell() {
    for work in [agent("toolu_bg", true), agent("toolu_fg", false), shell("toolu_sh", true)] {
        let t = Translator::new("acp-1".into(), "default", "haiku", "default");
        turn_with(&t, work.clone()).await;
        let meta = json!({"steer": true, "steerNow": true});
        let Outbound::Lines(written) = t.outbound(&prompt(2, "reply PINEAPPLE", meta)).await else {
            panic!()
        };
        assert!(!written.iter().any(is_interrupt), "{work}: {written:?}");
        assert_eq!(written.len(), 1, "{work}: {written:?}");
    }
}

#[tokio::test]
async fn send_now_for_a_waiting_steer_never_stops_a_running_subagent_or_background_shell() {
    for work in [agent("toolu_bg", true), agent("toolu_fg", false), shell("toolu_sh", true)] {
        let t = Translator::new("acp-1".into(), "default", "haiku", "default");
        turn_with(&t, work.clone()).await;
        let steer = json!({"steer": true});
        let Outbound::Lines(_) = t.outbound(&prompt(2, "reply PINEAPPLE", steer)).await else {
            panic!()
        };
        let now = Message::request(9, method::MUX_STEP_NOW, json!({"sessionId": "acp-1"}));
        let Outbound::Reply(reply) = t.outbound(&now).await else {
            panic!("{work}: it stopped the step")
        };
        assert_eq!(answer(&[reply], 9).unwrap()["interrupted"], false, "{work}");
    }
}

/// A foreground shell alone is the step Send now stops: nothing else ends with it.
#[tokio::test]
async fn a_steer_sent_now_still_stops_a_foreground_shell() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    turn_with(&t, shell("toolu_sh", false)).await;
    let meta = json!({"steer": true, "steerNow": true});
    let Outbound::Lines(written) = t.outbound(&prompt(2, "reply PINEAPPLE", meta)).await else {
        panic!()
    };
    assert_eq!(written.iter().filter(|l| is_interrupt(l)).count(), 1, "{written:?}");
}
