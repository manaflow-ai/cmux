//! Chief fast evals, deterministic group `replies` (plans/cmux-next/
//! agent-evals-DESIGN.md, "Chief fast evals"). Found by the first model
//! baseline (2026-10-26): a person's "thanks" that the Chief answered with a
//! tapback still sat in the reply ledger, so a `[no reply]` retry turn ran
//! 5 s later and posted words ("I liked your message."); and a turn that
//! called `stop` before it said anything paid a whole second turn (the
//! retry) to answer. Now a reaction answers the message it is on, and `stop`
//! or `sleep` with a seen person message still unanswered is refused inside
//! the turn, which then replies in the same turn.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::*;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{Orchestrator, SendCall, SleepCall};
use serde_json::json;

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

fn run<T: Send + 'static>(h: &mut Harness, f: impl FnOnce() -> T + Send + 'static) -> T {
    let worker = std::thread::spawn(f);
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    worker.join().unwrap()
}

/// Every turn says nothing (a turn that only reacts, or only stops).
fn silent() -> Script {
    Box::new(|_, _| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        ]
    })
}

/// The first turn never ends on its own (held at the fake agent).
fn endless_first_turn() -> Script {
    let base = default_script();
    Box::new(move |turn, blocks| {
        let mut events = base(turn, blocks);
        if turn == 0 {
            events.pop();
        }
        events
    })
}

fn running(h: &mut Harness, text: &str) {
    h.agents.hold(true);
    h.connect();
    h.say("user_local", text);
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
}

fn line_of(h: &Harness, seq: u64) -> u64 {
    h.chat
        .logged_id(&format!("{CONV}#{seq}"))
        .expect("the message is in the log")
}

fn prompts(h: &Harness) -> usize {
    h.agents.inner.lock().unwrap().prompts.len()
}

#[test]
fn a_tapback_answers_the_message_it_is_on() {
    let mut h = Harness::new(silent());
    h.connect();
    h.say("user_local", "thanks");
    h.settle_posts();
    let line = line_of(&h, 1);
    let sp = spawner(&h);
    let answer = run(&mut h, move || sp.react(line, "like")).expect("react answers");
    assert!(answer.starts_with("outcome: done"), "{answer}");
    assert!(
        h.brain.awaiting_replies().is_empty(),
        "a tapback is the answer to an acknowledgement: {:?}",
        h.brain.awaiting_replies()
    );
    h.brain.fire_reply_checks_at(u64::MAX / 2);
    h.settle_posts();
    assert_eq!(prompts(&h), 1, "no [no reply] retry turn");
}

#[test]
fn stop_with_an_unanswered_person_message_is_refused_in_the_turn() {
    let mut h = Harness::new(endless_first_turn());
    running(&mut h, "start the work");
    let sp = spawner(&h);
    let refused = run(&mut h, move || sp.stop_turn());
    let why = refused.expect_err("stop before any reply is refused");
    assert!(why.contains("start the work"), "names the message: {why}");
    assert!(
        h.agents.inner.lock().unwrap().cancels.is_empty(),
        "the turn goes on"
    );
    // Said in words: now stop ends it.
    let sp = spawner(&h);
    run(&mut h, move || {
        sp.send(SendCall {
            sign_in: None,
            text: Some("On it.".into()),
            attachments: Vec::new(),
            reply_to: None,
        })
    })
    .expect("send answers");
    let sp = spawner(&h);
    let answer = run(&mut h, move || sp.stop_turn()).expect("stop answers");
    assert!(answer.starts_with("outcome: done"), "{answer}");
}

#[test]
fn stop_after_a_tapback_is_allowed() {
    let mut h = Harness::new(endless_first_turn());
    running(&mut h, "thanks!");
    let line = line_of(&h, 1);
    let sp = spawner(&h);
    run(&mut h, move || sp.react(line, "love")).expect("react answers");
    let sp = spawner(&h);
    let answer = run(&mut h, move || sp.stop_turn()).expect("stop answers");
    assert!(answer.starts_with("outcome: done"), "{answer}");
}

#[test]
fn sleep_with_an_unanswered_person_message_is_refused_in_the_turn() {
    let mut h = Harness::new(endless_first_turn());
    running(&mut h, "watch the nightly");
    let sp = spawner(&h);
    let refused = run(&mut h, move || {
        sp.sleep(SleepCall {
            seconds: 600,
            note: Some("check the nightly".into()),
            until: None,
        })
    });
    assert!(refused.is_err(), "{refused:?}");
    assert!(h.brain.pending_wakes().is_empty(), "no wake saved");
}
