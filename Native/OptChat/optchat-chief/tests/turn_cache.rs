//! The prompt cache across consecutive turns on the Claude Code path, as
//! measured with a capture proxy on the requests Claude Code 2.1.287 sends
//! (2026-10-08):
//!
//! - Two consecutive turns send the same bytes up to the earlier turn's
//!   mark, and the later turn's mark is within the API's 20-block lookback
//!   of it, even after a turn that added hundreds of view lines.
//! - Our mark is a 1-hour mark by default, and the session's Claude Code
//!   settings pin `promptCacheTtl` to the same TTL: the API refuses a 1h mark
//!   after a 5m one, and Claude Code marks blocks before and after ours.
//! - `cache.ttl` in the Chief's settings picks 5 minutes instead.
//! - A route that refuses the 1-hour TTL reruns the turn at 5 minutes, and
//!   later turns stay at 5 minutes.

mod common;

use std::sync::{Arc, Mutex};

use common::*;
use optchat_core::Kind;
use serde_json::{Value, json};

fn fill(chat: &optchat_host::OptChat, from: usize, n: usize) {
    for i in from..from + n {
        chat.append(
            Kind::Note,
            &format!(
                "note {i:04}: the build cache for project {i} lives in /srv/cache/{i} on host b{i}"
            ),
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

fn markers(blocks: &[Value]) -> Vec<usize> {
    blocks
        .iter()
        .enumerate()
        .filter(|(_, b)| b.get("cache_control").is_some())
        .map(|(i, _)| i)
        .collect()
}

fn owner() -> Arc<Mutex<Owner>> {
    Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }))
}

/// The session directory's Claude Code project settings.
fn session_settings(h: &Harness, file: &str) -> Value {
    let path = h.dir.path().join("session").join(".claude").join(file);
    serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap()
}

fn claude_harness(chief_settings: Option<Value>) -> Harness {
    let dir = tempfile::tempdir().unwrap();
    if let Some(value) = chief_settings {
        std::fs::write(dir.path().join("settings.json"), value.to_string()).unwrap();
    }
    let s = settings(dir.path());
    let h = Harness::configured(dir, default_script(), owner(), s, Arc::new(|_: &str| {}));
    h.agents.inner.lock().unwrap().system_prompts = true;
    h
}

const ONE_HOUR: fn() -> Value = || json!({"type": "ephemeral", "ttl": "1h"});

#[test]
fn consecutive_turns_send_the_same_bytes_up_to_the_last_mark_and_mark_within_the_lookback() {
    let mut h = claude_harness(None);
    fill(&h.chat, 0, 1_200);
    h.connect();
    h.say("user_local", "one");
    h.settle();
    // A long tool run between two turns: 160 new view lines, 40 blocks,
    // twice the API's lookback.
    fill(&h.chat, 1_200, 160);
    h.say("user_local", "two");
    h.settle();
    h.say("user_local", "three");
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.prompts.len(), 3);
    for pair in inner.prompts.windows(2) {
        let (a, b) = (&pair[0], &pair[1]);
        let (ma, mb) = (markers(a), markers(b));
        assert_eq!(ma.len(), 1, "one mark of ours per request");
        assert_eq!(mb.len(), 1, "one mark of ours per request");
        let (ma, mb) = (ma[0], mb[0]);
        // Every byte up to and including the earlier mark is unchanged...
        assert_eq!(texts(a)[..=ma], texts(b)[..=ma]);
        // ...and the later mark finds it within the API's 20 blocks.
        assert!(
            mb >= ma && mb - ma <= 20,
            "marks {ma} then {mb}: the later request cannot read the earlier one's entry"
        );
    }
}

#[test]
fn a_claude_turn_marks_one_hour_and_pins_claude_codes_marks_to_one_hour() {
    let mut h = claude_harness(None);
    fill(&h.chat, 0, 1_200);
    h.connect();
    h.say("user_local", "where is project 7?");
    h.settle();
    {
        let inner = h.agents.inner.lock().unwrap();
        let blocks = &inner.prompts[0];
        let m = markers(blocks);
        assert_eq!(m.len(), 1);
        assert_eq!(blocks[m[0]]["cache_control"], ONE_HOUR());
    }
    for file in ["settings.json", "settings.local.json"] {
        assert_eq!(
            session_settings(&h, file)["promptCacheTtl"],
            "1h",
            "{file}: Claude Code's own marks must not be 5m around a 1h mark"
        );
    }
}

#[test]
fn the_chiefs_cache_ttl_setting_picks_five_minutes() {
    let mut h = claude_harness(Some(json!({"cache": {"ttl": "5m"}})));
    fill(&h.chat, 0, 1_200);
    h.connect();
    h.say("user_local", "one");
    h.settle();
    {
        let inner = h.agents.inner.lock().unwrap();
        let blocks = &inner.prompts[0];
        let m = markers(blocks);
        assert_eq!(m.len(), 1);
        assert_eq!(blocks[m[0]]["cache_control"], json!({"type": "ephemeral"}));
    }
    assert_eq!(session_settings(&h, "settings.json")["promptCacheTtl"], "5m");
}

/// The API's answer to a 1h mark after a 5m one, or from a route without
/// the 1-hour TTL.
const TTL_REFUSED: &str = "API Error: 400 {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"messages.0.content.10.cache_control.ttl: a ttl='1h' cache_control block must not come after a ttl='5m' cache_control block. Note that blocks are processed in the following order: `tools`, `system`, `messages`.\"}}";

#[test]
fn a_route_that_refuses_the_one_hour_ttl_reruns_the_turn_at_five_minutes() {
    let dir = tempfile::tempdir().unwrap();
    let s = settings(dir.path());
    let script: Script = Box::new(|turn, blocks| {
        if turn == 0 {
            vec![
                json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                json!({"dir": "mux", "kind": "turn_error", "msg": {"error": TTL_REFUSED}}),
            ]
        } else {
            default_script()(turn, blocks)
        }
    });
    let mut h = Harness::configured(dir, script, owner(), s, Arc::new(|_: &str| {}));
    {
        let mut inner = h.agents.inner.lock().unwrap();
        inner.system_prompts = true;
        inner.answer_error = Some(TTL_REFUSED.into());
    }
    fill(&h.chat, 0, 1_200);
    h.connect();
    h.say("user_local", "one");
    h.settle();
    {
        let inner = h.agents.inner.lock().unwrap();
        assert_eq!(inner.prompts.len(), 2, "the refused prompt, then the same turn again");
        let (a, b) = (&inner.prompts[0], &inner.prompts[1]);
        assert_eq!(a[markers(a)[0]]["cache_control"], ONE_HOUR());
        assert_eq!(b[markers(b)[0]]["cache_control"], json!({"type": "ephemeral"}));
        assert_eq!(texts(a), texts(b));
    }
    assert_eq!(session_settings(&h, "settings.json")["promptCacheTtl"], "5m");
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1, "{sends:?}");
    assert!(!sends[0].1.contains("cache_control"), "{sends:?}");
    h.say("user_local", "two");
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    let c = &inner.prompts[2];
    assert_eq!(c[markers(c)[0]]["cache_control"], json!({"type": "ephemeral"}));
}

#[test]
fn the_pooled_session_reads_the_ttl_before_the_first_turn() {
    // The pool starts the next turn's Claude Code when acpmux connects; it
    // reads promptCacheTtl then, so the file must hold it already.
    let mut h = claude_harness(None);
    h.connect();
    assert_eq!(session_settings(&h, "settings.json")["promptCacheTtl"], "1h");
}

#[test]
fn a_session_pooled_before_a_ttl_change_reruns_its_turn_once_at_the_old_ttl() {
    let dir = tempfile::tempdir().unwrap();
    let s = settings(dir.path());
    // Turn 1 lands on a session the pool started under 1h, after the user
    // set 5m: the API refuses our 5m mark before Claude Code's 1h end mark.
    let script: Script = Box::new(|turn, blocks| {
        if turn == 1 {
            vec![
                json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                json!({"dir": "mux", "kind": "turn_error", "msg": {"error": TTL_REFUSED}}),
            ]
        } else {
            default_script()(turn, blocks)
        }
    });
    let mut h = Harness::configured(dir, script, owner(), s, Arc::new(|_: &str| {}));
    h.agents.inner.lock().unwrap().system_prompts = true;
    fill(&h.chat, 0, 1_200);
    h.connect();
    h.say("user_local", "one");
    h.settle();
    h.brain.set_setting("cache.ttl", "5m").unwrap();
    h.agents.inner.lock().unwrap().answer_error = Some(TTL_REFUSED.into());
    h.say("user_local", "two");
    h.settle();
    h.agents.inner.lock().unwrap().answer_error = None;
    h.say("user_local", "three");
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    let ttl = |k: usize| {
        let b = &inner.prompts[k];
        b[markers(b)[0]]["cache_control"].clone()
    };
    assert_eq!(inner.prompts.len(), 4, "one, two refused, two again, three");
    assert_eq!(ttl(0), ONE_HOUR());
    assert_eq!(ttl(1), json!({"type": "ephemeral"}));
    assert_eq!(ttl(2), ONE_HOUR(), "the rerun matches the pooled session");
    assert_eq!(ttl(3), json!({"type": "ephemeral"}), "the setting holds after it");
    drop(inner);
    assert_eq!(session_settings(&h, "settings.json")["promptCacheTtl"], "5m");
}
