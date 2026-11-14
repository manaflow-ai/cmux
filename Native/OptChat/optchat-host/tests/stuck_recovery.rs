//! https://github.com/manaflow-ai/cmux/issues/36026: a compactor node that
//! cannot be built must recover rather than stay unsummarized.
//!
//! - A request the API refuses as too large repeats that refusal on every
//!   try: the node keeps its input, cut to the line's room (the stand-in),
//!   instead of staying stuck forever.
//! - A transient failure (acpmux's `session/new` not answering under load)
//!   that runs out of tries is retried until the route works again, and the
//!   status shows the latest error, not the first one from hours before.

mod common;

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use common::*;
use optchat_host::*;

const INPUT: &str = "echo: gh api graphql: PR 26546 mergeable CLEAN, 46 checks pass";

fn request() -> CompactRequest {
    CompactRequest {
        node: NodeId::new(0, 1634),
        system: "system".to_owned(),
        context: "<chat>\n</chat>".to_owned(),
        step: format!("Compaction: compress message 1634\n<input>\n{INPUT}\n</input>"),
        cut: None,
        imported: false,
    }
}

struct Fails {
    message: &'static str,
    calls: AtomicUsize,
}

impl CompactModel for Fails {
    fn call(&self, _: &CompactRequest, _: &[Followup]) -> Result<Reply, ModelError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Err(ModelError::new(self.message))
    }
}

const TOO_LONG: &str =
    "API Error: 400 {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\
                        \"message\":\"prompt is too long: 214093 tokens > 200000 maximum\"}}";

#[test]
fn a_request_too_large_for_the_model_keeps_its_input_as_the_line() {
    let main = Fails {
        message: TOO_LONG,
        calls: AtomicUsize::new(0),
    };
    let built = build_node(&main, None, &request()).expect("the stand-in, not an error");
    assert!(built.stand_in, "{built:?}");
    assert!(built.text.contains("PR 26546"), "{built:?}");
    assert!(
        built
            .oversized
            .as_deref()
            .is_some_and(|e| e.contains("too long")),
        "{built:?}"
    );
}

#[test]
fn an_oversized_request_on_both_models_still_builds_the_stand_in() {
    let main = Fails {
        message: TOO_LONG,
        calls: AtomicUsize::new(0),
    };
    let fallback = Fails {
        message: "HTTP 413: {\"type\":\"error\",\"error\":{\"type\":\"request_too_large\",\"message\":\"Request exceeds the maximum allowed number of bytes.\"}}",
        calls: AtomicUsize::new(0),
    };
    let built = build_node(&main, Some(&fallback), &request()).unwrap();
    assert!(built.stand_in, "{built:?}");
}

#[test]
fn another_request_error_stays_an_error() {
    // A 400 that is not about size (a bad marker, a bad parameter) may be
    // fixed by a new build: it never writes a stand-in over the line.
    let main = Fails {
        message: "API Error: 400 {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\
                  \"message\":\"A maximum of 4 blocks with cache_control may be provided. Found 5.\"}}",
        calls: AtomicUsize::new(0),
    };
    assert!(build_node(&main, None, &request()).is_err());
}

#[test]
fn a_transient_failure_past_its_tries_recovers_when_the_route_answers_again() {
    let dir = tempfile::tempdir().unwrap();
    let up = Arc::new(AtomicBool::new(false));
    let tries = Arc::new(AtomicUsize::new(0));
    let (u, t) = (up.clone(), tries.clone());
    let model: Arc<dyn CompactModel> = Arc::new(Fake(move |r: &CompactRequest, _: &[Followup]| {
        if u.load(Ordering::SeqCst) {
            return Ok(Reply::text(summary(r.node, 120)));
        }
        let n = t.fetch_add(1, Ordering::SeqCst) + 1;
        Err(ModelError::new(format!(
            "starting a compactor session: session/new: no answer within 200 s (try {n})"
        )))
    }));
    let clock = Arc::new(ManualClock::new());
    let chat = OptChat::open_with(dir.path(), config(4_000).0, model, clock.clone()).unwrap();
    chat.append(Kind::User, &long(0)).unwrap();

    // Every try fails until the node is stuck: turns no longer wait for it.
    while chat.status().stuck.is_empty() {
        assert!(
            clock.wait_for_sleepers(1, Duration::from_secs(30)),
            "{:?}",
            chat.status()
        );
        if chat.status().stuck.is_empty() {
            clock.advance(MAX_RETRY_WAIT);
        }
    }
    assert!(chat.turn_ready());
    let status = chat.status();
    let failure = &status.failures[0];
    let last = tries.load(Ordering::SeqCst);
    assert!(last >= COMPACT_TRIES as usize, "{status:?}");
    assert!(
        failure.error.ends_with(&format!("(try {last})")),
        "the status names the latest error, got {:?}",
        failure.error
    );

    // The route answers again: the stuck node is built on its next retry.
    up.store(true, Ordering::SeqCst);
    assert!(clock.wait_for_sleepers(1, Duration::from_secs(30)));
    clock.advance(STUCK_RETRY);
    assert!(chat.wait_idle(None, WAIT), "{:?}", chat.status());
    let status = chat.status();
    assert!(
        status.stuck.is_empty() && status.failures.is_empty(),
        "{status:?}"
    );
    assert!(status.recovered, "{status:?}");
    assert_eq!(status.unbuilt, 0, "{status:?}");
}

/// A stuck node waits for its next try (`STUCK_RETRY`) without holding one of the `JOBS`
/// model-call slots. It held one: once `JOBS` merges were stuck (acpmux kept their session
/// names taken, so every try failed at once), no new message was ever summarized, and the
/// Chief's view showed thousands of "(not summarized yet)" lines (default Chief, Nov 2026).
#[test]
fn stuck_merges_never_starve_new_messages_of_model_slots() {
    let dir = tempfile::tempdir().unwrap();
    let model: Arc<dyn CompactModel> = Arc::new(Fake(|r: &CompactRequest, _: &[Followup]| {
        if r.node.l > 0 {
            // The error a merge's session start gave for days.
            return Err(ModelError::setup(format!(
                "starting a compactor session: session/new: session name \"optchat-compact-test-{}\" is taken",
                r.node.name()
            )));
        }
        Ok(Reply::text(summary(r.node, 120)))
    }));
    let clock = Arc::new(ManualClock::new());
    // A budget the messages pass many times over: every pair of leaves wants its merge.
    let chat = OptChat::open_with(dir.path(), config(2_000).0, model, clock.clone()).unwrap();
    let jobs = optchat_core::JOBS as u64;
    let mut next = 0;
    // Enough messages for more stuck merges than there are slots.
    while (chat.status().stuck.len() as u64) < jobs + 4 && next < 8 * jobs {
        chat.append(Kind::User, &long(next)).unwrap();
        next += 1;
        wait_settled(&chat);
    }
    assert!(
        chat.status().stuck.len() as u64 >= jobs,
        "the precondition: at least JOBS stuck merges, got {}",
        chat.status().stuck.len()
    );
    // New messages after that: each is summarized, though no clock tick ends a stuck wait.
    for _ in 0..3 {
        chat.append(Kind::User, &long(next)).unwrap();
        next += 1;
    }
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    while !leaves_built(&chat, next) && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(
        leaves_built(&chat, next),
        "new messages stayed unsummarized behind stuck merges: {:?}",
        chat.status()
    );
}

/// Every message's own node is built (its line is no placeholder).
fn leaves_built(chat: &OptChat, t: u64) -> bool {
    let view = chat.render_compact_view().text;
    (t.saturating_sub(3)..t).all(|i| !view.contains(&format!("{i}+1|(not summarized yet")))
        && chat.status().unbuilt == 0
}

/// Waits until nothing runs but stuck nodes waiting for their next try.
fn wait_settled(chat: &OptChat) {
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    loop {
        let s = chat.status();
        if s.busy.iter().all(|n| s.stuck.contains(n)) || std::time::Instant::now() > deadline {
            return;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}
