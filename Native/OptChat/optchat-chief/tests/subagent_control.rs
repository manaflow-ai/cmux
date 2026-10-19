//! Native subagent control (DESIGN 2026-10-19): `tell` never fails for a
//! known subagent (a82: "I tried to add this to a82's job twice, but it's
//! still waiting to start"), and `control` answers every call with a clear
//! outcome that a repeat turns into a noop.

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{ControlCall, Orchestrator};

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

/// Runs `f` on its own thread while the brain takes its inputs; then lets
/// the brain take what is left.
fn run<T: Send + 'static>(h: &mut Harness, f: impl FnOnce() -> T + Send + 'static) -> T {
    let worker = std::thread::spawn(f);
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    settle(h);
    worker.join().unwrap()
}

fn settle(h: &mut Harness) {
    while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(80)) {
        h.brain.step(input);
    }
}

/// The text of every prompt sent to a subagent session, in order.
fn sub_prompts(h: &Harness) -> Vec<String> {
    let inner = h.agents.inner.lock().unwrap();
    let subs: Vec<String> = inner
        .specs
        .iter()
        .enumerate()
        .filter(|(_, s)| s.tags.contains_key("optchat.subagent"))
        .map(|(k, _)| format!("s{}", k + 1))
        .collect();
    inner
        .prompts
        .iter()
        .zip(&inner.prompt_sessions)
        .filter(|(_, s)| subs.contains(s))
        .map(|(blocks, _)| serde_json::to_string(blocks).unwrap())
        .collect()
}

fn wait_for(h: &mut Harness, what: impl Fn(&Harness) -> bool) {
    let until = Instant::now() + Duration::from_secs(5);
    while !what(h) && Instant::now() < until {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    assert!(what(h), "timed out");
}

#[test]
fn a_tell_to_a_starting_subagent_waits_and_follows_its_task() {
    let mut h = Harness::new(default_script());
    h.agents.inner.lock().unwrap().slow_session =
        Some(("optchat-sub".into(), Duration::from_millis(400)));
    let sp = spawner(&h);
    let (a, b) = (sp.clone(), sp.clone());
    let answers = run(&mut h, move || {
        let spawn = std::thread::spawn(move || a.spawn(vec!["say hello".into()], None));
        std::thread::sleep(Duration::from_millis(150));
        let first = b.tell("a1", "also count to three");
        let second = b.tell("a1", "and then stop");
        (spawn.join().unwrap(), first, second)
    });
    assert!(answers.0.unwrap().contains("Started a1"));
    let first = answers
        .1
        .expect("a tell to a starting subagent never fails");
    assert!(first.starts_with("outcome: queued."), "{first}");
    assert!(answers.2.unwrap().contains("2 waiting"));
    wait_for(&mut h, |h| sub_prompts(h).len() >= 2);
    let prompts = sub_prompts(&h);
    assert!(prompts[0].contains("say hello"), "{prompts:?}");
    let later = prompts[1..].join("\n");
    let (one, two) = (
        later
            .find("also count to three")
            .expect("first message delivered"),
        later
            .find("and then stop")
            .expect("second message delivered"),
    );
    assert!(one < two, "in order: {later}");
}

#[test]
fn a_queued_subagent_gets_its_messages_with_its_task_when_the_cap_rises() {
    let mut h = Harness::new(default_script());
    h.brain.set_max_live(Some(1));
    h.agents.hold(true);
    let sp = spawner(&h);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn(vec!["task one".into(), "task two".into()], None)
    })
    .unwrap();
    assert!(spawned.contains("a2: queued"), "{spawned}");
    let a = sp.clone();
    let told = run(&mut h, move || a.tell("a2", "use the staging branch")).unwrap();
    assert!(told.starts_with("outcome: queued."), "{told}");
    assert!(told.contains("with its task"), "{told}");
    let a = sp.clone();
    let cap = run(&mut h, move || {
        a.control(ControlCall {
            action: "cap".into(),
            n: Some(0),
            ..ControlCall::default()
        })
    })
    .unwrap();
    assert!(cap.starts_with("outcome: done."), "{cap}");
    wait_for(&mut h, |h| sub_prompts(h).len() >= 2);
    let second = &sub_prompts(&h)[1];
    assert!(second.contains("task two"), "{second}");
    assert!(second.contains("use the staging branch"), "{second}");
    // The same cap again changes nothing.
    let a = sp.clone();
    let again = run(&mut h, move || {
        a.control(ControlCall {
            action: "cap".into(),
            n: Some(0),
            ..ControlCall::default()
        })
    })
    .unwrap();
    assert!(again.starts_with("outcome: noop."), "{again}");
}

#[test]
fn keyed_tells_and_cancels_are_idempotent() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = spawner(&h);
    let a = sp.clone();
    run(&mut h, move || a.spawn(vec!["long job".into()], None)).unwrap();
    wait_for(&mut h, |h| !sub_prompts(h).is_empty());
    let a = sp.clone();
    let (one, two) = run(&mut h, move || {
        (
            a.tell_keyed("a1", "focus on tests", Some("k1")),
            a.tell_keyed("a1", "focus on tests", Some("k1")),
        )
    });
    assert!(one.unwrap().starts_with("outcome: done."));
    assert!(two.unwrap().starts_with("outcome: noop."));
    let cancel = |sp: &Arc<Spawner>| {
        let a = sp.clone();
        move || {
            a.control(ControlCall {
                action: "cancel".into(),
                id: Some("a1".into()),
                ..ControlCall::default()
            })
        }
    };
    let first = run(&mut h, cancel(&sp)).unwrap();
    assert!(first.starts_with("outcome: done."), "{first}");
    assert_eq!(h.agents.inner.lock().unwrap().cancels.len(), 1);
    let second = run(&mut h, cancel(&sp)).unwrap();
    assert!(second.starts_with("outcome: noop."), "{second}");
    assert_eq!(h.agents.inner.lock().unwrap().cancels.len(), 1);
    let a = sp.clone();
    let status = run(&mut h, move || {
        a.control(ControlCall {
            action: "status".into(),
            ..ControlCall::default()
        })
    })
    .unwrap();
    assert!(status.contains("a1 [cancelled]"), "{status}");
    let a = sp.clone();
    let none = run(&mut h, move || a.tell("a9", "hi"));
    assert_eq!(none.unwrap_err(), "no subagent a9");
}
