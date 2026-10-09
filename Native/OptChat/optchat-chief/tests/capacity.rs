//! A turn whose model route has no capacity now ("503 no non-exhausted
//! claude accounts available ... (retry after Ns)") is not a failure: the
//! Chief waits the retry-after, quietly, and runs the same turn again; a
//! newer message ends the wait at once. Nothing but the reply is posted.

mod common;

use std::sync::{Arc, Mutex};

use common::*;
use serde_json::json;

fn owner() -> Arc<Mutex<Owner>> {
    Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }))
}

const EXHAUSTED: &str = "API Error: 503 no non-exhausted claude accounts available; next account frees up in 1m (retry after 1s). This is a server-side issue, usually temporary";

#[test]
fn a_turn_on_an_exhausted_route_waits_and_runs_again_with_no_error_posted() {
    let lines = Arc::new(Mutex::new(Vec::<String>::new()));
    let sink = lines.clone();
    let dir = tempfile::tempdir().unwrap();
    let s = settings(dir.path());
    let script: Script = Box::new(|turn, blocks| {
        if turn == 0 {
            vec![
                json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                json!({"dir": "mux", "kind": "turn_error", "msg": {"error": EXHAUSTED}}),
            ]
        } else {
            default_script()(turn, blocks)
        }
    });
    let mut h = Harness::configured(
        dir,
        script,
        owner(),
        s,
        Arc::new(move |l: &str| sink.lock().unwrap().push(l.to_owned())),
    );
    h.agents.inner.lock().unwrap().answer_error = Some(EXHAUSTED.into());
    h.connect();
    h.say("user_local", "hello");
    h.settle();
    let prompts = h.agents.inner.lock().unwrap().prompts.len();
    assert_eq!(
        prompts, 2,
        "the refused turn, then the same turn after the retry-after"
    );
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1, "only the reply: {sends:?}");
    assert!(!sends[0].1.contains("turn failed"), "{sends:?}");
    assert!(!sends[0].1.contains("503"), "{sends:?}");
    assert!(
        lines
            .lock()
            .unwrap()
            .iter()
            .any(|l| l.contains("no capacity") && l.contains("again")),
        "one quiet log line: {:?}",
        lines.lock().unwrap()
    );
}

#[test]
fn capacity_errors_are_told_from_other_errors() {
    use optchat_chief::turn::capacity_retry_after;
    use std::time::Duration;
    assert_eq!(
        capacity_retry_after(EXHAUSTED),
        Some(Duration::from_secs(1))
    );
    assert_eq!(
        capacity_retry_after("API Error: 529 overloaded_error (retry after 30s)"),
        Some(Duration::from_secs(30))
    );
    // No retry-after given: a short default, not forever.
    assert_eq!(
        capacity_retry_after("API Error: 503 no non-exhausted claude accounts available"),
        Some(Duration::from_secs(60))
    );
    assert_eq!(
        capacity_retry_after("API Error: 400 invalid_request_error"),
        None
    );
    assert_eq!(
        capacity_retry_after("No conversation found with session ID x"),
        None
    );
}

const UNREACHABLE: &str = "API Error: Connection error. (Can't reach the API server: getaddrinfo ENOTFOUND api.anthropic.com)";

#[test]
fn a_turn_that_cannot_reach_the_api_retries_with_backoff_and_posts_only_the_reply() {
    let dir = tempfile::tempdir().unwrap();
    let s = settings(dir.path());
    let script: Script = Box::new(|turn, blocks| {
        if turn < 2 {
            vec![
                json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                json!({"dir": "mux", "kind": "turn_error", "msg": {"error": UNREACHABLE}}),
            ]
        } else {
            default_script()(turn, blocks)
        }
    });
    let mut h = Harness::configured(dir, script, owner(), s, Arc::new(|_: &str| {}));
    h.agents.inner.lock().unwrap().answer_error = Some(UNREACHABLE.into());
    h.connect();
    h.say("user_local", "hello");
    h.settle();
    assert_eq!(h.agents.inner.lock().unwrap().prompts.len(), 3, "two failures, then the reply");
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1, "only the reply: {sends:?}");
    assert!(!sends[0].1.contains("turn failed"), "{sends:?}");
}

#[test]
fn connection_errors_back_off_and_end() {
    use optchat_chief::turn::transient_retry_after;
    use std::time::Duration;
    assert_eq!(transient_retry_after(UNREACHABLE, 0), Some(Duration::from_secs(1)));
    assert_eq!(transient_retry_after(UNREACHABLE, 3), Some(Duration::from_secs(8)));
    assert_eq!(transient_retry_after("fetch failed: ECONNREFUSED", 6), Some(Duration::from_secs(60)));
    assert_eq!(transient_retry_after(UNREACHABLE, 8), None, "8 tries, then the turn fails");
    // A capacity refusal keeps its own retry-after.
    assert_eq!(transient_retry_after(EXHAUSTED, 0), Some(Duration::from_secs(1)));
    assert_eq!(transient_retry_after("API Error: 400 invalid_request_error", 0), None);
}
