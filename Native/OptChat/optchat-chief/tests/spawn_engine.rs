//! Subagents run on the Chief's engine (2026-10-08: the Chief Settings
//! said codex, gpt-6-sol; turns ran on codex, but `spawn` started its
//! subagents on the harness the host started with, claude-sr). A spawn
//! takes the harness and model of the turn that called it, with that
//! family's subagent preset; with no engine.json it stays on the host's
//! subagent harness.

mod common;

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use common::*;
use optchat_chief::acpmux::Family;
use optchat_chief::brain::Settings;
use optchat_chief::engine::{EngineChoice, save};
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;

struct Setup {
    h: Harness,
    spawner: Arc<Spawner>,
    file: std::path::PathBuf,
}

fn setup() -> Setup {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("engine.json");
    let settings = Settings {
        engine_file: Some(file.clone()),
        families: BTreeMap::from([
            ("claude-sr".to_owned(), Family::Claude),
            ("codex".to_owned(), Family::Codex),
        ]),
        codex_preset: Some("optchat-chief-codex-h0me".into()),
        ..settings(dir.path())
    };
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let mut h = Harness::configured(
        dir,
        default_script(),
        owner,
        settings,
        Arc::new(|_: &str| {}),
    );
    h.agents.inner.lock().unwrap().catalog = Some(catalog());
    h.connect();
    let spawner = Spawner::new(
        h.chat.clone(),
        h.agents.clone(),
        SubagentSettings {
            harness: "claude-sr".into(),
            policy: "approve-all".into(),
            model: None,
            preset: Some("optchat-sub-h0me".into()),
            cwd: h.dir.path().join("subagent"),
            prefix: "optchat-sub-h0me".into(),
            parent: optchat_chief::brain::PARENT.into(),
            claude_md: None,
        },
        h.tx.clone(),
        Arc::new(|_: &str| {}),
    );
    Setup {
        h,
        spawner: Arc::new(spawner),
        file,
    }
}

fn spawn(s: &mut Setup, tasks: &[&str]) -> String {
    let tasks: Vec<String> = tasks.iter().map(|t| t.to_string()).collect();
    let spawner = s.spawner.clone();
    let worker = std::thread::spawn(move || spawner.spawn(tasks, None));
    while !worker.is_finished() {
        if let Ok(input) = s.h.rx.recv_timeout(std::time::Duration::from_millis(20)) {
            s.h.brain.step(input);
        }
    }
    while let Ok(input) = s.h.rx.recv_timeout(std::time::Duration::from_millis(50)) {
        s.h.brain.step(input);
    }
    worker.join().unwrap().unwrap()
}

#[test]
fn a_spawn_runs_its_subagents_on_the_chiefs_engine() {
    let mut s = setup();
    save(
        &s.file,
        &EngineChoice {
            harness: Some("codex".into()),
            model: Some("gpt-6-sol".into()),
            ..EngineChoice::default()
        },
    )
    .unwrap();
    s.h.say("user_local", "can u make some subagents");
    s.h.settle();
    let answer = spawn(&mut s, &["list the files"]);
    assert!(answer.contains("a1"), "{answer}");
    let agents = s.h.agents.inner.lock().unwrap();
    assert_eq!(agents.specs[0].harness, "codex", "the turn ran on codex");
    let sub = agents.specs.last().unwrap();
    assert_eq!(sub.name, "optchat-sub-h0me-a1");
    assert_eq!(
        sub.harness, "codex",
        "the subagent runs on the Chief's harness"
    );
    assert_eq!(sub.model.as_deref(), Some("gpt-6-sol"));
    assert_eq!(sub.preset.as_deref(), Some("optchat-sub-h0me-codex"));
}

#[test]
fn without_an_engine_choice_a_spawn_stays_on_the_hosts_subagent_harness() {
    let mut s = setup();
    s.h.say("user_local", "hello");
    s.h.settle();
    spawn(&mut s, &["list the files"]);
    let agents = s.h.agents.inner.lock().unwrap();
    let sub = agents.specs.last().unwrap();
    assert_eq!(sub.harness, "claude-sr");
    assert_eq!(sub.model, None);
    assert_eq!(sub.preset.as_deref(), Some("optchat-sub-h0me"));
}
