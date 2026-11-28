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

/// How long a lost daemon connection stays quiet: no error row and no "reconnecting…" before
/// it (the GUI chat's Reconnecting waits the same 10 s, cmux#43290, #43291, #43349).
pub(super) const QUIET: Duration = cmux_bounded::CONNECTION_QUIET;

/// `work`'s result. Only if it is still running after `quiet` does `loud` run, once (it says the
/// connection is down); a `work` that ends within `quiet` says nothing.
pub(super) async fn quietly<T>(
    work: impl Future<Output = Result<T>>,
    quiet: Duration,
    loud: impl FnOnce() -> Result<()>,
) -> Result<T> {
    tokio::pin!(work);
    tokio::select! {
        done = &mut work => return done,
        () = tokio::time::sleep(quiet) => {}
    }
    loud()?;
    work.await
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
#[path = "reconnect_wait_tests.rs"]
mod tests;
