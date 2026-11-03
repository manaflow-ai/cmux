//! Per-turn native routing must reach both the API and its usage trace.

mod common;

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use optchat_chief::acpmux::SessionSpec;
use optchat_chief::native::{CallError, ChatModel, Native, NativeConfig};
use optchat_chief::trace::Trace;
use optchat_chief::turn::TurnStart;
use serde_json::{Value, json};

#[derive(Default)]
struct RecordingModel(Mutex<Vec<Value>>);

impl ChatModel for RecordingModel {
    fn send(&self, body: &Value, _: &dyn Fn() -> bool) -> Result<Value, CallError> {
        let mut calls = self.0.lock().unwrap();
        calls.push(body.clone());
        Ok(json!({
            "id": format!("message-{}", calls.len()),
            "content": [{"type": "text", "text": "Done."}],
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 5, "output_tokens": 2}
        }))
    }
}

#[test]
fn native_turns_override_model_and_effort_without_changing_defaults() {
    let dir = tempfile::tempdir().unwrap();
    let chat = common::open_chat(&dir.path().join("chat"));
    let trace_dir = dir.path().join("trace");
    let model = Arc::new(RecordingModel::default());
    let native = Native::new(
        NativeConfig {
            model: "configured-model".into(),
            effort: Some("medium".into()),
            max_tokens: 128,
            server_fallback: false,
            system: "Answer briefly.".into(),
            cwd: dir.path().to_owned(),
            env: BTreeMap::new(),
            bash_timeout: Duration::from_secs(1),
            pwd_file: dir.path().join("pwd"),
        },
        model.clone(),
        Duration::ZERO,
    )
    .with_trace(Trace::open(&trace_dir, false).unwrap());
    let cases = [
        (Some("claude-haiku-5-5"), Some("low")),
        (Some("claude-opus-5-5"), Some("medium")),
        (None, None),
    ];
    for (n, (model, effort)) in cases.into_iter().enumerate() {
        let start = TurnStart {
            key: format!("turn:native-route:{n}"),
            session: SessionSpec {
                model: model.map(str::to_owned),
                effort: effort.map(str::to_owned),
                ..Default::default()
            },
            blocks: vec![json!({"type": "text", "text": "Hello."})],
            limit: Some(Duration::from_secs(1)),
            ..Default::default()
        };
        let outcome = native.run(&chat, &start, &|_| {}, &Vec::new, &|| false);
        assert_eq!(outcome.error, None);
        assert_eq!(outcome.reply.as_deref(), Some("Done."));
    }

    let calls = model.0.lock().unwrap();
    assert_eq!(calls.len(), 3);
    let expected = [
        ("claude-haiku-5-5", "low"),
        ("claude-opus-5-5", "medium"),
        ("configured-model", "medium"),
    ];
    for (body, (model, effort)) in calls.iter().zip(expected) {
        assert_eq!(body["model"], model);
        assert_eq!(body["output_config"]["effort"], effort);
    }
    let mut requests = BTreeMap::new();
    for file in std::fs::read_dir(&trace_dir).unwrap() {
        let contents = std::fs::read_to_string(file.unwrap().path()).unwrap();
        for line in contents.lines() {
            let event: Value = serde_json::from_str(line).unwrap();
            if event["ev"] == "request" {
                requests.insert(event["turn"].as_str().unwrap().to_owned(), event);
            }
        }
    }
    assert_eq!(requests.len(), 3);
    for (n, (model, _)) in expected.into_iter().enumerate() {
        assert_eq!(requests[&format!("turn:native-route:{n}")]["model"], model);
    }
}
