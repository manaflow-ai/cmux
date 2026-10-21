//! One Claude Code session per Chief across turns (`Settings::keep_turn_session`,
//! the Unii baseline's shape; plans/cmux-next/unii-vs-chief-harness-DESIGN.md):
//! a turn that keeps the frozen view prompts the session the last turn left
//! with only its new messages, so it starts no process and its input is a
//! cached prefix plus a few new tokens. The session runs with Claude Code's
//! own cache marks (ours would pile up in its history past the API's four).
//! A failed turn ends its session, and the next one starts fresh with the
//! whole view again.

mod common;

use std::sync::{Arc, Mutex};

use common::*;
use optchat_chief::brain::Settings;
use optchat_core::Kind;
use serde_json::Value;

fn fill(chat: &optchat_host::OptChat, n: usize) {
    for i in 0..n {
        chat.append(
            Kind::Note,
            &format!("note {i:04}: the build cache for project {i} lives in /srv/cache/{i}"),
        )
        .unwrap();
    }
    assert!(chat.wait_idle(None, Some(WAIT)));
}

fn texts(blocks: &[Value]) -> Vec<String> {
    blocks
        .iter()
        .map(|b| b["text"].as_str().unwrap_or_default().to_owned())
        .collect()
}

fn marked(blocks: &[Value]) -> bool {
    blocks.iter().any(|b| b.get("cache_control").is_some())
}

fn kept(dir: &std::path::Path) -> Settings {
    Settings {
        keep_turn_session: true,
        ..settings(dir)
    }
}

fn harness() -> Harness {
    let dir = tempfile::tempdir().unwrap();
    let s = kept(dir.path());
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let h = Harness::configured(dir, default_script(), owner, s, Arc::new(|_: &str| {}));
    h.agents.inner.lock().unwrap().system_prompts = true;
    h
}

fn logged(h: &Harness, kind: &str, text: &str) -> Vec<u64> {
    h.log()
        .iter()
        .enumerate()
        .filter(|(_, (k, t))| k == kind && t == text)
        .map(|(i, _)| i as u64)
        .collect()
}

fn session_settings(h: &Harness) -> Value {
    let path = h
        .dir
        .path()
        .join("session")
        .join(".claude")
        .join("settings.json");
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

#[test]
fn consecutive_turns_reuse_one_claude_code_session_and_send_only_the_new_messages() {
    let mut h = harness();
    fill(&h.chat, 120);
    h.connect();
    h.say("user_local", "one");
    h.settle();
    h.say("user_local", "two");
    h.settle();
    let two = logged(&h, "user", "two")[0];
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.specs.len(), 1, "one session for both turns");
    assert_eq!(inner.prompt_sessions, vec!["s1", "s1"]);
    assert!(!inner.ended.contains(&"s1".to_owned()), "the session stays");
    let (a, b) = (&inner.prompts[0], &inner.prompts[1]);
    assert!(
        texts(a)[0].starts_with("<chat>"),
        "the first turn sends the view"
    );
    // The second turn: only its new message (plus per-turn state), no view.
    let tb = texts(b);
    assert!(
        tb.iter().all(|t| !t.contains("<chat>")),
        "no view again: {tb:?}"
    );
    assert_eq!(tb[0], format!("{two}+1|user: two\n"));
    // Claude Code's own marks: ours would pile up in the session's history.
    assert!(!marked(a) && !marked(b));
    drop(inner);
    let s = session_settings(&h);
    assert!(s["env"].get("DISABLE_PROMPT_CACHING").is_none(), "{s}");
    assert_eq!(s["promptCacheTtl"], "1h");
    // Each turn folded only its own events: one reply each, none twice.
    assert_eq!(logged(&h, "talk", "answer 0").len(), 1);
    assert_eq!(logged(&h, "talk", "answer 1").len(), 1);
}

#[test]
fn a_failed_turn_ends_its_session_and_the_next_turn_starts_fresh_with_the_view() {
    let mut h = harness();
    fill(&h.chat, 120);
    h.connect();
    h.agents.inner.lock().unwrap().answer_error = Some("boom".into());
    h.say("user_local", "one");
    h.settle();
    h.say("user_local", "two");
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.specs.len(), 2, "a new session after the failure");
    assert!(inner.ended.contains(&"s1".to_owned()));
    let last = inner.prompts.last().unwrap();
    assert!(texts(last)[0].starts_with("<chat>"), "the view again");
}

#[test]
fn without_the_setting_each_turn_still_gets_a_fresh_session() {
    let dir = tempfile::tempdir().unwrap();
    let s = settings(dir.path());
    assert!(!s.keep_turn_session);
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let mut h = Harness::configured(dir, default_script(), owner, s, Arc::new(|_: &str| {}));
    h.agents.inner.lock().unwrap().system_prompts = true;
    fill(&h.chat, 120);
    h.connect();
    h.say("user_local", "one");
    h.settle();
    h.say("user_local", "two");
    h.settle();
    assert_eq!(h.agents.inner.lock().unwrap().specs.len(), 2);
}
