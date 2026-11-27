//! "Restarting for an update, a successor is expected": a durable marker in the acpmux home.
//!
//! A daemon follows its owner app (`owner_exit.rs`) and stops 2 s after the app is gone when
//! nothing keeps it. An update quits the app and opens the new one: the bundle swap, the launch and
//! the window restore take longer than 2 s, so the daemon of idle chats stopped in between and the
//! new app's chats came up on "The agent service stopped" (Leo, after every update). The quit that
//! knows a relaunch follows (the app's update quit, `tools/nightly-update`, `acpmux daemon
//! expect-relaunch`) writes this marker first; while it holds, the owner's exit waits up to the
//! marker's deadline instead of 2 s, and the relaunched app is adopted as the owner when it connects
//! (`owner_exit::adopt_if_relaunched`), which clears it. A successor daemon (an executable swap)
//! reads the same file, so the marker outlives the daemon that saw it written. A marker past its
//! deadline is ignored: a relaunch that never came stops the daemon as a quit would.

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// The marker's file in the acpmux home.
pub(crate) const FILE: &str = "owner-relaunch.json";

/// How long a relaunch is waited for when the writer names no time.
pub(crate) const DEFAULT_WITHIN: Duration = Duration::from_secs(60);

/// The longest wait a marker can ask: a stale or hostile marker cannot keep an unused daemon.
pub(crate) const MAX_WITHIN: Duration = Duration::from_secs(300);

/// The marker in `home`.
pub(crate) fn path_in(home: &Path) -> PathBuf {
    home.join(FILE)
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

/// Writes the marker in `home`: a relaunch is expected within `within` (capped at
/// [`MAX_WITHIN`]). Atomic: a reader sees the old marker or the new one.
pub(crate) fn expect_in(home: &Path, within: Duration, reason: &str) -> std::io::Result<()> {
    let within = within.min(MAX_WITHIN);
    let body = serde_json::json!({
        "untilMs": now_ms().saturating_add(within.as_millis() as u64),
        "reason": reason,
        "pid": std::process::id(),
    });
    std::fs::create_dir_all(home)?;
    let path = path_in(home);
    let tmp = home.join(format!(".{FILE}.{}.tmp", std::process::id()));
    std::fs::write(&tmp, body.to_string())?;
    std::fs::rename(&tmp, &path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}

/// How long the marker in `home` still asks to wait, with its reason; None without one, when it
/// does not parse, or once its deadline passed.
pub(crate) fn left_in(home: &Path) -> Option<(Duration, String)> {
    let raw = std::fs::read_to_string(path_in(home)).ok()?;
    let value: serde_json::Value = serde_json::from_str(&raw).ok()?;
    let until = value.get("untilMs")?.as_u64()?;
    let left = Duration::from_millis(until.checked_sub(now_ms())?).min(MAX_WITHIN);
    let reason = value.get("reason").and_then(|r| r.as_str()).unwrap_or("a relaunch").to_owned();
    (!left.is_zero()).then_some((left, reason))
}

/// Removes the marker in `home`, if any.
pub(crate) fn clear_in(home: &Path) {
    match std::fs::remove_file(path_in(home)) {
        Ok(()) => tracing::info!("the relaunch marker is cleared"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => tracing::warn!(%error, "cannot clear the relaunch marker"),
    }
}

/// [`left_in`] for this daemon's home.
pub(crate) fn left() -> Option<(Duration, String)> {
    left_in(&crate::config::home())
}

/// The relaunched owner arrived: the marker has done its work.
pub(crate) fn arrived() {
    clear_in(&crate::config::home());
}

#[cfg(test)]
#[path = "owner_relaunch_tests.rs"]
mod tests;
