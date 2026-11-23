//! Daemon-owned v2 lifecycle state and join-boundary supervision.
#![deny(clippy::indexing_slicing, clippy::string_slice, clippy::expect_used)]
#![forbid(unsafe_code)]

use crate::hub::{Hub, HubWriter};
use crate::registry::Registry;
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
    /// The chat registry: made only when the daemon writes books (`books` in the set, a store on
    /// disk).
    registry: Option<Registry>,
}

impl V2 {
    pub fn new(hub: Hub, writer: HubWriter) -> Self {
        Self::with_surfaces(hub, writer, ["list"].into_iter().map(str::to_owned).collect())
    }

    pub fn with_surfaces(hub: Hub, writer: HubWriter, surfaces: HashSet<String>) -> Self {
        Self {
            hub: Arc::new(hub),
            writer: Mutex::new(Some(writer)),
            surfaces: Arc::new(surfaces),
            registry: None,
        }
    }

    /// The handle with a chat registry: the daemon's when it writes books.
    pub fn with_registry(mut self, registry: Registry) -> Self {
        self.registry = Some(registry);
        self
    }

    pub fn registry(&self) -> Option<&Registry> {
        self.registry.as_ref()
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
mod tests {
    use super::*;
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };

    #[tokio::test(start_paused = true)]
    async fn a_panic_restarts_through_the_factory_after_a_wait() {
        let scope = Scope::new("supervision-test");
        let starts = Arc::new(AtomicUsize::new(0));
        let (health, _) = watch::channel(Health::Starting);
        let policy = Policy { first_wait: Duration::from_millis(10), ..Policy::default() };
        let before = Instant::now();
        let result = supervise(
            &scope,
            || {
                let starts = Arc::clone(&starts);
                async move {
                    if starts.fetch_add(1, Ordering::SeqCst) == 0 {
                        panic!("injected actor panic");
                    }
                    Ok::<_, ()>(42)
                }
            },
            policy,
            health,
        )
        .await;
        assert!(matches!(result, Ok(42)));
        assert_eq!(starts.load(Ordering::SeqCst), 2);
        assert!(before.elapsed() >= policy.first_wait);
        assert!(scope.close(Duration::from_secs(1)).await.joined());
    }

    #[tokio::test(start_paused = true)]
    async fn an_actor_error_uses_the_same_restart_wait_as_a_panic() {
        let scope = Scope::new("supervision-test");
        let starts = Arc::new(AtomicUsize::new(0));
        let (health, _) = watch::channel(Health::Starting);
        let policy = Policy { first_wait: Duration::from_millis(10), ..Policy::default() };
        let result = supervise(
            &scope,
            || {
                let starts = Arc::clone(&starts);
                async move {
                    if starts.fetch_add(1, Ordering::SeqCst) < 2 {
                        Err::<u32, _>(())
                    } else {
                        Ok::<u32, _>(42)
                    }
                }
            },
            policy,
            health,
        )
        .await;
        assert!(matches!(result, Ok(42)));
        assert_eq!(starts.load(Ordering::SeqCst), 3);
        assert!(scope.close(Duration::from_secs(1)).await.joined());
    }

    #[tokio::test(start_paused = true)]
    async fn five_panics_fail_the_chat_without_a_sixth_immediate_start() {
        let scope = Arc::new(Scope::new("supervision-test"));
        let owned_scope = Arc::clone(&scope);
        let starts = Arc::new(AtomicUsize::new(0));
        let owned = Arc::clone(&starts);
        let (health, mut receiver) = watch::channel(Health::Starting);
        let policy = Policy { first_wait: Duration::from_millis(1), ..Policy::default() };
        let supervisor = tokio::spawn(async move {
            supervise(
                &owned_scope,
                move || {
                    let starts = Arc::clone(&owned);
                    async move {
                        starts.fetch_add(1, Ordering::SeqCst);
                        panic!("injected actor panic");
                        #[allow(unreachable_code)]
                        Ok::<(), ()>(())
                    }
                },
                policy,
                health,
            )
            .await
        });
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
        assert!(scope.close(Duration::from_secs(1)).await.joined());
    }

    #[tokio::test(start_paused = true)]
    async fn cancelling_the_supervisor_also_cancels_its_writer() {
        struct Writer(watch::Sender<bool>);
        impl Drop for Writer {
            fn drop(&mut self) {
                self.0.send_replace(true);
            }
        }
        let scope = Arc::new(Scope::new("supervision-test"));
        let owned_scope = Arc::clone(&scope);
        let (closed, mut receiver) = watch::channel(false);
        let (started, mut ready) = watch::channel(false);
        let (health, _) = watch::channel(Health::Starting);
        let supervisor = tokio::spawn(async move {
            supervise(
                &owned_scope,
                move || {
                    let writer = Writer(closed.clone());
                    let started = started.clone();
                    async move {
                        let _writer = writer;
                        started.send_replace(true);
                        std::future::pending::<Result<(), ()>>().await
                    }
                },
                Policy::default(),
                health,
            )
            .await
        });
        assert!(ready.changed().await.is_ok());
        supervisor.abort();
        assert!(supervisor.await.is_err());
        assert!(receiver.changed().await.is_ok());
        assert!(*receiver.borrow());
        assert!(scope.close(Duration::from_secs(1)).await.joined());
    }
}
