//! Host-side dedupe of the phone's sends by client id
//! (design/messaging-grade-send.md, phase 1; the phone's side is
//! `cmux_mobile_link::outbox`). A phone resends what a lost link did not
//! answer; the Mac runs each id at most once and answers a repeat with the
//! first copy's outcome. acpmux already does this for chat prompts
//! (`_meta.acpmux.promptId`); this is the same rule for what has no id of its
//! own yet, a terminal's keys first. Pure and not wired into a service yet.

use std::collections::{HashMap, VecDeque};

pub use cmux_mobile_link::outbox::HostAck;

/// How many ids are remembered per phone by default: far more than a phone
/// holds unanswered (its sends wait at most 10 s).
pub const DEFAULT_CAPACITY: usize = 4096;

/// The Mac's side of the ids: which sends it already handled, so a resend
/// (a link lost before its answer, a restored outbox) runs at most once. A
/// bounded memory per phone: the oldest ids go first, well after any send
/// could still come again (a phone holds a send 10 s).
#[derive(Debug)]
pub struct SeenIds {
    order: VecDeque<String>,
    outcomes: HashMap<String, Option<HostAck>>,
    capacity: usize,
}

/// What [`SeenIds::admit`] decides.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Admit {
    /// First time: run it, then [`SeenIds::settle`] its outcome.
    New,
    /// Seen before: do not run it again; answer its outcome (`None` while
    /// the first copy still runs: answer when it ends).
    Duplicate(Option<HostAck>),
}

impl SeenIds {
    pub fn new(capacity: usize) -> Self {
        Self { order: VecDeque::new(), outcomes: HashMap::new(), capacity: capacity.max(1) }
    }

    pub fn admit(&mut self, id: &str) -> Admit {
        if let Some(outcome) = self.outcomes.get(id) {
            return Admit::Duplicate(outcome.clone());
        }
        self.outcomes.insert(id.to_owned(), None);
        self.order.push_back(id.to_owned());
        while self.order.len() > self.capacity {
            if let Some(old) = self.order.pop_front() {
                self.outcomes.remove(&old);
            }
        }
        Admit::New
    }

    /// The first copy of `id` ended with `outcome`.
    pub fn settle(&mut self, id: &str, outcome: HostAck) {
        if let Some(slot) = self.outcomes.get_mut(id) {
            *slot = Some(outcome);
        }
    }
}

impl Default for SeenIds {
    fn default() -> Self {
        Self::new(DEFAULT_CAPACITY)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_id_runs_once_and_a_repeat_gets_its_outcome() {
        let mut seen = SeenIds::default();
        assert_eq!(seen.admit("k1"), Admit::New);
        // Resent while the first copy still runs: wait for it, run nothing.
        assert_eq!(seen.admit("k1"), Admit::Duplicate(None));
        seen.settle("k1", HostAck::Delivered);
        assert_eq!(seen.admit("k1"), Admit::Duplicate(Some(HostAck::Delivered)));
        assert_eq!(seen.admit("k2"), Admit::New);
        seen.settle("k2", HostAck::Refused("closed".into()));
        assert_eq!(seen.admit("k2"), Admit::Duplicate(Some(HostAck::Refused("closed".into()))));
    }

    #[test]
    fn the_oldest_ids_are_forgotten_past_capacity() {
        let mut seen = SeenIds::new(2);
        seen.admit("a");
        seen.admit("b");
        seen.admit("c");
        assert_eq!(seen.admit("b"), Admit::Duplicate(None));
        assert_eq!(seen.admit("a"), Admit::New);
        // Settling a forgotten id is a no-op.
        seen.settle("zz", HostAck::Delivered);
    }
}
