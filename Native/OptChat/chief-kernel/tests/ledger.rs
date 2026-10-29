//! The ledgers as a pure fold (cloud-chief-durable-DESIGN.md section 13,
//! export 3): `ledger_apply(state, event, ctx) -> {state, intents}`. The
//! kernel decides and the host acts: it stores the state and performs each
//! intent with its key. These are the reply ledger's and the outcome
//! ledger's rules (optchat-chief brain/reply_ledger.rs, outcome_ledger.rs),
//! with the clock in `ctx`.

use chief_kernel::ledger::ledger_apply;
use serde_json::{Value, json};

/// Applies `events` in order from an empty state at `now_ms`, each with its
/// own `at` when it names one; the last call's state and every intent.
fn run(events: &[Value]) -> (Value, Vec<Value>) {
    let mut state = "{}".to_owned();
    let mut intents = Vec::new();
    for e in events {
        let now = e.get("at").and_then(Value::as_u64).unwrap_or(1_000);
        let ctx = json!({"now_ms": now}).to_string();
        let out: Value =
            serde_json::from_str(&ledger_apply(&state, &e.to_string(), &ctx).unwrap()).unwrap();
        state = out["state"].to_string();
        intents.extend(out["intents"].as_array().unwrap().iter().cloned());
    }
    (serde_json::from_str(&state).unwrap(), intents)
}

fn kinds(intents: &[Value]) -> Vec<String> {
    intents
        .iter()
        .map(|i| i["kind"].as_str().unwrap().to_owned())
        .collect()
}

fn message(id: &str, text: &str) -> Value {
    json!({"type": "message_logged", "id": id, "seq": 1, "text": text, "from_person": true})
}

#[test]
fn a_person_message_waits_until_a_post_answers_it() {
    let (state, intents) = run(&[
        message("msg_1", "deploy it"),
        json!({"type": "turn_started", "seen": ["msg_1"]}),
        json!({"type": "reply_posted", "answers": ["msg_1"], "chief": true, "text": "Deployed."}),
    ]);
    assert!(
        state["awaiting"].as_array().is_none_or(|a| a.is_empty()),
        "{state}"
    );
    assert!(intents.is_empty(), "{intents:?}");
}

#[test]
fn a_turn_that_ends_silent_schedules_a_check_then_a_retry_note() {
    let (state, intents) = run(&[
        message("msg_1", "send me the link"),
        json!({"type": "turn_started", "seen": ["msg_1"]}),
        json!({"type": "turn_ended", "at": 2_000, "said_no_reply": false}),
    ]);
    // A check 5 s after the turn's end.
    assert_eq!(kinds(&intents), vec!["schedule"], "{intents:?}");
    assert_eq!(intents[0]["at_ms"], 7_000);
    assert!(
        intents[0]["key"]
            .as_str()
            .unwrap()
            .starts_with("reply-check-")
    );
    // The check fires with no turn running: a retry note, tries counted.
    let ctx = json!({"now_ms": 7_000}).to_string();
    let fired: Value = serde_json::from_str(
        &ledger_apply(
            &state.to_string(),
            &json!({"type": "check_due"}).to_string(),
            &ctx,
        )
        .unwrap(),
    )
    .unwrap();
    let it = fired["intents"].as_array().unwrap();
    let note = it
        .iter()
        .find(|i| i["kind"] == "notice")
        .expect("a retry note for the turn");
    let text = note["text"].as_str().unwrap();
    assert!(
        text.starts_with("[no reply]") && text.contains("send me the link"),
        "{text}"
    );
    assert_eq!(fired["state"]["awaiting"][0]["tries"], 1);
}

#[test]
fn after_the_retries_the_person_gets_a_failure_post_in_the_thread() {
    let mut state = run(&[
        message("msg_1", "deploy it"),
        json!({"type": "turn_started", "seen": ["msg_1"]}),
        json!({"type": "turn_ended", "at": 0, "said_no_reply": true}),
    ])
    .0;
    let mut last = Vec::new();
    for now in [10_000_u64, 100_000, 1_000_000, 10_000_000] {
        let ctx = json!({"now_ms": now}).to_string();
        let out: Value = serde_json::from_str(
            &ledger_apply(
                &state.to_string(),
                &json!({"type": "check_due"}).to_string(),
                &ctx,
            )
            .unwrap(),
        )
        .unwrap();
        state = out["state"].clone();
        last = out["intents"].as_array().unwrap().clone();
        // Each retry turn ends silent too.
        let ended = json!({"type": "turn_ended", "said_no_reply": true});
        state = serde_json::from_str::<Value>(
            &ledger_apply(&state.to_string(), &ended.to_string(), &ctx).unwrap(),
        )
        .unwrap()["state"]
            .clone();
    }
    let post = last
        .iter()
        .find(|i| i["kind"] == "post")
        .expect("the failure post");
    assert_eq!(post["reply_to"], "msg_1");
    assert_eq!(post["key"], "no-reply-msg_1");
    assert!(post["text"].as_str().unwrap().contains("deploy it"));
    assert!(
        state["awaiting"].as_array().is_none_or(|a| a.is_empty()),
        "{state}"
    );
}

#[test]
fn a_busy_turn_moves_the_check_later() {
    let (state, _) = run(&[
        message("msg_1", "x"),
        json!({"type": "turn_started", "seen": ["msg_1"]}),
        json!({"type": "turn_ended", "at": 0, "said_no_reply": false}),
        json!({"type": "turn_started", "seen": []}),
    ]);
    let ctx = json!({"now_ms": 5_000}).to_string();
    let out: Value = serde_json::from_str(
        &ledger_apply(
            &state.to_string(),
            &json!({"type": "check_due"}).to_string(),
            &ctx,
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(kinds(out["intents"].as_array().unwrap()), vec!["schedule"]);
    assert_eq!(out["state"]["awaiting"][0]["tries"], 0);
}

#[test]
fn a_finished_subagent_not_named_gets_one_untold_note_then_is_dropped() {
    let (state, intents) = run(&[
        json!({"type": "outcome_reported", "id": "a1", "stopped": false}),
        json!({"type": "turn_started", "seen": [], "reports": ["a1"]}),
        json!({"type": "reply_posted", "chief": true, "text": "a12 is still working"}),
        json!({"type": "turn_ended", "at": 0, "said_no_reply": false}),
    ]);
    assert!(
        kinds(&intents).contains(&"schedule".to_owned()),
        "{intents:?}"
    );
    let ctx = json!({"now_ms": 5_000}).to_string();
    let out: Value = serde_json::from_str(
        &ledger_apply(
            &state.to_string(),
            &json!({"type": "check_due"}).to_string(),
            &ctx,
        )
        .unwrap(),
    )
    .unwrap();
    let it = out["intents"].as_array().unwrap();
    let note = it
        .iter()
        .find(|i| i["kind"] == "notice")
        .expect("an untold note");
    assert!(
        note["text"].as_str().unwrap().starts_with("[untold]")
            && note["text"].as_str().unwrap().contains("a1")
    );
    // Its retry turn ends without naming a1 either: dropped, no loop.
    let ended = json!({"type": "turn_ended", "said_no_reply": false});
    let s2: Value = serde_json::from_str(
        &ledger_apply(&out["state"].to_string(), &ended.to_string(), &ctx).unwrap(),
    )
    .unwrap();
    let late = json!({"now_ms": 50_000}).to_string();
    let s3: Value = serde_json::from_str(
        &ledger_apply(
            &s2["state"].to_string(),
            &json!({"type": "check_due"}).to_string(),
            &late,
        )
        .unwrap(),
    )
    .unwrap();
    assert!(
        s3["intents"]
            .as_array()
            .unwrap()
            .iter()
            .all(|i| i["kind"] != "notice"),
        "{s3}"
    );
    assert!(
        s3["state"]["untold"]
            .as_array()
            .is_none_or(|a| a.is_empty()),
        "{s3}"
    );
}

#[test]
fn naming_a_subagent_as_a_word_tells_it_and_a12_does_not_tell_a1() {
    let (state, _) = run(&[
        json!({"type": "outcome_reported", "id": "a1", "stopped": false}),
        json!({"type": "outcome_reported", "id": "a12", "stopped": false}),
        json!({"type": "reply_posted", "chief": true, "text": "a12 landed the fix."}),
    ]);
    let left: Vec<&str> = state["untold"]
        .as_array()
        .unwrap()
        .iter()
        .map(|u| u["id"].as_str().unwrap())
        .collect();
    assert_eq!(left, vec!["a1"]);
}

#[test]
fn a_stopped_subagent_and_a_host_notice_owe_and_answer_nothing() {
    let (state, _) = run(&[
        message("msg_1", "x"),
        json!({"type": "outcome_reported", "id": "a1", "stopped": true}),
        json!({"type": "reply_posted", "chief": false, "text": "the host restarted"}),
    ]);
    assert_eq!(
        state["awaiting"].as_array().unwrap().len(),
        1,
        "a notice is no reply"
    );
    assert!(
        state["untold"].as_array().is_none_or(|a| a.is_empty()),
        "{state}"
    );
}

#[test]
fn bad_input_is_an_error() {
    let ctx = json!({"now_ms": 0}).to_string();
    assert!(ledger_apply("not json", "{}", &ctx).is_err());
    assert!(ledger_apply("{}", r#"{"type": "no_such_event"}"#, &ctx).is_err());
    assert!(
        ledger_apply("{}", r#"{"type": "check_due"}"#, "{}").is_err(),
        "now_ms is required"
    );
}

// The ask ledger (section 14 order item 1): one person message often holds
// several asks. A turn records the asks it took (`asks_taken`), each with an
// owner: a subagent id, "me" (Chief does it in the turn), or "declined" with a
// reason. An ask with no owner after its turn ends gets a retry note naming
// it. A spawn the turn asked for comes back as a keyed `spawn` intent, so the
// host starts each agent once; its report (`outcome_reported`) closes the
// asks it owns. An `ack` intent marks a message whose every ask has an owner.

fn apply(state: &Value, event: Value, now: u64) -> Value {
    let ctx = json!({"now_ms": now}).to_string();
    serde_json::from_str(&ledger_apply(&state.to_string(), &event.to_string(), &ctx).unwrap())
        .unwrap()
}

#[test]
fn a_spawn_request_becomes_one_keyed_spawn_intent_per_task() {
    let s = run(&[message("msg_1", "fix the flicker, and make tabs 28pt")]).0;
    let out = apply(
        &s,
        json!({"type": "spawn_requested", "message": "msg_1", "tasks": [
        {"ask": "fix the flicker", "task": "Title: Flicker\nfix it"},
        {"ask": "make tabs 28pt", "task": "Title: Tabs\n28pt"}]}),
        1_000,
    );
    let spawns: Vec<&Value> = out["intents"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|i| i["kind"] == "spawn")
        .collect();
    assert_eq!(spawns.len(), 2, "{out}");
    assert_eq!(spawns[0]["key"], "spawn-msg_1-0");
    assert_eq!(spawns[1]["key"], "spawn-msg_1-1");
    assert_eq!(spawns[0]["task"], "Title: Flicker\nfix it");
    // The same request again (a replayed turn) asks for nothing new.
    let again = apply(
        &out["state"],
        json!({"type": "spawn_requested", "message": "msg_1", "tasks": [
        {"ask": "fix the flicker", "task": "Title: Flicker\nfix it"},
        {"ask": "make tabs 28pt", "task": "Title: Tabs\n28pt"}]}),
        1_100,
    );
    assert!(
        again["intents"]
            .as_array()
            .unwrap()
            .iter()
            .all(|i| i["kind"] != "spawn"),
        "{again}"
    );
}

#[test]
fn a_spawn_started_gives_its_ask_an_owner_and_its_report_closes_it() {
    let s = run(&[message("msg_1", "fix the flicker")]).0;
    let s = apply(&s, json!({"type": "spawn_requested", "message": "msg_1", "tasks": [{"ask": "fix the flicker", "task": "t"}]}), 1_000)["state"].clone();
    let s = apply(
        &s,
        json!({"type": "spawn_started", "key": "spawn-msg_1-0", "id": "a7"}),
        1_200,
    )["state"]
        .clone();
    assert_eq!(s["asks"][0]["owner"], "a7", "{s}");
    let s = apply(
        &s,
        json!({"type": "outcome_reported", "id": "a7", "stopped": false}),
        2_000,
    )["state"]
        .clone();
    assert_eq!(s["asks"][0]["done"], true, "{s}");
}

#[test]
fn an_ask_with_no_owner_after_the_turn_gets_a_retry_note() {
    let s = run(&[message(
        "msg_1",
        "fix the flicker, also add a dock icon setting",
    )])
    .0;
    let s = apply(
        &s,
        json!({"type": "turn_started", "seen": ["msg_1"]}),
        1_000,
    )["state"]
        .clone();
    let s = apply(
        &s,
        json!({"type": "asks_taken", "message": "msg_1", "asks": [
        {"ask": "fix the flicker", "owner": "a7"},
        {"ask": "add a dock icon setting"}]}),
        1_500,
    )["state"]
        .clone();
    let s = apply(&s, json!({"type": "reply_posted", "chief": true, "answers": ["msg_1"], "text": "a7 fixes the flicker."}), 1_600)["state"].clone();
    let ended = apply(
        &s,
        json!({"type": "turn_ended", "said_no_reply": false}),
        2_000,
    );
    assert!(
        ended["intents"]
            .as_array()
            .unwrap()
            .iter()
            .any(|i| i["kind"] == "schedule"),
        "{ended}"
    );
    let fired = apply(&ended["state"], json!({"type": "check_due"}), 10_000);
    let note = fired["intents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["kind"] == "notice")
        .expect("an unowned-ask note");
    let text = note["text"].as_str().unwrap();
    assert!(
        text.starts_with("[unowned]") && text.contains("dock icon"),
        "{text}"
    );
    assert!(
        !text.contains("flicker"),
        "an owned ask is not named: {text}"
    );
}

#[test]
fn every_ask_owned_acks_the_message_and_declined_counts_as_owned() {
    let s = run(&[message("msg_1", "two things")]).0;
    let out = apply(
        &s,
        json!({"type": "asks_taken", "message": "msg_1", "asks": [
        {"ask": "rename the button", "owner": "me"},
        {"ask": "buy the domain", "owner": "declined", "reason": "money: needs the person's word"}]}),
        1_000,
    );
    let ack = out["intents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["kind"] == "ack")
        .expect("an ack");
    assert_eq!(ack["message"], "msg_1");
    assert_eq!(ack["key"], "ack-msg_1");
    let ended = apply(
        &out["state"],
        json!({"type": "turn_ended", "said_no_reply": false}),
        2_000,
    );
    let fired = apply(&ended["state"], json!({"type": "check_due"}), 60_000);
    assert!(
        fired["intents"]
            .as_array()
            .unwrap()
            .iter()
            .all(|i| !i["text"].as_str().unwrap_or("").starts_with("[unowned]")),
        "{fired}"
    );
}
