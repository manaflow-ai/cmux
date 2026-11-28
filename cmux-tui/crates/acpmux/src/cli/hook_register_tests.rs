use super::*;
use serde_json::json;

/// Repro (Lawrence, 2026-11-28): an ask after a code expired delivered a new one. An
/// answer that settles the chat (reached, or no code coming) leaves the mark; a waiting
/// code does not.
#[test]
fn only_a_settled_answer_leaves_the_mark() {
    let home = tempfile::tempdir().unwrap();
    let sock = "/tmp/cc-socks/77.sock";
    let mark = mark_path(home.path(), sock, "tok");
    mark_if_reached(home.path(), sock, "tok", &json!({"pending": true, "name": "x"}));
    assert!(!mark.exists());
    mark_if_reached(home.path(), sock, "tok", &json!({"offered": false, "reason": "r"}));
    assert!(mark.exists());
    assert!(!mark_path(home.path(), sock, "tok2").exists(), "a restarted process");
    assert!(settled(&json!({"offered": true})));
    assert!(!settled(&json!({"pending": true, "resent": false})));
    assert!(reached(&json!({"reachable": true})));
    assert!(reached(&json!({"renewed": true})));
    assert!(!reached(&json!({"renewed": null, "retryable": true})));
    assert!(!reached(&json!({"failed": "x", "repeat": true})));
}
