//! One Chief turn's Claude Code stream-json transcript, read by chief-turn
//! (`cloud::TurnStream`, `stream::Line`, `Usage`), the parser the Mac Chief
//! (optchat-chief) and the Cloud Chief's turn runner share: one JSON value per
//! line, a line that is not JSON skipped, then the turn's result for an exit
//! the first input byte picks.
//!
//! Invariants past "no panic": every event carries its `gen` and a `type`;
//! the result's `status` is `done`, `partial` or `failed`, a turn that is not
//! done says why (`reason`, an `error` of at most 500 characters), and a
//! `partial` turn always has a reply.
#![no_main]

use chief_turn::Usage;
use chief_turn::cloud::{Exit, TurnStream};
use libfuzzer_sys::fuzz_target;
use serde_json::Value;

/// The most lines one input feeds.
const MAX_LINES: usize = 256;

fuzz_target!(|data: &[u8]| {
    let Some((&how, rest)) = data.split_first() else {
        return;
    };
    let mut turn = TurnStream::new();
    for (n, raw) in rest.split(|b| *b == b'\n').take(MAX_LINES).enumerate() {
        let Ok(line) = serde_json::from_slice::<Value>(raw) else {
            continue;
        };
        let _ = Usage::parse(&line);
        let _ = Usage::parse_lenient(line.get("usage"));
        for note in turn.line(&line, n as u64 * 7) {
            assert!(
                note.event.get("gen").is_some(),
                "an event without gen: {:?}",
                note.event
            );
            assert!(
                note.event["type"].is_string(),
                "an event without type: {:?}",
                note.event
            );
        }
    }
    let stderr = String::from_utf8_lossy(rest);
    let exit = Exit {
        run: "fuzz",
        model: "fuzz-model",
        code: (how & 1 == 0).then_some(i32::from(how >> 2)),
        timed_out: how & 2 == 2,
        signal: (how & 1 == 1).then_some(9),
        stderr: &stderr,
        total_ms: 1,
    };
    let result = turn.finish(exit);
    let status = result["status"].as_str().expect("a status");
    assert!(
        matches!(status, "done" | "partial" | "failed"),
        "status {status}"
    );
    if status != "done" {
        assert!(
            result["reason"].is_string(),
            "a turn that is not done without a reason: {result}"
        );
        let error = result["error"].as_str().expect("an error text");
        assert!(error.chars().count() <= 500, "an error past 500 characters");
    }
    if status == "partial" {
        assert!(
            !result["reply"].as_str().unwrap_or("").is_empty(),
            "a partial turn without a reply"
        );
    }
});
