//! The machine's helper limit (src/machine_limits.rs): helpers over it are
//! queued with their place in line, never refused, and start when a slot
//! frees or the machine has room again (Leo 2026-11-24, after a Chief-driven
//! Mac sat at load 300 with 27 helpers and swap full).

mod common;

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
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

/// Over the machine's ceiling a helper is queued with its place in line and
/// the limit named; nothing is refused.
#[test]
fn over_the_machine_ceiling_helpers_queue_in_line() {
    let mut h = Harness::new(default_script());
    h.brain.set_machine_limit(1, Box::new(|| None));
    h.agents.hold(true);
    let sp = spawner(&h);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn(vec!["one".into(), "two".into(), "three".into()], None)
    })
    .unwrap();
    assert_ne!(status(&h, "a1"), SubStatus::Queued, "{spawned}");
    assert!(spawned.contains("a2: queued, #1 in line"), "{spawned}");
    assert!(spawned.contains("a3: queued, #2 in line"), "{spawned}");
    assert!(spawned.contains("this machine's limit of 1"), "{spawned}");
    assert_eq!(status(&h, "a2"), SubStatus::Queued);
    assert_eq!(status(&h, "a3"), SubStatus::Queued);

    // A later spawn queues behind them.
    let b = sp.clone();
    let later = run(&mut h, move || b.spawn(vec!["four".into()], None)).unwrap();
    assert!(later.contains("a4: queued, #3 in line"), "{later}");
}

/// While the machine is over budget only the floor's helpers start; the rest
/// wait and start on the first tick that finds room.
#[test]
fn an_overloaded_machine_holds_new_helpers_until_it_has_room() {
    let mut h = Harness::new(default_script());
    let over = Arc::new(AtomicBool::new(true));
    let o = over.clone();
    h.brain.set_machine_limit(
        24,
        Box::new(move || {
            o.load(Ordering::SeqCst)
                .then(|| "load 300 on 15 cores".to_owned())
        }),
    );
    h.agents.hold(true);
    let sp = spawner(&h);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn(vec!["one".into(), "two".into(), "three".into()], None)
    })
    .unwrap();
    assert_ne!(status(&h, "a1"), SubStatus::Queued, "{spawned}");
    assert_ne!(
        status(&h, "a2"),
        SubStatus::Queued,
        "the floor always starts: {spawned}"
    );
    assert!(spawned.contains("a3: queued, #1 in line"), "{spawned}");
    assert!(spawned.contains("over budget"), "{spawned}");

    // Still over budget: a tick starts nothing.
    run(&mut h, || ());
    h.brain.step(Input::SubTick);
    run(&mut h, || ());
    assert_eq!(status(&h, "a3"), SubStatus::Queued);

    // Room again: the next tick starts it.
    over.store(false, Ordering::SeqCst);
    h.brain.step(Input::SubTick);
    run(&mut h, || ());
    assert_ne!(
        status(&h, "a3"),
        SubStatus::Queued,
        "a3 started once the machine had room"
    );
}

/// `control cap 0` lifts every cap, the machine's too; an explicit cap wins
/// over the machine's.
#[test]
fn an_explicit_cap_wins_over_the_machine_limit() {
    let mut h = Harness::new(default_script());
    h.brain.set_machine_limit(1, Box::new(|| None));
    h.brain.set_max_live(Some(3));
    h.agents.hold(true);
    let sp = spawner(&h);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn(vec!["one".into(), "two".into(), "three".into()], None)
    })
    .unwrap();
    assert!(!spawned.contains("queued"), "the env's 3 wins: {spawned}");
}
