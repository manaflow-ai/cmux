//! chief.engine.get names the models and efforts the Chief can take: the
//! Home Chief Settings panel listed three hard-coded model ids whatever acpmux
//! offered (cx-miuo, ownership audit V-2). The models are acpmux's for the
//! engine's harness (`_acpmux/models`), the efforts the brain checks a set
//! against.

mod common;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};

use optchat_chief::acpmux::{Acpmux, AgentEvent};
use optchat_chief::brain::{Brain, EngineRequest, Input, Settings};
use optchat_chief::state::StateFile;
use serde_json::{Value, json};

/// A fake acpmux whose `_acpmux/models` offers two harnesses.
fn serve(listener: UnixListener) {
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            std::thread::spawn(move || {
                let mut out = conn.try_clone().unwrap();
                for line in BufReader::new(conn).lines() {
                    let Ok(line) = line else { return };
                    let req: Value = serde_json::from_str(&line).unwrap();
                    let id = req["id"].clone();
                    let result = match req["method"].as_str().unwrap_or("") {
                        "_acpmux/sessions" => json!({"sessions": []}),
                        "_acpmux/models" => json!({"harnesses": [
                            {"harness": "codex", "kind": "acp", "models": [
                                {"id": "gpt-6-sol", "name": "GPT-6 Sol"},
                            ]},
                            {"harness": "claude-sr", "kind": "claude-stdio", "models": [
                                {"id": "default", "name": "Default (Claude Code's choice)"},
                                {"id": "opus", "name": "Opus"},
                                {"id": "claude-fable-5-1", "name": "Fable 5.1"},
                            ]},
                        ]}),
                        _ => json!({}),
                    };
                    writeln!(
                        out,
                        "{}",
                        json!({"jsonrpc": "2.0", "id": id, "result": result})
                    )
                    .unwrap();
                }
            });
        }
    });
}

#[test]
fn the_engine_answer_offers_the_harness_models_acpmux_has() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("acpmux.sock");
    serve(UnixListener::bind(&socket).unwrap());
    let acpmux = Acpmux::new(socket, None, Vec::new());
    let (events, up) = channel();
    let sink = Mutex::new(events);
    acpmux.spawn_link(
        Arc::new(move |e| {
            let _ = sink.lock().unwrap().send(e);
        }),
        Arc::new(|_: &str| {}),
    );
    while !matches!(up.recv_timeout(common::WAIT).unwrap(), AgentEvent::Up(_)) {}

    let settings = Settings {
        engine_file: Some(dir.path().join("engine.json")),
        ..common::settings(dir.path())
    };
    let (tx, _rx) = channel();
    let mut brain = Brain::new(
        common::open_chat(&dir.path().join("chat")),
        acpmux,
        settings,
        StateFile::new(&dir.path().join("host.json")),
        tx,
        Arc::new(|_: &str| {}),
    );
    let (reply, answer) = channel();
    brain.step(Input::Engine {
        request: EngineRequest::Show,
        reply,
    });
    let answer = answer.recv_timeout(common::WAIT).unwrap();

    assert_eq!(answer["engine"]["harness"], "claude-sr", "{answer:#}");
    let models: Vec<&str> = answer["offered"]["models"]
        .as_array()
        .unwrap_or_else(|| panic!("no offered models: {answer:#}"))
        .iter()
        .filter_map(|m| m["id"].as_str())
        .collect();
    assert_eq!(models, ["default", "opus", "claude-fable-5-1"]);
    assert_eq!(answer["offered"]["models"][2]["name"], "Fable 5.1");
    assert_eq!(
        answer["offered"]["efforts"],
        json!(["minimal", "low", "medium", "high", "xhigh", "max"])
    );
}
