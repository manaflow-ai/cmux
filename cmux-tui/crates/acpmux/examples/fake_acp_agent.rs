//! A test-only ACP agent, native, for hosts without Python (the Windows
//! agent pane relay test): the answers of tests/fake_agent.py on its plain
//! path. initialize, session/new (modes and a model option), session/load
//! (one replayed user chunk), session/fork, session/set_mode,
//! session/set_config_option, session/cancel, and session/prompt: a
//! thought chunk, the text as `echo: <text>` (resource links appended as
//! `resource_link:<name>:<mime>:<uri>`), then end_turn. "slow" streams
//! three ticks and honours session/cancel. Anything else with an id gets
//! -32601. Not shipped: `cargo build --example fake_acp_agent`.

use serde_json::{Value, json};
use std::collections::HashSet;
use std::io::{BufRead, Write};
use std::sync::{Arc, Mutex};

fn send(out: &Mutex<std::io::Stdout>, message: &Value) {
    let mut out = out.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let _ = writeln!(out, "{message}");
    let _ = out.flush();
}

fn update(out: &Mutex<std::io::Stdout>, session: &str, update: Value) {
    send(
        out,
        &json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session, "update": update}}),
    );
}

fn chunk(kind: &str, text: &str) -> Value {
    json!({"sessionUpdate": kind, "content": {"type": "text", "text": text}})
}

fn prompt_text(params: &Value) -> String {
    let blocks = params.get("prompt").and_then(Value::as_array).cloned().unwrap_or_default();
    let mut text: String =
        blocks.iter().filter_map(|b| b.get("text").and_then(Value::as_str)).collect();
    let links: Vec<String> = blocks
        .iter()
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("resource_link"))
        .map(|b| {
            let field = |k: &str| b.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
            format!("resource_link:{}:{}:{}", field("name"), field("mimeType"), field("uri"))
        })
        .collect();
    if !links.is_empty() {
        text.push(' ');
        text.push_str(&links.join(" "));
    }
    text
}

fn main() {
    let out = Arc::new(Mutex::new(std::io::stdout()));
    let cancelled: Arc<Mutex<HashSet<String>>> = Arc::default();
    let mut sessions = 0u32;
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        let Ok(message) = serde_json::from_str::<Value>(line.trim()) else { continue };
        let Some(method) = message.get("method").and_then(Value::as_str) else { continue };
        let id = message.get("id").cloned();
        let params = message.get("params").cloned().unwrap_or(Value::Null);
        let reply = |result: Value| json!({"jsonrpc": "2.0", "id": id, "result": result});
        match method {
            "initialize" => send(
                &out,
                &reply(json!({
                    "protocolVersion": 1,
                    "_meta": {"steering": {"supported": false}},
                    "agentInfo": {"name": "fake", "version": "0"},
                    "agentCapabilities": {"loadSession": true, "sessionCapabilities": {"fork": {}}},
                    "authMethods": [],
                })),
            ),
            "session/new" => {
                sessions += 1;
                send(
                    &out,
                    &reply(json!({
                        "sessionId": format!("fake-{sessions}"),
                        "modes": {"currentModeId": "normal", "availableModes": [{"id": "normal", "name": "Normal"}, {"id": "strict", "name": "Strict"}]},
                        "configOptions": [{"id": "model", "name": "Model", "type": "select", "currentValue": "m1", "options": [{"value": "m1", "name": "m1"}, {"value": "m2", "name": "m2"}]}],
                    })),
                );
            }
            "session/load" => {
                let session = params.get("sessionId").and_then(Value::as_str).unwrap_or("");
                update(&out, session, chunk("user_message_chunk", "replayed"));
                send(&out, &reply(Value::Null));
            }
            "session/fork" => {
                sessions += 1;
                send(&out, &reply(json!({"sessionId": format!("fake-{sessions}")})));
            }
            "session/set_mode" => send(&out, &reply(json!({}))),
            "session/set_config_option" => send(
                &out,
                &reply(
                    json!({"configOptions": [{"id": "model", "name": "Model", "type": "select", "currentValue": params.get("value"), "options": []}]}),
                ),
            ),
            "session/cancel" => {
                if let Some(session) = params.get("sessionId").and_then(Value::as_str) {
                    cancelled
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .insert(session.to_owned());
                }
            }
            "session/prompt" => {
                let (out, cancelled) = (out.clone(), cancelled.clone());
                std::thread::spawn(move || {
                    let session =
                        params.get("sessionId").and_then(Value::as_str).unwrap_or("").to_owned();
                    let text = prompt_text(&params);
                    let end = |reason: &str| json!({"jsonrpc": "2.0", "id": id, "result": {"stopReason": reason}});
                    if text == "slow" {
                        for i in 0..3 {
                            if cancelled
                                .lock()
                                .unwrap_or_else(std::sync::PoisonError::into_inner)
                                .remove(&session)
                            {
                                send(&out, &end("cancelled"));
                                return;
                            }
                            update(
                                &out,
                                &session,
                                chunk("agent_message_chunk", &format!("tick{i} ")),
                            );
                            std::thread::sleep(std::time::Duration::from_millis(300));
                        }
                        send(&out, &end("end_turn"));
                        return;
                    }
                    update(&out, &session, chunk("agent_thought_chunk", "thinking"));
                    update(&out, &session, chunk("agent_message_chunk", &format!("echo: {text}")));
                    send(&out, &end("end_turn"));
                });
            }
            _ if id.is_some() => send(
                &out,
                &json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "no such method"}}),
            ),
            _ => {}
        }
    }
}
