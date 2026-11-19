//! A per-phase timeline of the daemon's stop, for measurement only.
//!
//! [`begin`] runs once when the stop is decided; each [`mark`] then records its name and the
//! milliseconds since then (a no-op before `begin`). The daemon prints [`line`] to stderr as
//! `STOP-TIMELINE {...}` just before it logs "stopped", and only when the env var
//! `ACPMUX_STOP_TIMELINE` is `1` (a test-only switch, read by the stop-under-load test,
//! `tests/stop_under_load.rs`). Without it the daemon behaves exactly as before.

use std::future::Future;
use std::pin::Pin;
use std::sync::{Mutex, OnceLock};
use std::task::{Context, Poll};
use std::time::Instant;

struct Timeline {
    started: Instant,
    print: bool,
    marks: Mutex<Vec<(String, u64)>>,
}

/// A task's future whose polls and drop are timed against the stop: a poll that was running
/// when the stop began notes how long it ran (`<name>:poll-at-stop-ms`), each later poll its
/// length (`<name>:poll-after-stop-ms`), and the drop its length (`<name>:drop-ms`).
pub(crate) struct Polled<F> {
    name: &'static str,
    task: Option<Pin<Box<F>>>,
}

impl<F> Polled<F> {
    pub(crate) fn new(name: &'static str, task: F) -> Self {
        Self { name, task: Some(Box::pin(task)) }
    }
}

impl<F: Future> Future for Polled<F> {
    type Output = F::Output;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<F::Output> {
        let name = self.name;
        let started = Instant::now();
        let Some(task) = self.task.as_mut() else { return Poll::Pending };
        let out = task.as_mut().poll(cx);
        if let Some(timeline) = TIMELINE.get() {
            let what =
                if started <= timeline.started { "poll-at-stop-ms" } else { "poll-after-stop-ms" };
            note(format!("{name}:{what}"), millis(started));
        }
        out
    }
}

impl<F> Drop for Polled<F> {
    fn drop(&mut self) {
        let started = Instant::now();
        self.task = None;
        note(format!("{}:drop-ms", self.name), millis(started));
    }
}

fn millis(since: Instant) -> u64 {
    u64::try_from(since.elapsed().as_millis()).unwrap_or(u64::MAX)
}

/// Record `value` under `name` as a mark's ms is. A no-op if [`begin`] never ran.
pub(crate) fn note(name: String, value: u64) {
    let Some(timeline) = TIMELINE.get() else { return };
    timeline.marks.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push((name, value));
}

static TIMELINE: OnceLock<Timeline> = OnceLock::new();

/// The stop has begun: later marks count from now. Only the first call counts.
pub(crate) fn begin() {
    let _ = TIMELINE.get_or_init(|| Timeline {
        started: Instant::now(),
        print: std::env::var("ACPMUX_STOP_TIMELINE").is_ok_and(|v| v == "1"),
        marks: Mutex::new(Vec::new()),
    });
}

/// Record that the phase `name` ended now. A no-op if [`begin`] never ran.
pub(crate) fn mark(name: &'static str) {
    let Some(timeline) = TIMELINE.get() else { return };
    let ms = u64::try_from(timeline.started.elapsed().as_millis()).unwrap_or(u64::MAX);
    note(name.to_owned(), ms);
}

/// The timeline as one JSON object, `{"totalMs": N, "marks": [["name", ms], ...]}`, when the
/// stop has begun and `ACPMUX_STOP_TIMELINE=1` asked for it.
pub(crate) fn line() -> Option<String> {
    let timeline = TIMELINE.get()?;
    if !timeline.print {
        return None;
    }
    let total = u64::try_from(timeline.started.elapsed().as_millis()).unwrap_or(u64::MAX);
    let marks: Vec<serde_json::Value> = timeline
        .marks
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter()
        .map(|(name, ms)| serde_json::json!([name, ms]))
        .collect();
    Some(serde_json::json!({"totalMs": total, "marks": marks}).to_string())
}
