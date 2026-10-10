//! Chief 2026-10-10: a user turn never waits more than 10 s on compaction.
//! The brain, its memory and its turn loop run end to end; only the
//! compactor model is held. A turn whose view lines are still building
//! starts after `SETTLE_BOUND` and reads them as the placeholder; the next
//! turn reads their summaries.

mod common;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use common::*;
use optchat_core::{Kind, PLACEHOLDER};
use optchat_host::{
    CompactModel, CompactRequest, Config, Followup, ModelError, OptChat, Reply, SystemClock,
};
use serde_json::Value;

/// The chief's bound (brain `SETTLE_BOUND`).
const SETTLE_BOUND: Duration = Duration::from_secs(10);

/// A compactor that builds normally, but only once it is let go.
#[derive(Default)]
struct Held {
    open: Mutex<bool>,
    changed: Condvar,
    calls: AtomicUsize,
}

impl Held {
    fn open(&self) {
        *self.open.lock().unwrap() = true;
        self.changed.notify_all();
    }
}

impl CompactModel for Held {
    fn call(&self, request: &CompactRequest, _: &[Followup]) -> Result<Reply, ModelError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let mut open = self.open.lock().unwrap();
        while !*open {
            open = self.changed.wait(open).unwrap();
        }
        Ok(Reply::text(format!("summary of {}", request.node.name())))
    }
}

/// A message too long for its own view line: it needs a summary.
fn long_message(i: usize) -> String {
    format!(
        "message {i}: {}",
        "the release script copies build output to /srv/releases and restarts the unit; "
            .repeat(30)
    )
}

fn prompt_text(h: &Harness, turn: usize) -> String {
    h.agents.inner.lock().unwrap().prompts[turn]
        .iter()
        .map(|b: &Value| b["text"].as_str().unwrap_or_default().to_owned())
        .collect::<Vec<_>>()
        .join("\n")
}

/// Steps the brain until `n` turns were prompted; how long that took.
fn until_prompt(h: &mut Harness, n: usize) -> Duration {
    let asked = Instant::now();
    while h.agents.inner.lock().unwrap().prompts.len() < n {
        h.step();
    }
    asked.elapsed()
}

#[test]
fn a_turn_waits_at_most_the_bound_for_lines_still_building_and_the_next_turn_reads_their_summaries()
{
    let dir = tempfile::tempdir().unwrap();
    let held = Arc::new(Held::default());
    let config = Config {
        reporter: Arc::new(|_| {}),
        ..Config::default()
    };
    let chat = Arc::new(
        OptChat::open_with(
            &dir.path().join("chat"),
            config,
            held.clone(),
            Arc::new(SystemClock),
        )
        .unwrap(),
    );
    // The chat's own messages (an imported note would not hold a turn).
    for i in 0..4 {
        let kind = if i % 2 == 0 { Kind::User } else { Kind::Talk };
        chat.append(kind, &long_message(i)).unwrap();
    }
    assert!(chat.status().unbuilt > 0, "the messages need summaries");
    let lines = Arc::new(Mutex::new(Vec::<String>::new()));
    let logged = lines.clone();
    let settings = settings(dir.path());
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let mut h = Harness::over_chat(
        dir,
        default_script(),
        owner,
        settings,
        Arc::new(move |line: &str| logged.lock().unwrap().push(line.to_owned())),
        chat.clone(),
    );
    h.connect();

    // Turn 1: the compactor is building (held), so the turn waits the bound
    // and no longer, then reads the messages as the placeholder.
    h.say("user_local", "where do releases go?");
    let waited = until_prompt(&mut h, 1);
    assert!(waited >= SETTLE_BOUND, "it waited the bound: {waited:?}");
    assert!(
        waited < SETTLE_BOUND + Duration::from_secs(5),
        "and not longer: {waited:?}"
    );
    assert!(held.calls.load(Ordering::SeqCst) > 0, "the nodes were building");
    let first = prompt_text(&h, 0);
    assert!(first.contains(PLACEHOLDER), "turn 1 reads the placeholder: {first}");
    let status = chat.status();
    assert!(status.failures.is_empty() && status.stuck.is_empty(), "{status:?}");
    assert!(
        lines
            .lock()
            .unwrap()
            .iter()
            .any(|l| l.starts_with("turn starts without")),
        "the host log says the turn did not wait: {:?}",
        lines.lock().unwrap()
    );
    h.settle();

    // The compactor finishes; turn 2 starts at once and reads the summaries.
    held.open();
    assert!(chat.wait_idle(None, Some(WAIT)));
    h.say("user_local", "and the unit?");
    let waited = until_prompt(&mut h, 2);
    assert!(waited < Duration::from_secs(5), "turn 2 did not wait: {waited:?}");
    let second = prompt_text(&h, 1);
    assert!(
        !second.contains(PLACEHOLDER),
        "turn 2 reads no placeholder: {second}"
    );
    assert!(second.contains("summary of"), "turn 2 reads the summaries: {second}");
    h.settle();
}
