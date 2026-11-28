//! Subagent to subagent messages (acp-chief-issues.md #11): a subagent
//! lists the others (`peers`) and tells one (`tell`), without the Chief
//! relaying it.

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use common::*;
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

/// acp-chief-issues.md #11 (a115 could not reach a192, 3711): a subagent
/// lists the others and tells one directly; the message says who sent it.
#[test]
fn a_subagent_lists_the_others_and_tells_one() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = spawner(&h);
    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn(
            vec![
                "Tab mute click path\n\nthe speaker".into(),
                "Pane tab mute button\n\nmake it clickable".into(),
            ],
            None,
        )
    })
    .unwrap();
    assert!(spawned.contains("a2"), "{spawned}");
    wait_for(&mut h, |h| sub_prompts(h).len() >= 2);
    let a = sp.clone();
    let listed = run(&mut h, move || a.peers("a1")).unwrap();
    assert!(listed.contains("a2"), "{listed}");
    assert!(listed.contains("Pane tab mute button"), "{listed}");
    let a = sp.clone();
    let told = run(&mut h, move || {
        a.peer_tell(
            "a1",
            "a2",
            "the click path is TabCell.audioButtonRect",
            None,
        )
    })
    .unwrap();
    assert!(told.starts_with("outcome:"), "{told}");
    h.agents.inner.lock().unwrap().steering = true;
    wait_for(&mut h, |h| {
        let inner = h.agents.inner.lock().unwrap();
        let steered = inner.steers.iter().any(|(_, b)| {
            serde_json::to_string(b)
                .unwrap()
                .contains("TabCell.audioButtonRect")
        });
        drop(inner);
        steered
            || sub_prompts(h)
                .iter()
                .any(|p| p.contains("TabCell.audioButtonRect"))
    });
    let inner = h.agents.inner.lock().unwrap();
    let all: Vec<String> = inner
        .steers
        .iter()
        .map(|(_, b)| serde_json::to_string(b).unwrap())
        .chain(
            inner
                .prompts
                .iter()
                .map(|b| serde_json::to_string(b).unwrap()),
        )
        .filter(|t| t.contains("TabCell.audioButtonRect"))
        .collect();
    assert!(all.iter().all(|t| t.contains("from a1")), "{all:?}");
    drop(inner);
    // Itself, or an id that does not exist: refused.
    let a = sp.clone();
    assert!(run(&mut h, move || a.peer_tell("a1", "a1", "hi", None)).is_err());
    let a = sp.clone();
    assert!(run(&mut h, move || a.peer_tell("a1", "a9", "hi", None)).is_err());
}

/// A tools-socket caller under a subagent session is that subagent: its id
/// comes from the session name acpmux gave it (`-2` when the name was taken).
#[test]
fn a_subagent_session_name_names_its_id() {
    let b = optchat_chief::turn_caller::TurnBinding::for_home("optchat-h0me", "h0me");
    assert_eq!(
        b.subagent_id("optchat-sub-h0me-a12").as_deref(),
        Some("a12")
    );
    assert_eq!(
        b.subagent_id("optchat-sub-h0me-a12-2").as_deref(),
        Some("a12")
    );
    assert_eq!(b.subagent_id("optchat-sub-other-a12"), None);
    assert_eq!(b.subagent_id("optchat-h0me-123"), None);
}
