//! Leo 2026-10-21 (#89(4)): "The approval prompt from a paired device shows
//! raw JSON ("mcp__optchat__tell wants to run: {"id":"a12","message":…}").
//! Render it as a human card: "Chief wants to message a12 · Nightly train"".
//! acpmux writes that line (its `hub/permissions/display.rs`) from tags the
//! Chief puts on its sessions: the turn says who asks and whose children it
//! messages, each subagent its handle and its name.

mod common;

use std::sync::Arc;
use std::time::Duration;

use cmux_chief::rules::{CHIEF_DISPLAY_NAME, PARENT_TAG};

// The tag names acpmux reads (`cmux_chief::rules` LABEL_TAG and the rest),
// spelled out: they are the wire between the two.
const LABEL_TAG: &str = "mux.label";
const HANDLE_TAG: &str = "mux.handle";
const CHILDREN_TAG: &str = "mux.children";
use common::*;
use optchat_chief::subagents::{Spawner, SubagentSettings};

/// The tags of the session the spawn of `task` started.
fn subagent_tags(task: &str) -> std::collections::BTreeMap<String, String> {
    let mut h = Harness::new(default_script());
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
        let task = task.to_owned();
        std::thread::spawn(move || {
            use optchat_chief::tools::Orchestrator;
            spawner.spawn(vec![task], None)
        })
    };
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
    }
    let answer = worker.join().unwrap().expect("the spawn answers");
    assert!(answer.contains("Started a1"), "{answer}");
    let inner = h.agents.inner.lock().unwrap();
    inner
        .specs
        .iter()
        .find(|s| s.tags.contains_key("optchat.subagent"))
        .expect("a subagent session")
        .tags
        .clone()
}

#[test]
fn a_subagent_carries_its_handle_and_its_workspace_name() {
    let task = "title: Nightly train\nRun the nightly and report.";
    let tags = subagent_tags(task);
    assert_eq!(tags.get(HANDLE_TAG).map(String::as_str), Some("a1"));
    assert_eq!(
        tags.get(LABEL_TAG),
        Some(&optchat_chief::workspaces::title(task)),
        "the name its workspace shows"
    );
    assert_eq!(
        tags.get(LABEL_TAG).map(String::as_str),
        Some("Nightly train")
    );
    assert_eq!(
        tags.get(PARENT_TAG).map(String::as_str),
        Some(optchat_chief::brain::PARENT)
    );
}

#[test]
fn a_turn_names_the_chief_and_whose_children_it_messages() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "hello");
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    let tags = &inner
        .specs
        .iter()
        .find(|s| s.tags.get("cmux.chief.role").map(String::as_str) == Some("turn"))
        .expect("a turn session")
        .tags;
    assert_eq!(
        tags.get(LABEL_TAG).map(String::as_str),
        Some(CHIEF_DISPLAY_NAME)
    );
    // Its children are the sessions whose `mux.parent` is this value.
    assert_eq!(
        tags.get(CHILDREN_TAG).map(String::as_str),
        Some(optchat_chief::brain::PARENT)
    );
    // Which Chief it is: a message it sends another chat shows that Chief
    // (manaflow-ai/cmux#27914).
    assert_eq!(
        tags.get(optchat_chief::acpmux::CHIEF_PARTICIPANT_TAG)
            .map(String::as_str),
        Some("agent_mux")
    );
}
