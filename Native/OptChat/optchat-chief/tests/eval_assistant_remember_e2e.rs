//! Chief fast eval, group assistant (a676): `remember` over the host's tool
//! socket, as the Chief's MCP server and its `chief remember` launcher call
//! it, writes the person profile the next turn's system prompt reads.
#![cfg(unix)]

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::*;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{Call, Served, ask_as, serve_all};

fn spawner(h: &Harness, person: std::path::PathBuf) -> Arc<Spawner> {
    Arc::new(
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
        .with_person(person),
    )
}

/// Runs `f` on a thread while the brain answers its inputs.
fn run<T: Send + 'static>(h: &mut Harness, f: impl FnOnce() -> T + Send + 'static) -> T {
    let worker = std::thread::spawn(f);
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    worker.join().unwrap()
}

#[test]
fn remember_over_the_socket_writes_the_profile_once() {
    let mut h = Harness::new(default_script());
    let person = h.dir.path().join("optchat/person.md");
    let socket = h.dir.path().join("tools.sock");
    serve_all(
        &socket,
        Served {
            memory: open_chat(&h.dir.path().join("memory")),
            orchestrator: Some(spawner(&h, person.clone())),
            control: None,
            inspector: None,
            chief: None,
            turn: None,
            peers: None,
        },
    )
    .unwrap();
    let call = |text: &str| Call::parse("remember", &serde_json::json!({"text": text})).unwrap();
    let (s, c) = (socket.clone(), call("Default project is cmux-next."));
    let first = run(&mut h, move || ask_as(&s, c, false)).unwrap();
    assert!(first.starts_with("outcome: done"), "{first}");
    let (s, c) = (socket.clone(), call("default project is cmux-next"));
    let again = run(&mut h, move || ask_as(&s, c, false)).unwrap();
    assert!(again.starts_with("outcome: noop"), "{again}");
    let text = std::fs::read_to_string(&person).unwrap();
    assert_eq!(
        text.matches("Default project is cmux-next.").count(),
        1,
        "{text}"
    );
    // The next host start's system prompt carries it.
    let prompt = optchat_chief::prompt::chief_instructions(&person, &h.dir.path().join("none.md"))
        .unwrap_or_default();
    assert!(prompt.contains("Default project is cmux-next."), "{prompt}");
    // A subagent cannot write the person's profile.
    let (s, c) = (socket.clone(), call("Subagents may force push."));
    let refused = run(&mut h, move || ask_as(&s, c, true));
    assert!(refused.is_err(), "{refused:?}");
}
