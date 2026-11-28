//! A stop signal ends the process even when the runtime never reads it.
//!
//! SIGTERM and SIGINT reach the stop through tokio's signal stream, which only a task on the
//! runtime reads (`daemon.rs`, the stop loop). The stop's own watchdog (`stop_watchdog.rs`) is
//! armed after that read. So a daemon whose every worker is held (a blocking lock, `flock` or
//! `fsync` on a worker: `runtime_stall.rs` captures) never begins its stop: on a lane VM on
//! 2026-11-28, 29 stops in a row ran systemd's whole 90 s `TimeoutStopSec` and were SIGKILLed,
//! with no "stopping: SIGTERM" line, no end written and the next start counting a death.
//!
//! This is a signal action beside tokio's and `term_sender`'s (all three run on each delivery,
//! through `signal-hook-registry`) that writes one byte to a pipe, and a thread with no runtime
//! that reads it. At [`BACKSTOP`] after the first signal, if the process still runs, the thread
//! ends it through the watchdog's hard exit: this daemon's own child agents, its pid file and
//! its end within the exit's bound, then `_exit` with the stop's status. A stop that ends in time
//! (every stop's budget is at most [`crate::daemon::shutdown_budget`]`(true)`, 8 s) never meets
//! it: the process is gone, and the thread with it.

use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::Duration;

/// How long after the first stop signal the process may still run. Far past the longest stop's
/// budget (8 s, when the stop ends its agents) and its writers' drain, and well inside the 90 s a
/// service manager gives a stop before SIGKILL (systemd's default `TimeoutStopSec`).
// timeout: bound on a stop the runtime never began; when passed the process exits through the hard exit
pub(super) const BACKSTOP: Duration = Duration::from_secs(30);

/// Debug builds only: the backstop in ms, so a test need not wait [`BACKSTOP`], or `off` for
/// none (the stop as it was before this backstop, measured in the same harness).
#[cfg(debug_assertions)]
const BACKSTOP_ENV: &str = "ACPMUX_TEST_TERM_BACKSTOP_MS";

/// The pipe's write end, or -1 before [`arm`]. The signal action reads it with one atomic load.
static WRITE_FD: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(-1);

/// The hub whose own children the hard exit ends, once there is one.
static HUB: Mutex<Option<Weak<crate::hub::Hub>>> = Mutex::new(None);

fn backstop() -> Option<Duration> {
    #[cfg(debug_assertions)]
    match std::env::var(BACKSTOP_ENV).ok().as_deref() {
        Some("off") => return None,
        Some(ms) => {
            if let Ok(ms) = ms.parse() {
                return Some(Duration::from_millis(ms));
            }
        }
        None => {}
    }
    Some(BACKSTOP)
}

/// Starts the thread and registers the action for SIGTERM and SIGINT. Call it only after tokio's
/// own streams are registered: an action of ours alone would replace the default action. Once
/// per process; a later call does nothing.
pub(super) fn arm() {
    if WRITE_FD.load(std::sync::atomic::Ordering::SeqCst) >= 0 {
        return;
    }
    let Some(bound) = backstop() else { return };
    let mut fds = [-1i32; 2];
    // SAFETY: `fds` has room for the two descriptors pipe2 writes.
    if unsafe { pipe2(&mut fds) } != 0 {
        tracing::warn!(
            error = %std::io::Error::last_os_error(),
            "cannot start the stop backstop; a stop the runtime never reads runs to SIGKILL"
        );
        return;
    }
    let [read_fd, write_fd] = fds;
    let spawned =
        std::thread::Builder::new().name("acpmux-term-backstop".into()).spawn(move || {
            let mut byte = [0u8; 1];
            loop {
                // SAFETY: reads one byte into a live buffer from a descriptor this thread owns.
                let n = unsafe { libc::read(read_fd, byte.as_mut_ptr().cast(), 1) };
                if n == 1 {
                    break;
                }
                if n < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted
                {
                    continue;
                }
                return;
            }
            std::thread::sleep(bound);
            tracing::error!(
                after_ms = bound.as_millis() as u64,
                "a stop signal came and the daemon is still running: its runtime never ran the stop; exiting now"
            );
            let hub = HUB.lock().unwrap_or_else(PoisonError::into_inner).clone();
            super::stop_watchdog::exit_now(&hub.unwrap_or_default());
        });
    if let Err(error) = spawned {
        tracing::warn!(%error, "cannot start the stop backstop thread");
        // SAFETY: both descriptors are this function's and unused elsewhere.
        unsafe {
            libc::close(read_fd);
            libc::close(write_fd);
        }
        return;
    }
    WRITE_FD.store(write_fd, std::sync::atomic::Ordering::SeqCst);
    for signal in [libc::SIGTERM, libc::SIGINT] {
        // SAFETY: the action does an atomic load and one non-blocking write(2), both
        // async-signal-safe; errno is saved and restored around them.
        let registered = unsafe {
            signal_hook_registry::register_sigaction(signal, |_: &libc::siginfo_t| {
                let fd = WRITE_FD.load(std::sync::atomic::Ordering::SeqCst);
                if fd >= 0 {
                    let saved = errno();
                    let _ = libc::write(fd, [1u8].as_ptr().cast(), 1);
                    set_errno(saved);
                }
            })
        };
        if let Err(error) = registered {
            tracing::warn!(%error, signal, "cannot register the stop backstop's action");
        }
    }
}

/// The hub the hard exit ends the children of.
pub(super) fn attach(hub: &Arc<crate::hub::Hub>) {
    *HUB.lock().unwrap_or_else(PoisonError::into_inner) = Some(Arc::downgrade(hub));
}

/// Debug builds only: with `ACPMUX_TEST_STOP_UNREAD` set, the stop loop that just read a
/// SIGTERM parks for good, as a stop whose runtime never runs its reader does
/// (`tests/term_backstop.rs`). Release builds have no seam.
pub(super) fn test_hold_unread() {
    #[cfg(debug_assertions)]
    if std::env::var_os("ACPMUX_TEST_STOP_UNREAD").is_some() {
        loop {
            std::thread::park();
        }
    }
}

/// A pipe whose ends close on exec and whose write end never blocks (a full pipe drops the byte:
/// one is already there to read).
unsafe fn pipe2(fds: &mut [i32; 2]) -> i32 {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        // SAFETY: the caller's buffer holds two descriptors.
        unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC | libc::O_NONBLOCK) }
    }
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    {
        // SAFETY: the caller's buffer holds two descriptors; the flags are set on each before
        // the descriptor is shared.
        unsafe {
            if libc::pipe(fds.as_mut_ptr()) != 0 {
                return -1;
            }
            for fd in *fds {
                libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
            }
            let flags = libc::fcntl(fds[1], libc::F_GETFL);
            libc::fcntl(fds[1], libc::F_SETFL, flags | libc::O_NONBLOCK);
            // The read end stays blocking: the thread waits in read(2).
            0
        }
    }
}

fn errno() -> i32 {
    std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

fn set_errno(value: i32) {
    // SAFETY: writes this thread's errno through its libc location.
    unsafe {
        #[cfg(any(target_os = "linux", target_os = "android"))]
        {
            *libc::__errno_location() = value;
        }
        #[cfg(any(target_os = "macos", target_os = "ios", target_os = "freebsd"))]
        {
            *libc::__error() = value;
        }
    }
}
