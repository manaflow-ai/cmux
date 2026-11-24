//! Each main Chief turn ends with `<turn-checks>`: what to check at the turn's
//! start and end (Leo, 2026-11-24: agents are not ambitious enough, patch
//! instead of fixing the cause, don't think outside the box, "especially at
//! the beginnings and ends of turns"). In the per-turn tail after the delta,
//! never in the cached prefix; a subagent's prompt never carries it.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::*;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;
use serde_json::Value;

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

#[test]
fn a_main_turn_ends_with_turn_checks_and_a_subagent_prompt_has_none() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "hello there");
    h.settle_posts();

    let sp = spawner(&h);
    let worker = std::thread::spawn(move || sp.spawn(vec!["Fix the flaky test.".into()], None));
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    worker.join().unwrap().unwrap();

    let inner = h.agents.inner.lock().unwrap();
    let subagent_sessions: Vec<String> = inner
        .specs
        .iter()
        .enumerate()
        .filter(|(_, s)| s.tags.contains_key("optchat.subagent"))
        .map(|(k, _)| format!("s{}", k + 1))
        .collect();
    assert!(!subagent_sessions.is_empty(), "a subagent session");
    let mut main_turns = 0;
    let mut sub_prompts = 0;
    for (blocks, session) in inner.prompts.iter().zip(&inner.prompt_sessions) {
        let text = Value::Array(blocks.clone()).to_string();
        if subagent_sessions.contains(session) {
            sub_prompts += 1;
            assert!(!text.contains("<turn-checks>"), "subagent prompt: {text}");
        } else if text.contains("hello there") {
            main_turns += 1;
            assert!(text.contains("<turn-checks>"), "main turn: {text}");
            assert!(
                text.contains(chief_kernel::TURN_CHECKS.trim().split('\n').next().unwrap()),
                "the shared text: {text}"
            );
            // The tail's last block: after the delta, never before a mark.
            let last = blocks.last().and_then(|b| b["text"].as_str()).unwrap_or("");
            assert!(last.trim_end().ends_with("</turn-checks>"), "{last}");
        }
    }
    assert!(
        main_turns > 0 && sub_prompts > 0,
        "{main_turns} {sub_prompts}"
    );
}
