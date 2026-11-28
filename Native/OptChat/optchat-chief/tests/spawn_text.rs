//! A turn that starts subagents posts words beside their chips (user
//! 2026-11-05, msg 22013). A spawn turn that ends with no text gets the
//! start host-posted (`[a1] started: TITLE`, Lucas's latency plan item 3),
//! with no extra Chief turn; a spawn turn that said something gets neither.

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::brain::NO_TEXT_TAG;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{Orchestrator, SendCall};
use serde_json::{Value, json};

/// The Chief's first turn says `first` ("" says nothing); a `[no text]`
/// turn says `after`; a subagent's turn says "done".
fn script(first: &'static str, after: &'static str) -> Script {
    Box::new(move |_, blocks: &[Value]| {
        let prompt = serde_json::to_string(blocks).unwrap_or_default();
        let text = if prompt.contains("SUB-TASK") {
            "done"
        } else if prompt.contains(NO_TEXT_TAG) {
            after
        } else {
            first
        };
        let mut events = vec![json!({"dir": "mux", "kind": "turn_started", "msg": {}})];
        if !text.is_empty() {
            events.push(update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": text}}),
            ));
        }
        events.push(json!({"dir": "mux", "kind": "turn_end", "msg": {}}));
        events
    })
}

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

/// Runs `f` on its own thread while the brain takes its inputs.
fn run<T: Send + 'static>(h: &mut Harness, f: impl FnOnce() -> T + Send + 'static) -> T {
    let worker = std::thread::spawn(f);
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    worker.join().unwrap()
}

/// The Chief's prompts (not its subagents'), in order.
fn chief_prompts(h: &Harness) -> Vec<String> {
    h.agents
        .inner
        .lock()
        .unwrap()
        .prompts
        .iter()
        .map(|b| serde_json::to_string(b).unwrap())
        .filter(|p| !p.contains("SUB-TASK"))
        .collect()
}

/// A turn for "start the fix" runs, held at the fake agent; it spawns a1 and
/// optionally sends `send` before it ends.
fn spawn_turn(h: &mut Harness, send: Option<&'static str>) {
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "start the fix");
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.poll_step();
    }
    let sp = spawner(h);
    let started = run(h, move || {
        sp.spawn(vec!["Title: Fix it\n\nSUB-TASK fix it".into()], None)
    });
    assert!(started.is_ok(), "{started:?}");
    if let Some(text) = send {
        let sp = spawner(h);
        let sent = run(h, move || {
            sp.send(SendCall {
                text: Some(text.to_owned()),
                ..SendCall::default()
            })
        });
        assert!(sent.is_ok_and(|s| s.starts_with("outcome: done")));
    }
    h.agents.hold(false);
    h.agents.release();
}

/// Steps the brain until `done` holds or 10 s pass.
fn settle_until(h: &mut Harness, done: impl Fn(&Harness) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !done(h) && Instant::now() < deadline {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
    }
    h.settle_posts();
}

#[test]
fn a_spawn_turn_with_no_text_gets_its_start_host_posted() {
    let mut h = Harness::new(script("", "Started a1 on the fix."));
    spawn_turn(&mut h, None);
    let posted = |h: &Harness| {
        h.owner
            .lock()
            .unwrap()
            .sends()
            .iter()
            .any(|(key, text)| key == "host-spawn:a1" && text == "[a1] started: Fix it")
    };
    settle_until(&mut h, posted);
    assert!(
        posted(&h),
        "the host posted the start: {:?}",
        h.owner.lock().unwrap().sends()
    );
    // No Chief turn was spent relaying it: no `[no text]` turn follows.
    settle_until(&mut h, |_| false);
    let prompts = chief_prompts(&h);
    assert_eq!(prompts.len(), 1, "{prompts:?}");
    assert!(
        prompts.iter().all(|p| !p.contains(NO_TEXT_TAG)),
        "{prompts:?}"
    );
}

#[test]
fn a_spawn_turn_that_sends_words_gets_no_note() {
    let mut h = Harness::new(script("", "unused"));
    spawn_turn(&mut h, Some("Started a1 on the fix."));
    settle_until(&mut h, |_| false);
    let prompts = chief_prompts(&h);
    assert!(
        prompts.iter().all(|p| !p.contains(NO_TEXT_TAG)),
        "{prompts:?}"
    );
}

#[test]
fn a_spawn_turn_whose_reply_has_words_gets_no_note() {
    let mut h = Harness::new(script("Started a1 on the fix.", "unused"));
    spawn_turn(&mut h, None);
    settle_until(&mut h, |_| false);
    let prompts = chief_prompts(&h);
    assert!(
        prompts.iter().all(|p| !p.contains(NO_TEXT_TAG)),
        "{prompts:?}"
    );
}
