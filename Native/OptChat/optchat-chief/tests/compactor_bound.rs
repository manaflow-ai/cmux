//! A user turn never waits more than 1 s on compaction (chief 2026-10-10:
//! 10 s; hq-6d 2026-10-14, "the chief responds too slow": 1 s).
//! The brain, its memory and its turn loop run end to end; only the
//! compactor model is held. A turn whose view lines are still building
//! starts after `SETTLE_BOUND` and reads them as the placeholder; the next
//! turn sends that frozen view again byte for byte (spec 5a.1: a fold alone
//! does not change it; a re-render folds the summaries in).
//! The bound reads the brain's injected turn clock (`Brain::with_turn_clock`):
//! the test moves that time itself and never measures a real wait.

mod common;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use optchat_chief::brain::TurnClock;

use common::*;
use optchat_core::{Kind, PLACEHOLDER};
use optchat_host::{
    CompactModel, CompactRequest, Config, Followup, ModelError, OptChat, Reply, SystemClock,
};
use serde_json::Value;

/// The chief's bound (brain `SETTLE_BOUND`).
const SETTLE_BOUND: Duration = Duration::from_secs(1);

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

/// The settle bound's clock: time moves only when the test calls `advance`.
/// Every read is counted, so the test knows when the turn worker has looked
/// at the time again (a signal, not a wait for real time to pass).
struct FakeTurnClock {
    start: Instant,
    state: Mutex<(Duration, u64)>,
    read: Condvar,
}

impl FakeTurnClock {
    fn new() -> FakeTurnClock {
        FakeTurnClock {
            start: Instant::now(),
            state: Mutex::new((Duration::ZERO, 0)),
            read: Condvar::new(),
        }
    }

    fn advance(&self, d: Duration) {
        self.state.lock().unwrap().0 += d;
    }

    fn reads(&self) -> u64 {
        self.state.lock().unwrap().1
    }

    /// Blocks until the clock was read `n` more times after `seen` reads, or
    /// `limit` of real time passes; whether it was.
    fn wait_reads(&self, seen: u64, n: u64, limit: Duration) -> bool {
        let state = self.state.lock().unwrap();
        let (_state, timeout) = self
            .read
            .wait_timeout_while(state, limit, |(_, reads)| *reads < seen + n)
            .unwrap();
        !timeout.timed_out()
    }
}

impl TurnClock for FakeTurnClock {
    fn now(&self) -> Instant {
        let mut state = self.state.lock().unwrap();
        state.1 += 1;
        self.read.notify_all();
        self.start + state.0
    }
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
            dir.path().join("chat"),
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
    let clock = Arc::new(FakeTurnClock::new());
    let mut h = Harness::over_chat(
        dir,
        default_script(),
        owner,
        settings,
        Arc::new(move |line: &str| logged.lock().unwrap().push(line.to_owned())),
        chat.clone(),
    )
    .with_turn_clock(clock.clone());
    h.connect();
    let did_not_wait = |lines: &Mutex<Vec<String>>| {
        lines
            .lock()
            .unwrap()
            .iter()
            .any(|l| l.starts_with("turn starts without"))
    };

    // Turn 1: the compactor is building (held). The bound counts from the
    // message: one moment short of it, the turn worker looks at the time
    // and still waits.
    h.say("user_local", "where do releases go?");
    clock.advance(SETTLE_BOUND - Duration::from_millis(1));
    let seen = clock.reads();
    assert!(
        clock.wait_reads(seen, 2, WAIT),
        "the turn worker reads the bound's clock"
    );
    assert!(
        !did_not_wait(&lines),
        "the turn did not start before the bound: {:?}",
        lines.lock().unwrap()
    );
    assert!(
        h.agents.inner.lock().unwrap().prompts.is_empty(),
        "no prompt before the bound"
    );
    // At the bound it starts, and reads the messages as the placeholder.
    clock.advance(Duration::from_millis(1));
    h.step_to_prompts(1);
    assert!(
        held.calls.load(Ordering::SeqCst) > 0,
        "the nodes were building"
    );
    let first = prompt_text(&h, 0);
    assert!(
        first.contains(PLACEHOLDER),
        "turn 1 reads the placeholder: {first}"
    );
    let status = chat.status();
    assert!(
        status.failures.is_empty() && status.stuck.is_empty(),
        "{status:?}"
    );
    assert!(
        did_not_wait(&lines),
        "the host log says the turn did not wait: {:?}",
        lines.lock().unwrap()
    );
    h.settle();

    // The compactor finishes; turn 2 starts at once and repeats turn 1's
    // input (a fold alone does not change the frozen view, spec 5a.1).
    held.open();
    assert!(chat.wait_idle(None, Some(WAIT)));
    // The bound's clock does not move: a turn that waited for it would
    // never start.
    h.say("user_local", "and the unit?");
    h.step_to_prompts(2);
    let second = prompt_text(&h, 1);
    assert!(
        second.starts_with(&first[..first.find("where do releases go?").unwrap()]),
        "turn 2 sends turn 1's view and delta again: {second}"
    );
    h.settle();
}
