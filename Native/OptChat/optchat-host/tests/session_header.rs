//! Raw Messages API callers name their conversation to the team gateway
//! (`X-Subrouter-Session`), so the gateway keeps it on one account and its
//! prompt cache keeps hitting (Oct 29: without a session id, 5-18 of 70 later
//! Chief turns per run were sent to another account and re-wrote their whole
//! prefix).

use optchat_host::{session_key, SESSION_HEADER};
use serde_json::json;

fn body(system: &str, first: &str, more: bool) -> serde_json::Value {
    let mut messages = vec![json!({"role": "user", "content": first})];
    if more {
        messages.push(json!({"role": "assistant", "content": "ok"}));
        messages.push(json!({"role": "user", "content": "next"}));
    }
    json!({"model": "m", "system": [{"type": "text", "text": system}], "messages": messages})
}

#[test]
fn the_header_is_the_gateways_session_header() {
    assert_eq!(SESSION_HEADER, "x-subrouter-session");
}

#[test]
fn a_chief_keeps_one_key_across_its_turns() {
    // Every turn of one Chief has the same system prompt; its first message
    // (the view and the delta) changes each turn.
    let a = session_key(
        "chief",
        &body("You are Chief.", "turn 1 view", false),
        false,
    );
    let b = session_key("chief", &body("You are Chief.", "turn 2 view", true), false);
    assert_eq!(a, b);
    assert!(a.starts_with("optchat-chief-"), "{a}");
}

#[test]
fn a_conversation_key_keeps_one_conversation_and_splits_others() {
    let a1 = session_key("eval", &body("You are Chief.", "case A", false), true);
    let a2 = session_key("eval", &body("You are Chief.", "case A", true), true);
    let b = session_key("eval", &body("You are Chief.", "case B", false), true);
    assert_eq!(a1, a2, "later requests of one conversation");
    assert_ne!(a1, b, "parallel conversations spread");
}

#[test]
fn another_chief_or_scope_gets_another_key() {
    let a = session_key(
        "chief",
        &body("You are Chief for Lawrence.", "x", false),
        false,
    );
    let b = session_key("chief", &body("You are Chief for Leo.", "x", false), false);
    let c = session_key(
        "compactor",
        &body("You are Chief for Lawrence.", "x", false),
        false,
    );
    assert_ne!(a, b);
    assert_ne!(a, c);
}
