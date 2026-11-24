//! A take-over start that finds this home already served by its own build yields instead of asking
//! that daemon to hand over (`acquire_daemon_lock`).
//!
//! An update starts two take-over daemons at once: the replaced daemon's own swap
//! (`exe_swap.rs`) and the installer's. Both wait on the old daemon's lock; one wins and serves,
//! and the other used to look at the new holder, see a pid it had not asked yet, and ask it to hand
//! over too. Every chat then went dark a second time for a daemon that ran the same build.
//! Leo's NIGHTLY, 2026-11-22 21:38Z: the update's handover took 11.5 s, then the second start asked
//! the new daemon (ready for 0.7 s) to hand over and the socket was dark 7.3 s more, 20 s in all,
//! with the pane on "Reconnecting…" and then "Waiting for the agent service" (Leo, 2026-11-22
//! 22:3xZ: "you guys shouldn't be showing that message/shouldn't have that issue in the first
//! place"). A holder that started after this start began waiting, on this start's build, is the
//! successor this start would have been: there is nothing left to hand over.
//!
//! No I/O, no clock: the caller reads the holder's `_acpmux/status` and the time it began waiting.

use serde_json::Value;

/// The build id a daemon without a stamp reports (`build_info.rs`): two such daemons may be
/// different code, so one never yields to another.
const UNSTAMPED: &str = "unstamped";

/// Whether the daemon whose `_acpmux/status` is `status` already serves what a take-over start of
/// `build`, waiting since `since_ms` (`store::now_ms` time), would serve: it runs this start's
/// build and its hub started at or after the start began waiting (so it is a successor of the
/// same update, never the daemon this start was started to replace).
pub(super) fn serves_this_start(status: &Value, build: &str, since_ms: u64) -> bool {
    build != UNSTAMPED
        && status.get("build").and_then(Value::as_str) == Some(build)
        && status.get("startedAt").and_then(Value::as_u64).is_some_and(|at| at >= since_ms)
}

/// The readiness line a yielding start writes for its launcher: the daemon that serves the home,
/// as `handover::wait` reports a winner.
pub(super) fn ready_line(status: &Value) -> Value {
    serde_json::json!({
        "ready": true,
        "lockHeld": true,
        "pid": field(status, "pid"),
        "socket": field(status, "socket"),
        "listen": field(status, "listen"),
        "webUrl": field(status, "webUrl"),
    })
}

/// `value[key]` without the panicking index: a missing key reads as null.
fn field<'a>(value: &'a Value, key: &str) -> &'a Value {
    value.get(key).unwrap_or(&Value::Null)
}

/// A take-over start yielded: `ready` names the daemon of its own build that serves the home.
#[derive(Debug)]
pub(super) struct ServedByThisBuild {
    pub ready: Value,
}

impl std::fmt::Display for ServedByThisBuild {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "daemon {} of this build already serves this home", field(&self.ready, "pid"))
    }
}

impl std::error::Error for ServedByThisBuild {}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const BUILD: &str = "abc1234-20261122";

    #[test]
    fn a_successor_of_this_build_that_started_after_the_wait_serves_this_start() {
        // 21:38Z: 12396 took the lock at :43 on the new build; the swap's start waited from :31.
        let status = json!({"pid": 12396, "build": BUILD, "startedAt": 2_000});
        assert!(serves_this_start(&status, BUILD, 1_000));
        assert!(serves_this_start(&status, BUILD, 2_000));
    }

    #[test]
    fn the_daemon_this_start_replaces_is_asked() {
        // The old build: the update this start exists for.
        let old = json!({"pid": 8581, "build": "fff0000-20261121", "startedAt": 2_000});
        assert!(!serves_this_start(&old, BUILD, 1_000));
        // The same build, started before this start waited (a daemon a heal or rollback restarts
        // from a backup bundle, or a detached start this one was asked to replace).
        let earlier = json!({"pid": 8581, "build": BUILD, "startedAt": 999});
        assert!(!serves_this_start(&earlier, BUILD, 1_000));
    }

    #[test]
    fn unstamped_or_unreadable_holders_are_asked() {
        let unstamped = json!({"build": UNSTAMPED, "startedAt": 2_000});
        assert!(!serves_this_start(&unstamped, UNSTAMPED, 1_000));
        assert!(!serves_this_start(&json!({"build": BUILD}), BUILD, 1_000));
        assert!(!serves_this_start(&json!({"startedAt": 2_000}), BUILD, 1_000));
        assert!(!serves_this_start(&json!({"build": BUILD, "startedAt": "2000"}), BUILD, 1_000));
    }

    #[test]
    fn the_ready_line_names_the_serving_daemon() {
        let status =
            json!({"pid": 7, "socket": "/s", "listen": "127.0.0.1:1", "webUrl": "http://x"});
        let ready = ready_line(&status);
        assert_eq!(ready["ready"], true);
        assert_eq!(ready["lockHeld"], true);
        assert_eq!(ready["pid"], 7);
        assert_eq!(ready["socket"], "/s");
    }
}
