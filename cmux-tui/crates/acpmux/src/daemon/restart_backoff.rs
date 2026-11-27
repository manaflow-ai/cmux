//! systemd's restart delay for the daemon's unit grows from `RestartSec=3` to
//! `RestartMaxDelaySec=60` over `RestartSteps=5` (`cli/hosts.rs` `SYSTEMD_UNIT`), counted by the
//! unit's restart counter, which systemd never lowers while the service runs. A machine whose
//! daemon died twice that day waited about 10 s for the third start (a carrier fault run,
//! 2026-11-22: "Scheduled restart job, restart counter is at 3" 10.0 s after the kill), and
//! one that died five times waited 60 s for every later one, however long it ran between.
//!
//! A daemon that has served for [`STEADY`] resets its own unit's counter
//! (`systemctl --user reset-failed UNIT`, which zeroes it on a running unit), so the next
//! death of a daemon that ran is restarted after the base 3 s. A crash loop (each daemon
//! dying before [`STEADY`]) never resets it and still backs off to 60 s.

use std::time::Duration;

/// How long a daemon serves before its death counts as a new one rather than part of a loop.
/// Shorter than two faults a minute apart (a carrier fault run, 2026-11-23: with 60 s the counter
/// was still at 3, and systemd waited 10.1 s to restart); a daemon that dies after it is restarted
/// every `RestartSec` + 15 s at most, which is no hot loop.
pub(crate) const STEADY: Duration = Duration::from_secs(15);

// timeout: cleanup for a wedged systemctl; nothing waits on the reset.
const RESET_BUDGET: Duration = Duration::from_secs(5);

/// The systemd unit this process runs in, from `/proc/self/cgroup` (cgroup v2's `0::PATH`, whose
/// last part is the unit): only an acpmux service unit, never a session scope or another unit.
pub(crate) fn own_unit(cgroup: &str) -> Option<String> {
    let path = cgroup.lines().find_map(|l| l.strip_prefix("0::"))?;
    let unit = path.trim().rsplit('/').next()?;
    (unit.starts_with("acpmux") && unit.ends_with(".service")).then(|| unit.to_string())
}

/// Starts the reset: once this daemon has served for [`STEADY`], under its systemd unit only
/// (systemd set `INVOCATION_ID`; a daemon a client started has no unit counter to reset).
pub(crate) fn start(scope: &cmux_scope::Scope) {
    if std::env::var_os("INVOCATION_ID").is_none() {
        return;
    }
    let Some(unit) =
        std::fs::read_to_string("/proc/self/cgroup").ok().as_deref().and_then(own_unit)
    else {
        return;
    };
    scope.spawn_until_cancelled("restart-backoff-reset", async move {
        tokio::time::sleep(STEADY).await;
        let reset = tokio::process::Command::new("systemctl")
            .args(["--user", "reset-failed", &unit])
            .kill_on_drop(true)
            .output();
        match tokio::time::timeout(RESET_BUDGET, reset).await {
            Ok(Ok(out)) if out.status.success() => tracing::info!(
                unit,
                "served {}s: reset the unit's restart delay to its base",
                STEADY.as_secs()
            ),
            Ok(Ok(out)) => tracing::warn!(
                unit,
                stderr = %String::from_utf8_lossy(&out.stderr).trim(),
                "could not reset the unit's restart delay"
            ),
            Ok(Err(error)) => {
                tracing::warn!(unit, %error, "could not reset the unit's restart delay")
            }
            Err(_) => tracing::warn!(
                unit,
                "could not reset the unit's restart delay: systemctl did not answer in {}s",
                RESET_BUDGET.as_secs()
            ),
        }
    });
}

#[cfg(test)]
#[path = "restart_backoff_tests.rs"]
mod tests;
