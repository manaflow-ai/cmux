//! The native engine end to end against a fake Messages API: the request
//! layout and breakpoints of section 8, the log of a turn, and messages
//! delivered between tool calls (section 7).

mod common;

use std::collections::{BTreeMap, VecDeque};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use common::*;
use optchat_chief::brain::Engine;
use optchat_chief::native::{CallError, ChatModel, Native, NativeConfig};
use serde_json::{Value, json};

/// Answers each call with the next scripted message and keeps every body.
/// While `gate` is set, the first call waits.
struct Scripted {
    replies: Mutex<VecDeque<Value>>,
    bodies: Mutex<Vec<Value>>,
    gate: Mutex<bool>,
    opened: Condvar,
}

impl ChatModel for Scripted {
    fn send(&self, body: &Value, _stop: &dyn Fn() -> bool) -> Result<Value, CallError> {
        self.bodies.lock().unwrap().push(body.clone());
        {
            let mut gate = self.gate.lock().unwrap();
            while *gate {
                gate = self.opened.wait(gate).unwrap();
            }
        }
        self.replies
            .lock()
            .unwrap()
            .pop_front()
            .ok_or(CallError::new("no reply scripted", false))
    }
}

fn scripted(replies: Vec<Value>, gated: bool) -> Arc<Scripted> {
    Arc::new(Scripted {
        replies: Mutex::new(replies.into()),
        bodies: Mutex::new(Vec::new()),
        gate: Mutex::new(gated),
        opened: Condvar::new(),
    })
}

fn native(model: Arc<dyn ChatModel>, dir: &std::path::Path) -> Engine {
    let config = NativeConfig {
        model: "claude-opus-5-5".into(),
        effort: Some("high".into()),
        max_tokens: 64_000,
        server_fallback: false,
        system: optchat_chief::prompt::claude_md(None),
        cwd: dir.to_owned(),
        env: BTreeMap::new(),
        bash_timeout: Duration::from_secs(30),
        pwd_file: dir.join(".pwd"),
    };
    Engine::Native(Arc::new(Native::new(
        config,
        model,
        Duration::from_millis(10),
    )))
}

fn tool_step() -> Value {
    json!({
        "stop_reason": "tool_use",
        "usage": {"input_tokens": 10, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 900, "output_tokens": 20},
        "content": [
            {"type": "thinking", "thinking": "", "signature": "sig-1"},
            {"type": "text", "text": "Checking."},
            {"type": "tool_use", "id": "t1", "name": "bash", "input": {"command": "echo hi"}}
        ]
    })
}

fn final_step(text: &str) -> Value {
    json!({
        "stop_reason": "end_turn",
        "usage": {"input_tokens": 5, "cache_read_input_tokens": 900, "cache_creation_input_tokens": 40, "output_tokens": 8},
        "content": [{"type": "text", "text": text}]
    })
}

fn pairs(log: &[(String, String)]) -> Vec<(&str, &str)> {
    log.iter().map(|(k, t)| (k.as_str(), t.as_str())).collect()
}

#[test]
fn a_native_turn_logs_its_steps_and_lays_out_the_request_for_the_cache() {
    let model = scripted(vec![tool_step(), final_step("It says hi.")], false);
    let workdir = tempfile::tempdir().unwrap();
    let mut h = Harness::with_engine(native(model.clone(), workdir.path()));
    h.connect();
    h.say("user_local", "what does echo say?");
    h.settle();
    assert_eq!(
        pairs(&h.log()),
        vec![
            ("user", "what does echo say?"),
            ("talk", "Checking."),
            ("tool", "bash {\"command\":\"echo hi\"}"),
            ("echo", "hi\n"),
            ("talk", "It says hi."),
        ]
    );
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1);
    assert_eq!(sends[0].1, "It says hi.");
    let bodies = model.bodies.lock().unwrap().clone();
    assert_eq!(bodies.len(), 2);
    let first = &bodies[0];
    assert_eq!(first["model"], "claude-opus-5-5");
    assert_eq!(first["stream"], true);
    assert_eq!(first["output_config"]["effort"], "high");
    assert_eq!(
        first["cache_control"]["type"], "ephemeral",
        "the request end"
    );
    assert_eq!(first["tools"][0]["type"], "bash_20250124");
    assert_eq!(first["tools"][2]["name"], "zoom");
    assert_eq!(
        first["system"], bodies[1]["system"],
        "byte-identical system prompt"
    );
    assert_eq!(first["tools"], bodies[1]["tools"], "byte-identical tools");
    let opening = first["messages"][0]["content"].as_array().unwrap();
    assert_eq!(opening[0]["text"], "<chat>\n</chat>");
    assert_eq!(opening[0]["cache_control"]["type"], "ephemeral");
    assert_eq!(opening[1]["text"], "what does echo say?");
    assert!(opening[1].get("cache_control").is_none());
    let second = bodies[1]["messages"].as_array().unwrap();
    assert_eq!(second.len(), 3);
    assert_eq!(
        second[0], first["messages"][0],
        "the opening is resent unchanged"
    );
    assert_eq!(
        second[1]["content"],
        tool_step()["content"],
        "model output kept verbatim"
    );
    assert_eq!(
        second[2]["content"],
        json!([{"type": "tool_result", "tool_use_id": "t1", "content": "hi\n"}])
    );
}

#[test]
fn a_message_sent_during_a_native_turn_is_delivered_between_tool_calls() {
    let model = scripted(vec![tool_step(), final_step("A and B are fine.")], true);
    let workdir = tempfile::tempdir().unwrap();
    let mut h = Harness::with_engine(native(model.clone(), workdir.path()));
    h.connect();
    h.say("user_local", "check A");
    h.step(); // settled: the turn starts, its first call waits
    // This model ignores `stop` (a whole reply arrives at once), so the
    // message waits for the tool call it asks for, then goes with its result.
    let deadline = std::time::Instant::now() + WAIT;
    while model.bodies.lock().unwrap().is_empty() {
        assert!(std::time::Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(5));
    }
    h.say("user_local", "also check B");
    *model.gate.lock().unwrap() = false;
    model.opened.notify_all();
    h.settle();
    assert_eq!(
        pairs(&h.log()),
        vec![
            ("user", "check A"),
            ("talk", "Checking."),
            ("tool", "bash {\"command\":\"echo hi\"}"),
            ("echo", "hi\n"),
            ("user", "also check B"),
            ("talk", "A and B are fine."),
        ]
    );
    let bodies = model.bodies.lock().unwrap().clone();
    assert_eq!(
        bodies.len(),
        2,
        "one turn, no second turn for the delivered message"
    );
    assert_eq!(
        bodies[1]["messages"][2]["content"][1],
        json!({"type": "text", "text": "also check B"})
    );
    let owner = h.owner.lock().unwrap();
    assert_eq!(owner.sends().len(), 1);
    assert_eq!(
        owner.cursors(),
        vec![1, 2],
        "the cursor passes the delivered message"
    );
    assert!(
        h.agents.inner.lock().unwrap().prompts.is_empty(),
        "no acpmux session"
    );
}

#[test]
fn a_native_turn_that_is_refused_says_so() {
    let model = scripted(
        vec![json!({"stop_reason": "refusal", "content": [], "usage": {"input_tokens": 1}})],
        false,
    );
    let workdir = tempfile::tempdir().unwrap();
    let mut h = Harness::with_engine(native(model, workdir.path()));
    h.connect();
    h.say("user_local", "hello");
    h.settle();
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1);
    assert!(sends[0].1.contains("refusal"), "{sends:?}");
}

/// Streams each call's events one chunk at a time, checking `stop` after
/// every chunk as the HTTP model does. The first call pauses after
/// `pause_after` chunks until the test opens the gate.
struct Streaming {
    calls: Mutex<VecDeque<Vec<Value>>>,
    bodies: Mutex<Vec<Value>>,
    pause_after: usize,
    /// (paused, open)
    gate: Mutex<(bool, bool)>,
    changed: Condvar,
    /// Chunks the first call had fed when it saw `stop`.
    stopped_at: Mutex<Option<usize>>,
}

impl ChatModel for Streaming {
    fn send(&self, body: &Value, stop: &dyn Fn() -> bool) -> Result<Value, CallError> {
        let first = {
            let mut bodies = self.bodies.lock().unwrap();
            bodies.push(body.clone());
            bodies.len() == 1
        };
        let events = self
            .calls
            .lock()
            .unwrap()
            .pop_front()
            .expect("a scripted call");
        let mut assembler = optchat_chief::native::Assembler::default();
        for (i, event) in events.iter().enumerate() {
            assembler.feed(event);
            if first && i + 1 == self.pause_after {
                let mut gate = self.gate.lock().unwrap();
                gate.0 = true;
                self.changed.notify_all();
                while !gate.1 {
                    gate = self.changed.wait(gate).unwrap();
                }
            }
            if stop() {
                if first {
                    *self.stopped_at.lock().unwrap() = Some(i + 1);
                }
                return Err(CallError::interrupted());
            }
        }
        assembler.finish().map_err(|e| CallError::new(e, false))
    }
}

fn thinking_stream() -> Vec<Value> {
    let mut events = vec![
        json!({"type": "message_start", "message": {"role": "assistant", "content": [], "usage": {"input_tokens": 1}}}),
        json!({"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": "", "signature": ""}}),
    ];
    for i in 0..20 {
        events.push(json!({"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": format!("step {i}. ")}}));
    }
    events.extend([
        json!({"type": "content_block_stop", "index": 0}),
        json!({"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}}),
        json!({"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "Half an ans"}}),
        json!({"type": "content_block_stop", "index": 1}),
        json!({"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 9}}),
        json!({"type": "message_stop"}),
    ]);
    events
}

fn final_stream(text: &str) -> Vec<Value> {
    vec![
        json!({"type": "message_start", "message": {"role": "assistant", "content": [], "usage": {"input_tokens": 1}}}),
        json!({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
        json!({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}}),
        json!({"type": "content_block_stop", "index": 0}),
        json!({"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 3}}),
        json!({"type": "message_stop"}),
    ]
}

// m6 (decision 2026-10-04): a human message stops the model at once, even
// mid-thinking, and a new call starts with the message delivered.
#[test]
fn a_message_during_thinking_aborts_the_stream_and_starts_a_new_call() {
    let model = Arc::new(Streaming {
        calls: Mutex::new(vec![thinking_stream(), final_stream("You're welcome.")].into()),
        bodies: Mutex::new(Vec::new()),
        pause_after: 4,
        gate: Mutex::new((false, false)),
        changed: Condvar::new(),
        stopped_at: Mutex::new(None),
    });
    let workdir = tempfile::tempdir().unwrap();
    let mut h = Harness::with_engine(native(model.clone(), workdir.path()));
    h.connect();
    h.say("user_local", "plan the release");
    h.step(); // settled: the turn starts and streams
    {
        let mut gate = model.gate.lock().unwrap();
        while !gate.0 {
            gate = model.changed.wait_timeout(gate, WAIT).unwrap().0;
        }
    }
    h.say("user_local", "thanks");
    {
        let mut gate = model.gate.lock().unwrap();
        gate.1 = true;
        model.changed.notify_all();
    }
    h.settle();
    assert_eq!(
        *model.stopped_at.lock().unwrap(),
        Some(4),
        "the stream stops at the first chunk after the message"
    );
    assert_eq!(
        pairs(&h.log()),
        vec![
            ("user", "plan the release"),
            ("user", "thanks"),
            ("talk", "You're welcome."),
        ],
        "nothing of the interrupted step is logged"
    );
    let bodies = model.bodies.lock().unwrap().clone();
    assert_eq!(bodies.len(), 2);
    let messages = bodies[1]["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 1, "the interrupted output is not resent");
    let opening = messages[0]["content"].as_array().unwrap();
    assert_eq!(
        opening.last().unwrap(),
        &json!({"type": "text", "text": "thanks"})
    );
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1);
    assert_eq!(sends[0].1, "You're welcome.");
}

// m6: a running tool call finishes, its result is logged and sent, then the
// new call carries the message (no step of the model's own in between).
#[test]
fn thanks_during_a_tool_lets_the_tool_finish_then_starts_a_new_call() {
    let step = json!({
        "stop_reason": "tool_use",
        "usage": {"input_tokens": 1},
        "content": [{"type": "tool_use", "id": "t1", "name": "bash", "input": {"command": "sleep 1; echo built"}}]
    });
    let model = scripted(vec![step, final_step("Built; you're welcome.")], false);
    let workdir = tempfile::tempdir().unwrap();
    let mut h = Harness::with_engine(native(model.clone(), workdir.path()));
    h.connect();
    h.say("user_local", "build it");
    h.step(); // settled: the turn starts
    let deadline = std::time::Instant::now() + WAIT;
    while model.bodies.lock().unwrap().is_empty() {
        assert!(std::time::Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    h.say("user_local", "thanks");
    h.settle();
    assert_eq!(
        pairs(&h.log()),
        vec![
            ("user", "build it"),
            ("tool", "bash {\"command\":\"sleep 1; echo built\"}"),
            ("echo", "built\n"),
            ("user", "thanks"),
            ("talk", "Built; you're welcome."),
        ]
    );
    let bodies = model.bodies.lock().unwrap().clone();
    assert_eq!(bodies.len(), 2);
    assert_eq!(
        bodies[1]["messages"][2]["content"],
        json!([
            {"type": "tool_result", "tool_use_id": "t1", "content": "built\n"},
            {"type": "text", "text": "thanks"}
        ])
    );
}

/// An image sent while a native turn runs reaches the model with the
/// delivered text, between tool calls, in the Messages API's shape.
#[test]
fn an_image_sent_during_a_native_turn_is_delivered_with_its_text() {
    const HASH: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    let model = scripted(vec![tool_step(), final_step("It says ORCHID.")], true);
    let workdir = tempfile::tempdir().unwrap();
    let mut h = Harness::with_engine(native(model.clone(), workdir.path()));
    h.owner
        .lock()
        .unwrap()
        .attachments
        .insert((HASH.into(), "original".into()), "QUJD".into());
    h.connect();
    h.say("user_local", "check A");
    h.step();
    let deadline = std::time::Instant::now() + WAIT;
    while model.bodies.lock().unwrap().is_empty() {
        assert!(std::time::Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(5));
    }
    h.say_parts(
        "user_local",
        vec![
            cmux_conversation::Part::Attachment {
                hash: HASH.into(),
                name: "shot.png".into(),
                mime_type: "image/png".into(),
                byte_count: 3,
                width: None,
                height: None,
                duration_ms: None,
                poster: None,
                preview: None,
            },
            cmux_conversation::Part::Text {
                text: "what does this say?".into(),
                runs: None,
            },
        ],
    );
    *model.gate.lock().unwrap() = false;
    model.opened.notify_all();
    h.settle();
    let bodies = model.bodies.lock().unwrap().clone();
    assert_eq!(bodies.len(), 2, "delivered in the same turn");
    let content = bodies[1]["messages"][2]["content"]
        .as_array()
        .unwrap()
        .clone();
    assert_eq!(
        content[1],
        json!({"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "QUJD"}})
    );
    assert_eq!(
        content[2],
        json!({"type": "text", "text": "what does this say?\n[image sha256:0123456789ab \"shot.png\" image/png]"})
    );
}
