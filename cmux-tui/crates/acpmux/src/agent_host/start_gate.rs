//! Admission of agent host starts, after Chrome's child process launcher: a
//! bounded number of starts run at once, sized from the machine's cores, and
//! the rest wait their turn in priority order, first come first served within
//! a priority (P-AUSTIN B10).
//!
//! A wave of 25 chats opened at once on a busy Mac started 25 hosts at once,
//! and each took 10 s or more to report ready; a fixed 10 s budget then ended
//! every one of them, so no chat of the wave opened. A start no longer has a
//! time budget (`link::spawn`), and starts beyond the cap wait here instead of
//! competing for the same cores: a wave opens in order, the first chats first.
//!
//! A start the person waits for ([`StartPriority::Interactive`]) goes before a
//! pool prewarm nobody waits for yet ([`StartPriority::Prewarm`]). A waiter
//! learns its place once ([`Queued`]) so its chat can show it. Nothing here
//! refuses: a caller that stops waiting (its chat closed, its own deadline)
//! drops its wait and gives its place, or its slot, to the next.

use crate::no_panic::LockExt;
use std::collections::VecDeque;
use std::sync::{Mutex as StdMutex, OnceLock};
use tokio::sync::oneshot;

/// Whose start it is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StartPriority {
    /// A chat a person (or their agent) opened and waits for.
    Interactive,
    /// A pooled host started ahead of need.
    Prewarm,
}

impl StartPriority {
    fn rank(self) -> usize {
        match self {
            Self::Interactive => 0,
            Self::Prewarm => 1,
        }
    }
}

/// Where a start that must wait stands when it starts waiting.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Queued {
    /// Starts admitted before this one (its priority and higher, all queued
    /// before it).
    pub ahead: usize,
    /// Starts that run now.
    pub running: usize,
    /// How many may run at once.
    pub cap: usize,
}

struct State {
    running: usize,
    next_ticket: u64,
    /// One queue per priority, highest first.
    waiting: [VecDeque<(u64, oneshot::Sender<()>)>; 2],
}

/// The admission of starts: at most `cap` hold a [`StartPermit`] at once.
pub struct StartGate {
    cap: usize,
    state: StdMutex<State>,
}

impl StartGate {
    /// A gate that admits `cap` starts at once (at least one).
    pub fn new(cap: usize) -> Self {
        Self {
            cap: cap.max(1),
            state: StdMutex::new(State {
                running: 0,
                next_ticket: 0,
                waiting: [VecDeque::new(), VecDeque::new()],
            }),
        }
    }

    /// The daemon's gate: one start per core the process may run on. A host
    /// start is one process exec and one harness spawn, so more at once than
    /// there are cores only makes each of them slower.
    pub fn global() -> &'static StartGate {
        static GATE: OnceLock<StartGate> = OnceLock::new();
        GATE.get_or_init(|| {
            StartGate::new(std::thread::available_parallelism().map_or(1, std::num::NonZero::get))
        })
    }

    pub fn cap(&self) -> usize {
        self.cap
    }

    /// Starts that hold a permit now.
    pub fn running(&self) -> usize {
        self.state.lock_or_recover().running
    }

    /// Starts waiting for a permit now.
    pub fn waiting(&self) -> usize {
        self.state.lock_or_recover().waiting.iter().map(VecDeque::len).sum()
    }

    /// A permit to start one host: at once while fewer than `cap` run, else
    /// after every start queued before it at its priority or higher. A wait
    /// calls `on_queued` once, with its place, before it waits. Dropping the
    /// future gives its place up.
    pub async fn admit(
        &self,
        priority: StartPriority,
        on_queued: impl FnOnce(Queued),
    ) -> StartPermit<'_> {
        let (ticket, rx, queued) = {
            let mut state = self.state.lock_or_recover();
            if state.running < self.cap {
                state.running += 1;
                return StartPermit { gate: self };
            }
            let ticket = state.next_ticket;
            state.next_ticket += 1;
            let (tx, rx) = oneshot::channel();
            let rank = priority.rank();
            let ahead = state.waiting[..=rank].iter().map(VecDeque::len).sum();
            state.waiting[rank].push_back((ticket, tx));
            (ticket, rx, Queued { ahead, running: state.running, cap: self.cap })
        };
        let mut wait = Waiting { gate: self, rank: priority.rank(), ticket, rx: Some(rx) };
        on_queued(queued);
        // Its sender stays in the queue until `release` hands it this slot. The
        // receiver lives in `wait`, so it is still open while `wait`'s drop
        // decides whether a slot came: a send to a live wait never fails.
        if let Some(rx) = wait.rx.as_mut() {
            let _ = rx.await;
        }
        wait.rx = None;
        StartPermit { gate: self }
    }

    /// One permit ends: its slot goes to the first waiter still waiting, or
    /// is free again.
    fn release(&self) {
        let mut state = self.state.lock_or_recover();
        for rank in 0..state.waiting.len() {
            while let Some((_, tx)) = state.waiting[rank].pop_front() {
                // A waiter that already gave up has dropped its receiver.
                if tx.send(()).is_ok() {
                    return;
                }
            }
        }
        state.running = state.running.saturating_sub(1);
    }
}

/// One admitted start. Dropping it admits the next.
pub struct StartPermit<'a> {
    gate: &'a StartGate,
}

impl Drop for StartPermit<'_> {
    fn drop(&mut self) {
        self.gate.release();
    }
}

/// A wait in the queue; dropped before its slot came, it leaves the queue,
/// and dropped after, it hands the slot on.
struct Waiting<'a> {
    gate: &'a StartGate,
    rank: usize,
    ticket: u64,
    /// None once the wait ended with a permit, which owns the slot now.
    rx: Option<oneshot::Receiver<()>>,
}

impl Drop for Waiting<'_> {
    fn drop(&mut self) {
        if self.rx.is_none() {
            return;
        }
        let mut state = self.gate.state.lock_or_recover();
        let queue = &mut state.waiting[self.rank];
        if let Some(at) = queue.iter().position(|(t, _)| *t == self.ticket) {
            queue.remove(at);
            return;
        }
        // Not queued any more: `release` handed this wait a slot (under the
        // same lock), which nobody will use now.
        drop(state);
        self.gate.release();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[tokio::test]
    async fn starts_past_the_cap_wait_in_order_and_interactive_ones_first() {
        let gate = Arc::new(StartGate::new(2));
        let a = gate.admit(StartPriority::Interactive, |_| panic!("a slot was free")).await;
        let b = gate.admit(StartPriority::Prewarm, |_| panic!("a slot was free")).await;
        assert_eq!(gate.running(), 2);
        let (order_tx, mut order) = tokio::sync::mpsc::unbounded_channel();
        let mut waits = Vec::new();
        for (name, priority, ahead) in [
            ("prewarm-1", StartPriority::Prewarm, 0),
            ("chat-1", StartPriority::Interactive, 0),
            ("chat-2", StartPriority::Interactive, 1),
            ("prewarm-2", StartPriority::Prewarm, 3),
        ] {
            let (gate, order_tx) = (gate.clone(), order_tx.clone());
            let (placed_tx, placed) = oneshot::channel();
            waits.push(tokio::spawn(async move {
                let permit = gate
                    .admit(priority, |q| {
                        let _ = placed_tx.send(q);
                    })
                    .await;
                order_tx.send(name).unwrap();
                // Held until the test lets every start through.
                std::future::pending::<()>().await;
                drop(permit);
            }));
            let q = placed.await.unwrap();
            assert_eq!((name, q.ahead, q.running, q.cap), (name, ahead, 2, 2));
        }
        assert_eq!(gate.waiting(), 4);
        drop(a);
        assert_eq!(order.recv().await, Some("chat-1"));
        drop(b);
        assert_eq!(order.recv().await, Some("chat-2"));
        assert_eq!(gate.running(), 2);
        assert_eq!(gate.waiting(), 2);
        // Each slot freed goes to the prewarm queued first.
        for (chat, prewarm) in [(1, "prewarm-1"), (2, "prewarm-2")] {
            waits[chat].abort();
            let _ = (&mut waits[chat]).await;
            assert_eq!(order.recv().await, Some(prewarm));
        }
        for (i, w) in waits.into_iter().enumerate() {
            // The two chats' tasks ended above.
            if i != 1 && i != 2 {
                w.abort();
                let _ = w.await;
            }
        }
        assert_eq!((gate.running(), gate.waiting()), (0, 0));
    }

    #[tokio::test]
    async fn a_wait_dropped_in_the_queue_gives_its_place_up() {
        let gate = Arc::new(StartGate::new(1));
        let first = gate.admit(StartPriority::Interactive, |_| {}).await;
        let g = gate.clone();
        let (placed_tx, placed) = oneshot::channel();
        let gave_up = tokio::spawn(async move {
            let _p = g
                .admit(StartPriority::Interactive, |_| {
                    let _ = placed_tx.send(());
                })
                .await;
            std::future::pending::<()>().await;
        });
        placed.await.unwrap();
        gave_up.abort();
        let _ = gave_up.await;
        assert_eq!(gate.waiting(), 0);
        drop(first);
        assert_eq!((gate.running(), gate.waiting()), (0, 0));
        let _again = gate.admit(StartPriority::Interactive, |_| panic!("the slot is free")).await;
    }
}
