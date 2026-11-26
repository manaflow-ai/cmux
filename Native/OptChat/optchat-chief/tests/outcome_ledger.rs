//! The outcome ledger: when a subagent finishes, the person hears its outcome
//! (Lawrence 2026-10-28: "i'm still worried about chief's tenacity/persistence,
//! in acting on + following up with literally every single action i say").
//! Oct 20-27, 32% of the subagents of Lawrence's Chief (108 of 342) finished
//! with no Chief post naming them in the hour after; Austin's 25%, Leo's 33%.
//!
//! A finished subagent (not stopped by the person) waits until a Chief post
//! names it (`a1`). A turn that saw its report and ended without naming it
//! gets one retry turn on an `[untold]` note; after that it is dropped. A
//! mechanical result (final, no open question or decision) is host-posted
//! once its window passes instead (Lucas's latency plan, item 3): no
//! `[untold]` Chief turn relays it.

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::auto_resume::ResumePolicy;
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
        // The subagent's own prompt (a Chief turn names the task too, in `<open-items>`).
        if text.contains("REPORT-TASK") && !text.contains("<open-items>") {
            return say("Landed the sidebar fix on feat-cmux-next.");
        }
        // A judgment report (an open question) keeps the model turn: it is
        // never host-posted, so it waits untold for the Chief.
        if text.contains("REPORT-QUESTION") && !text.contains("<open-items>") {
            return say("Blocked: should I keep the old sidebar? Need you to decide.");
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

fn running(session: &str) -> cmux_chief::acp::SessionSummary {
    serde_json::from_value(json!({
        "sessionId": session, "name": "a1", "status": "running", "harness": "claude",
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
/// Whether the host posted a1's result to the chat itself.
fn host_posted(h: &Harness) -> bool {
    h.owner
        .lock()
        .unwrap()
        .sends()
        .iter()
        .any(|(key, text)| key == "host-outcome:a1" && text.starts_with("[a1] "))
}

fn report_and_settle(h: &mut Harness) -> Arc<Spawner> {
    report_task(h, "REPORT-TASK fix it")
}

/// As [`report_and_settle`], with the subagent's task `task` (its report
/// follows the marker it names: REPORT-TASK or REPORT-QUESTION).
fn report_task(h: &mut Harness, task: &str) -> Arc<Spawner> {
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
    let sp = spawner.clone();
    let task = task.to_owned();
    let worker = std::thread::spawn(move || sp.spawn(vec![task], None));
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
    spawner
}

#[test]
fn a_report_turn_that_never_names_the_subagent_gets_one_untold_retry() {
    // A question keeps the model turn. The Chief's turns answer without
    // naming a1, until the retry names it.
    let mut h = Harness::new(script(|_, prompt| {
        if prompt.contains(UNTOLD_TAG) {
            Some("a1: asks whether to keep the old sidebar.")
        } else {
            None
        }
    }));
    report_task(&mut h, "REPORT-QUESTION fix it");
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
fn a_late_empty_report_after_a_told_outcome_does_not_reopen_it() {
    let mut h = Harness::new(script(|_, prompt| {
        prompt
            .contains("[a1]")
            .then_some("a1 landed the sidebar fix.")
    }));
    report_and_settle(&mut h);
    assert!(
        h.brain.untold_outcomes().is_empty(),
        "the first outcome was told"
    );
    let session = sub_session(&h).expect("the subagent session");
    let before = h.brain.state().sub("a1").unwrap().1.clone();
    let prompts_before = prompts(&h).len();
    assert!(
        before.told_ms >= before.reported_ms,
        "the setup must record a told outcome: {before:?}"
    );

    h.agents.append_events(
        &session,
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
        ],
    );
    h.brain
        .step(Input::from(AgentEvent::SessionChanged(running(&session))));
    h.brain
        .step(Input::from(AgentEvent::SessionChanged(idle(&session))));

    assert!(
        h.brain.untold_outcomes().is_empty(),
        "an empty late report is not a new outcome"
    );
    let after = h.brain.state().sub("a1").unwrap().1;
    assert_eq!(after.report, before.report, "keep the told report");
    assert_eq!(
        after.reported_ms, before.reported_ms,
        "keep its report time"
    );
    assert!(after.told_ms >= after.reported_ms, "the outcome stays told");
    assert_eq!(after.last_report, before.last_report);
    assert!(after.floor > before.floor, "consume the empty turn");
    h.brain
        .step(Input::from(AgentEvent::Up(vec![idle(&session)])));
    assert!(h.brain.untold_outcomes().is_empty(), "reconnect cannot redeliver it");
    h.brain.fire_outcome_checks_at(u64::MAX / 2);
    h.settle_posts();
    assert_eq!(prompts(&h).len(), prompts_before, "no report or untold turn");
}

#[test]
fn a_late_retry_exhaustion_notice_after_a_told_outcome_does_not_reopen_it() {
    let mut h = Harness::new(script(|_, prompt| {
        prompt
            .contains("[a1]")
            .then_some("a1 landed the sidebar fix.")
    }));
    report_and_settle(&mut h);
    let session = sub_session(&h).expect("the subagent session");
    let before = h.brain.state().sub("a1").unwrap().1.clone();
    let prompts_before = prompts(&h).len();
    assert!(
        before.told_ms >= before.reported_ms,
        "the setup must record a told outcome"
    );
    h.brain.set_auto_resume(
        Some(ResumePolicy {
            max_attempts: 0,
            ..ResumePolicy::default()
        }),
        None,
    );

    h.agents.append_events(
        &session,
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": "(turn failed: API Error: 500)"}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
        ],
    );
    h.brain
        .step(Input::from(AgentEvent::SessionChanged(running(&session))));
    h.brain
        .step(Input::from(AgentEvent::SessionChanged(idle(&session))));

    assert!(
        h.brain.untold_outcomes().is_empty(),
        "a late exhausted-retry notice is not a new outcome"
    );
    let after = h.brain.state().sub("a1").unwrap().1;
    assert_eq!(after.report, before.report, "keep the told report");
    assert_eq!(
        after.reported_ms, before.reported_ms,
        "keep its report time"
    );
    assert!(after.told_ms >= after.reported_ms, "the outcome stays told");
    h.brain
        .step(Input::from(AgentEvent::Up(vec![idle(&session)])));
    assert!(h.brain.untold_outcomes().is_empty(), "reconnect cannot redeliver it");
    h.brain.fire_outcome_checks_at(u64::MAX / 2);
    h.settle_posts();
    assert_eq!(prompts(&h).len(), prompts_before, "no report or untold turn");
}

#[test]
fn a_new_user_task_after_a_told_outcome_still_reports_retry_exhaustion() {
    let mut harness = Harness::new(script(|_, prompt| {
        prompt.contains("[a1]").then_some("a1 landed the sidebar fix.")
    }));
    report_and_settle(&mut harness);
    let session = sub_session(&harness).unwrap();
    harness.brain.set_auto_resume(
        Some(ResumePolicy { max_attempts: 0, ..ResumePolicy::default() }),
        None,
    );
    harness.agents.append_events(&session, vec![
        json!({"dir": "mux", "kind": "user_message", "msg": {"text": "Do the next task", "promptId": "person-next"}}),
        json!({"dir": "mux", "kind": "turn_started", "msg": {"promptId": "person-next", "persons": true}}),
        json!({"dir": "mux", "kind": "turn_error", "msg": {"error": "API Error: 500"}}),
    ]);
    harness.brain.step(Input::from(AgentEvent::SessionChanged(running(&session))));
    harness.brain.step(Input::from(AgentEvent::SessionChanged(idle(&session))));
    assert_eq!(harness.brain.untold_outcomes(), vec!["a1"]);
    assert!(harness.brain.state().sub("a1").unwrap().1.last_report.contains("retries are exhausted"));
}

#[test]
fn after_one_retry_that_still_does_not_tell_it_is_dropped() {
    let mut h = Harness::new(script(|_, _| None));
    report_task(&mut h, "REPORT-QUESTION fix it");
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

#[test]
fn a_subagent_sent_back_to_work_is_not_untold() {
    // Persona replay (Oct 28): a report that finished nothing ("tests still
    // queued") got a restart or a tell from Chief, and the [untold] retry then
    // pushed a ping the person did not want ("this ping is noise"). An agent
    // that runs again reports again; that report is the one to tell.
    let mut h = Harness::new(script(|_, _| None));
    let spawner = report_task(&mut h, "REPORT-QUESTION fix it");
    assert_eq!(h.brain.untold_outcomes(), vec!["a1".to_owned()]);
    let worker = std::thread::spawn(move || spawner.tell("a1", "finish the fleet runs and land"));
    let deadline = Instant::now() + Duration::from_secs(20);
    while !worker.is_finished() {
        assert!(Instant::now() < deadline, "tell did not answer");
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
    }
    assert!(worker.join().unwrap().is_ok());
    assert!(
        h.brain.untold_outcomes().is_empty(),
        "a1 runs again: its next report is the one to tell"
    );
    h.brain.fire_outcome_checks_at(u64::MAX / 2);
    h.settle_posts();
    assert!(
        !prompts(&h).iter().any(|t| t.contains(UNTOLD_TAG)),
        "no untold retry turn"
    );
}

/// Leo, 2026-11-02: one forced `[untold]` turn per finished subagent (22 in
/// four days) made Chief post one status message per report. The check waits
/// a batching window, so outcomes that finish close together go out as one
/// digest turn, and the note asks for one message.
#[test]
fn untold_checks_wait_a_batching_window_and_ask_for_one_digest() {
    assert!(
        optchat_chief::brain::UNTOLD_WAIT >= Duration::from_secs(60),
        "a window, not 5 s"
    );
    let mut h = Harness::new(script(|_, prompt| {
        if prompt.contains(UNTOLD_TAG) {
            Some("a1: asks whether to keep the old sidebar.")
        } else {
            None
        }
    }));
    report_task(&mut h, "REPORT-QUESTION fix it");
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;
    h.brain.fire_outcome_checks_at(now + 10_000);
    h.settle_posts();
    assert!(
        !prompts(&h).iter().any(|t| t.contains(UNTOLD_TAG)),
        "no retry turn 10 s after the report"
    );
    h.brain.fire_outcome_checks_at(u64::MAX / 2);
    h.settle_posts();
    let p = prompts(&h);
    let retry = p
        .iter()
        .find(|t| t.contains(UNTOLD_TAG))
        .expect("an untold retry turn once the window passed");
    assert!(retry.contains("one message"), "a digest: {retry}");
}

/// A final report the Chief's turn did not name is host-posted once its
/// batching window passes, not relayed by an `[untold]` turn. The Chief's
/// next turn is told in its log that the host posted it, so the Chief sees
/// the result without a repost.
#[test]
fn a_host_posted_result_shows_in_the_chiefs_next_turn() {
    let mut h = Harness::new(script(|_, _| None));
    report_and_settle(&mut h);
    assert_eq!(h.brain.untold_outcomes(), vec!["a1".to_owned()]);
    h.brain.fire_outcome_checks_at(u64::MAX / 2);
    h.settle_posts();
    assert!(host_posted(&h), "the host posted the result to the chat");
    assert!(
        h.brain.untold_outcomes().is_empty(),
        "host-posted: nothing waits for the Chief"
    );
    assert!(
        !prompts(&h).iter().any(|t| t.contains(UNTOLD_TAG)),
        "no [untold] turn spent relaying it"
    );
    h.say("user_local", "what happened to the sidebar?");
    h.settle();
    let turns = prompts(&h);
    let next = turns
        .iter()
        .rev()
        .find(|t| t.contains("what happened to the sidebar"))
        .expect("the person's turn");
    assert!(
        next.contains("host posted subagent a1's result; it is in the Chief log"),
        "the next turn is told the result was posted: {next}"
    );
}

/// A judgment report (an open question) is never host-posted: the Chief's
/// turn answers it, so the chat gets no `[a1]` post from the host.
#[test]
fn a_judgment_report_is_not_host_posted() {
    let mut h = Harness::new(script(|_, _| None));
    report_task(&mut h, "REPORT-QUESTION fix it");
    assert!(!host_posted(&h), "no host post for a question");
    assert_eq!(h.brain.untold_outcomes(), vec!["a1".to_owned()]);
}
