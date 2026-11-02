//! Fix-forwards from the reviews of #31188 and #31191: a launch recovered
//! from the log trims its harness and model (#31193), the picker routes only
//! to families whose subagent preset was made (#31211), and the 8-task cap
//! holds before a routed spawn splits (#31212). Routing stays off by default
//! (Leo, 2026-11-01: "optional ofc we don't wanna change defaults or whatnot
//! yet").

mod common;

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use common::*;
use optchat_chief::acpmux::Family;
use optchat_chief::engine::EngineChoice;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;

fn families() -> BTreeMap<String, Family> {
    BTreeMap::from([
        ("claude".to_owned(), Family::Claude),
        ("codex".to_owned(), Family::Codex),
        ("opencode".to_owned(), Family::Other),
    ])
}

fn spawner(h: &Harness, engine_file: &std::path::Path, harness: &str) -> Arc<Spawner> {
    Arc::new(
        Spawner::new(
            h.chat.clone(),
            h.agents.clone(),
            SubagentSettings {
                harness: harness.into(),
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

fn routing_auto(dir: &tempfile::TempDir) -> std::path::PathBuf {
    let engine_file = dir.path().join("engine.json");
    optchat_chief::engine::save(
        &engine_file,
        &EngineChoice {
            subagent_routing: Some("auto".into()),
            ..EngineChoice::default()
        },
    )
    .unwrap();
    engine_file
}

/// #31193: a padded or empty harness or model in the logged spawn call is
/// trimmed or dropped, as `Call::parse` does for a live spawn.
#[test]
fn a_launch_from_the_log_trims_its_harness_and_model() {
    use optchat_core::Kind;
    let log = vec![
        (Kind::Echo, "Queued a1.\n- a1: queued (a cap)".to_owned()),
        (
            Kind::Tool,
            r#"mcp__optchat__spawn {"harness":" codex ","model":"  ","tasks":["one"]}"#.to_owned(),
        ),
    ];
    let got = optchat_chief::subagents::recover_launch("a1", log.into_iter()).expect("a1");
    assert_eq!(got.harness.as_deref(), Some("codex"));
    assert_eq!(got.model, None);
}

/// #31211 and #31212 in one test, so the settings file the env names is not
/// shared across threads.
#[test]
fn the_picker_respects_presets_and_the_task_cap() {
    let config = tempfile::NamedTempFile::new().unwrap();
    std::fs::write(config.path(), "{}").unwrap();
    // SAFETY: the only test in this binary that reads the settings file.
    unsafe { std::env::set_var("CMUX_NEXT_CONFIG_FILE", config.path()) };
    let dir = tempfile::tempdir().unwrap();
    let engine_file = routing_auto(&dir);

    // #31211: on an Other-family subagent harness the host makes only the
    // codex family preset, so a writing task stays on the default instead
    // of going to a Claude harness that has none.
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = spawner(&h, &engine_file, "opencode");
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    let a = sp.clone();
    let doc = run(&mut h, move || {
        a.spawn_with_route(
            vec!["Title: Spaces doc\nWrite the spaces design doc".to_owned()],
            None,
            None,
            None,
            None,
            None,
        )
    });
    // The test acpmux has no opencode harness, so the start itself is
    // refused; what matters is that nothing went to claude.
    let doc = doc.unwrap_or_else(|e| e);
    assert!(!doc.contains("Routed to claude"), "{doc}");
    assert!(!sub_harnesses(&h).contains(&"claude".to_owned()), "{doc}");
    // A code task still goes to codex, whose preset was made.
    let a = sp.clone();
    let code = run(&mut h, move || {
        a.spawn_with_route(
            vec!["Title: Fix CI\nFix the failing cargo test and open a PR".to_owned()],
            None,
            None,
            None,
            None,
            None,
        )
    })
    .unwrap();
    assert!(code.contains("Routed to codex"), "{code}");
    assert_eq!(sub_harnesses(&h), vec!["codex"], "{code}");

    // #31212: nine tasks of mixed kinds start nothing, though each
    // per-harness group alone would fit under the cap.
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = spawner(&h, &engine_file, "claude");
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    let tasks: Vec<String> = (0..9)
        .map(|k| {
            if k % 2 == 0 {
                format!("Title: Fix {k}\nFix the failing cargo test {k}")
            } else {
                format!("Title: Doc {k}\nWrite design doc {k}")
            }
        })
        .collect();
    let a = sp.clone();
    let nine = run(&mut h, move || {
        a.spawn_with_route(tasks, None, None, None, None, None)
    });
    let err = nine.expect_err("nine tasks");
    assert!(err.contains("at most 8"), "{err}");
    assert!(sub_harnesses(&h).is_empty());
}
