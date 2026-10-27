//! The daemon's hang watch (p09-observability section 3E, task 074): Chrome's `HangWatcher` for
//! the work acpmux runs outside its async tasks (base/threading/hang_watcher.h). The runtime's
//! workers are watched through the runtime's park and unpark hooks (task 118); this module covers
//! the rest:
//!
//! - **Blocking-pool items.** [`spawn_blocking`] runs one item in one scope of
//!   [`BLOCKING_ITEM`], Chrome's default `WatchHangsInScope` deadline for a task. Work that runs
//!   long by design (a child process, a bulk load at startup, a tree walk or a worktree change)
//!   stays on `tokio::task::spawn_blocking`, unwatched, as Chrome's `ScopedBlockingCall`
//!   `WILL_BLOCK` stops watching a wait. A wait for a child process inside watched work calls
//!   [`will_block`] first, at the call that waits.
//! - **Sync threads.** A daemon thread that runs one item at a time (a writer, a file watcher)
//!   registers once ([`SyncThread::register`]) and opens one scope per item, never around its
//!   wait for the next one ([`SyncThread::item`]).
//!
//! A hang appends a line to `$ACPMUX_HOME/hangs-<pid>.jsonl`, beside the panic log ([`init`]).

use std::path::Path;
use std::time::Duration;

use cmux_hang_watch::{Guard, Scope, ThreadKind};

/// How long one blocking-pool item may run: Chrome's default task deadline.
pub const BLOCKING_ITEM: Duration = cmux_hang_watch::DEFAULT_DEADLINE;
/// How long one write of a writer thread (a config file, a session record) may run: the
/// daemon journal writer's batch deadline (task 073).
pub const WRITE_ITEM: Duration = Duration::from_secs(5);
/// The name a blocking-pool thread that is not registered yet is watched under for its item.
pub const BLOCKING_THREAD: &str = "acpmux-blocking";

/// Starts the process's hang watch, with hang records in `dir`. A daemon that cannot start it
/// runs unwatched.
pub(crate) fn init(dir: &Path) {
    if let Err(error) = cmux_hang_watch::init(dir) {
        tracing::warn!("the daemon is not hang-watched: {error}");
    }
}

/// `cmux_blocking::spawn_blocking` (a `MayBlock` item, so its `scoped_blocking_call`s are
/// allowed), with the item watched for [`BLOCKING_ITEM`] ([`blocking_item`]).
#[track_caller]
pub fn spawn_blocking<F, R>(work: F) -> tokio::task::JoinHandle<R>
where
    F: FnOnce() -> R + Send + 'static,
    R: Send + 'static,
{
    cmux_blocking::spawn_blocking(move || blocking_item(BLOCKING_ITEM, work))
}

/// Runs `work` as one watched item of the calling thread: a scope of the thread's registration,
/// or, on a thread nobody registered (a blocking-pool thread the runtime's hooks did not
/// register), a registration of its own for the item ([`BLOCKING_THREAD`]).
pub fn blocking_item<R>(deadline: Duration, work: impl FnOnce() -> R) -> R {
    let scope = cmux_hang_watch::watch(deadline);
    if scope.is_watching() {
        let _scope = scope;
        return work();
    }
    drop(scope);
    let registration = cmux_hang_watch::register_thread(ThreadKind::Pool, BLOCKING_THREAD);
    let _scope = registration.watch(deadline);
    work()
}

/// Before a wait on a child process (or a signal's grace): the wait is the child's time, not the
/// daemon's, so the calling thread's open scopes stop blaming it until the outermost one closes
/// (Chrome's `ScopedBlockingCall` `WILL_BLOCK`, base/threading/scoped_blocking_call.h). A no-op on a
/// thread with no open scope.
pub fn will_block() {
    cmux_hang_watch::invalidate_active();
}

/// A daemon thread that runs one item at a time, registered with the process's hang watch for as
/// long as it lives. It belongs to the thread that registered it.
pub struct SyncThread {
    registration: Guard<'static>,
    deadline: Duration,
}

impl SyncThread {
    /// Registers the calling thread as `name`; each item may run for `deadline`.
    pub fn register(name: &str, deadline: Duration) -> SyncThread {
        SyncThread {
            registration: cmux_hang_watch::register_thread(ThreadKind::Lane, name),
            deadline,
        }
    }

    /// One item's scope: open it after the wait for the item, close it when the item is done.
    pub fn item(&self) -> Scope<'static> {
        self.registration.watch(self.deadline)
    }

    /// Whether the thread is watched (the process's watch runs).
    pub fn is_registered(&self) -> bool {
        self.registration.is_registered()
    }
}
