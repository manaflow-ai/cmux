//! The automatic harness picker (spawn_route.rs): with routing on and a
//! spawn that names no harness or model, each task goes to the harness its
//! kind fits, as grokbot routes (Leo, 2026-10-31: "if you look into grokbot
//! they auto route stuff all the time", "we wanna be at least as good as
//! grokbot"). Routing stays off by default (Leo, 2026-11-01: "optional ofc
//! we don't wanna change defaults or whatnot yet").

mod common;

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use common::*;
use optchat_chief::acpmux::Family;
use optchat_chief::engine::EngineChoice;
use optchat_chief::spawn_route::{TaskKind, classify, pick};
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;

fn families() -> BTreeMap<String, Family> {
    BTreeMap::from([
        ("claude".to_owned(), Family::Claude),
        ("claude-sr2".to_owned(), Family::Claude),
        ("codex".to_owned(), Family::Codex),
    ])
}

fn all(_: &str) -> bool {
    true
}

fn none_offered(_: &str) -> Vec<String> {
    Vec::new()
}

#[test]
fn tasks_are_classified_by_kind() {
    assert_eq!(
        classify("Title: Fix CI\nFix the failing cargo test in acpmux and open a PR"),
        Some(TaskKind::Code)
    );
    assert_eq!(
        classify("Title: Refactor parser\nRefactor the Rust parser"),
        Some(TaskKind::Code)
    );
    assert_eq!(
        classify("Title: Spaces plan\nResearch the spaces design and summarize it in a doc"),
        Some(TaskKind::Writing)
    );
    assert_eq!(
        classify("Review PR 31020 at its head and post a verdict"),
        Some(TaskKind::Review)
    );
    assert_eq!(
        classify("Wait for the nightly run and relay its status"),
        Some(TaskKind::Mechanical)
    );
    // Nothing to go on: no pick.
    assert_eq!(classify("hello there"), None);
}

#[test]
fn each_kind_picks_its_harness() {
    let fam = families();
    // A Claude Chief: code goes to codex, writing stays on claude (no
    // route), review crosses to the other family.
    let code = pick("fix the failing cargo test", "claude", &fam, &all, &none_offered).unwrap();
    assert_eq!(code.harness, "codex");
    assert_eq!(code.kind, TaskKind::Code);
    assert!(pick("write the design doc", "claude", &fam, &all, &none_offered).is_none());
    let review = pick("review the PR", "claude", &fam, &all, &none_offered).unwrap();
    assert_eq!(review.harness, "codex");
    // A Codex Chief: writing and review go to Claude, preferring the plain
    // `claude` profile.
    let doc = pick("write the design doc", "codex", &fam, &all, &none_offered).unwrap();
    assert_eq!(doc.harness, "claude");
    let review = pick("review the PR", "codex", &fam, &all, &none_offered).unwrap();
    assert_eq!(review.harness, "claude");
    assert!(pick("fix the failing cargo test", "codex", &fam, &all, &none_offered).is_none());
    // Mechanical: a small model when the harness offers one.
    let haiku = |_: &str| vec!["claude-opus-5-5".to_owned(), "claude-haiku-5-5".to_owned()];
    let small = pick("wait for the run and relay its status", "claude", &fam, &all, &haiku).unwrap();
    assert_eq!(small.harness, "claude");
    assert_eq!(small.model.as_deref(), Some("claude-haiku-5-5"));
    assert!(
        pick("wait for the run and relay its status", "claude", &fam, &all, &none_offered).is_none()
    );
    // Only a harness acpmux has and the grant allows.
    let no_codex = |h: &str| h != "codex";
    assert!(pick("fix the failing cargo test", "claude", &fam, &no_codex, &none_offered).is_none());
    let claude_only = BTreeMap::from([("claude".to_owned(), Family::Claude)]);
    assert!(pick("fix the failing cargo test", "claude", &claude_only, &all, &none_offered).is_none());
    // Unclear: stay.
    assert!(pick("hello there", "claude", &fam, &all, &none_offered).is_none());
}

fn spawner(h: &Harness, engine_file: &std::path::Path) -> Arc<Spawner> {
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
        .with_families(families()),
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

fn sub_harnesses(h: &Harness) -> Vec<String> {
    h.agents
        .inner
        .lock()
        .unwrap()
        .specs
        .iter()
        .filter(|s| s.tags.contains_key("optchat.subagent"))
        .map(|s| s.harness.clone())
        .collect()
}

/// One test, so the settings file the env names is not shared across threads.
#[test]
fn a_spawn_routes_each_task_only_when_routing_is_on() {
    let config = tempfile::NamedTempFile::new().unwrap();
    std::fs::write(config.path(), "{}").unwrap();
    // SAFETY: the only test in this binary that reads the settings file.
    unsafe { std::env::set_var("CMUX_NEXT_CONFIG_FILE", config.path()) };
    let dir = tempfile::tempdir().unwrap();
    let engine_file = dir.path().join("engine.json");

    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = spawner(&h, &engine_file);
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    let tasks = || {
        vec![
            "Title: Fix CI\nFix the failing cargo test and open a PR".to_owned(),
            "Title: Spaces doc\nWrite the spaces design doc".to_owned(),
        ]
    };

    // Off (the default): every task on the Chief's subagent harness.
    let a = sp.clone();
    let t = tasks();
    let off = run(&mut h, move || a.spawn_with_route(t, None, None, None, None, None)).unwrap();
    assert!(!off.contains("Routed"), "{off}");
    assert_eq!(sub_harnesses(&h), vec!["claude", "claude"]);

    // On: the code task goes to codex, the doc stays on claude, and the
    // answer names the pick.
    optchat_chief::engine::save(
        &engine_file,
        &EngineChoice {
            subagent_routing: Some("auto".into()),
            ..EngineChoice::default()
        },
    )
    .unwrap();
    let a = sp.clone();
    let t = tasks();
    let on = run(&mut h, move || a.spawn_with_route(t, None, None, None, None, None)).unwrap();
    assert!(on.contains("Routed to codex"), "{on}");
    assert!(on.contains("code task"), "{on}");
    let mut routed = sub_harnesses(&h)[2..].to_vec();
    routed.sort();
    assert_eq!(routed, vec!["claude", "codex"]);

    // A named harness wins over the picker.
    let a = sp.clone();
    let t = tasks();
    let named = run(&mut h, move || {
        a.spawn_with_route(t, None, None, None, Some("claude".into()), None)
    })
    .unwrap();
    assert!(!named.contains("Routed"), "{named}");
    assert_eq!(sub_harnesses(&h)[4..].to_vec(), vec!["claude", "claude"]);
}
