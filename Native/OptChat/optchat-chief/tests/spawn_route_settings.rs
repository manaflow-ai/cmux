//! Follow-up to #30586: routing a spawn's subagents to another harness is
//! off by default (Leo, 2026-11-01: "optional ofc we don't wanna change
//! defaults or whatnot yet"), `spawn` takes an optional `model`, and
//! `chief engine set --subagent-routing auto|off --subagent-harness H`
//! sets both in engine.json, which wins over cmux.json.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::*;
use optchat_chief::engine::{EngineChoice, apply_flags};
use optchat_chief::subagents::{Spawner, SubagentSettings, routing_on};
use optchat_chief::tools::Orchestrator;
use serde_json::json;

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
        .with_engine_file(Some(engine_file.to_path_buf())),
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

/// (harness, model) of each subagent session acpmux was asked to start.
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

fn flags(words: &[&str]) -> optchat_chief::cli::Flags {
    optchat_chief::cli::Flags::parse(&words.iter().map(|w| (*w).to_owned()).collect::<Vec<_>>())
}

#[test]
fn engine_routing_wins_over_cmux_json_and_defaults_off() {
    let auto = EngineChoice {
        subagent_routing: Some("auto".into()),
        ..EngineChoice::default()
    };
    let off = EngineChoice {
        subagent_routing: Some("off".into()),
        ..EngineChoice::default()
    };
    let on_json = json!({"chief": {"autoRouteSubagents": true}});
    let off_json = json!({"chief": {"autoRouteSubagents": false}});
    assert!(!routing_on(&EngineChoice::default(), None));
    assert!(!routing_on(&EngineChoice::default(), Some(&json!({}))));
    assert!(routing_on(&EngineChoice::default(), Some(&on_json)));
    assert!(routing_on(&auto, Some(&off_json)));
    assert!(!routing_on(&off, Some(&on_json)));
}

#[test]
fn engine_set_takes_subagent_routing_and_harness() {
    let choice = apply_flags(
        EngineChoice::default(),
        &flags(&[
            "engine",
            "set",
            "--subagent-routing",
            "auto",
            "--subagent-harness",
            "codex",
        ]),
    )
    .unwrap();
    assert_eq!(choice.subagent_routing.as_deref(), Some("auto"));
    assert_eq!(choice.subagent_harness.as_deref(), Some("codex"));
    // `off` is kept; `default` clears.
    let choice = apply_flags(
        choice,
        &flags(&[
            "engine",
            "set",
            "--subagent-routing",
            "off",
            "--subagent-harness",
            "default",
        ]),
    )
    .unwrap();
    assert_eq!(choice.subagent_routing.as_deref(), Some("off"));
    assert_eq!(choice.subagent_harness, None);
    let choice = apply_flags(
        choice,
        &flags(&["engine", "set", "--subagent-routing", "default"]),
    )
    .unwrap();
    assert_eq!(choice.subagent_routing, None);
    // Anything else is refused, naming the values it takes.
    let err = apply_flags(
        EngineChoice::default(),
        &flags(&["engine", "set", "--subagent-routing", "maybe"]),
    )
    .unwrap_err();
    assert!(err.contains("auto, off or default"), "{err}");
    assert!(optchat_chief::engine::USAGE.contains("--subagent-routing auto|off"));
    assert!(optchat_chief::engine::USAGE.contains("--subagent-harness H"));
}

/// One test, so the settings file the env names is not shared across threads.
#[test]
fn spawn_routing_follows_engine_json_and_takes_a_model() {
    let config = tempfile::NamedTempFile::new().unwrap();
    std::fs::write(config.path(), "{}").unwrap();
    // SAFETY: the only test in this binary that reads the settings file.
    unsafe { std::env::set_var("CMUX_NEXT_CONFIG_FILE", config.path()) };
    let engine_dir = tempfile::tempdir().unwrap();
    let engine_file = engine_dir.path().join("engine.json");

    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = spawner(&h, &engine_file);
    h.brain.set_sub_starter(Some(sp.queue_starter()));

    // Off by default: a named harness or model starts nothing.
    let a = sp.clone();
    let refused = run(&mut h, move || {
        a.spawn_with_route(
            vec!["refactor the parser".into()],
            None,
            None,
            None,
            Some("codex".into()),
            None,
        )
    })
    .unwrap_err();
    assert!(refused.contains("--subagent-routing auto"), "{refused}");
    let a = sp.clone();
    let refused = run(&mut h, move || {
        a.spawn_with_route(
            vec!["write the doc".into()],
            None,
            None,
            None,
            None,
            Some("claude-sonnet-5-5".into()),
        )
    })
    .unwrap_err();
    assert!(refused.contains("model"), "{refused}");
    assert!(subs(&h).is_empty());

    // engine.json turns it on, over cmux.json saying nothing.
    optchat_chief::engine::save(
        &engine_file,
        &EngineChoice {
            subagent_routing: Some("auto".into()),
            ..EngineChoice::default()
        },
    )
    .unwrap();
    let a = sp.clone();
    let routed = run(&mut h, move || {
        a.spawn_with_route(
            vec!["refactor the parser".into()],
            None,
            None,
            None,
            Some("codex".into()),
            Some("gpt-6-astra".into()),
        )
    })
    .unwrap();
    assert!(routed.contains("Started a1"), "{routed}");
    assert_eq!(
        subs(&h),
        vec![("codex".to_owned(), Some("gpt-6-astra".to_owned()))]
    );

    // A subagent harness the person set applies with routing off, to a
    // spawn that names none.
    optchat_chief::engine::save(
        &engine_file,
        &EngineChoice {
            subagent_routing: Some("off".into()),
            subagent_harness: Some("codex".into()),
            ..EngineChoice::default()
        },
    )
    .unwrap();
    let a = sp.clone();
    let plain = run(&mut h, move || {
        a.spawn_with_route(vec!["fix CI".into()], None, None, None, None, None)
    })
    .unwrap();
    assert!(plain.contains("Started a2"), "{plain}");
    assert_eq!(subs(&h).len(), 2);
    assert_eq!(subs(&h)[1].0, "codex");
}
