//! Subagent ids (`a<N>`) are given once per home, for all time
//! (plans/cmux-next/persistent-ids-DESIGN.md): a host restart, a counter
//! that reads back as 0 (unreadable or missing field) or a moved home never
//! gives an id that a recorded spawn already gave.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::*;
use optchat_chief::state::StateFile;
use optchat_chief::subagents::{Spawner, SubagentSettings};

fn spawn_one(h: &mut Harness) -> String {
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
    let worker = {
        let spawner = spawner.clone();
        std::thread::spawn(move || {
            use optchat_chief::tools::Orchestrator;
            spawner.spawn(vec!["say hello".into()], None)
        })
    };
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
    }
    while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(50)) {
        h.brain.step(input);
    }
    worker.join().unwrap().expect("the spawn answers")
}

/// A brain on the same home again (a host restart).
fn restart(h: Harness) -> Harness {
    let Harness {
        dir,
        owner,
        brain,
        chat,
        ..
    } = h;
    drop(brain);
    drop(chat);
    Harness::in_dir(dir, default_script(), owner)
}

#[test]
fn persistent_ids_a_restart_keeps_subagent_ids_counting_up() {
    let mut h = Harness::new(default_script());
    assert!(spawn_one(&mut h).contains("Started a1"));
    let mut h = restart(h);
    let answer = spawn_one(&mut h);
    assert!(answer.contains("Started a2"), "{answer}");
}

#[test]
fn persistent_ids_a_lost_counter_never_gives_an_id_twice() {
    let mut h = Harness::new(default_script());
    assert!(spawn_one(&mut h).contains("Started a1"));
    assert!(spawn_one(&mut h).contains("Started a2"));
    let h = restart(h);
    // The counter is lost (an unreadable or missing field reads as 0); the
    // spawns it gave are still recorded.
    {
        let file = StateFile::new(&h.dir.path().join("host.json")).attach(h.chat.clone());
        let mut state = file.load();
        assert!(state.next_subagent >= 3, "{}", state.next_subagent);
        state.next_subagent = 0;
        file.save(&state).unwrap();
    }
    let mut h = restart(h);
    let answer = spawn_one(&mut h);
    assert!(answer.contains("Started a3"), "{answer}");
    assert!(!answer.contains("Started a1"), "{answer}");
}

/// `cmux chief move` copies the home to another folder or machine: the
/// moved home keeps the id its acpmux sessions are tagged and named with.
#[test]
fn persistent_ids_a_moved_home_keeps_its_id() {
    use optchat_chief::paths::{Paths, home_id};
    let dir = tempfile::tempdir().unwrap();
    let (old, new) = (
        dir.path().join("old").join("mux"),
        dir.path().join("new-place"),
    );
    Paths::new(&old).create().unwrap();
    let id = home_id(&old);
    assert_eq!(id.len(), 8);
    // A second start changes nothing.
    Paths::new(&old).create().unwrap();
    assert_eq!(home_id(&old), id);
    // The move: the home's files at another path.
    std::fs::create_dir_all(new.join("optchat")).unwrap();
    std::fs::copy(
        old.join("optchat").join("home-id"),
        new.join("optchat").join("home-id"),
    )
    .unwrap();
    Paths::new(&new).create().unwrap();
    assert_eq!(home_id(&new), id, "a moved home got a new id");
}
