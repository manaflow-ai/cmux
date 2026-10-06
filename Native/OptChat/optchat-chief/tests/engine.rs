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
