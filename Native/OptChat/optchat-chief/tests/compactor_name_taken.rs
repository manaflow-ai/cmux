//! A compactor node whose session name acpmux still holds, and will not let go of (its purge is
//! refused: an unreadable chat "may be a fork" of every chat a purge ends), gets a fresh name
//! and is built. It was not: every try asked for the same taken name, failed at once, and the
//! node stayed stuck for days (default Chief 2e448bc2, Nov 9-11 2026: 67 merges stuck, every
//! later message "(not summarized yet)").

mod common;

use std::sync::Arc;

use common::*;
use optchat_chief::acpmux::Family;
use optchat_chief::compactor::{
    AcpmuxCompactor, COMPACTOR_SESSIONS, CompactorSpec, Slots, compactor_spec,
};
use serde_json::json;

fn request(node: optchat_host::NodeId) -> optchat_host::CompactRequest {
    optchat_host::CompactRequest {
        imported: false,
        node,
        system: "SYS".into(),
        context: "<chat>\n</chat>\n".into(),
        step: format!("STEP {}", node.name()),
        cut: None,
    }
}

fn compactor(dir: &std::path::Path, agents: &Arc<FakeAgents>) -> (AcpmuxCompactor, String) {
    agents.inner.lock().unwrap().system_prompts = true;
    let home = dir.join("mux");
    let paths = optchat_chief::paths::Paths::new(&home);
    let spec = CompactorSpec {
        work: dir.join("work"),
        ..compactor_spec(&paths, &home, "claude-sr", Family::Claude, None)
    };
    let name = spec.name.clone();
    (
        AcpmuxCompactor::new(agents.clone(), spec, Slots::new(COMPACTOR_SESSIONS)),
        name,
    )
}

fn answers() -> Script {
    Box::new(|_, _| {
        vec![update(
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": "user: ping"}}),
        )]
    })
}

#[test]
fn a_session_name_acpmux_keeps_taken_gets_a_fresh_name_and_the_node_is_built() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(answers());
    let (compactor, base) = compactor(dir.path(), &agents);
    let node = optchat_host::NodeId::new(3, 25592);
    let old = format!("{base}-{}", node.name());
    {
        let mut inner = agents.inner.lock().unwrap();
        inner.taken.insert(old.clone());
        inner.end_error =
            Some("kill: chat 01a0's metadata does not read, and it may be a fork of 01a1".into());
    }
    let text = optchat_host::run_node(&compactor, &request(node))
        .unwrap_or_else(|e| panic!("the node stayed unbuilt behind a taken name: {e:?}"));
    assert_eq!(text, "user: ping");
    let names: Vec<String> = agents
        .inner
        .lock()
        .unwrap()
        .specs
        .iter()
        .map(|s| s.name.clone())
        .collect();
    assert_eq!(names.len(), 1, "one session started: {names:?}");
    assert_ne!(names[0], old, "the taken name was asked for again");
    assert!(
        names[0].starts_with(&old),
        "the fresh name still names the node: {names:?}"
    );
}

/// Two describe sessions (image descriptions, ids counting down from u64::MAX) of two host
/// runs never share a name: the count restarts at 0 with each host, so a run's first
/// description asked for the name the last run's first one still held.
#[test]
fn an_image_description_after_a_restart_does_not_reuse_the_last_runs_name() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(answers());
    let (first, base) = compactor(dir.path(), &agents);
    let describe = optchat_host::NodeId::new(0, u64::MAX);
    // The last run's first description, left in acpmux (its end refused).
    let left = format!("{base}-{}", describe.name());
    agents.inner.lock().unwrap().taken.insert(left.clone());
    agents.inner.lock().unwrap().end_error = Some("kill: refused".into());
    let text = optchat_host::run_node(&first, &request(describe))
        .unwrap_or_else(|e| panic!("a description failed on the last run's name: {e:?}"));
    assert_eq!(text, "user: ping");
    let names: Vec<String> = agents
        .inner
        .lock()
        .unwrap()
        .specs
        .iter()
        .map(|s| s.name.clone())
        .collect();
    assert!(!names.contains(&left), "{names:?}");
}
