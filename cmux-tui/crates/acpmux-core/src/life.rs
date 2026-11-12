//! Join-boundary supervision. Restart factories reopen durable state rather than reuse it.
#![deny(clippy::indexing_slicing, clippy::string_slice, clippy::expect_used)]
#![forbid(unsafe_code)]

use std::collections::VecDeque;
use std::time::Duration;
use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio::time::{Instant, sleep};

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

// A cancelled supervisor must not detach a writer. The restarted owner must never
// overlap the previous task just because its JoinHandle was dropped during shutdown.
struct Active<T>(JoinHandle<T>);
impl<T> Drop for Active<T> {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// The factory starts one task; its panic is observed only by joining that task.
/// The actor factory must open the checkpoint inside a blocking task on every call.
/// A normal return (including idle eviction) ends supervision; an I/O error is reported.
pub async fn supervise<T, E>(
    mut start: impl FnMut() -> JoinHandle<Result<T, E>>,
    policy: Policy,
    health: watch::Sender<Health>,
) -> Result<T, Failure<E>> {
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
    let mut failed = false;
    loop {
        // A failed chat stays failed during its probationary attempt. Its actor publishes
        // Running only after recovery succeeds, so callers cannot observe false readiness.
        if !failed {
            health.send_replace(Health::Starting);
        }
        let mut active = Active(start());
        match (&mut active.0).await {
            Ok(Ok(value)) => {
                health.send_replace(Health::Ended);
                return Ok(value);
            }
            Ok(Err(error)) => {
                health.send_replace(Health::Failed);
                return Err(Failure::Task(error));
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
                failed = panics.len() >= policy.panic_limit;
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
mod tests {
    use super::*;
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };

    #[tokio::test(start_paused = true)]
    async fn a_panic_restarts_through_the_factory_after_a_wait() {
        let starts = Arc::new(AtomicUsize::new(0));
        let (health, _) = watch::channel(Health::Starting);
        let policy = Policy { first_wait: Duration::from_millis(10), ..Policy::default() };
        let before = Instant::now();
        let result = supervise(
            || {
                let starts = Arc::clone(&starts);
                tokio::spawn(async move {
                    if starts.fetch_add(1, Ordering::SeqCst) == 0 {
                        panic!("injected actor panic");
                    }
                    Ok::<_, ()>(42)
                })
            },
            policy,
            health,
        )
        .await;
        assert!(matches!(result, Ok(42)));
        assert_eq!(starts.load(Ordering::SeqCst), 2);
        assert!(before.elapsed() >= policy.first_wait);
    }

    #[tokio::test(start_paused = true)]
    async fn five_panics_fail_the_chat_without_a_sixth_immediate_start() {
        let starts = Arc::new(AtomicUsize::new(0));
        let owned = Arc::clone(&starts);
        let (health, mut receiver) = watch::channel(Health::Starting);
        let policy = Policy { first_wait: Duration::from_millis(1), ..Policy::default() };
        let supervisor = tokio::spawn(supervise(
            move || {
                let starts = Arc::clone(&owned);
                tokio::spawn(async move {
                    starts.fetch_add(1, Ordering::SeqCst);
                    panic!("injected actor panic");
                    #[allow(unreachable_code)]
                    Ok::<(), ()>(())
                })
            },
            policy,
            health,
        ));
        let observed = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if *receiver.borrow_and_update() == Health::Failed {
                    break;
                }
                if receiver.changed().await.is_err() {
                    break;
                }
            }
        })
        .await;
        assert!(observed.is_ok());
        assert_eq!(*receiver.borrow(), Health::Failed);
        assert_eq!(starts.load(Ordering::SeqCst), 5);
        supervisor.abort();
        assert!(supervisor.await.is_err());
    }

    #[tokio::test(start_paused = true)]
    async fn cancelling_the_supervisor_also_cancels_its_writer() {
        struct Writer(watch::Sender<bool>);
        impl Drop for Writer {
            fn drop(&mut self) {
                self.0.send_replace(true);
            }
        }
        let (closed, mut receiver) = watch::channel(false);
        let (started, mut ready) = watch::channel(false);
        let (health, _) = watch::channel(Health::Starting);
        let supervisor = tokio::spawn(supervise(
            move || {
                let writer = Writer(closed.clone());
                let started = started.clone();
                tokio::spawn(async move {
                    let _writer = writer;
                    started.send_replace(true);
                    std::future::pending::<Result<(), ()>>().await
                })
            },
            Policy::default(),
            health,
        ));
        assert!(ready.changed().await.is_ok());
        supervisor.abort();
        assert!(supervisor.await.is_err());
        assert!(receiver.changed().await.is_ok());
        assert!(*receiver.borrow());
    }
}
