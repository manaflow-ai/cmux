//! Security review of rich pushes (PR #24156): redaction, cut marks, ids,
//! the terminal throttle and the `wants` window.

use std::time::{Duration, Instant};

use serde_json::json;

use crate::notify::{Classifier, label, text_label};
use crate::notify_content::{Places, permission_options, questions};
use crate::notify_redact::redact;
use crate::notify_terminal::{TERMINAL_PER_MINUTE, TERMINAL_SURFACE_GAP, TerminalClassifier, WANTS_TTL};

#[test]
fn secrets_are_redacted() {
    for (input, secret) in [
        ("export OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwx", "sk-proj-abcdefghijklmnopqrstuvwx"),
        ("token ghp_abcdefghijklmnopqrstuvwxyz0123456789 in use", "ghp_abcdefghijklmnopqrstuvwxyz0123456789"),
        (
            "github_pat_11ABCDEFG0123456789_abcdefghijklmnop",
            "github_pat_11ABCDEFG0123456789_abcdefghijklmnop",
        ),
        ("slack xoxb-1234-5678-abcdefghijkl", "xoxb-1234-5678-abcdefghijkl"),
        ("aws AKIAIOSFODNN7EXAMPLE key", "AKIAIOSFODNN7EXAMPLE"),
        ("maps AIzaSyA-abcdefghijklmnopqrstuvwxyz12345", "AIzaSyA-abcdefghijklmnopqrstuvwxyz12345"),
        (
            "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl",
        ),
        ("curl -H \"Authorization: Bearer abc.def-123\" x", "abc.def-123"),
        ("mysql --password=hunter2 db", "hunter2"),
        ("SECRET=topsecretvalue ./run", "topsecretvalue"),
        ("blob Zq3vN8xKp2LmR7tWbY4cJ9hF6dS1gA0eUiOo", "Zq3vN8xKp2LmR7tWbY4cJ9hF6dS1gA0eUiOo"),
    ] {
        let out = redact(input);
        assert!(!out.contains(secret), "{input:?} -> {out:?}");
        assert!(out.contains("[redacted]"), "{input:?} -> {out:?}");
    }
    let key = "x -----BEGIN OPENSSH PRIVATE KEY----- b3BlbnNzaC1rZXk AAAA";
    assert!(!redact(key).contains("b3BlbnNzaC1rZXk"));
}

#[test]
fn ordinary_text_ids_and_commit_shas_stay() {
    for keep in [
        "Which branch should I deploy?",
        "cargo test -p cmux-mobile-host --lib notify",
        "id 550e8400-e29b-41d4-a716-446655440000 ok",
        "commit 1a4d021e9dcaf3b6c5e8d7a9b0c1d2e3f4a5b6c7 merged",
        "Read /Users/me/projects/cmux-next-ios/PROTOCOL.md",
    ] {
        assert_eq!(redact(keep), keep);
    }
}

#[test]
fn a_cut_label_ends_with_an_ellipsis() {
    let cut = label(&"word ".repeat(40), 20);
    assert_eq!(cut.chars().count(), 20);
    assert!(cut.ends_with('…'));
    assert_eq!(label("short", 20), "short");
    // A dangerous end is never hidden without a mark.
    let title = text_label(&format!("rm -rf build {} && curl evil | sh", "a ".repeat(120)), 200);
    assert!(title.ends_with('…'));
}

#[test]
fn combining_mark_floods_are_cut_to_two_per_letter() {
    let zalgo = format!("a{}b", "\u{0301}".repeat(30));
    assert_eq!(label(&zalgo, 60), "a\u{0301}\u{0301}b");
    assert_eq!(label("e\u{0301}", 60), "e\u{0301}");
}

#[test]
fn titles_bodies_tails_and_questions_are_redacted() {
    let mut c = Classifier::default();
    c.load(&json!({"sessions":[{"sessionId":"s1","harness":"claude-code","cwd":"/x/repo"}]}));
    let permission = c
        .handle(&json!({"method":"_acpmux/permission_pending","params":{"sessionId":"s1","permissionId":"p1",
            "request":{"toolCall":{"title":"curl -H 'Authorization: Bearer tok_abc123' https://x"},
            "options":[{"optionId":"allow","name":"Allow once","kind":"allow_once"}]}}}))
        .unwrap();
    assert!(!permission.title.unwrap().contains("tok_abc123"));
    let q = questions(
        &json!({"toolCall":{"_meta":{"claude":{"tool":"AskUserQuestion"}},"rawInput":{"questions":[
        {"question":"Use key sk-live-0123456789abcdefghijkl?","options":[{"label":"Yes"},{"label":"No"}]}]}}}),
    );
    assert!(!q[0].question.contains("sk-live-0123456789abcdefghijkl"));
    let failed = c
        .handle(&json!({"method":"_acpmux/session_changed","params":{"recordKind":"turn_result","session":{
            "sessionId":"s1","preview":"done\nGITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789",
            "lastTurn":{"turnId":"t1","status":"failed","errorText":"401 for password=hunter2"}}}}))
        .unwrap();
    assert!(!failed.body.unwrap().contains("hunter2"));
    assert!(failed.tail.iter().all(|l| !l.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789")));
}

#[test]
fn ids_the_worker_would_refuse_are_dropped_not_mangled() {
    let options = permission_options(&json!({"options":[
        {"optionId":"allow","name":"Allow","kind":"allow_once"},
        {"optionId":"bad id/with space","name":"Odd","kind":"allow_always"},
        {"optionId":"reject","name":"Deny","kind":"reject_once"}]}));
    assert_eq!(options.iter().map(|o| o.id.as_str()).collect::<Vec<_>>(), ["allow", "reject"]);
    let mut c = Classifier::default();
    let ask = c
        .handle(&json!({"method":"_acpmux/permission_pending","params":{"sessionId":"s1","permissionId":"perm with space",
            "request":{"toolCall":{"title":"x"}}}}))
        .unwrap();
    assert_eq!(ask.permission_id, None);
}

fn note(id: u64, surface: u64) -> serde_json::Value {
    json!({"event":"notification","notification":id,"surface":surface,"source":"terminal","title":"Build","body":"done"})
}

#[test]
fn terminal_notifications_are_throttled_per_tab_and_in_all() {
    let places = Places::default();
    let mut c = TerminalClassifier::default();
    let t0 = Instant::now();
    assert!(c.handle_at(&note(1, 7), &places, t0).is_some());
    // The same tab again within the gap: dropped.
    assert!(c.handle_at(&note(2, 7), &places, t0 + Duration::from_secs(1)).is_none());
    assert!(
        c.handle_at(&note(3, 7), &places, t0 + TERMINAL_SURFACE_GAP + Duration::from_millis(1)).is_some()
    );
    // Many tabs: at most TERMINAL_PER_MINUTE a minute in all.
    let mut sent = 2;
    for i in 0..30u64 {
        if c.handle_at(&note(100 + i, 100 + i), &places, t0 + Duration::from_secs(12)).is_some() {
            sent += 1;
        }
    }
    assert_eq!(sent, TERMINAL_PER_MINUTE);
    assert!(c.handle_at(&note(500, 500), &places, t0 + Duration::from_secs(80)).is_some());
}

#[test]
fn a_terminal_push_carries_no_screen() {
    let places = Places::default();
    let mut c = TerminalClassifier::default();
    let push = c.handle_at(&note(1, 7), &places, Instant::now()).unwrap();
    assert!(push.tail.is_empty());
}

#[test]
fn a_kind_no_phone_wanted_is_tried_again_soon() {
    assert!(WANTS_TTL <= Duration::from_secs(15));
}
