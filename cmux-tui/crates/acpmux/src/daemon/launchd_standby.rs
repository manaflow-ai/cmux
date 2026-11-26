//! A launchd job's daemon that finds its home held stands by instead of exiting.
//!
//! launchd restarts a `KeepAlive` job whatever its exit status (it has no
//! `RestartPreventExitStatus`, which keeps systemd's unit from looping on the lock refusal,
//! exit 75). So a LaunchDaemon or LaunchAgent that runs `acpmux daemon run` on a home another
//! daemon serves (the app's own, `/Applications/cmux NIGHTLY.app/.../acpmux`) started, met the
//! held lock, exited 75 and was started again every ten seconds: 1311 runs on one Mac by
//! 2026-11-25, and a "daemon down" page for a home that was served all along.
//!
//! Such a start now waits instead: it holds nothing, never asks the holder to hand over (the
//! home stays the app's), and looks at the lock every [`STANDBY_LOOK`]. Once the holder is gone
//! it lets [`STANDBY_GRACE`] pass, so a handover's successor (the app's next daemon) takes the
//! home first, and only then tries the lock itself: launchd still supervises the home, as
//! `KeepAlive` meant, without one run per ten seconds.

use std::time::Duration;

/// How often a standing-by start looks at the lock: one read of the lock file each.
// timeout: not a deadline; the standby lasts as long as the holder does.
pub(super) const STANDBY_LOOK: Duration = Duration::from_secs(2);

/// How long a standing-by start leaves the home free after its holder went before trying the
/// lock, so the holder's own successor (an update or handover) takes it first.
// timeout: not a deadline; a handover's successor takes the lock within it.
pub(super) const STANDBY_GRACE: Duration = Duration::from_secs(30);

/// Whether a start that found its home held stands by: launchd started it directly (its parent
/// is pid 1) as one of acpmux's daemon jobs (`launchd_label`, launchd's `XPC_SERVICE_NAME`), and
/// it is no `--take-over` start (that one asks the holder to hand over). A start from a shell,
/// the app or `daemon start` keeps the prompt refusal (exit 75) its caller reads.
pub(super) fn stands_by(launchd_label: Option<&str>, parent_pid: u32, take_over: bool) -> bool {
    !take_over && parent_pid == 1 && launchd_label.is_some_and(is_daemon_job_label)
}

/// acpmux's own daemon job labels: `host setup`'s LaunchAgent and the per-home login-session
/// job (`login_placement::LABEL_PREFIX`), which a fleet Mac may also run as a LaunchDaemon.
fn is_daemon_job_label(label: &str) -> bool {
    label == crate::cli::daemon_service::LAUNCHD_LABEL
        || label.starts_with(super::login_placement::LABEL_PREFIX)
}

/// [`stands_by`] for this process. launchd runs only on macOS: elsewhere no start has a
/// launchd label, so none stands by.
pub(super) fn this_start_stands_by(take_over: bool) -> bool {
    #[cfg(target_os = "macos")]
    {
        // SAFETY: getppid has no preconditions.
        let parent = unsafe { libc::getppid() } as u32;
        stands_by(std::env::var("XPC_SERVICE_NAME").ok().as_deref(), parent, take_over)
    }
    #[cfg(not(target_os = "macos"))]
    {
        stands_by(None, 0, take_over)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_launchd_daemon_job_stands_by() {
        assert!(stands_by(Some("com.acpmux.daemon"), 1, false));
        assert!(stands_by(Some("com.cmux.acpmux.daemon.077f602dcb3c3936"), 1, false));
    }

    #[test]
    fn every_other_start_keeps_the_prompt_refusal() {
        // A take-over start asks the holder instead.
        assert!(!stands_by(Some("com.acpmux.daemon"), 1, true));
        // Not launchd's direct child: a shell, the app, `daemon start`.
        assert!(!stands_by(Some("com.acpmux.daemon"), 4242, false));
        // Terminal sets XPC_SERVICE_NAME=0; an app's children inherit its own label.
        assert!(!stands_by(Some("0"), 1, false));
        assert!(!stands_by(Some("application.com.cmuxterm.app.nightly.123"), 1, false));
        assert!(!stands_by(None, 1, false));
    }
}
