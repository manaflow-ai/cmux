//! Daemon-owned v2 lifecycle state and join-boundary supervision.
#![deny(clippy::indexing_slicing, clippy::string_slice, clippy::expect_used)]
#![forbid(unsafe_code)]

use crate::hub::{Hub, HubWriter};
use cmux_scope::Scope;
use std::collections::{HashSet, VecDeque};
use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio::time::{Instant, sleep};

/// The single v2 handle a daemon keeps after its listener is ready.
///
/// Construction is intentionally synchronous: starting v2 never gates the
/// daemon's v1 listener or waits on a chat/book.
pub struct V2 {
    pub hub: Arc<Hub>,
    pub writer: Mutex<Option<HubWriter>>,
    surfaces: Arc<HashSet<String>>,
}

impl V2 {
    pub fn new(hub: Hub, writer: HubWriter) -> Self {
        Self::with_surfaces(hub, writer, ["list"].into_iter().map(str::to_owned).collect())
    }

    pub fn with_surfaces(hub: Hub, writer: HubWriter, surfaces: HashSet<String>) -> Self {
        Self { hub: Arc::new(hub), writer: Mutex::new(Some(writer)), surfaces: Arc::new(surfaces) }
    }

    pub fn hub(&self) -> Arc<Hub> {
        Arc::clone(&self.hub)
    }

    pub fn take_writer(&self) -> Option<HubWriter> {
        self.writer.lock().ok().and_then(|mut writer| writer.take())
    }

    pub fn allows_surfaces(&self, requested: &[&str]) -> bool {
        !requested.is_empty() && requested.iter().all(|surface| self.surfaces.contains(*surface))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Health {
    Starting,
    Running,
    Restarting,
    /// Callers must receive an error until a later attempt succeeds.
    Failed,
    Ended,
}

#[derive(Clone, Copy, Debug)]
pub struct Policy {
    pub first_wait: Duration,
    pub max_wait: Duration,
    pub panic_window: Duration,
    pub panic_limit: usize,
    pub failed_wait: Duration,
}

impl Default for Policy {
    fn default() -> Self {
        Self {
            first_wait: Duration::from_millis(100),
            max_wait: Duration::from_secs(30),
            panic_window: Duration::from_secs(5 * 60),
            panic_limit: 5,
            failed_wait: Duration::from_secs(60),
        }
    }
}

#[derive(Debug)]
pub enum Failure<E> {
    Task(E),
    Cancelled,
    InvalidPolicy,
}

// Dropping the supervisor requests cancellation of its async child rather than
// detaching it. As with any abort, the child's destructor runs when it next yields.
struct Active<T>(JoinHandle<T>);
impl<T> Drop for Active<T> {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// Starts an owned async task for each factory future; observes panics only at its join.
/// The caller closes the scope and checks its joined report before replacing an
/// externally cancelled supervisor. The scope must belong to this chat alone.
/// The factory constructs a future without doing work itself. That future owns the
/// writer and must be cancellation safe: no detached background writer. Checkpoint
/// open can run off the worker, but an abandoned open must drop its result and lock.
/// Blocking work is not abortable, so its owner must finish before any replacement
/// can acquire the book lock. A normal return (including idle eviction) ends
/// supervision; an I/O error is reported.
pub async fn supervise<T, E, F>(
    scope: &Scope,
    mut start: impl FnMut() -> F,
    policy: Policy,
    health: watch::Sender<Health>,
) -> Result<T, Failure<E>>
where
    F: Future<Output = Result<T, E>> + Send + 'static,
    T: Send + 'static,
    E: Send + 'static,
{
    if policy.first_wait.is_zero()
        || policy.max_wait < policy.first_wait
        || policy.panic_window.is_zero()
        || policy.panic_limit == 0
        || policy.failed_wait.is_zero()
    {
        health.send_replace(Health::Failed);
        return Err(Failure::InvalidPolicy);
    }
    let mut panics = VecDeque::new();
    let mut delay = policy.first_wait;
    loop {
        // A failed chat stays failed during its probationary attempt. Its actor publishes
        // Running only after recovery succeeds, so callers cannot observe false readiness.
        if *health.borrow() != Health::Failed {
            health.send_replace(Health::Starting);
        }
        let mut active = Active(scope.spawn_named("chat-actor", start()));
        match (&mut active.0).await {
            Ok(Ok(value)) => {
                health.send_replace(Health::Ended);
                return Ok(value);
            }
            Ok(Err(_error)) => {
                let now = Instant::now();
                while panics
                    .front()
                    .is_some_and(|at| now.duration_since(*at) >= policy.panic_window)
                {
                    panics.pop_front();
                }
                if panics.len() == policy.panic_limit {
                    panics.pop_front();
                }
                panics.push_back(now);
                let failed = panics.len() >= policy.panic_limit;
                health.send_replace(if failed { Health::Failed } else { Health::Restarting });
                sleep(if failed { policy.failed_wait } else { delay }).await;
                delay = delay.saturating_mul(2).min(policy.max_wait);
            }
            Err(error) if error.is_panic() => {
                let now = Instant::now();
                while panics
                    .front()
                    .is_some_and(|at| now.duration_since(*at) >= policy.panic_window)
                {
                    panics.pop_front();
                }
                // Retain only enough timestamps to decide the threshold, never an unbounded history.
                if panics.len() == policy.panic_limit {
                    panics.pop_front();
                }
                panics.push_back(now);
                let failed = panics.len() >= policy.panic_limit;
                health.send_replace(if failed { Health::Failed } else { Health::Restarting });
                sleep(if failed { policy.failed_wait } else { delay }).await;
                delay = delay.saturating_mul(2).min(policy.max_wait);
            }
            Err(_) => {
                health.send_replace(Health::Failed);
                return Err(Failure::Cancelled);
            }
        }
    }
}

#[cfg(test)]
mod tests;
