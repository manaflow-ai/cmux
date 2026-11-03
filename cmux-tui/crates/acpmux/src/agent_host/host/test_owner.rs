//! Debug builds only: a host a test started ends with that test's process. Hosts outlive their
//! daemon on purpose, so a test daemon that panicked, timed out or was killed left its hosts (and
//! their stand-in harnesses) running for days on lane VMs and fleet hosts: about 23 on one lane VM
//! (2026-11-03), run from checkouts that no longer existed. The record watch (`watch_record`) ends
//! a host only when its home goes, and a killed test never removes its scratch.
//!
//! Every process a test starts gets [`TEST_OWNER_PID_ENV`] with the test process's pid
//! (`tests/support/daemon_env.rs`), a daemon passes it on to the hosts it starts (`link.rs`), and
//! the host follows that pid as a daemon follows its app (`daemon/owner_exit.rs`: a kqueue
//! `NOTE_EXIT` or a pidfd, no polling). Once it exits, the host ends like SIGTERM. Release builds
//! have no seam.

use super::*;

/// The pid of the test process whose end ends this host.
pub(crate) const TEST_OWNER_PID_ENV: &str = "ACPMUX_TEST_HOST_OWNER_PID";

/// Follows the test process named in [`TEST_OWNER_PID_ENV`], if any: sends [`Event::Term`] on
/// `tx` once it exited. A pid that does not parse, is 0 or 1, or is this process names none.
pub(super) fn follow(tx: mpsc::Sender<Event>) {
    let Some(pid) = owner_pid(std::env::var(TEST_OWNER_PID_ENV).ok().as_deref()) else {
        return;
    };
    let spawned =
        std::thread::Builder::new().name("acpmux-test-owner-watch".into()).spawn(move || {
            match crate::daemon::owner_exit::wait_exit(pid) {
                // Not a runtime thread: a blocking send never drops the end when the queue is full.
                Ok(()) => {
                    let _ = tx.blocking_send(Event::Term);
                }
                Err(error) => tracing::warn!(pid, %error, "cannot watch the test process"),
            }
        });
    if let Err(error) = spawned {
        tracing::warn!(pid, %error, "cannot start the test process watch");
    }
}

fn owner_pid(value: Option<&str>) -> Option<u32> {
    let pid = value?.trim().parse::<u32>().ok()?;
    (pid > 1 && pid != std::process::id() && i32::try_from(pid).is_ok()).then_some(pid)
}
