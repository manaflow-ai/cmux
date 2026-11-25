//! The stop's one deadline (moved out of `daemon.rs`, which is over its size budget) and, with
//! `start` in `acpmux.v2`, its hard exit: a thread that ends the process 800 ms into a stop
//! whatever else is true (hq `docs/design/agent-service-v2.md`, "Stop is exit", row 10).
//!
//! Every bound in the stop sequence (`daemon.rs`) is a timer on the runtime, so none of them
//! fires when the runtime itself is held: a pass that never yields kept a NIGHTLY daemon alive
//! with its lock held and its socket already removed (2026-11-02), and the app waited 38 s on a
//! stop. The watchdog is a thread with a condition variable and no runtime, so it runs whatever
//! the stop is stuck in. At its hard point ([`EXIT_MARGIN`] before the stop's deadline: 800 ms
//! into every stop that keeps its agents) it kills this daemon's own child agents, removes the
//! pid file and writes the daemon's end within [`LAST_WORDS`], and calls `_exit` with the stop's
//! status.
//! Host records and live locks stay as they are: the agents under hosts keep running and the
//! next daemon adopts them. What a writer still held in memory is lost, as in a crash at that
//! moment; the design writes each item at its event so nothing a person would miss is there.
//!
//! The fence is every daemon's; the watchdog is `start`'s. With the setting empty no thread is
//! started and the stop is base's: the same waits in the same order, and the writers still
//! finish past the deadline (Codex review of #42296). A stop that ends in time never meets it:
//! `run`'s return disarms it ([`Armed`]).

use std::sync::{Arc, Condvar, Mutex, PoisonError, Weak};
use std::time::{Duration, Instant};

/// How long before the stop's deadline the process exits by itself: the exit's own last writes
/// and the process's end fit in what is left.
// timeout: margin before the stop's deadline, no event to wait for; when passed the process exits
const EXIT_MARGIN: Duration = Duration::from_millis(200);

/// The most the exit's own last writes get (this daemon's end, its pid file, the log's last
/// lines): they run on a thread of their own, so a disk that does not answer cannot hold the
/// exit.
// timeout: bound on the exit's own last writes; when passed the process exits without them
const LAST_WORDS: Duration = Duration::from_millis(100);

/// Debug builds only: set, the stop parks for good right after it began, as a stop whose runtime
/// is held does (`tests/stop_watchdog.rs`). Release builds have no seam.
#[cfg(debug_assertions)]
const STALL_ENV: &str = "ACPMUX_TEST_STOP_STALL";

/// Includes the CLI's final diagnostic-log flush, which used to add a fresh second after
/// the daemon had consumed its entire shutdown budget.
static SHUTDOWN_DEADLINE: Mutex<Option<Instant>> = Mutex::new(None);

pub(crate) fn shutdown_time_left() -> Option<Duration> {
    SHUTDOWN_DEADLINE
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .as_ref()
        .map(|deadline| deadline.saturating_duration_since(Instant::now()))
}

/// No stop is under way: `run` starts.
pub(super) fn reset() {
    *SHUTDOWN_DEADLINE.lock().unwrap_or_else(PoisonError::into_inner) = None;
}

/// Whether `run` returned, which the watchdog waits on beside its hard point.
#[derive(Default)]
struct Returned {
    yes: Mutex<bool>,
    moved: Condvar,
}

impl Returned {
    fn set(&self) {
        *self.yes.lock().unwrap_or_else(PoisonError::into_inner) = true;
        self.moved.notify_all();
    }

    /// Blocks until `run` returned (false) or `hard` passed with it still running (true). Only
    /// the return wakes it before then; nothing is polled.
    fn overdue(&self, hard: Instant) -> bool {
        let mut yes = self.yes.lock().unwrap_or_else(PoisonError::into_inner);
        loop {
            if *yes {
                return false;
            }
            let left = hard.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return true;
            }
            yes = self.moved.wait_timeout(yes, left).unwrap_or_else(PoisonError::into_inner).0;
        }
    }
}

/// The armed hard exit, or none. Dropped when `run` returns, which disarms it.
pub(super) struct Armed(Option<Arc<Returned>>);

impl Drop for Armed {
    fn drop(&mut self) {
        if let Some(returned) = &self.0 {
            returned.set();
        }
    }
}

/// The stop began and ends by `deadline`: records it for [`shutdown_time_left`] and, when
/// `hard_exit` (`start` in `acpmux.v2`), starts the watchdog, which ends the process
/// [`EXIT_MARGIN`] before it. Without its thread the stop has its timers only.
pub(super) fn arm(hub: &Arc<crate::hub::Hub>, deadline: Instant, hard_exit: bool) -> Armed {
    *SHUTDOWN_DEADLINE.lock().unwrap_or_else(PoisonError::into_inner) = Some(deadline);
    let armed = if hard_exit {
        let returned = Arc::new(Returned::default());
        let hard = deadline.checked_sub(EXIT_MARGIN).unwrap_or(deadline);
        let (watched, hub) = (returned.clone(), Arc::downgrade(hub));
        let watch = move || {
            if watched.overdue(hard) {
                exit(&hub);
            }
        };
        let spawned = std::thread::Builder::new().name("acpmux-stop-watchdog".into()).spawn(watch);
        if let Err(error) = spawned {
            tracing::warn!(%error, "cannot start the stop watchdog; this stop has no hard exit");
        }
        Armed(Some(returned))
    } else {
        Armed(None)
    };
    #[cfg(debug_assertions)]
    if std::env::var_os(STALL_ENV).is_some() {
        loop {
            std::thread::park();
        }
    }
    armed
}

/// Ends the process now, with the status `run`'s return would have given it: an intended stop
/// stays one for whoever started the daemon. First the agents that are this daemon's own
/// children (nothing else would end them), then, within [`LAST_WORDS`], this daemon's end and pid
/// file as `run` writes them, and the log's last lines.
fn exit(hub: &Weak<crate::hub::Hub>) -> ! {
    let status = super::exit_status();
    let killed = hub.upgrade().map_or(0, |hub| hub.kill_children_at_exit());
    tracing::error!(
        killed,
        "the stop did not end in time; exiting now (agents under hosts keep running)"
    );
    let (done, finished) = std::sync::mpsc::channel::<()>();
    let last = std::thread::Builder::new().name("acpmux-stop-last-words".into()).spawn(move || {
        let began = Instant::now();
        if !crate::config::home_lost() {
            let home = crate::config::home();
            // The pid file first: it is one unlink, where the end record is a write the disk may
            // hold past the bound.
            let _ = crate::home_fs::remove_file(home.join("daemon.pid"));
            let unlinked = began.elapsed();
            super::supervision::finish(&home, status);
            tracing::warn!(
                pid_file_ms = unlinked.as_millis() as u64,
                end_record_ms = began.elapsed().as_millis() as u64,
                "the hard exit's last writes"
            );
        }
        let _ = crate::log_sink::flush(LAST_WORDS);
        let _ = done.send(());
    });
    if last.is_ok() {
        let _ = finished.recv_timeout(LAST_WORDS);
    }
    end_process(status)
}

/// The process ends here, on purpose: a new exit site, which the crash ratchet counts in its
/// `process::exit` spelling only (`scripts/cmux-next/crash_ratchet.py`), so the waiver below
/// stands for both. On Unix with no exit handler and no destructor: one of them may wait on what
/// the stop is stuck in.
#[cfg(unix)]
fn end_process(status: i32) -> ! {
    // SAFETY: `_exit` takes a status and does not return.
    unsafe { libc::_exit(status) }
}

#[cfg(not(unix))]
fn end_process(status: i32) -> ! {
    // crash-allow: the stop's own end, only from the watchdog of a daemon with `start` in acpmux.v2 that was asked to stop and is past its hard point; exits with the stop's status, and what the journal acknowledged is already on disk
    std::process::exit(status)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_stop_still_running_is_overdue_at_the_hard_point() {
        let returned = Returned::default();
        let hard = Instant::now() + Duration::from_millis(60);
        assert!(returned.overdue(hard));
        assert!(Instant::now() >= hard, "it returned before the hard point");
    }

    #[test]
    fn a_stop_that_returns_is_never_overdue() {
        let returned = Arc::new(Returned::default());
        drop(Armed(Some(returned.clone())));
        let passed = Instant::now().checked_sub(Duration::from_millis(1)).unwrap();
        assert!(!returned.overdue(passed));
    }

    /// The return wakes the wait: the watchdog's thread ends at once, not at its hard point.
    #[test]
    fn the_return_wakes_the_wait() {
        let returned = Returned::default();
        let began = Instant::now();
        let overdue = std::thread::scope(|scope| {
            let waiting = scope.spawn(|| returned.overdue(began + Duration::from_secs(60)));
            std::thread::sleep(Duration::from_millis(50));
            returned.set();
            waiting.join().unwrap()
        });
        assert!(!overdue);
        assert!(began.elapsed() < Duration::from_secs(10), "{:?}", began.elapsed());
    }
}
