//! The engine swaps between turns (engine.rs): engine.json is read at each
//! turn start; a change runs the next turn on the new harness, model and
//! effort with that family's layout, is logged as a note, and the trace
//! records which engine answered each turn.

mod common;

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use common::*;
use optchat_chief::acpmux::Family;
use optchat_chief::brain::Settings;
use optchat_chief::engine::{EngineChoice, save};
use optchat_chief::trace::Trace;

fn harness() -> (Harness, std::path::PathBuf, std::path::PathBuf) {
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
    let traces = h.dir.path().join("traces");
    h.brain.set_trace(Trace::open(&traces, false).unwrap());
    h.agents.inner.lock().unwrap().system_prompts = true;
    h.connect();
    (h, file, traces)
}

#[test]
fn a_harness_change_applies_from_the_next_turn_and_back() {
    let (mut h, file, traces) = harness();
    h.say("user_local", "one");
    h.settle();
    save(
        &file,
        &EngineChoice {
            harness: Some("codex".into()),
            model: Some("gpt-6-sol".into()),
            effort: Some("high".into()),
            ..EngineChoice::default()
        },
    )
    .unwrap();
    h.say("user_local", "two");
    h.settle();
    save(&file, &EngineChoice::default()).unwrap();
    h.say("user_local", "three");
    h.settle();
    let agents = h.agents.inner.lock().unwrap();
    let turns: Vec<_> = agents.specs.iter().collect();
    assert_eq!(turns.len(), 3);
    assert_eq!(turns[0].harness, "claude-sr");
    assert_eq!(
        turns[0].preset.as_deref(),
        Some(TURN_PRESET),
        "Claude: the cached layout"
    );
    assert_eq!(turns[1].harness, "codex");
    assert_eq!(turns[1].model.as_deref(), Some("gpt-6-sol"));
    assert_eq!(turns[1].effort.as_deref(), Some("high"));
    assert_eq!(turns[1].preset.as_deref(), Some("optchat-chief-codex-h0me"));
    assert!(
        agents.prompts[1]
            .iter()
            .all(|b| b.get("cache_control").is_none()),
        "codex: the view as blocks, no marker"
    );
    assert_eq!(turns[2].harness, "claude-sr");
    drop(agents);
    // Each change is a note in the memory.
    let notes: Vec<String> = h
        .log()
        .into_iter()
        .filter(|(k, _)| k == "note")
        .map(|(_, t)| t)
        .collect();
    assert_eq!(notes.len(), 2, "{notes:?}");
    assert!(notes[0].starts_with("engine changed to harness=codex model=gpt-6-sol effort=high"));
    assert!(notes[1].starts_with("engine changed to harness=claude-sr"));
    // The trace says which engine answered each turn.
    let events = optchat_chief::report::read(&traces, 0).unwrap();
    let answered: Vec<&str> = events
        .iter()
        .filter(|e| e["ev"] == "turn.end")
        .filter_map(|e| e["harness"].as_str())
        .collect();
    assert_eq!(answered, vec!["claude-sr", "codex", "claude-sr"]);
    assert_eq!(events.iter().filter(|e| e["ev"] == "engine").count(), 3);
}

#[test]
fn an_unknown_harness_keeps_the_default() {
    let (mut h, file, _) = harness();
    save(
        &file,
        &EngineChoice {
            harness: Some("nope".into()),
            ..EngineChoice::default()
        },
    )
    .unwrap();
    h.say("user_local", "one");
    h.settle();
    assert_eq!(h.agents.inner.lock().unwrap().specs[0].harness, "claude-sr");
}

/// Lawrence 2026-10-09 ("just always use haiku for default compactor"):
/// the turns' harness never picks the compactor's. With no compactor
/// harness set, engine.json's turn harness (codex here) leaves the
/// compactor's choice empty, so the host gives it its Claude route. Only an
/// explicit setting (env, then engine.json's compactor-harness) picks one.
#[test]
fn the_turn_harness_never_picks_the_compactor_harness() {
    use optchat_chief::engine::compactor_harness_setting;
    let codex_turns = EngineChoice {
        harness: Some("codex".into()),
        ..EngineChoice::default()
    };
    assert_eq!(compactor_harness_setting(None, &codex_turns), None);
    let pinned = EngineChoice {
        compactor_harness: Some("claude".into()),
        ..codex_turns.clone()
    };
    assert_eq!(
        compactor_harness_setting(None, &pinned).as_deref(),
        Some("claude")
    );
    assert_eq!(
        compactor_harness_setting(Some("claude-sr".into()), &pinned).as_deref(),
        Some("claude-sr")
    );
    assert_eq!(
        compactor_harness_setting(None, &EngineChoice::default()),
        None
    );
}

/// Engine speed: engine.json's `speed` reaches a codex turn session as the
/// fast tier; `default` (or none) leaves it off. Claude Code has no fast
/// mode, so a Claude harness refuses `fast` with the reason.
#[test]
fn a_fast_codex_turn_runs_fast_and_claude_refuses_fast() {
    use optchat_chief::engine::check_speed;
    let (mut h, file, _traces) = harness();
    save(
        &file,
        &EngineChoice {
            harness: Some("codex".into()),
            speed: Some("fast".into()),
            ..EngineChoice::default()
        },
    )
    .unwrap();
    h.say("user_local", "one");
    h.settle();
    save(
        &file,
        &EngineChoice {
            harness: Some("codex".into()),
            ..EngineChoice::default()
        },
    )
    .unwrap();
    h.say("user_local", "two");
    h.settle();
    let fast: Vec<bool> = h
        .agents
        .inner
        .lock()
        .unwrap()
        .specs
        .iter()
        .map(|s| s.fast)
        .collect();
    assert_eq!(fast, [true, false]);
    assert!(check_speed("fast", Family::Codex).is_ok());
    assert!(check_speed("default", Family::Claude).is_ok());
    let refused = check_speed("fast", Family::Claude).unwrap_err();
    assert!(refused.contains("Claude Code"), "{refused}");
    assert!(check_speed("ultrafast", Family::Codex).is_err());
    // engine set flags take both speeds.
    let args: Vec<String> = [
        "engine",
        "set",
        "--speed",
        "fast",
        "--compactor-speed",
        "fast",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    let flags = optchat_chief::cli::Flags::parse(&args);
    let choice = optchat_chief::engine::apply_flags(EngineChoice::default(), &flags).unwrap();
    assert_eq!(choice.speed.as_deref(), Some("fast"));
    assert_eq!(choice.compactor_speed.as_deref(), Some("fast"));
}

/// Lawrence 2026-10-09: a codex (or any non-Claude) Chief with no compactor
/// settings builds its nodes on a Claude route (the configured CodeRouter
/// route, else the user's own claude) with Claude Haiku 5.5; a Claude Chief
/// keeps its own route (claude-sr when that is the turns').
#[test]
fn a_non_claude_chief_compacts_on_claude_haiku() {
    use optchat_chief::host::default_compactor_harness;
    assert_eq!(
        default_compactor_harness("codex", Family::Codex, "claude"),
        "claude"
    );
    assert_eq!(
        default_compactor_harness("opencode", Family::Other, "claude-cr"),
        "claude-cr"
    );
    assert_eq!(
        default_compactor_harness("claude-sr", Family::Claude, "claude"),
        "claude-sr"
    );
    assert_eq!(
        optchat_chief::compactor::compactor_model_for(Family::Claude).as_deref(),
        Some("claude-haiku-5-5")
    );
}
