use super::*;

fn event(kind: &str, msg: Value) -> Value {
    json!({"sessionId": "s", "seq": 1, "at": 0, "dir": "mux", "kind": kind, "msg": msg})
}

fn steered(turn: &str) -> Result<Value> {
    Ok(json!({"stopReason": "steered", "_meta": {"acpmux": {"turnId": turn, "steer": true}}}))
}

#[test]
fn a_steered_answer_waits_for_its_turns_end() {
    let mut s = SteerReply::new("p1", true);
    assert!(s.answered(steered("t1")).is_none());
    assert!(s.waiting());
    let other = event("turn_end", json!({"turnId": "t0", "stopReason": "end_turn"}));
    assert!(s.heard(method::MUX_EVENT, &other).is_none(), "another turn's end");
    let end = event("turn_end", json!({"turnId": "t1", "stopReason": "end_turn"}));
    let r = s.heard(method::MUX_EVENT, &end).unwrap().unwrap();
    assert_eq!(r["stopReason"], "end_turn");
    assert_eq!(r.pointer("/_meta/acpmux/turnId"), Some(&json!("t1")));
}

#[test]
fn a_turn_that_ended_before_the_steered_answer_came_answers_at_once() {
    let mut s = SteerReply::new("p1", true);
    let end = event(
        "turn_result",
        json!({"turnId": "t1", "status": "cancelled", "stopReason": "cancelled"}),
    );
    assert!(s.heard(method::MUX_EVENT, &end).is_none());
    let r = s.answered(steered("t1")).unwrap().unwrap();
    assert_eq!(r["stopReason"], "cancelled");
    assert_eq!(s.turn(), Some("t1"), "its reply is that turn's, read from the log");
}

#[test]
fn a_failed_turn_fails_the_send() {
    let mut s = SteerReply::new("p1", true);
    assert!(s.answered(steered("t1")).is_none());
    let failed = event("turn_error", json!({"turnId": "t1", "error": "agent process closed"}));
    let e = s.heard(method::MUX_EVENT, &failed).unwrap().unwrap_err();
    assert_eq!(e.to_string(), "agent process closed");
}

/// A timeout before any record of the steer arrived leaves the turn it may have gone into
/// running; a steer that fell back to the queue (its turn ended first) runs a turn of its own,
/// which a timeout stops, as it does a send that never steered.
#[test]
fn a_steer_is_in_another_turn_until_a_record_shows_its_own() {
    let mut s = SteerReply::new("p1", true);
    assert!(s.in_another_turn(), "no record yet: maybe steered in");
    let steer = event("user_message", json!({"promptId": "p1", "steer": true, "turnId": "t1"}));
    s.heard(method::MUX_EVENT, &steer);
    assert!(s.in_another_turn() && !s.waiting(), "steered in, not read yet");
    let other = event("queued", json!({"promptId": "p0", "turnId": "t2"}));
    s.heard(method::MUX_EVENT, &other);
    assert!(s.in_another_turn(), "another prompt queued");
    let fallback = event("queued", json!({"promptId": "p1", "turnId": "t2"}));
    s.heard(method::MUX_EVENT, &fallback);
    assert!(!s.in_another_turn(), "fell back: its own turn");
    let mut started = SteerReply::new("p1", true);
    let own = event("user_message", json!({"promptId": "p1", "turnId": "t3"}));
    started.heard(method::MUX_EVENT, &own);
    assert!(!started.in_another_turn(), "a steer to an idle session started its own turn");
    assert!(!SteerReply::new("p1", false).in_another_turn(), "never sent as a steer");
}

#[test]
fn a_rows_last_turn_gives_its_end_only_when_it_is_that_turn() {
    let row = |last: Value| json!({"sessionId": "s", "lastTurn": last});
    let done = row(json!({"turnId": "t1", "status": "completed", "stopReason": "end_turn"}));
    assert_eq!(last_turn_end(&done, "t1").unwrap().unwrap()["stopReason"], "end_turn");
    assert!(last_turn_end(&done, "t2").is_none(), "another turn's");
    let failed =
        row(json!({"turnId": "t1", "status": "failed", "errorText": "agent process closed"}));
    let e = last_turn_end(&failed, "t1").unwrap().unwrap_err();
    assert_eq!(e.to_string(), "agent process closed");
    assert!(last_turn_end(&json!({"sessionId": "s", "lastTurn": null}), "t1").is_none());
}

#[test]
fn any_other_answer_is_the_sends_own() {
    let mut s = SteerReply::new("p1", true);
    // codex-acp answers a steer at the turn's end; a steer taken back answers `withdrawn`.
    for stop in ["end_turn", "withdrawn", "cancelled"] {
        let answer = json!({"stopReason": stop, "_meta": {"acpmux": {"turnId": "t1"}}});
        assert_eq!(s.answered(Ok(answer.clone())).unwrap().unwrap(), answer);
    }
    assert!(s.answered(Err(anyhow!("refused"))).unwrap().is_err());
    // An older daemon's steered answer names no turn: nothing to wait for.
    let bare = json!({"stopReason": "steered"});
    assert_eq!(s.answered(Ok(bare.clone())).unwrap().unwrap(), bare);
    assert!(!s.waiting());
    // A session update is no turn's end.
    let update = json!({"sessionId": "s", "update": {"sessionUpdate": "agent_message_chunk"}});
    assert!(s.heard(method::SESSION_UPDATE, &update).is_none());
}

/// A steered turn that failed typed (`auth.signed_out` and its recovery on the turn's end)
/// fails the steer's wait with them, as the turn's own prompt does (#37541), not text only.
#[test]
fn a_typed_turn_failure_keeps_its_kind_and_recovery() {
    let msg = json!({"turnId": "t1", "status": "failed", "error": "Failed to authenticate.",
            "errorKind": "auth.signed_out", "recovery": "Sign in to Claude."});
    let (_, end) = turn_end(method::MUX_EVENT, &event("turn_result", msg)).unwrap();
    let e = end.unwrap_err();
    assert_eq!(e.to_string(), "Failed to authenticate.");
    let data = e.downcast_ref::<crate::client::DaemonError>().and_then(|d| d.0.data.clone());
    let data = data.expect("the failure keeps the turn's typed fields");
    assert_eq!(data["errorKind"], "auth.signed_out");
    assert_eq!(data["recovery"], "Sign in to Claude.");
    // An untyped failure stays text.
    let msg = json!({"turnId": "t1", "status": "failed", "error": "agent said no"});
    let (_, end) = turn_end(method::MUX_EVENT, &event("turn_result", msg)).unwrap();
    assert!(end.unwrap_err().downcast_ref::<crate::client::DaemonError>().is_none());
}

/// The same turn's typed failure read from the session row's `lastTurn` (a wait that saw
/// the end there, not as an event) keeps its kind and recovery too.
#[test]
fn a_typed_last_turn_keeps_its_kind_and_recovery() {
    let row = json!({"lastTurn": {"turnId": "t1", "status": "failed",
            "errorText": "Failed to authenticate.", "errorKind": "auth.signed_out",
            "recovery": "Sign in to Claude."}});
    let e = last_turn_end(&row, "t1").unwrap().unwrap_err();
    assert_eq!(e.to_string(), "Failed to authenticate.");
    let data = e.downcast_ref::<crate::client::DaemonError>().and_then(|d| d.0.data.clone());
    let data = data.expect("the row's failure keeps its typed fields");
    assert_eq!(data["errorKind"], "auth.signed_out");
    assert_eq!(data["recovery"], "Sign in to Claude.");
}
