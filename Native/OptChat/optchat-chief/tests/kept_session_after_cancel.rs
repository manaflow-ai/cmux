//! A turn cancelled at a point the next turn can go on from keeps its Claude
//! Code session (`Settings::keep_turn_session`): the Chief's own `stop` after
//! its reply, and a person's newer message that cannot reach the turn.
//!
//! Nearly every live Chief turn ends with its own `stop` or `sleep`, and
//! until 2026-11-19 every cancel ended the session: 8 of ~1,400 turns kept
//! one (Lawrence's Chief, Nov 12-19). Each turn then started a new Claude
//! Code and wrote its whole input (55-80k tokens) to the cache again, which
//! is most of its first request's 3-4 s before the first token. A person who
//! writes during a turn lost the turn's work too: the next turn started over
//! from the view instead of going on with the message, as Claude Code does
//! when a person interrupts and writes again.

mod common;

use std::sync::{Arc, Mutex};
use std::time::Duration;

use common::*;
use optchat_chief::brain::{Input, Settings};
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{Orchestrator, SendCall};
use cmux_conversation::{Op, Part};
use optchat_core::Kind;
use serde_json::Value;

fn fill(chat: &optchat_host::OptChat, n: usize) {
    for i in 0..n {
        chat.append(
            Kind::Note,
            &format!("note {i:04}: the build cache for project {i} lives in /srv/cache/{i}"),
        )
        .unwrap();
    }
    assert!(chat.wait_idle(None, Some(WAIT)));
}

fn texts(blocks: &[Value]) -> Vec<String> {
    blocks
        .iter()
        .map(|b| b["text"].as_str().unwrap_or_default().to_owned())
        .collect()
}

fn harness(script: Script) -> Harness {
    let dir = tempfile::tempdir().unwrap();
    let s = Settings {
        keep_turn_session: true,
        ..settings(dir.path())
    };
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let h = Harness::configured(dir, script, owner, s, Arc::new(|_: &str| {}));
    h.agents.inner.lock().unwrap().system_prompts = true;
    fill(&h.chat, 120);
    h
}

fn logged(h: &Harness, kind: &str, text: &str) -> Vec<u64> {
    h.log()
        .iter()
        .enumerate()
        .filter(|(_, (k, t))| k == kind && t == text)
        .map(|(i, _)| i as u64)
        .collect()
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

/// The default script, except that turn 0 never ends by itself.
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

/// Turn 0 sits in a long tool call (no result, no turn end yet).
fn long_tool_script() -> Script {
    let rest = default_script();
    Box::new(move |turn, blocks| {
        if turn > 0 {
            return rest(turn, blocks);
        }
        vec![
            serde_json::json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "tool_call",
                serde_json::json!({"toolCallId": "t0", "title": "Bash", "rawInput": {"command": "sleep 600"}, "_meta": {"claude": {"tool": "Bash"}}}),
            ),
        ]
    })
}

/// A turn runs for `text`, held at the fake agent, and the brain knows its
/// session.
fn running(h: &mut Harness, text: &str) {
    h.agents.hold(true);
    h.connect();
    h.say("user_local", text);
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while h
        .brain
        .state()
        .turn
        .as_ref()
        .and_then(|t| t.session_id.as_ref())
        .is_none()
    {
        assert!(std::time::Instant::now() < deadline, "no turn session");
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
    }
}

fn tick(h: &mut Harness) {
    if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
        h.brain.step(input);
    }
    if h.brain
        .next_timer()
        .is_some_and(|at| at <= std::time::Instant::now())
    {
        h.brain.on_timer();
    }
}

fn until_prompts(h: &mut Harness, n: usize) {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while h.agents.inner.lock().unwrap().prompts.len() < n {
        assert!(std::time::Instant::now() < deadline, "no prompt {n}");
        tick(h);
    }
}

#[test]
fn a_turn_the_chief_stops_itself_keeps_its_session_for_the_next_turn() {
    let mut h = harness(endless_first_turn());
    running(&mut h, "one");
    let sp = spawner(&h);
    run(&mut h, move || {
        sp.send(SendCall {
            text: Some("On it.".into()),
            ..SendCall::default()
        })
    })
    .expect("send answers");
    let sp = spawner(&h);
    run(&mut h, move || sp.stop_turn()).expect("stop answers");
    h.agents.hold(false);
    h.settle_posts();
    assert!(
        !h.agents.inner.lock().unwrap().cancels.is_empty(),
        "the stop cancelled the session"
    );
    h.say("user_local", "two");
    h.settle();
    let two = logged(&h, "user", "two")[0];
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.specs.len(), 1, "one session for both turns");
    assert_eq!(inner.prompt_sessions, vec!["s1", "s1"]);
    assert!(!inner.ended.contains(&"s1".to_owned()), "the session stays");
    let tb = texts(inner.prompts.last().unwrap());
    assert!(
        tb.iter().all(|t| !t.contains("<chat>")),
        "no view again: {tb:?}"
    );
    assert_eq!(tb[0], format!("{two}+1|user: two\n"));
}

#[test]
fn a_person_message_that_cannot_reach_the_turn_goes_on_in_the_same_session() {
    let mut h = harness(long_tool_script());
    // acpmux refuses the steer: the turn is cut at once for the message.
    h.agents.inner.lock().unwrap().steering = false;
    running(&mut h, "fix the sidebar");
    h.say("user_local", "wait, wrong repo");
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while h.agents.inner.lock().unwrap().cancels.is_empty() {
        assert!(std::time::Instant::now() < deadline, "no cancel");
        tick(&mut h);
    }
    h.agents.hold(false);
    until_prompts(&mut h, 2);
    h.settle_posts();
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(
        inner.prompt_sessions,
        vec!["s1", "s1"],
        "the message goes into the session that holds the work so far"
    );
    assert!(!inner.ended.contains(&"s1".to_owned()), "the session stays");
    let tb = texts(&inner.prompts[1]);
    assert!(
        tb.iter().all(|t| !t.contains("<chat>")),
        "only the new message, no view again: {tb:?}"
    );
    assert!(
        tb.iter().any(|t| t.contains("wait, wrong repo")),
        "{tb:?}"
    );
}

/// The posted texts that contain `needle`.
fn posted(h: &Harness, needle: &str) -> usize {
    h.owner
        .lock()
        .unwrap()
        .ops
        .iter()
        .filter(|(_, op)| match op {
            Op::MessageSend { parts, .. } => parts
                .iter()
                .any(|p| matches!(p, Part::Text { text, .. } if text.contains(needle))),
            _ => false,
        })
        .count()
}

#[test]
fn the_next_turn_in_a_kept_session_posts_its_reply_once() {
    let mut h = harness(endless_first_turn());
    running(&mut h, "one");
    let sp = spawner(&h);
    run(&mut h, move || {
        sp.send(SendCall {
            text: Some("On it.".into()),
            ..SendCall::default()
        })
    })
    .expect("send answers");
    let sp = spawner(&h);
    run(&mut h, move || sp.stop_turn()).expect("stop answers");
    h.agents.hold(false);
    h.settle_posts();
    h.say("user_local", "two");
    h.settle_posts();
    assert_eq!(h.agents.inner.lock().unwrap().prompt_sessions, vec!["s1", "s1"]);
    assert_eq!(posted(&h, "answer 1"), 1, "the second turn's reply, once");
    assert_eq!(posted(&h, "On it."), 1, "the first turn's line, once");
}

#[test]
fn the_owners_stop_after_the_chiefs_own_stop_still_ends_the_session() {
    let mut h = harness(endless_first_turn());
    running(&mut h, "one");
    let sp = spawner(&h);
    run(&mut h, move || {
        sp.send(SendCall {
            text: Some("On it.".into()),
            ..SendCall::default()
        })
    })
    .expect("send answers");
    let sp = spawner(&h);
    run(&mut h, move || sp.stop_turn()).expect("stop answers");
    // The owner presses Stop before the turn has ended.
    let (reply, _answer) = std::sync::mpsc::channel();
    h.brain.step(Input::Stop { reply });
    h.agents.hold(false);
    h.settle_posts();
    h.say("user_local", "two");
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.specs.len(), 2, "a new session after the owner's Stop");
    assert!(inner.ended.contains(&"s1".to_owned()), "the stopped session ended");
}

#[test]
fn a_message_left_unread_in_the_session_ends_it() {
    let mut h = harness(long_tool_script());
    {
        let mut inner = h.agents.inner.lock().unwrap();
        inner.steering = true;
        // Claude Code is in a long tool call: the steer waits unread in it.
        inner.steer_at_end = true;
    }
    h.brain.set_steer_deadline(Some(Duration::from_millis(20)));
    running(&mut h, "fix the sidebar");
    h.say("user_local", "stop, do the composer first");
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while h.agents.inner.lock().unwrap().cancels.is_empty() {
        assert!(std::time::Instant::now() < deadline, "no cancel");
        tick(&mut h);
    }
    h.agents.hold(false);
    until_prompts(&mut h, 2);
    h.settle_posts();
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(
        inner.prompt_sessions,
        vec!["s1", "s2"],
        "the session that may still hold the message is not prompted again"
    );
    assert!(inner.ended.contains(&"s1".to_owned()));
}

#[test]
fn an_unread_message_taken_back_from_the_session_goes_on_in_it() {
    let mut h = harness(long_tool_script());
    {
        let mut inner = h.agents.inner.lock().unwrap();
        inner.steering = true;
        // Claude Code is in a long tool call: the steer waits unread in it,
        // and Claude Code drops it when asked (cancel_async_message).
        inner.steer_at_end = true;
        inner.withdraws = true;
    }
    h.brain.set_steer_deadline(Some(Duration::from_millis(20)));
    running(&mut h, "fix the sidebar");
    h.say("user_local", "stop, do the composer first");
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while h.agents.inner.lock().unwrap().cancels.is_empty() {
        assert!(std::time::Instant::now() < deadline, "no cancel");
        tick(&mut h);
    }
    h.agents.hold(false);
    until_prompts(&mut h, 2);
    h.settle_posts();
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.withdrawn.len(), 1, "the unread steer was asked back");
    assert!(inner.withdrawn[0].1.starts_with("optchat-steer:"), "{:?}", inner.withdrawn);
    assert_eq!(
        inner.prompt_sessions,
        vec!["s1", "s1"],
        "the message goes into the session that holds the work so far"
    );
    let tb = texts(&inner.prompts[1]);
    assert!(
        tb.iter().any(|t| t.contains("stop, do the composer first")),
        "{tb:?}"
    );
    assert!(tb.iter().all(|t| !t.contains("<chat>")), "{tb:?}");
}
