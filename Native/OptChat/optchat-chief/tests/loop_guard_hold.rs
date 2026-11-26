//! While the conversation's loop guard refuses the Chief's messages
//! (`agent_budget`: six agent messages since the person last wrote), the host
//! does not ask the Chief to tell anything: it cannot post.
//!
//! Lawrence's Chief, 2026-11-21: after the guard closed the thread, every
//! subagent report still cost the Chief a refused `send`, a refused `stop`
//! ("landed work it has not told") and then a host `[untold] ... Tell the
//! person now` turn whose sends were refused again, dozens of times, all
//! posting nothing. A `[no text]` note after a spawn turn did the same.
//!
//! Now, while the guard holds: `stop` and `sleep` go through, and the
//! `[untold]` and `[no text]` notes wait. The person's next message ends the
//! hold, and its turn carries what is owed, so the answer tells it.

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::{Input, NO_TEXT_TAG, UNTOLD_TAG};
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{Orchestrator, SendCall, SleepCall};
use serde_json::{Value, json};

/// The subagent's turn reports `report`; the Chief's turns say `chief`
/// ("" says nothing).
fn script(report: &'static str, chief: &'static str) -> Script {
    Box::new(move |_, blocks: &[Value]| {
        let text = serde_json::to_string(blocks).unwrap_or_default();
        let say = if (text.contains("REPORT-TASK") || text.contains("SUB-TASK"))
            && !text.contains("<open-items>")
        {
            report
        } else {
            chief
        };
        let mut events = vec![json!({"dir": "mux", "kind": "turn_started", "msg": {}})];
        if !say.is_empty() {
            events.push(update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": say}}),
            ));
        }
        events.push(json!({"dir": "mux", "kind": "turn_end", "msg": {}}));
        events
    })
}

fn spawner(h: &Harness) -> Arc<Spawner> {
    Arc::new(Spawner::new(
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
    ))
}

/// Runs `f` on its own thread while the brain takes its inputs.
fn run<T: Send + 'static>(h: &mut Harness, f: impl FnOnce() -> T + Send + 'static) -> T {
    let worker = std::thread::spawn(f);
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    worker.join().unwrap()
}

/// The Chief's prompts (not its subagents'), in order.
fn chief_prompts(h: &Harness) -> Vec<String> {
    h.agents
        .inner
        .lock()
        .unwrap()
        .prompts
        .iter()
        .map(|b| serde_json::to_string(b).unwrap())
        .filter(|p| {
            !(p.contains("REPORT-TASK") || p.contains("SUB-TASK")) || p.contains("<open-items>")
        })
        .collect()
}

/// The guard refuses every agent message from now until `open_guard`.
fn close_guard(h: &Harness) {
    let mut owner = h.owner.lock().unwrap();
    owner.rejects.clear();
    owner
        .rejects
        .extend(std::iter::repeat_n(Some("agent_budget".to_owned()), 50));
}

fn open_guard(h: &Harness) {
    h.owner.lock().unwrap().rejects.clear();
}

fn send(text: &str) -> SendCall {
    SendCall {
        text: Some(text.to_owned()),
        ..SendCall::default()
    }
}

fn sleep_call() -> SleepCall {
    SleepCall {
        seconds: 1800,
        note: Some("check the others".into()),
        until: Some("event".into()),
    }
}

/// Steps the brain until `done` holds or 10 s pass.
fn settle_until(h: &mut Harness, done: impl Fn(&Harness) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !done(h) && Instant::now() < deadline {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
    }
    h.settle_posts();
}

/// a1 is spawned and reports `report`. With `hold`, the Chief's turn on the
/// report runs and is held at the fake agent; else it runs to its end.
fn report(h: &mut Harness, hold: bool) {
    h.agents.hold(hold);
    h.connect();
    let sp = spawner(h);
    let worker = std::thread::spawn(move || sp.spawn(vec!["REPORT-TASK fix it".into()], None));
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut idle_sent = false;
    loop {
        let in_turn = chief_prompts(h).iter().any(|p| p.contains("[a1]"));
        if in_turn {
            break;
        }
        assert!(Instant::now() < deadline, "no report turn: {:?}", h.log());
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
            continue;
        }
        if !idle_sent && worker.is_finished() {
            let session = {
                let inner = h.agents.inner.lock().unwrap();
                inner
                    .specs
                    .iter()
                    .position(|s| s.tags.contains_key("optchat.subagent"))
                    .map(|k| format!("s{}", k + 1))
            };
            if let Some(session) = session {
                idle_sent = true;
                let idle: cmux_chief::acp::SessionSummary = serde_json::from_value(json!({
                    "sessionId": session, "name": "a1", "status": "idle", "harness": "claude",
                }))
                .unwrap();
                h.brain.step(Input::from(AgentEvent::SessionChanged(idle)));
            }
        }
    }
    if !hold {
        h.settle_posts();
    }
}

const LANDED: &str = "Landed 1a2b3c4d..5e6f7a8b on feat-cmux-next; tests green.";

#[test]
fn stop_and_sleep_go_through_while_the_loop_guard_refuses_sends() {
    for tool in ["stop", "sleep"] {
        let mut h = Harness::new(script(LANDED, ""));
        report(&mut h, true);
        close_guard(&h);
        let sp = spawner(&h);
        let refused = run(&mut h, move || {
            sp.send(send("a1 landed the fix: 1a2b3c4d..5e6f7a8b."))
        })
        .expect_err("the guard refuses the send");
        assert!(refused.contains("agent_budget"), "{refused}");
        let sp = spawner(&h);
        let answer = run(&mut h, move || {
            if tool == "stop" {
                sp.stop_turn()
            } else {
                sp.sleep(sleep_call())
            }
        })
        .unwrap_or_else(|e| panic!("{tool} must go through while the guard refuses: {e}"));
        assert!(answer.starts_with("outcome: done"), "{tool}: {answer}");
        h.agents.hold(false);
        h.agents.release();
        h.settle_posts();
    }
}

#[test]
fn the_landed_refusal_comes_back_once_the_guard_lets_sends_through() {
    // The guard held in an earlier turn; a send the owner takes ends the
    // hold, and the stop guard asks for the landed range again.
    let mut h = Harness::new(script(LANDED, ""));
    report(&mut h, true);
    close_guard(&h);
    let sp = spawner(&h);
    run(&mut h, move || sp.send(send("Checking the fleet."))).expect_err("refused");
    open_guard(&h);
    let sp = spawner(&h);
    run(&mut h, move || sp.send(send("Fleet is green."))).expect("the owner takes it");
    let sp = spawner(&h);
    let refused = run(&mut h, move || sp.stop_turn()).expect_err("the hold ended");
    assert!(refused.contains("a1"), "{refused}");
    h.agents.hold(false);
    h.agents.release();
    h.settle_posts();
}

#[test]
fn untold_waits_while_the_guard_refuses_and_rides_on_the_person_s_next_message() {
    let mut h = Harness::new(script(LANDED, "Checking."));
    close_guard(&h);
    report(&mut h, false);
    assert_eq!(
        h.brain.untold_outcomes(),
        vec!["a1".to_owned()],
        "the report turn's reply was refused: a1 is still owed"
    );
    for _ in 0..3 {
        h.brain.fire_outcome_checks_at(u64::MAX / 2);
        h.settle_posts();
    }
    let p = chief_prompts(&h);
    assert!(
        !p.iter().any(|t| t.contains(UNTOLD_TAG)),
        "no [untold] turn while the guard refuses sends: {p:?}"
    );
    assert_eq!(
        h.brain.untold_outcomes(),
        vec!["a1".to_owned()],
        "held, not dropped"
    );
    // The person writes: the guard opens, and their turn carries a1.
    open_guard(&h);
    h.say("user_local", "how is it going?");
    settle_until(&mut h, |h| {
        chief_prompts(h)
            .iter()
            .any(|p| p.contains("how is it going?"))
    });
    let p = chief_prompts(&h);
    let turn = p
        .iter()
        .find(|t| t.contains("how is it going?"))
        .expect("the person's turn");
    assert!(
        turn.contains("loop guard") && turn.contains("a1"),
        "the person's turn says what is owed: {turn}"
    );
}

#[test]
fn a_silent_spawn_turn_under_the_guard_gets_no_note_until_the_person_writes() {
    let mut h = Harness::new(script("done", ""));
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "start the fix");
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
    let sp = spawner(&h);
    let started = run(&mut h, move || {
        sp.spawn(vec!["Title: Fix it\n\nSUB-TASK fix it".into()], None)
    });
    assert!(started.is_ok(), "{started:?}");
    close_guard(&h);
    let sp = spawner(&h);
    run(&mut h, move || sp.send(send("Started a1 on the fix."))).expect_err("refused");
    h.agents.hold(false);
    h.agents.release();
    settle_until(&mut h, |_| false);
    let p = chief_prompts(&h);
    assert!(
        !p.iter().any(|t| t.contains(NO_TEXT_TAG)),
        "no [no text] turn while the guard refuses sends: {p:?}"
    );
    open_guard(&h);
    h.say("user_local", "anything new?");
    settle_until(&mut h, |h| {
        chief_prompts(h).iter().any(|p| p.contains("anything new?"))
    });
    let p = chief_prompts(&h);
    let turn = p
        .iter()
        .find(|t| t.contains("anything new?"))
        .expect("the person's turn");
    assert!(
        turn.contains("loop guard") && turn.contains("a1"),
        "the person's turn names the unannounced start: {turn}"
    );
    settle_until(&mut h, |_| false);
    assert!(
        !chief_prompts(&h).iter().any(|t| t.contains(NO_TEXT_TAG)),
        "and no [no text] turn after it"
    );
}

/// The guard's refusal can come after the turn ended: a send the owner held
/// back (`agent_rate`) answers "queued", so the silent spawn turn queues its
/// `[no text]` note, and the outbox retry is refused (`agent_budget`) while
/// that note still waits for its turn. The note is dropped and its ids wait
/// for the person, like a note the hold kept from being queued.
#[test]
fn a_no_text_note_already_queued_when_the_guard_refuses_is_held_too() {
    let dir = tempfile::tempdir().unwrap();
    let lines = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
    let sink = lines.clone();
    let settings = optchat_chief::brain::Settings {
        // Long enough that the retry comes after the turn ended.
        agent_gap: Duration::from_millis(400),
        ..common::settings(dir.path())
    };
    let owner = Arc::new(std::sync::Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let mut h = Harness::configured(
        dir,
        script("done", ""),
        owner,
        settings,
        Arc::new(move |l: &str| sink.lock().unwrap().push(l.to_owned())),
    );
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "start the fix");
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
    let sp = spawner(&h);
    let started = run(&mut h, move || {
        sp.spawn(vec!["Title: Fix it\n\nSUB-TASK fix it".into()], None)
    });
    assert!(started.is_ok(), "{started:?}");
    {
        let mut owner = h.owner.lock().unwrap();
        owner.rejects.clear();
        owner.rejects.push_back(Some("agent_rate".into()));
        owner
            .rejects
            .extend(std::iter::repeat_n(Some("agent_budget".to_owned()), 50));
    }
    let sp = spawner(&h);
    let queued = run(&mut h, move || sp.send(send("Started a1 on the fix.")))
        .expect("held back, not refused yet");
    assert!(queued.starts_with("outcome: queued"), "{queued}");
    h.agents.hold(false);
    h.agents.release();
    // Step only until the turn ended and queued its note: the note's turn
    // has not started when the retry is refused.
    let noted = |lines: &std::sync::Mutex<Vec<String>>| {
        lines
            .lock()
            .unwrap()
            .iter()
            .any(|l| l.contains(NO_TEXT_TAG) && l.contains("queuing"))
    };
    let deadline = Instant::now() + Duration::from_secs(10);
    while !noted(&lines) {
        assert!(
            Instant::now() < deadline,
            "no note: {:?}",
            lines.lock().unwrap()
        );
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(5)) {
            h.brain.step(input);
        }
    }
    let at = h.brain.next_timer().expect("the outbox retry is armed");
    std::thread::sleep(at.saturating_duration_since(Instant::now()));
    h.brain.on_timer();
    settle_until(&mut h, |_| false);
    let p = chief_prompts(&h);
    assert!(
        !p.iter().any(|t| t.contains(NO_TEXT_TAG)),
        "the queued [no text] note was dropped under the guard: {p:?}"
    );
    open_guard(&h);
    h.say("user_local", "anything new?");
    settle_until(&mut h, |h| {
        chief_prompts(h).iter().any(|p| p.contains("anything new?"))
    });
    let p = chief_prompts(&h);
    let turn = p
        .iter()
        .find(|t| t.contains("anything new?"))
        .expect("the person's turn");
    assert!(
        turn.contains("loop guard") && turn.contains("a1"),
        "the person's turn names the unannounced start: {turn}"
    );
}

/// A second agent in the Chief conversation: the owner's per-thread cap
/// applies (`cmux_conversation` budget: two or more agents).
fn with_second_agent(h: &Harness) {
    let mut owner = h.owner.lock().unwrap();
    let summary = owner.summary.as_mut().unwrap();
    summary.participants.push(cmux_conversation::Participant {
        id: "agent_other".into(),
        kind: cmux_conversation::ParticipantKind::Agent,
        display_name: "Other Chief".into(),
        agent_class: None,
        acp_session: None,
        person: None,
    });
}

/// Lawrence's Chief, 2026-11-22: a1212 finished again and again while the
/// guard already refused the Chief's messages; each report got an
/// `[untold]` turn and a refused `stop`, before any send of the host's own
/// was refused in that run (a host that starts with the guard closed, after
/// an update). The host reads the guard's count from the conversation (the
/// owner's `thread_agent_streak` rule), so the hold starts before a refusal.
#[test]
fn a_guard_already_at_its_budget_when_the_host_starts_holds_without_a_refusal() {
    let mut h = Harness::new(script(LANDED, ""));
    with_second_agent(&h);
    {
        let mut owner = h.owner.lock().unwrap();
        owner.messages.push(message(1, "user_local", "keep going"));
        for seq in 2..=7 {
            let author = if seq % 2 == 0 {
                "agent_mux"
            } else {
                "agent_other"
            };
            owner.messages.push(message(seq, author, "status"));
        }
        owner
            .summary
            .as_mut()
            .unwrap()
            .read_cursors
            .insert("agent_mux".into(), 7);
    }
    close_guard(&h);
    report(&mut h, true);
    let sp = spawner(&h);
    let answer = run(&mut h, move || sp.stop_turn())
        .unwrap_or_else(|e| panic!("stop must go through at once: {e}"));
    assert!(answer.starts_with("outcome: done"), "{answer}");
    h.agents.hold(false);
    h.agents.release();
    h.settle_posts();
    for _ in 0..3 {
        h.brain.fire_outcome_checks_at(u64::MAX / 2);
        h.settle_posts();
    }
    let p = chief_prompts(&h);
    assert!(
        !p.iter().any(|t| t.contains(UNTOLD_TAG)),
        "no [untold] turn: {p:?}"
    );
    assert_eq!(h.brain.untold_outcomes(), vec!["a1".to_owned()], "held");
}

/// The same, with the guard's count reached live: six agent texts arrive
/// after the person's last one.
#[test]
fn six_agent_texts_since_the_person_wrote_start_the_hold_live() {
    let mut h = Harness::new(script(LANDED, ""));
    with_second_agent(&h);
    h.connect();
    h.say("user_local", "keep going");
    settle_until(&mut h, |h| !chief_prompts(h).is_empty());
    for _ in 0..6 {
        h.say("agent_other", "status");
    }
    close_guard(&h);
    report(&mut h, true);
    let sp = spawner(&h);
    let answer = run(&mut h, move || sp.stop_turn())
        .unwrap_or_else(|e| panic!("stop must go through at once: {e}"));
    assert!(answer.starts_with("outcome: done"), "{answer}");
    h.agents.hold(false);
    h.agents.release();
    h.settle_posts();
    h.brain.fire_outcome_checks_at(u64::MAX / 2);
    h.settle_posts();
    assert!(
        !chief_prompts(&h).iter().any(|t| t.contains(UNTOLD_TAG)),
        "no [untold] turn"
    );
}
