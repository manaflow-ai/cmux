//! chief.stop {start: name}: Start now on a queued agent's tab in Home (user
//! 2026-11-07, msg 23835: a queued agent's chip "failed to open in
//! workspace"). The named queued subagent starts at once, past the live cap;
//! the others keep their places in the queue.

mod common;

use std::sync::Arc;
use std::sync::mpsc::channel;
use std::time::Duration;

use common::*;
use optchat_chief::brain::Input;
use optchat_chief::state::SubStatus;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;

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
    while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(80)) {
        h.brain.step(input);
    }
    worker.join().unwrap()
}

fn status(h: &Harness, id: &str) -> SubStatus {
    h.brain.state().sub(id).expect(id).1.status
}

/// chief.stop {start: name}, as the host's control socket sends it.
fn start_now(h: &mut Harness, name: &str) -> serde_json::Value {
    let (reply, answer) = channel();
    h.brain.step(Input::StartSubagent {
        name: name.into(),
        reply,
    });
    answer
        .try_recv()
        .expect("chief.stop {start} answers at once")
}

#[test]
fn start_now_starts_one_queued_subagent_past_the_cap() {
    let mut h = Harness::new(default_script());
    h.brain.set_max_live(Some(1));
    h.agents.hold(true);
    let sp = spawner(&h);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn(vec!["one".into(), "two".into(), "three".into()], None)
    })
    .unwrap();
    assert!(spawned.contains("a2: queued"), "{spawned}");
    assert!(spawned.contains("a3: queued"), "{spawned}");

    let answer = start_now(&mut h, "a3");
    assert_eq!(answer["started"], true, "{answer}");
    run(&mut h, || ());
    assert_ne!(status(&h, "a3"), SubStatus::Queued, "a3 started now");
    assert_eq!(status(&h, "a2"), SubStatus::Queued, "a2 keeps its place");
    assert_ne!(status(&h, "a1"), SubStatus::Queued, "a1 goes on");
}

#[test]
fn start_now_refuses_an_agent_that_is_not_queued() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = spawner(&h);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    let a = sp.clone();
    run(&mut h, move || a.spawn(vec!["one".into()], None)).unwrap();

    let answer = start_now(&mut h, "a1");
    assert_eq!(answer["started"], false, "{answer}");
    assert!(
        answer["error"]
            .as_str()
            .unwrap_or("")
            .contains("not queued"),
        "{answer}"
    );
    let missing = start_now(&mut h, "a99");
    assert_eq!(missing["started"], false, "{missing}");
}
