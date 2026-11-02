//! Review follow-ups of #31020:
//! - #31163: a pinned subagent harness (OPTCHAT_SUBAGENT_HARNESS) still
//!   lets a spawn pick the model, with routing on; only `harness` is refused.
//! - #31164: a queued subagent keeps the model its spawn chose in its saved
//!   launch, so a host restart starts it on that model.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::*;
use optchat_chief::engine::EngineChoice;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{ControlCall, Orchestrator};

fn spawner(h: &Harness, engine_file: &std::path::Path, pinned: bool) -> Arc<Spawner> {
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
        .with_engine_file(Some(engine_file.to_path_buf()))
        .with_pinned_harness(pinned),
    )
}

fn run<T: Send + 'static>(h: &mut Harness, f: impl FnOnce() -> T + Send + 'static) -> T {
    let worker = std::thread::spawn(f);
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(80)) {
        h.brain.step(input);
    }
    worker.join().unwrap()
}

fn subs(h: &Harness) -> Vec<(String, Option<String>)> {
    h.agents
        .inner
        .lock()
        .unwrap()
        .specs
        .iter()
        .filter(|s| s.tags.contains_key("optchat.subagent"))
        .map(|s| (s.harness.clone(), s.model.clone()))
        .collect()
}

fn routing_auto(dir: &tempfile::TempDir) -> std::path::PathBuf {
    let file = dir.path().join("engine.json");
    optchat_chief::engine::save(
        &file,
        &EngineChoice {
            subagent_routing: Some("auto".into()),
            ..EngineChoice::default()
        },
    )
    .unwrap();
    file
}

/// #31163.
#[test]
fn a_pinned_harness_still_takes_a_model() {
    let dir = tempfile::tempdir().unwrap();
    let engine_file = routing_auto(&dir);
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = spawner(&h, &engine_file, true);
    h.brain.set_sub_starter(Some(sp.queue_starter()));

    // The pin refuses another harness...
    let a = sp.clone();
    let refused = run(&mut h, move || {
        a.spawn_with_route(
            vec!["refactor it".into()],
            None,
            None,
            None,
            Some("codex".into()),
            None,
        )
    })
    .unwrap_err();
    assert!(refused.contains("OPTCHAT_SUBAGENT_HARNESS"), "{refused}");
    // ...but a model on the pinned harness starts.
    let a = sp.clone();
    let started = run(&mut h, move || {
        a.spawn_with_route(
            vec!["write the doc".into()],
            None,
            None,
            None,
            None,
            Some("claude-sonnet-5-5".into()),
        )
    })
    .unwrap();
    assert!(started.contains("Started a1"), "{started}");
    assert_eq!(
        subs(&h),
        vec![("claude".to_owned(), Some("claude-sonnet-5-5".to_owned()))]
    );
}

/// #31164.
#[test]
fn a_queued_subagent_saves_its_model() {
    let dir = tempfile::tempdir().unwrap();
    let engine_file = routing_auto(&dir);
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = spawner(&h, &engine_file, false);
    h.brain.set_sub_starter(Some(sp.queue_starter()));

    // One at a time: the second task queues.
    let a = sp.clone();
    run(&mut h, move || {
        a.control(ControlCall {
            action: "cap".into(),
            n: Some(1),
            ..ControlCall::default()
        })
    })
    .unwrap();
    let a = sp.clone();
    let answer = run(&mut h, move || {
        a.spawn_with_route(
            vec!["one".into(), "two".into()],
            None,
            None,
            None,
            Some("codex".into()),
            Some("gpt-6-astra".into()),
        )
    })
    .unwrap();
    assert!(answer.contains("a2: queued"), "{answer}");
    let saved = h
        .brain
        .state()
        .sub("a2")
        .expect("a2")
        .1
        .queued_launch
        .clone()
        .expect("a2's saved launch");
    assert_eq!(saved.harness.as_deref(), Some("codex"));
    assert_eq!(saved.model.as_deref(), Some("gpt-6-astra"));
}

/// #31164: a launch rebuilt from the log keeps the spawn call's harness and
/// model too (the record was not saved).
#[test]
fn a_launch_from_the_log_keeps_its_harness_and_model() {
    use optchat_core::Kind;
    let log = vec![
        (Kind::Echo, "Queued a2.\n- a1: started\n- a2: queued (a cap)".to_owned()),
        (
            Kind::Tool,
            r#"mcp__optchat__spawn {"harness":"codex","model":"gpt-6-astra","tasks":["one","two"]}"#
                .to_owned(),
        ),
    ];
    let got = optchat_chief::subagents::recover_launch("a2", log.into_iter()).expect("a2");
    assert_eq!(got.task, "two");
    assert_eq!(got.harness.as_deref(), Some("codex"));
    assert_eq!(got.model.as_deref(), Some("gpt-6-astra"));
}
