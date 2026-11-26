//! Lucas's latency item 4, default off (`OPTCHAT_SPAWN_BACKGROUND=1`): `spawn`
//! answers once its ids are registered and starts each session on its own
//! thread; off, it answers after the sessions start, with the start lines.

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;

/// The spawn's answer, whether a subagent session exists, and the start
/// note the host sent the brain (`background` on), `background` on or off.
fn spawn_one(background: bool) -> (String, bool, Option<String>) {
    let mut h = Harness::new(default_script());
    let spawner = Arc::new(
        Spawner::new(
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
        )
        .with_background_start(background),
    );
    let worker = {
        let spawner = spawner.clone();
        std::thread::spawn(move || spawner.spawn(vec!["Run the nightly.".into()], None))
    };
    let mut note = None;
    let step = |h: &mut Harness, note: &mut Option<String>| {
        let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) else {
            return;
        };
        if let optchat_chief::brain::Input::SpawnStartNote { text } = &input {
            *note = Some(text.clone());
        }
        h.brain.step(input);
    };
    while !worker.is_finished() {
        step(&mut h, &mut note);
    }
    let answer = worker.join().unwrap().expect("the spawn answers");
    let session = |h: &Harness| {
        h.agents
            .inner
            .lock()
            .unwrap()
            .specs
            .iter()
            .any(|s| s.tags.contains_key("optchat.subagent"))
    };
    if background {
        // The session starts on the spawn's thread, after the answer.
        let deadline = Instant::now() + Duration::from_secs(10);
        while (!session(&h) || note.is_none()) && Instant::now() < deadline {
            step(&mut h, &mut note);
        }
    }
    let started = session(&h);
    (answer, started, note)
}

#[test]
fn off_by_default_spawn_answers_with_its_start_lines() {
    let (answer, started, note) = spawn_one(false);
    assert!(answer.contains("Started a1"), "{answer}");
    assert!(started, "the session exists when spawn answers");
    assert!(note.is_none(), "no start note when spawn answered with it");
}

#[test]
fn on_spawn_answers_before_the_session_starts_and_it_still_starts() {
    let (answer, started, note) = spawn_one(true);
    assert!(answer.starts_with("Starting a1."), "{answer}");
    assert!(answer.contains("never wait or poll"), "{answer}");
    assert!(!answer.contains("Started"), "{answer}");
    assert!(started, "the background start made the session");
    // The detail the off path answers with reaches the turn as the host's note.
    let note = note.expect("the host's start note");
    assert!(note.contains("Started a1"), "{note}");
}
