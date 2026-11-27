//! `trace.full`: a per-Chief setting that makes the trace keep whole texts
//! (the turn's reply, tool arguments), for replaying real turns. The app
//! starts the Chief host with a fixed environment, so OPTCHAT_TRACE_FULL never
//! reaches it: the setting lives in the Chief home's settings.json, read at
//! host start and switched at once by `settings set trace.full`.

mod common;

use std::time::Duration;

use common::*;
use optchat_chief::chief_settings::{ChiefSettings, TRACE_FULL};
use optchat_chief::trace::Trace;
use serde_json::Value;

fn turn_ends(dir: &std::path::Path) -> Vec<Value> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let text = std::fs::read_to_string(entry.path()).unwrap();
        out.extend(
            text.lines()
                .filter_map(|l| serde_json::from_str::<Value>(l).ok())
                .filter(|e| e["ev"] == "turn.end"),
        );
    }
    out
}

fn settle_turn(h: &mut Harness, text: &str, turns: usize, dir: &std::path::Path) {
    h.say("user_local", text);
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while turn_ends(dir).len() < turns {
        assert!(std::time::Instant::now() < deadline, "no turn.end");
        h.step();
    }
}

#[test]
fn trace_full_is_read_from_settings_and_kept_by_a_save() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("settings.json");
    std::fs::write(
        &file,
        r#"{"show":{"afterReport":false},"trace":{"full":true}}"#,
    )
    .unwrap();
    let s = ChiefSettings::load(&file);
    assert!(s.trace_full);
    assert!(!s.show_after_report);
    s.save(&file).unwrap();
    let saved: Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
    assert_eq!(saved["trace"]["full"], true, "{saved}");
    assert!(
        !ChiefSettings::load(&dir.path().join("none.json")).trace_full,
        "off by default"
    );
}

#[test]
fn setting_trace_full_makes_the_running_trace_keep_whole_texts() {
    let mut h = Harness::new(default_script());
    let traces = h.dir.path().join("traces");
    h.brain.set_trace(Trace::open(&traces, false).unwrap());
    h.connect();
    settle_turn(&mut h, "first", 1, &traces);
    let before = turn_ends(&traces);
    assert!(
        before[0]["reply"]["text"].is_null(),
        "off: no whole text {}",
        before[0]
    );

    let answer = h.brain.set_setting(TRACE_FULL, "true").expect("a setting");
    assert!(answer.contains("true"), "{answer}");
    settle_turn(&mut h, "second", 2, &traces);
    let after = turn_ends(&traces);
    let reply = &after[1]["reply"];
    assert!(reply["text"].is_string(), "on: the whole reply {reply}");
    let saved = ChiefSettings::load(&h.dir.path().join("settings.json"));
    assert!(saved.trace_full, "saved for the next host start");
}
