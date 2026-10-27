//! Owned background tasks: every task hostd starts has an owner that keeps
//! its handle and learns how it ended, so a panic is never lost.
//!
//! Chromium posts work only to a task runner its owner holds
//! (`base/task/sequenced_task_runner.h`) and closes a misbehaving renderer
//! instead of the browser (`ReportBadMessage`,
//! `content/public/browser/render_process_host.h`). A [`TaskScope`] is that
//! owner here, and its owner picks the policy when a task ends:
//!
//! - process workers (`host::run`: control input, SIGTERM, pushes, the
//!   network watcher, held mailbox turns) are fatal when they panic: `run`
//!   returns [`WorkerFailed`] and hostd exits with [`EXIT_WORKER_FAILED`], so
//!   the app's supervisor starts a fresh hostd;
//! - a phone's tasks (its link, media session, mailbox frame, channels) end
//!   that phone only: its link closes and the others keep working.
//!
//! Dropping a scope aborts the tasks it still holds.

use std::any::Any;
use std::future::Future;
use std::panic::AssertUnwindSafe;

use futures_util::FutureExt;
use tokio::task::JoinSet;

/// hostd's exit status after a process worker failed (`EX_SOFTWARE`, the
/// status `cmux_panic_log::supervise` uses): the app restarts hostd.
pub const EXIT_WORKER_FAILED: i32 = 70;

/// Tasks with one owner, each named by a label of type `L`.
pub struct TaskScope<L> {
    set: JoinSet<(L, Result<(), String>)>,
}

/// How a task of a [`TaskScope`] ended.
#[derive(Debug, PartialEq, Eq)]
pub enum Ended<L> {
    /// The task returned.
    Finished(L),
    /// The task panicked; the message is the panic's payload.
    Panicked(L, String),
    /// The runtime dropped the task while it shut down.
    Cancelled,
}

impl<L> Default for TaskScope<L> {
    fn default() -> Self {
        Self { set: JoinSet::new() }
    }
}

impl<L: Send + 'static> TaskScope<L> {
    /// Starts `task` on the current runtime; the scope keeps its handle.
    pub fn spawn<F>(&mut self, label: L, task: F)
    where
        F: Future<Output = ()> + Send + 'static,
    {
        // The panic is caught at the task boundary, where tokio would catch it
        // anyway, so the owner gets it with the task's label.
        self.set.spawn(async move {
            let outcome = AssertUnwindSafe(task).catch_unwind().await.map_err(|panic| panic_message(&*panic));
            (label, outcome)
        });
    }

    /// The next task that ends. Pending while the scope holds none, so it
    /// can sit in a `select!` beside the owner's own work.
    pub async fn ended(&mut self) -> Ended<L> {
        match self.set.join_next().await {
            Some(Ok((label, Ok(())))) => Ended::Finished(label),
            Some(Ok((label, Err(message)))) => Ended::Panicked(label, message),
            Some(Err(_)) => Ended::Cancelled,
            None => std::future::pending().await,
        }
    }

    /// Waits for every task to end, in the order they end.
    pub async fn drain(&mut self, mut each: impl FnMut(Ended<L>)) {
        while !self.set.is_empty() {
            each(self.ended().await);
        }
    }

    /// How many tasks are still held (running, or ended and not yet reported).
    pub fn len(&self) -> usize {
        self.set.len()
    }

    pub fn is_empty(&self) -> bool {
        self.set.is_empty()
    }
}

/// The text of a panic payload (`panic!` with a literal or a format).
pub fn panic_message(panic: &(dyn Any + Send)) -> String {
    if let Some(text) = panic.downcast_ref::<&str>() {
        (*text).to_owned()
    } else if let Some(text) = panic.downcast_ref::<String>() {
        text.clone()
    } else {
        "a panic with a non-text payload".to_owned()
    }
}

/// A process worker of hostd that failed: hostd stops so its supervisor
/// starts it again (the default policy of `cmux_panic_log::supervise`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkerFailed {
    pub worker: &'static str,
    pub reason: String,
}

impl std::fmt::Display for WorkerFailed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "hostd worker `{}` failed: {}", self.worker, self.reason)
    }
}

impl std::error::Error for WorkerFailed {}

/// Process workers: each runs for the life of hostd.
pub type Workers = TaskScope<&'static str>;

impl Workers {
    /// The next worker that panicked (or was cancelled), as the error that
    /// ends hostd. A worker that returns has finished its job (no network
    /// watcher off macOS, no SIGTERM stream) and is not a failure.
    pub async fn failed(&mut self) -> WorkerFailed {
        loop {
            match self.ended().await {
                Ended::Finished(worker) => tracing::debug!(worker, "hostd worker finished"),
                Ended::Panicked(worker, reason) => return WorkerFailed { worker, reason },
                Ended::Cancelled => {
                    return WorkerFailed { worker: "unknown", reason: "cancelled by the runtime".into() };
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_panicking_task_reports_its_label_and_message() {
        let mut scope = TaskScope::default();
        scope.spawn("boom", async { panic!("bad frame {}", 7) });
        assert_eq!(scope.ended().await, Ended::Panicked("boom", "bad frame 7".into()));
        assert!(scope.is_empty());
    }

    #[tokio::test]
    async fn a_finished_worker_is_not_a_failure_and_a_panicking_one_is() {
        let mut workers = Workers::default();
        workers.spawn("netwatch", async {});
        let (release, wait) = tokio::sync::oneshot::channel::<()>();
        workers.spawn("notify", async move {
            let _ = wait.await;
            panic!("push worker broke");
        });
        // The finished worker is reaped while `failed` waits for the other.
        let failed = workers.failed();
        tokio::pin!(failed);
        assert!(failed.as_mut().now_or_never().is_none());
        let _ = release.send(());
        assert_eq!(failed.await, WorkerFailed { worker: "notify", reason: "push worker broke".into() });
    }

    #[tokio::test]
    async fn an_empty_scope_stays_pending_beside_other_work() {
        let mut scope = TaskScope::<&str>::default();
        let other = async { 5 };
        let got = tokio::select! {
            _ = scope.ended() => 0,
            value = other => value,
        };
        assert_eq!(got, 5);
    }

    #[tokio::test]
    async fn dropping_a_scope_aborts_its_tasks() {
        let (tx, rx) = tokio::sync::oneshot::channel::<()>();
        let mut scope = TaskScope::default();
        scope.spawn("holder", async move {
            let _keep = tx;
            std::future::pending::<()>().await;
        });
        drop(scope);
        // The task's sender dropped with it.
        assert!(rx.await.is_err());
    }

    #[tokio::test]
    async fn drain_waits_for_every_task() {
        let mut scope = TaskScope::default();
        for n in 0..3 {
            scope.spawn(n, async move { tokio::task::yield_now().await });
        }
        let mut seen = Vec::new();
        scope
            .drain(|ended| {
                if let Ended::Finished(n) = ended {
                    seen.push(n);
                }
            })
            .await;
        seen.sort_unstable();
        assert_eq!(seen, vec![0, 1, 2]);
    }
}
