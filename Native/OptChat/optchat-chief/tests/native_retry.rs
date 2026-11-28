//! Busy and rate-limited model calls on the native engine (parity item 8):
//! up to 8 tries, waiting the server's `retry-after` when it gives one and
//! else 2^k times the base wait (doubling), instead of a fixed wait and 6
//! tries.

mod common;

use std::collections::{BTreeMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::brain::Engine;
use optchat_chief::native::{CallError, ChatModel, Native, NativeConfig};
use serde_json::{Value, json};

const BASE: Duration = Duration::from_millis(10);

/// Answers each call with the next scripted result and keeps the times.
struct Flaky {
    results: Mutex<VecDeque<Result<Value, CallError>>>,
    calls: Mutex<Vec<Instant>>,
}

impl ChatModel for Flaky {
    fn send(&self, _body: &Value, _stop: &dyn Fn() -> bool) -> Result<Value, CallError> {
        self.calls.lock().unwrap().push(Instant::now());
        self.results
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or_else(|| Err(CallError::new("no result scripted", false)))
    }
}

fn reply() -> Value {
    json!({
        "stop_reason": "end_turn",
        "usage": {"input_tokens": 5, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 40, "output_tokens": 8},
        "content": [{"type": "text", "text": "Done."}]
    })
}

fn run(results: Vec<Result<Value, CallError>>) -> (Harness, Vec<Duration>) {
    let model = Arc::new(Flaky {
        results: Mutex::new(results.into()),
        calls: Mutex::new(Vec::new()),
    });
    let dir = tempfile::tempdir().unwrap();
    let config = NativeConfig {
        model: "claude-opus-5-5".into(),
        effort: None,
        max_tokens: 1_000,
        server_fallback: false,
        system: optchat_chief::prompt::claude_md(None),
        cwd: dir.path().to_owned(),
        env: BTreeMap::new(),
        bash_timeout: Duration::from_secs(5),
        pwd_file: dir.path().join(".pwd"),
    };
    let engine = Engine::Native(Arc::new(Native::new(config, model.clone(), BASE)));
    let mut h = Harness::with_engine(engine);
    h.connect();
    h.say("user_local", "go");
    h.settle();
    let calls = model.calls.lock().unwrap().clone();
    let gaps = calls.windows(2).map(|w| w[1] - w[0]).collect();
    (h, gaps)
}

fn busy() -> Result<Value, CallError> {
    Err(CallError::new("HTTP 529: overloaded", true))
}

#[test]
fn eight_tries_with_doubling_waits() {
    let mut results: Vec<_> = (0..7).map(|_| busy()).collect();
    results.push(Ok(reply()));
    let (h, gaps) = run(results);
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.last().unwrap().1, "Done.", "{sends:?}");
    assert_eq!(gaps.len(), 7);
    for (k, gap) in gaps.iter().enumerate() {
        assert!(*gap >= BASE * 2u32.pow(k as u32), "wait {k} was {gap:?}");
    }
}

#[test]
fn the_servers_retry_after_is_honored() {
    let wait = Duration::from_millis(300);
    let (h, gaps) = run(vec![
        busy().map_err(|e| e.with_retry_after(wait)),
        Ok(reply()),
    ]);
    assert_eq!(h.owner.lock().unwrap().sends().last().unwrap().1, "Done.");
    assert!(gaps[0] >= wait, "waited {:?}", gaps[0]);
}
