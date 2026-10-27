//! Warm compactor sessions start only for chat work. The host's start-up
//! probe builds one tiny node at every launch; the Claude Code a warm-up
//! would start after it sat idle until the idle reap (about 100 MB at
//! launch, before anyone wrote to the Chief).

mod common;

use common::*;
use optchat_chief::acpmux::Family;
use optchat_chief::compactor::{
    AcpmuxCompactor, COMPACTOR_SESSIONS, CompactorSpec, Slots, compactor_spec,
};
use serde_json::json;

fn warm_sessions(agents: &FakeAgents) -> Vec<String> {
    agents
        .inner
        .lock()
        .unwrap()
        .specs
        .iter()
        .map(|s| s.name.clone())
        .filter(|name| name.contains("-warm-"))
        .collect()
}

#[test]
fn the_start_up_probe_leaves_no_warm_claude_code_running() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": "user: ping"}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
        ]
    }));
    let home = dir.path().join("mux");
    let paths = optchat_chief::paths::Paths::new(&home);
    let spec = CompactorSpec {
        work: dir.path().join("work"),
        ..compactor_spec(&paths, &home, "claude-sr", Family::Claude, None)
    };
    // Not shared: a warm-up runs on the caller's thread, so the assertions
    // below see it without waiting.
    let compactor = AcpmuxCompactor::new(
        optchat_chief::supervisor::exiting(),
        agents.clone(),
        spec,
        Slots::new(COMPACTOR_SESSIONS),
    )
    .with_warm(2);

    optchat_host::probe(&compactor, "SYS").unwrap();
    assert_eq!(
        warm_sessions(&agents),
        Vec::<String>::new(),
        "the start-up probe started a warm compactor session"
    );

    // A chat node still leaves one warm for the next node.
    let request = optchat_host::CompactRequest {
        imported: false,
        node: optchat_host::NodeId::new(0, 0),
        system: "SYS".into(),
        context: "<chat>\n</chat>".into(),
        step: "STEP".into(),
        cut: None,
    };
    optchat_host::run_node(&compactor, &request).unwrap();
    assert_eq!(warm_sessions(&agents).len(), 1);
}
