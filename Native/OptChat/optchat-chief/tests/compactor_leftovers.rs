//! A Chief host ends the closed compactor sessions it finds when it
//! connects (2026-10-20: `acpmux ls` listed about 450 closed
//! `optchat-compact-*` sessions, one turn each, that an older acpmux had
//! loaded back after their purge). It never ends a live compactor session, a
//! turn session or another Chief's.

mod common;

use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::Input;
use serde_json::json;

fn row(id: &str, status: &str, chief: &str, role: &str) -> cmux_chief::acp::SessionSummary {
    serde_json::from_value(json!({
        "sessionId": id, "name": format!("optchat-compact-{chief}-{id}"), "status": status,
        "harness": "claude", "tags": {"cmux.chief": chief, "cmux.chief.role": role}
    }))
    .unwrap()
}

#[test]
fn connecting_ends_only_this_chiefs_closed_compactor_sessions() {
    let mut h = Harness::new(default_script());
    // `common::settings` names this Chief `h0me`.
    h.brain.step(Input::from(AgentEvent::Up(vec![
        row("left-1", "closed", "h0me", "compactor"),
        row("left-2", "closed", "h0me", "compactor"),
        row("live", "idle", "h0me", "compactor"),
        row("busy", "running", "h0me", "compactor"),
        row("turn", "closed", "h0me", "turn"),
        row("other", "closed", "0ther", "compactor"),
    ])));
    let ended = h.agents.inner.lock().unwrap().ended.clone();
    assert_eq!(ended, vec!["left-1".to_owned(), "left-2".to_owned()]);
}
