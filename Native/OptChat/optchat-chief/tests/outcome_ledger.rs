//! The outcome ledger: when a subagent finishes, the person hears its outcome
//! (Lawrence 2026-10-28: "i'm still worried about chief's tenacity/persistence,
//! in acting on + following up with literally every single action i say").
//! Oct 20-27, 32% of the subagents of Lawrence's Chief (108 of 342) finished
//! with no Chief post naming them in the hour after; Austin's 25%, Leo's 33%.
//!
//! A finished subagent (not stopped by the person) waits until a Chief post
//! names it (`a1`). A turn that saw its report and ended without naming it
//! gets one retry turn on an `[untold]` note; after that it is dropped, and
//! the host never posts on the Chief's behalf.

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::{Input, UNTOLD_TAG};
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;
use serde_json::{Value, json};

/// The subagent's turn reports `REPORT`; the Chief's turns answer `chief(turn,
/// prompt)`, or the default answer when it gives None.
fn script(chief: fn(usize, &str) -> Option<&'static str>) -> Script {
    let default = default_script();
    Box::new(move |turn, blocks: &[Value]| {
        let text = serde_json::to_string(blocks).unwrap_or_default();
        let say = |t: &str| {
            vec![
                json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                update(
                    "agent_message_chunk",
                    json!({"content": {"type": "text", "text": t}}),
                ),
                json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
            ]
        };
        if text.contains("REPORT-TASK") {
            return say("Landed the sidebar fix on feat-cmux-next.");
        }
        match chief(turn, &text) {
            Some(t) => say(t),
            None => default(turn, blocks),
        }
    })
}

fn sub_session(h: &Harness) -> Option<String> {
    let inner = h.agents.inner.lock().unwrap();
    let k = inner
        .specs
        .iter()
        .position(|s| s.tags.contains_key("optchat.subagent"))?;
    let session = format!("s{}", k + 1);
    inner.prompt_sessions.contains(&session).then_some(session)
}

fn idle(session: &str) -> cmux_chief::acp::SessionSummary {
    serde_json::from_value(json!({
        "sessionId": session, "name": "a1", "status": "idle", "harness": "claude",
    }))
    .unwrap()
}

fn prompts(h: &Harness) -> Vec<String> {
    h.agents
        .inner
        .lock()
        .unwrap()
        .prompts
        .iter()
        .map(|b| serde_json::to_string(b).unwrap())
        .collect()
}

/// a1 is spawned, reports, and the Chief's turn on its report ends.
fn report_and_settle(h: &mut Harness) {
    let spawner = Arc::new(Spawner::new(
        h.chat.clone(),
        h.agents.clone(),
        SubagentSettings {
            harness: "claude".into(),
            policy: "approve-all".into(),
            model: None,
            effort: None,
            preset: Some("optchat-sub-h0me".into()),
            cwd: h.dir.path().join("subagent"),
            prefix: "optchat-sub-h0me".into(),
            parent: optchat_chief::brain::PARENT.into(),
            claude_md: None,
        },
        h.tx.clone(),
        Arc::new(|_: &str| {}),
    ));
    h.connect();
    let worker = std::thread::spawn(move || spawner.spawn(vec!["REPORT-TASK fix it".into()], None));
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut idle_sent = false;
    while !h.log().iter().any(|(_, t)| t.starts_with("[a1] ")) {
        assert!(Instant::now() < deadline, "no report: {:?}", h.log());
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
            continue;
        }
        if !idle_sent
            && worker.is_finished()
            && let Some(session) = sub_session(h)
        {
            idle_sent = true;
            h.brain
                .step(Input::from(AgentEvent::SessionChanged(idle(&session))));
        }
    }
    h.settle_posts();
}

#[test]
fn a_report_turn_that_never_names_the_subagent_gets_one_untold_retry() {
    // The Chief's turns answer without naming a1, until the retry names it.
    let mut h = Harness::new(script(|_, prompt| {
        if prompt.contains(UNTOLD_TAG) {
            Some("a1: landed the sidebar fix.")
        } else {
            None
        }
    }));
    report_and_settle(&mut h);
    assert_eq!(
        h.brain.untold_outcomes(),
        vec!["a1".to_owned()],
        "a1 waits to be told"
    );
    h.brain.fire_outcome_checks_at(u64::MAX / 2);
    h.settle_posts();
    let p = prompts(&h);
    let retry = p
        .iter()
        .find(|t| t.contains(UNTOLD_TAG))
        .expect("an untold retry turn");
    assert!(retry.contains("a1"), "{retry}");
    assert!(
        h.brain.untold_outcomes().is_empty(),
        "named in the retry: told"
    );
}

#[test]
fn a_report_turn_that_names_the_subagent_needs_no_retry() {
    let mut h = Harness::new(script(|_, prompt| {
        prompt
            .contains("[a1]")
            .then_some("a1 landed the sidebar fix.")
    }));
    report_and_settle(&mut h);
    assert!(h.brain.untold_outcomes().is_empty());
    h.brain.fire_outcome_checks_at(u64::MAX / 2);
    h.settle_posts();
    assert!(
        !prompts(&h).iter().any(|t| t.contains(UNTOLD_TAG)),
        "no retry turn"
    );
}

#[test]
fn after_one_retry_that_still_does_not_tell_it_is_dropped() {
    let mut h = Harness::new(script(|_, _| None));
    report_and_settle(&mut h);
    h.brain.fire_outcome_checks_at(u64::MAX / 2);
    h.settle_posts();
    h.brain.fire_outcome_checks_at(u64::MAX / 2);
    h.settle_posts();
    let retries = prompts(&h)
        .iter()
        .filter(|t| t.contains(UNTOLD_TAG))
        .count();
    assert_eq!(retries, 1, "one retry, never a loop");
    assert!(h.brain.untold_outcomes().is_empty());
}
