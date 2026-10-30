//! A turn ends when Claude Code ends it (`carry.rs`; Leo, 2026-10-29: "you clearly just ended
//! some fucking turns, and it still fucking shows this."). A steer Claude Code reads after its
//! turn ended runs in the next turn, whose prompt (`_meta.carried`) the hub sends then; one it
//! reads during its turn stays in that turn.

use super::*;

fn prompt(id: i64, text: &str, meta: Value) -> Message {
    Message::request(
        id,
        method::SESSION_PROMPT,
        json!({"sessionId": "acp-1", "prompt": [{"type": "text", "text": text}], "_meta": meta}),
    )
}

fn steer(id: i64, prompt_id: &str, text: &str) -> Message {
    prompt(id, text, json!({"steer": true, "promptId": prompt_id}))
}

/// The hub's prompt for the turn Claude Code runs on carried steers.
fn carried(id: i64) -> Message {
    Message::request(
        id,
        method::SESSION_PROMPT,
        json!({"sessionId": "acp-1", "prompt": [], "_meta": {"carried": true}}),
    )
}

fn echo(line: &Value) -> Value {
    json!({"type": "user", "isReplay": true, "uuid": line["uuid"], "message": line["message"]})
}

fn done(said: &str) -> Value {
    json!({"type": "result", "subtype": "success", "is_error": false, "num_turns": 1, "result": said})
}

fn answer(msgs: &[Message], want: i64) -> Option<Value> {
    msgs.iter().find_map(|m| match m {
        Message::Response { id, result, .. } if *id == want => result.clone(),
        _ => None,
    })
}

async fn lines(t: &Translator, m: &Message) -> Vec<Value> {
    match t.outbound(m).await {
        Outbound::Lines(lines) => lines,
        Outbound::Reply(r) => panic!("answered at once: {r:?}"),
    }
}

/// Prompt 1 runs, and steer 2 ("p-2") is written during it; returns the steer's line.
async fn turn_with_a_steer(t: &Translator) -> Value {
    let first = lines(t, &prompt(1, "work", json!({}))).await;
    t.inbound(&echo(&first[0])).await;
    let written = lines(t, &steer(2, "p-2", "one more thing")).await;
    assert_eq!(written.len(), 1, "{written:?}");
    written[0].clone()
}

#[tokio::test]
async fn a_steer_unread_at_end_turn_ends_the_turn_and_starts_the_next() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let line = turn_with_a_steer(&t).await;
    let msgs = t.inbound(&done("first")).await;
    let first = answer(&msgs, 1).expect("Claude Code ended its turn, and so did the prompt's");
    assert_eq!(first["stopReason"], "end_turn", "{first}");
    assert_eq!(first["_meta"]["claude"]["carried"]["promptIds"], json!(["p-2"]), "{first}");
    assert!(answer(&msgs, 2).is_none(), "the steer is not read yet: {msgs:?}");
    // The next turn's prompt writes nothing: Claude Code has its line already.
    assert!(lines(&t, &carried(3)).await.is_empty());
    let msgs = t.inbound(&echo(&line)).await;
    let read = answer(&msgs, 2).expect("the steer is answered at its echo");
    assert_eq!(read["stopReason"], "steered", "{read}");
    assert_eq!(read["_meta"]["claude"]["carried"], first["_meta"]["claude"]["carried"]["seq"]);
    let msgs = t.inbound(&done("second")).await;
    let next = answer(&msgs, 3).expect("the carried turn ends at Claude Code's result");
    assert_eq!(next["stopReason"], "end_turn", "{next}");
    assert!(next["_meta"]["claude"].get("carried").is_none(), "{next}");
}

/// The hub's prompt for the carried turn may come after that turn's result: it is answered at
/// once with it.
#[tokio::test]
async fn a_carried_turn_that_ended_first_answers_its_prompt_at_once() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let line = turn_with_a_steer(&t).await;
    assert!(answer(&t.inbound(&done("first")).await, 1).is_some());
    t.inbound(&echo(&line)).await;
    t.inbound(&done("second")).await;
    let Outbound::Reply(reply) = t.outbound(&carried(3)).await else {
        panic!("waited for a result that came already")
    };
    assert_eq!(answer(&[reply], 3).unwrap()["stopReason"], "end_turn");
}

/// Claude Code ends turn after turn while steers keep coming: each of its turns is a turn.
#[tokio::test]
async fn several_turns_while_steers_keep_coming_are_several_turns() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let mut line = turn_with_a_steer(&t).await;
    let mut prompt_id = 1;
    let mut seqs = Vec::new();
    for (next, steer_id) in [(3, 4), (5, 6), (7, 8)] {
        let msgs = t.inbound(&done("ended")).await;
        let ended = answer(&msgs, prompt_id).expect("Claude Code's turn ended the prompt's");
        let carry = ended["_meta"]["claude"]["carried"].clone();
        assert!(carry.is_object(), "{ended}");
        seqs.push(carry["seq"].clone());
        assert!(lines(&t, &carried(next)).await.is_empty());
        let msgs = t.inbound(&echo(&line)).await;
        let read = answer(&msgs, steer_id - 2).expect("read");
        assert_eq!(read["_meta"]["claude"]["carried"], carry["seq"], "{read}");
        // The next message comes while this turn runs, and Claude Code reads it after.
        line = lines(&t, &steer(steer_id, &format!("p-{steer_id}"), "and this")).await[0].clone();
        prompt_id = next;
    }
    seqs.dedup();
    assert_eq!(seqs.len(), 3, "each turn its own carry: {seqs:?}");
    let msgs = t.inbound(&done("ended")).await;
    assert!(answer(&msgs, 7).is_some_and(|a| a["_meta"]["claude"]["carried"].is_object()));
    assert!(lines(&t, &carried(9)).await.is_empty());
    t.inbound(&echo(&line)).await;
    let last = answer(&t.inbound(&done("last")).await, 9).expect("the last turn ends");
    assert!(last["_meta"]["claude"].get("carried").is_none(), "{last}");
}

/// A steer Claude Code reads during its turn stays in that turn, which its result ends.
#[tokio::test]
async fn a_steer_read_during_the_turn_joins_it() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let line = turn_with_a_steer(&t).await;
    let msgs = t.inbound(&echo(&line)).await;
    let read = answer(&msgs, 2).expect("read at a tool boundary");
    assert_eq!(read, json!({"stopReason": "steered"}));
    let ended = answer(&t.inbound(&done("both")).await, 1).expect("the turn ends");
    assert_eq!(ended["stopReason"], "end_turn");
    assert!(ended["_meta"]["claude"].get("carried").is_none(), "{ended}");
}

/// A carried turn's prompt with no carried turn owed ends at once, writing nothing.
#[tokio::test]
async fn a_carried_prompt_with_none_owed_ends_at_once() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let line = turn_with_a_steer(&t).await;
    t.inbound(&echo(&line)).await;
    assert!(answer(&t.inbound(&done("both")).await, 1).is_some());
    let Outbound::Reply(reply) = t.outbound(&carried(3)).await else { panic!("it waited") };
    assert_eq!(answer(&[reply], 3).unwrap()["stopReason"], "end_turn");
}

/// A turn that failed with a steer unread keeps the old way: the steer runs as one more turn of
/// the same prompt.
#[tokio::test]
async fn a_failed_turn_runs_its_unread_steer_in_the_same_prompt() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let line = turn_with_a_steer(&t).await;
    let failed = json!({"type": "result", "subtype": "success", "is_error": true, "num_turns": 1, "result": "API Error: 500"});
    assert!(answer(&t.inbound(&failed).await, 1).is_none());
    assert_eq!(
        answer(&t.inbound(&echo(&line)).await, 2).unwrap(),
        json!({"stopReason": "steered"})
    );
    let ended = answer(&t.inbound(&done("after")).await, 1).expect("the prompt ends");
    assert!(ended["_meta"]["claude"].get("carried").is_none(), "{ended}");
}

/// A steer written after Claude Code's turn ended, while it runs the carried turn, is read in
/// that turn: its answer names that carry.
#[tokio::test]
async fn a_steer_written_during_a_carried_turn_names_it() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let line = turn_with_a_steer(&t).await;
    let first = answer(&t.inbound(&done("first")).await, 1).unwrap();
    let seq = first["_meta"]["claude"]["carried"]["seq"].clone();
    let late = lines(&t, &steer(4, "p-4", "late")).await[0].clone();
    assert!(lines(&t, &carried(3)).await.is_empty());
    t.inbound(&echo(&line)).await;
    let read = answer(&t.inbound(&echo(&late)).await, 4).expect("read");
    assert_eq!(read["_meta"]["claude"]["carried"], seq, "{read}");
    let ended = answer(&t.inbound(&done("second")).await, 3).expect("the carried turn ends");
    assert!(ended["_meta"]["claude"].get("carried").is_none(), "{ended}");
    // The next prompt's turn is not a carried one: a steer read in it names none.
    let next = lines(&t, &prompt(5, "again", json!({}))).await;
    t.inbound(&echo(&next[0])).await;
    let steer6 = lines(&t, &steer(6, "p-6", "mid")).await[0].clone();
    assert_eq!(
        answer(&t.inbound(&echo(&steer6)).await, 6).unwrap(),
        json!({"stopReason": "steered"})
    );
}

/// The carried turn's result was lost (an answer over the size limit, `fail_pending`) before its
/// prompt came: the prompt ends failed, never as a success.
#[tokio::test]
async fn a_carried_turn_whose_result_was_lost_fails_its_prompt() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let line = turn_with_a_steer(&t).await;
    assert!(answer(&t.inbound(&done("first")).await, 1).is_some());
    assert!(t.holding().is_some(), "Claude Code's output waits for the carried turn's prompt");
    t.inbound(&echo(&line)).await;
    t.fail_pending("agent answer was over the size limit").await;
    let Outbound::Reply(reply) = t.outbound(&carried(3)).await else { panic!("it waited") };
    let Message::Response { error, .. } = &reply else { panic!("{reply:?}") };
    assert!(error.as_ref().is_some_and(|e| e.message.contains("size limit")), "{reply:?}");
    assert!(t.holding().is_none());
}
