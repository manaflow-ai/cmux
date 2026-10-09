//! The brain's engine and stop control (chief.engine.get / chief.engine.set
//! / chief.stop, 2026-10-08): the one op behind the CLI's `chief-control`
//! and the Home Chief Settings panel of a Chief on a paired server. The
//! brain reads and writes its own engine.json, refuses an unknown harness
//! or effort with a typed error instead of a silent fallback, answers the
//! last turns' engines, and stops a running turn as a newer message does.

mod common;

use std::collections::BTreeMap;
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};

use common::*;
use optchat_chief::acpmux::Family;
use optchat_chief::brain::{EngineRequest, Input, Settings};
use serde_json::{Value, json};

fn harness(script: Script) -> (Harness, std::path::PathBuf) {
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
    let mut h = Harness::configured(dir, script, owner, settings, Arc::new(|_: &str| {}));
    h.brain
        .set_trace(optchat_chief::trace::Trace::open(&h.dir.path().join("traces"), false).unwrap());
    h.connect();
    (h, file)
}

fn engine(h: &mut Harness, request: EngineRequest) -> Value {
    let (reply, answer) = channel();
    h.brain.step(Input::Engine { request, reply });
    answer.recv().unwrap()
}

fn set(harness: Option<&str>, model: Option<&str>, effort: Option<&str>) -> EngineRequest {
    EngineRequest::Set {
        harness: harness.map(str::to_owned),
        model: model.map(str::to_owned),
        effort: effort.map(str::to_owned),
    }
}

#[test]
fn engine_show_answers_the_resolved_engine_and_the_last_turn() {
    let (mut h, _) = harness(default_script());
    h.say("user_local", "hi");
    h.settle();
    let v = engine(&mut h, EngineRequest::Show);
    assert_eq!(v["engine"]["harness"], "claude-sr", "{v}");
    assert_eq!(v["engine"]["effort"], "medium", "{v}");
    assert_eq!(v["last_turn"]["harness"], "claude-sr", "{v}");
    assert_eq!(v["last_turn"]["status"], "ok", "{v}");
    assert!(v["recent"].as_array().is_some_and(|r| r.len() == 1), "{v}");
}

#[test]
fn engine_set_writes_engine_json_and_the_next_turn_runs_on_it() {
    let (mut h, file) = harness(default_script());
    let v = engine(&mut h, set(Some("codex"), Some("gpt-6-sol"), Some("high")));
    assert_eq!(v["engine"]["harness"], "codex", "{v}");
    assert_eq!(v["engine"]["model"], "gpt-6-sol", "{v}");
    let saved: Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
    assert_eq!(
        saved,
        json!({"harness": "codex", "model": "gpt-6-sol", "effort": "high"})
    );
    // An absent field stays; "default" clears one.
    let v = engine(&mut h, set(None, Some("default"), None));
    assert_eq!(v["engine"]["harness"], "codex", "{v}");
    assert_eq!(v["engine"]["model"], Value::Null, "{v}");
    h.say("user_local", "hi");
    h.settle();
    assert_eq!(h.agents.inner.lock().unwrap().specs[0].harness, "codex");
}

#[test]
fn engine_set_refuses_an_unknown_harness_or_effort_with_a_typed_error() {
    let (mut h, file) = harness(default_script());
    let v = engine(&mut h, set(Some("claude-nope"), None, None));
    assert_eq!(v["error"]["code"], "unknown_harness", "{v}");
    let v = engine(&mut h, set(None, None, Some("ludicrous")));
    assert_eq!(v["error"]["code"], "invalid_effort", "{v}");
    assert!(!file.exists(), "nothing written on a refusal");
}

/// Turn 0 runs on until it is stopped (no turn end); later turns answer.
fn open_first() -> Script {
    let rest = default_script();
    Box::new(move |turn, blocks| {
        if turn == 0 {
            vec![
                json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                update(
                    "agent_message_chunk",
                    json!({"content": {"type": "text", "text": "half done"}}),
                ),
            ]
        } else {
            rest(turn, blocks)
        }
    })
}

#[test]
fn stop_cancels_the_running_turn_and_says_so() {
    let (mut h, _) = harness(open_first());
    let (reply, answer) = channel();
    h.brain.step(Input::Stop { reply });
    assert_eq!(
        answer.recv().unwrap(),
        json!({"stopped": false}),
        "no turn runs"
    );
    h.agents.hold(true);
    h.say("user_local", "a long task");
    h.step();
    h.agents.wait_prompts(1);
    let (reply, answer) = channel();
    h.brain.step(Input::Stop { reply });
    assert_eq!(answer.recv().unwrap(), json!({"stopped": true}));
    h.agents.wait_cancels(1);
    h.settle();
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(
        sends.last().map(|(_, t)| t.as_str()),
        Some("half done\n\n(turn stopped)"),
        "{sends:?}"
    );
}
