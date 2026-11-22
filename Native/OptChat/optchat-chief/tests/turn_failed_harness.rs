//! A failed turn's message names the harness that ran it (2026-10-08: the
//! Chief on cmux-lawrence posted "(turn failed: agent process closed
//! (claude): No conversation found ...)" while its settings said codex, and
//! nothing said that the turn had run on claude-sr and its fallback). The
//! text names the profile acpmux ran the turn on, and the harness it stood
//! in for when acpmux moved the session onto a fallback.

mod common;

use common::*;
use serde_json::json;

fn failing(error: &'static str) -> Script {
    Box::new(move |_, _| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            json!({"dir": "mux", "kind": "turn_error", "msg": {"error": error}}),
        ]
    })
}

#[test]
fn a_failed_turn_names_its_harness() {
    let mut h = Harness::new(failing("boom"));
    h.agents.inner.lock().unwrap().catalog = Some(catalog());
    h.connect();
    h.say("user_local", "hi");
    h.settle();
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(
        sends.last().unwrap().1,
        "(turn failed on claude-sr: boom)",
        "{sends:?}"
    );
}

#[test]
fn a_failed_turn_on_a_fallback_names_both_harnesses() {
    let mut h = Harness::new(failing(
        "agent process closed (claude): No conversation found with session ID: x",
    ));
    {
        let mut inner = h.agents.inner.lock().unwrap();
        inner.catalog = Some(catalog());
        // acpmux moved the session onto claude-sr's fallback profile.
        inner.session_harness = Some("claude".into());
    }
    h.connect();
    h.say("user_local", "can u make some subagents");
    h.settle();
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(
        sends.last().unwrap().1,
        "(turn failed on claude (fallback for claude-sr): agent process closed (claude): No conversation found with session ID: x)",
        "{sends:?}"
    );
}
