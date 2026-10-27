//! Single flight for compactor nodes that share a cached prefix (the Unii
//! baseline's `AskAI.wait`; plans/cmux-next/unii-vs-chief-harness-DESIGN.md
//! row 5): while one node's request still writes the prefix, a parallel node
//! with the same prefix waits until that response begins, then reads the
//! entry instead of writing it again. A node with another prefix never waits.

mod common;

use std::time::{Duration, Instant};

use common::*;
use optchat_chief::acpmux::Family;
use optchat_chief::compactor::{
    AcpmuxCompactor, COMPACTOR_SESSIONS, CompactorSpec, Slots, compactor_spec,
};
use optchat_chief::prompt::CacheTtl;
use serde_json::json;

fn context(tag: &str) -> String {
    let mut s = String::from("<chat>\n");
    for i in 0..48 {
        s.push_str(&format!(
            "{i}+1|note: {tag} line {i}: the build cache for project {i} lives in /srv/cache/{i}\n"
        ));
    }
    s.push_str("</chat>\n");
    s
}

fn request(node: u64, context: &str) -> optchat_host::CompactRequest {
    optchat_host::CompactRequest {
        imported: false,
        node: optchat_host::NodeId::new(0, node),
        system: "SYS".into(),
        context: context.to_owned(),
        step: format!("STEP {node}"),
        cut: None,
    }
}

fn output() -> Vec<serde_json::Value> {
    vec![update(
        "agent_message_chunk",
        json!({"content": {"type": "text", "text": "user: ping"}}),
    )]
}

fn prompts(agents: &FakeAgents) -> Vec<String> {
    agents.inner.lock().unwrap().prompt_sessions.clone()
}

fn wait_prompts(agents: &FakeAgents, n: usize) -> Vec<String> {
    let deadline = Instant::now() + WAIT;
    loop {
        let p = prompts(agents);
        if p.len() >= n || Instant::now() > deadline {
            return p;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn compactor(dir: &std::path::Path, agents: &std::sync::Arc<FakeAgents>) -> AcpmuxCompactor {
    agents.inner.lock().unwrap().system_prompts = true;
    let home = dir.join("mux");
    let paths = optchat_chief::paths::Paths::new(&home);
    let spec = CompactorSpec {
        work: dir.join("work"),
        ..compactor_spec(&paths, &home, "claude-sr", Family::Claude, None)
    };
    AcpmuxCompactor::new(
        optchat_chief::supervisor::exiting(),
        agents.clone(),
        spec,
        Slots::new(COMPACTOR_SESSIONS),
    )
}

#[test]
fn a_parallel_node_with_the_same_prefix_waits_for_the_first_response_to_begin() {
    let shared = context("shared");
    // The precondition: the shared context has a mark, so it has a prefix to share.
    let layout =
        optchat_chief::compactor::cached_prompt_with(&request(0, &shared), true, CacheTtl::OneHour);
    assert!(
        layout
            .blocks
            .iter()
            .any(|b| b.get("cache_control").is_some())
    );
    let dir = tempfile::tempdir().unwrap();
    // No events from the script: the test streams each response itself.
    let agents = FakeAgents::new(Box::new(|_, _| Vec::new()));
    agents.hold(true);
    let compactor = compactor(dir.path(), &agents);
    let (a, b) = (request(0, &shared), request(1, &shared));
    std::thread::scope(|s| {
        let first = s.spawn(|| optchat_host::run_node(&compactor, &a));
        let leader = wait_prompts(&agents, 1);
        assert_eq!(leader.len(), 1);
        let second = s.spawn(|| optchat_host::run_node(&compactor, &b));
        std::thread::sleep(Duration::from_millis(400));
        // Asserted after both nodes finish: a held node never ends otherwise.
        let early = prompts(&agents).len();
        // The first response begins: its prefix is in the cache now.
        agents.push_events(&leader[0], output());
        let both = wait_prompts(&agents, 2);
        for session in both.iter().skip(1) {
            agents.push_events(session, output());
        }
        agents.release();
        agents.release();
        first.join().unwrap().unwrap();
        second.join().unwrap().unwrap();
        assert_eq!(
            early, 1,
            "the second node wrote the same prefix while the first still wrote it"
        );
        assert_eq!(both.len(), 2, "the second node never started");
    });
}

#[test]
fn a_node_with_another_prefix_does_not_wait() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| Vec::new()));
    agents.hold(true);
    let compactor = compactor(dir.path(), &agents);
    let (one, two) = (context("one"), context("two"));
    let (a, b) = (request(0, &one), request(1, &two));
    std::thread::scope(|s| {
        let first = s.spawn(|| optchat_host::run_node(&compactor, &a));
        assert_eq!(wait_prompts(&agents, 1).len(), 1);
        let second = s.spawn(|| optchat_host::run_node(&compactor, &b));
        let both = wait_prompts(&agents, 2);
        for session in &both {
            agents.push_events(session, output());
        }
        agents.release();
        agents.release();
        first.join().unwrap().unwrap();
        second.join().unwrap().unwrap();
        assert_eq!(both.len(), 2, "another prefix waited");
    });
}
