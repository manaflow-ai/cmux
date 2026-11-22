//! `spawn(harness)` routes a spawn's subagents to another harness than the
//! Chief's own (Leo, 2026-11-01: "maybe toggle off-able but if you look into
//! grokbot they auto route stuff all the time"), unless the person turned it
//! off with cmux.json `chief.autoRouteSubagents`.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::*;
use optchat_chief::subagents::{Spawner, SubagentSettings, auto_route_on};
use optchat_chief::tools::Orchestrator;
use serde_json::json;

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

/// The harness of each subagent session acpmux was asked to start.
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

/// Off by default (Leo, 2026-11-01: "optional ofc we don't wanna change
/// defaults or whatnot yet"): only the person turns it on.
#[test]
fn auto_route_is_off_unless_the_person_turns_it_on() {
    assert!(!auto_route_on(None));
    assert!(!auto_route_on(Some(&json!({}))));
    assert!(auto_route_on(Some(
        &json!({"chief": {"autoRouteSubagents": true}})
    )));
    assert!(!auto_route_on(Some(
        &json!({"chief": {"autoRouteSubagents": false}})
    )));
    assert!(!auto_route_on(Some(
        &json!({"chief.autoRouteSubagents": false})
    )));
}

/// One test, so the settings file the env names is not shared across threads.
#[test]
fn spawn_harness_routes_the_subagents_and_the_setting_turns_it_off() {
    let config = tempfile::NamedTempFile::new().unwrap();
    std::fs::write(config.path(), r#"{"chief": {"autoRouteSubagents": true}}"#).unwrap();
    // SAFETY: the only test in this binary that reads the settings file.
    unsafe { std::env::set_var("CMUX_NEXT_CONFIG_FILE", config.path()) };

    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = spawner(&h);
    h.brain.set_sub_starter(Some(sp.queue_starter()));

    // No harness: the Chief's own.
    let a = sp.clone();
    let plain = run(&mut h, move || {
        a.spawn_routed(vec!["write the doc".into()], None, None, None, None)
    })
    .unwrap();
    assert!(plain.contains("Started a1"), "{plain}");
    // Routed: on codex, though the Chief runs on Claude.
    let a = sp.clone();
    let routed = run(&mut h, move || {
        a.spawn_routed(
            vec!["refactor the parser".into()],
            None,
            None,
            None,
            Some("codex".into()),
        )
    })
    .unwrap();
    assert!(routed.contains("Started a2"), "{routed}");
    let harnesses = sub_harnesses(&h);
    assert_eq!(harnesses.len(), 2, "{harnesses:?}");
    assert_ne!(harnesses[0], "codex", "{harnesses:?}");
    assert_eq!(harnesses[1], "codex", "{harnesses:?}");

    // The person turned routing off: a named harness starts nothing.
    std::fs::write(config.path(), r#"{"chief": {"autoRouteSubagents": false}}"#).unwrap();
    let a = sp.clone();
    let refused = run(&mut h, move || {
        a.spawn_routed(
            vec!["refactor again".into()],
            None,
            None,
            None,
            Some("codex".into()),
        )
    })
    .unwrap_err();
    assert!(refused.contains("chief.autoRouteSubagents"), "{refused}");
    assert_eq!(sub_harnesses(&h).len(), 2);
}

#[test]
fn pinned_harness_controls_machine_login_selection_and_cached_auth_fallback() {
    for cached_signed_out in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        let mut settings = settings(dir.path());
        // Host startup supplies the catalog's families to the brain.
        settings.families = [
            ("claude-sr".into(), optchat_chief::acpmux::Family::Claude),
            ("claude".into(), optchat_chief::acpmux::Family::Claude),
            ("codex".into(), optchat_chief::acpmux::Family::Codex),
        ]
        .into();
        let mut h = Harness::configured(
            dir,
            default_script(),
            Arc::new(std::sync::Mutex::new(Owner {
                summary: Some(summary()),
                ..Owner::default()
            })),
            settings,
            Arc::new(|_| {}),
        );
        h.agents.hold(true);
        {
            let mut agents = h.agents.inner.lock().unwrap();
            agents.machine_status = Some(json!({
                "here": {"os": "macos", "pressure": {"ok": true}},
                "peers": [{"name": "mini", "connected": true,
                    "health": {"os": "macos", "pressure": {"ok": true}}}]
            }));
            agents.peer_catalogs.insert("mini".into(), catalog());
            agents.harness_health.insert(
                "mini".into(),
                json!({"harnesses": [
                    {"id": "claude", "auth": "signedIn"}
                ]}),
            );
            if cached_signed_out {
                agents.harness_health.insert(
                    "here".into(),
                    json!({"harnesses": [
                        {"id": "codex", "auth": "signedOut"}
                    ]}),
                );
            }
        }
        let engine = h.dir.path().join("engine.json");
        optchat_chief::engine::save(
            &engine,
            &optchat_chief::engine::EngineChoice {
                subagent_harness: Some("claude".into()),
                ..Default::default()
            },
        )
        .unwrap();
        let sp = Arc::new(
            Spawner::new(
                h.chat.clone(),
                h.agents.clone(),
                SubagentSettings {
                    harness: "codex".into(),
                    policy: "approve-all".into(),
                    model: None,
                    effort: None,
                    preset: None,
                    cwd: h.dir.path().join("subagent"),
                    prefix: "optchat-sub-h0me".into(),
                    parent: optchat_chief::brain::PARENT.into(),
                    claude_md: None,
                },
                h.tx.clone(),
                Arc::new(|_: &str| {}),
            )
            .with_pinned_harness(true)
            .with_engine_file(Some(engine)),
        );
        let answer = run(&mut h, move || {
            sp.spawn(vec!["build a hello web page".into()], None)
        })
        .unwrap();
        let agents = h.agents.inner.lock().unwrap();
        let specs: Vec<_> = agents
            .specs
            .iter()
            .filter(|s| s.tags.contains_key("optchat.subagent"))
            .collect();
        assert_eq!(specs.len(), 1, "{answer}");
        assert_eq!(
            specs[0].harness, "codex",
            "the pin wins over the engine and cached auth: {answer}"
        );
        assert_eq!(
            specs[0].peer, None,
            "the paired Mac has no Codex login: {answer}"
        );
    }
}
