//! Dial timelines: named marks relative to one start instant, so a slow
//! connect says which step took the time (signaling, ICE, DTLS, SCTP...).
//! Clones share the marks. Only the first mark of each name is kept.

use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

#[derive(Clone)]
pub struct Timeline {
    start: Instant,
    marks: Arc<Mutex<Vec<(String, Duration)>>>,
}

impl Default for Timeline {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Debug for Timeline {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.summary())
    }
}

impl Timeline {
    pub fn new() -> Self {
        Self::starting_at(Instant::now())
    }

    pub fn starting_at(start: Instant) -> Self {
        Self { start, marks: Arc::new(Mutex::new(Vec::new())) }
    }

    pub fn start(&self) -> Instant {
        self.start
    }

    /// Record `name` now, unless it was already recorded.
    pub fn mark(&self, name: &str) {
        let at = self.start.elapsed();
        let mut marks = self.marks.lock().unwrap_or_else(PoisonError::into_inner);
        if !marks.iter().any(|(n, _)| n == name) {
            marks.push((name.to_owned(), at));
        }
    }

    /// Every mark in the order recorded.
    pub fn marks(&self) -> Vec<(String, Duration)> {
        self.marks.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    pub fn get(&self, name: &str) -> Option<Duration> {
        self.marks
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, d)| *d)
    }

    /// `name=12.3ms name2=45.6ms ...` for logs.
    pub fn summary(&self) -> String {
        self.marks()
            .iter()
            .map(|(name, at)| format!("{name}={:.1}ms", at.as_secs_f64() * 1000.0))
            .collect::<Vec<_>>()
            .join(" ")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_first_mark_in_order() {
        let timeline = Timeline::new();
        timeline.mark("a");
        timeline.mark("b");
        timeline.mark("a");
        let names: Vec<_> = timeline.marks().into_iter().map(|(n, _)| n).collect();
        assert_eq!(names, ["a", "b"]);
        assert!(timeline.get("b").unwrap() >= timeline.get("a").unwrap());
        assert!(timeline.summary().starts_with("a="));
    }
}
