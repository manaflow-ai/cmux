//! Opt-in routing changes a turn's model, never its harness or saved defaults.
mod common;

use common::*;
use optchat_chief::{engine, trace::Trace, usage::Fold};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};

#[test]
fn routing_changes_each_turn_and_records_the_pick() {
    for (family, routing, text, model, tier) in [
        ("claude", "auto", "thanks!", "claude-haiku-5-5", "triage"),
        (
            "claude",
            "auto",
            "review this design and decide between A and B, why",
            "claude-opus-5-5",
            "hard",
        ),
        (
            "claude",
            "auto",
            "What time is it?",
            "claude-sonnet-5-5",
            "standard",
        ),
        ("codex", "auto", "review this design", "gpt-6.1-sol", "hard"),
        ("claude", "off", "review this design", "saved-model", ""),
        ("claude", "default", "review this design", "saved-model", ""),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("engine.json");
        let mut saved =
            json!({"model": "saved-model", "effort": "medium", "turn_routing": routing});
        if routing == "default" {
            saved.as_object_mut().unwrap().remove("turn_routing");
        }
        std::fs::write(&file, saved.to_string()).unwrap();
        let mut s = settings(dir.path());
        s.engine_file = Some(file.clone());
        s.families.insert(
            s.harness.clone(),
            if family == "codex" {
                optchat_chief::acpmux::Family::Codex
            } else {
                optchat_chief::acpmux::Family::Claude
            },
        );
        let trace_dir = dir.path().join("traces");
        let mut h = Harness::configured(
            dir,
            default_script(),
            Arc::new(Mutex::new(Owner {
                summary: Some(summary()),
                ..Owner::default()
            })),
            s,
            Arc::new(|_| {}),
        );
        h.brain.set_trace(Trace::open(&trace_dir, false).unwrap());
        h.connect();
        h.say("user_local", text);
        h.settle_posts();
        let (reply, answer) = std::sync::mpsc::channel();
        h.brain.step(optchat_chief::brain::Input::SpawnRegister {
            tasks: vec!["do the task".into()],
            peer: None,
            place: Some("local".into()),
            harness: None,
            machines: Vec::new(),
            reply,
        });
        let spawn = answer
            .recv_timeout(std::time::Duration::from_secs(2))
            .unwrap()
            .unwrap();
        assert_eq!(
            spawn.engine.unwrap().model.as_deref(),
            Some("saved-model"),
            "own-turn routing must not change subagent defaults"
        );
        let specs = &h.agents.inner.lock().unwrap().specs;
        let spec = specs
            .iter()
            .find(|s| s.name.starts_with(TURN_PREFIX))
            .unwrap();
        assert_eq!(spec.harness, "claude-sr", "the login stays put");
        assert_eq!(spec.model.as_deref(), Some(model), "{routing}: {text}");
        assert_eq!(
            serde_json::from_str::<Value>(&std::fs::read_to_string(file).unwrap()).unwrap(),
            saved
        );
        let events = optchat_chief::report::read(&trace_dir, 0).unwrap();
        let end = events.iter().find(|e| e["ev"] == "turn.end").unwrap();
        let line = serde_json::to_value(Fold::new().observe(end, "live").unwrap()).unwrap();
        assert_eq!(line["model"], model);
        if !tier.is_empty() {
            let route = events.iter().position(|e| e["ev"] == "turn.route").unwrap();
            let start = events.iter().position(|e| e["ev"] == "turn.start").unwrap();
            assert!(route < start);
            assert_eq!(events[route]["tier"], tier);
            assert_eq!(events[route]["family"], family);
            assert_eq!(events[route]["turn"], end["turn"]);
            assert_eq!(line["tier"], tier);
            assert!(!line["route"].as_str().unwrap().is_empty());
        } else {
            assert!(line["tier"].is_null());
        }
    }
}

#[test]
fn turn_routing_flags_validate_clear_and_survive_presets() {
    let mut choice = engine::EngineChoice::default();
    for (value, expected) in [
        ("auto", json!("auto")),
        ("off", json!("off")),
        ("default", Value::Null),
    ] {
        let flags = optchat_chief::cli::Flags::parse(
            &["engine", "set", "--turn-routing", value].map(str::to_owned),
        );
        choice = engine::apply_flags(choice, &flags).unwrap();
        assert_eq!(
            serde_json::to_value(&choice).unwrap()["turn_routing"],
            expected
        );
        let preset = engine::apply_preset(choice.clone(), "opus").unwrap();
        assert_eq!(
            serde_json::to_value(preset).unwrap()["turn_routing"],
            expected
        );
    }
    let flags = optchat_chief::cli::Flags::parse(
        &["engine", "set", "--turn-routing", "maybe"].map(str::to_owned),
    );
    assert!(engine::apply_flags(choice, &flags).is_err());
    let old: optchat_chief::usage::Line = serde_json::from_value(json!({"model": "old"})).unwrap();
    assert!(serde_json::to_value(old).unwrap()["tier"].is_null());
}
