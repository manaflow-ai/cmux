//! The chat's own foreground calls (`foreground_work.rs`): listed while they run, gone at their
//! result, and gone at every turn end, also one that ends without their result.

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

fn bash_call(id: &str) -> Value {
    json!({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": id,
        "name": "Bash", "input": {"command": "make long"}}]}})
}

/// The calls `FOREGROUND_WORK` lists, by id.
async fn listed(t: &Translator) -> Vec<String> {
    let work = t.foreground_work().await;
    work["work"]
        .as_array()
        .unwrap()
        .iter()
        .map(|w| w["toolCallId"].as_str().unwrap().to_owned())
        .collect()
}

const INTERRUPTED: &str = r#"{"type": "result", "subtype": "error_during_execution", "is_error": true, "result": null, "num_turns": 1}"#;

/// A Bash call is listed from its call until its result.
#[tokio::test]
async fn a_call_is_listed_until_its_result() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let Outbound::Lines(first) = t.outbound(&prompt(1, "build", json!({}))).await else { panic!() };
    t.inbound(&echo(&first[0])).await;
    t.inbound(&bash_call("toolu_a")).await;
    assert_eq!(listed(&t).await, ["toolu_a"]);
    t.inbound(&json!({"type": "user", "message": {"content": [{"type": "tool_result",
        "tool_use_id": "toolu_a", "content": "ok"}]}}))
        .await;
    assert_eq!(listed(&t).await, Vec::<String>::new());
}

/// A Stop that ends the step while a steer waits unread: the step's result returns early (the
/// steer runs as one more turn), with no result for the call. The call runs no more, so it is
/// not listed, and a later message moves nothing for it.
#[tokio::test]
async fn a_stopped_step_with_a_steer_waiting_leaves_no_call_listed() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let Outbound::Lines(first) = t.outbound(&prompt(1, "build", json!({}))).await else { panic!() };
    t.inbound(&echo(&first[0])).await;
    t.inbound(&bash_call("toolu_a")).await;
    let Outbound::Lines(_) = t.outbound(&prompt(2, "a question", json!({"steer": true}))).await
    else {
        panic!()
    };
    let stop = Message::notification(method::SESSION_CANCEL, json!({"sessionId": "acp-1"}));
    let Outbound::Lines(_) = t.outbound(&stop).await else { panic!() };
    t.inbound(&serde_json::from_str(INTERRUPTED).unwrap()).await;
    assert_eq!(listed(&t).await, Vec::<String>::new());
}
