//! The terminal client's reconnect to the daemon (`run.rs`'s `reconnect`) as a `cmux_bounded`
//! machine. Each waiting state declares its bound and what ends it: a daemon that accepts the
//! socket and never answers `initialize`, the watch or the list ends that attempt at [`ATTEMPT`]
//! and the next one dials, instead of the pane freezing on "reconnecting" forever. Past
//! [`BUDGET`] it gives up with the last reason, as a daemon that never came back always did.

use anyhow::Result;
use cmux_bounded::{BoundedMachine, Driver, Wait};
use std::future::Future;
use std::time::Duration;
use tokio::time::Instant;

/// The first pause before a dial, doubled after each failed one up to [`BACKOFF_MAX`].
pub(super) const BACKOFF_FIRST: Duration = Duration::from_millis(300);
pub(super) const BACKOFF_MAX: Duration = Duration::from_secs(3);
/// One attempt: connect (with `initialize`), the watch and the list. The quiet rule's 10 s
/// (`cmux_bounded::CONNECTION_QUIET`): a live daemon answers all three well inside it.
pub(super) const ATTEMPT: Duration = cmux_bounded::CONNECTION_QUIET;
/// No daemon back after this: the reconnect fails with the last reason.
pub(super) const BUDGET: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Phase {
    /// Paused `delay` before dial `attempt`, `left` of [`BUDGET`] to go.
    Backoff { attempt: u32, delay: Duration, left: Duration },
    /// Dial `attempt` sent; its connect, watch and list have not all answered.
    Dialing { attempt: u32, delay: Duration, left: Duration },
    /// Reconnected.
    Back,
    /// Out of [`BUDGET`]: the caller shows the last reason.
    GaveUp,
}

#[derive(Debug)]
pub(super) enum Event {
    /// The pause, `spent` long, is over.
    Dial {
        spent: Duration,
    },
    Connected,
    /// The attempt failed, or ran past [`ATTEMPT`], `spent` after it was sent.
    Failed {
        spent: Duration,
    },
}

#[derive(Debug)]
pub(super) struct Reconnect(Phase);

impl Reconnect {
    pub(super) fn new() -> Self {
        Self(Phase::Backoff { attempt: 1, delay: BACKOFF_FIRST, left: BUDGET })
    }
}

impl BoundedMachine for Reconnect {
    type State = Phase;
    type Event = Event;
    const NAME: &'static str = "acpmux.tui.reconnect";

    fn wait(state: &Phase) -> Wait<Event> {
        match state {
            // The pause never runs past what is left of the budget.
            Phase::Backoff { delay, left, .. } => {
                let pause = (*delay).min(*left);
                Wait::bounded(pause, Event::Dial { spent: pause }, "the pause before the next dial")
            }
            Phase::Dialing { .. } => Wait::bounded(
                ATTEMPT,
                Event::Failed { spent: ATTEMPT },
                "the daemon answers a reconnect's connect, watch and list",
            ),
            Phase::Back | Phase::GaveUp => Wait::Settled,
        }
    }

    fn step(&mut self, event: Event) {
        self.0 = match (&self.0, event) {
            (Phase::Back | Phase::GaveUp, _) => self.0.clone(),
            // A pause that used the rest of the budget gives up instead of dialing once more.
            (Phase::Backoff { left, .. }, Event::Dial { spent }) if spent >= *left => Phase::GaveUp,
            (Phase::Backoff { attempt, delay, left }, Event::Dial { spent }) => Phase::Dialing {
                attempt: *attempt,
                delay: *delay,
                left: left.saturating_sub(spent),
            },
            (Phase::Dialing { .. }, Event::Connected) => Phase::Back,
            (Phase::Dialing { left, .. }, Event::Failed { spent }) if spent >= *left => {
                Phase::GaveUp
            }
            (Phase::Dialing { attempt, delay, left }, Event::Failed { spent }) => Phase::Backoff {
                attempt: attempt.saturating_add(1),
                delay: delay.saturating_mul(2).min(BACKOFF_MAX),
                left: left.saturating_sub(spent),
            },
            (state @ (Phase::Backoff { .. } | Phase::Dialing { .. }), _) => state.clone(),
        };
    }

    fn state(&self) -> &Phase {
        &self.0
    }
}

/// Dial with `dial` until one attempt answers whole within [`ATTEMPT`], pausing between
/// attempts, for at most [`BUDGET`].
pub(super) async fn redial<T, F, Fut>(mut dial: F) -> Result<T>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T>>,
{
    let mut wait = Driver::<Reconnect, Instant>::new(Reconnect::new());
    let mut last = String::from("no attempt finished");
    loop {
        match wait.state() {
            Phase::Backoff { .. } => {
                wait.expired().await;
                wait.expire_due();
            }
            Phase::Dialing { .. } => {
                let attempt = tokio::select! {
                    answer = dial() => Some(answer),
                    () = wait.expired() => None,
                };
                match attempt {
                    Some(Ok(v)) => {
                        wait.feed(Event::Connected);
                        return Ok(v);
                    }
                    Some(Err(e)) => {
                        last = e.to_string();
                        wait.feed(Event::Failed { spent: wait.entered().elapsed() });
                    }
                    None => {
                        last = format!(
                            "the daemon accepted the connection but did not answer within {} s",
                            ATTEMPT.as_secs()
                        );
                        wait.expire_due();
                    }
                }
            }
            Phase::Back | Phase::GaveUp => {
                return Err(anyhow::anyhow!(
                    "daemon connection closed and no daemon came back within {}s: {last}",
                    BUDGET.as_secs()
                ));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU32, Ordering};

    #[test]
    fn every_reconnect_wait_recovers() {
        let states = [
            Phase::Backoff { attempt: 1, delay: BACKOFF_FIRST, left: BUDGET },
            Phase::Dialing { attempt: 1, delay: BACKOFF_FIRST, left: BUDGET },
            Phase::Dialing { attempt: 9, delay: BACKOFF_MAX, left: Duration::from_secs(1) },
            Phase::Backoff { attempt: 6, delay: BACKOFF_MAX, left: Duration::from_millis(500) },
            Phase::Back,
            Phase::GaveUp,
        ];
        // Unanswered, every state reaches `GaveUp` within the budget plus one attempt (a dial
        // sent with a moment of budget left still gets its whole attempt).
        let walks = cmux_bounded::testing::assert_every_wait_recovers::<Reconnect>(
            |s: &Phase| Reconnect(s.clone()),
            &states,
            BUDGET + ATTEMPT,
        );
        assert_eq!(walks.len(), 4, "the four waiting states");
    }

    /// Before: a daemon that accepts and never answers `initialize` held the reconnect forever
    /// (its 60 s deadline was read only after a dial failed). After: each attempt ends at
    /// `ATTEMPT` and the reconnect fails at `BUDGET` with why.
    #[tokio::test(start_paused = true)]
    async fn a_daemon_that_accepts_and_never_answers_ends_the_reconnect_at_its_budget() {
        let tries = Arc::new(AtomicU32::new(0));
        let counted = tries.clone();
        let before = cmux_bounded::overrun_count(Reconnect::NAME);
        let started = Instant::now();
        let ended = tokio::time::timeout(
            Duration::from_secs(600),
            redial(move || {
                counted.fetch_add(1, Ordering::SeqCst);
                std::future::pending::<Result<()>>()
            }),
        )
        .await
        .expect("a reconnect to a daemon that never answers held the pane forever");
        let err = ended.expect_err("a daemon that never answered reconnected").to_string();
        assert!(err.contains("did not answer within 10 s"), "{err}");
        assert!(started.elapsed() <= BUDGET + ATTEMPT + BACKOFF_MAX, "{:?}", started.elapsed());
        assert!(tries.load(Ordering::SeqCst) >= 4, "{tries:?}");
        assert!(cmux_bounded::overrun_count(Reconnect::NAME) > before);
    }

    /// One attempt the daemon never answers, then one it does: reconnected on the second.
    #[tokio::test(start_paused = true)]
    async fn a_dial_that_hangs_once_is_dialed_again_and_reconnects() {
        let tries = Arc::new(AtomicU32::new(0));
        let counted = tries.clone();
        let back = redial(move || {
            let n = counted.fetch_add(1, Ordering::SeqCst);
            async move {
                if n == 0 {
                    std::future::pending::<()>().await;
                }
                Ok(n)
            }
        })
        .await
        .expect("reconnected");
        assert_eq!(back, 1);
    }

    /// A dial that fails at once still backs off and gives up at the budget, as before.
    #[tokio::test(start_paused = true)]
    async fn a_dial_that_fails_gives_up_at_the_budget_with_its_reason() {
        let err = redial(|| async { Err::<(), _>(anyhow::anyhow!("no socket")) })
            .await
            .expect_err("no daemon")
            .to_string();
        assert!(err.contains("within 60s: no socket"), "{err}");
    }
}
