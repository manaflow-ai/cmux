//! A cmux-tui daemon older than the Computer Use client (cmux#48044).
//!
//! An app update replaces the bundle on disk, and acpmux takes over from the
//! new bundle at once, but the app's own daemon keeps running the old build
//! until the app relaunches and hands it off (`DaemonVersionHandoff.swift`).
//! Until then every Computer Use call met "bad request: unknown variant
//! `computer-use-endpoint`": the old daemon has no such command, and the
//! protocol number (12 on both builds) does not show it.
//!
//! On a refused endpoint the client reads the daemon's `identify`. A daemon
//! without `computer-use-v1` whose own CLI (`cli_path`, the binary that
//! started it, now replaced by the update) reports a newer build is swapped
//! for that build in place with `cmux daemon restart`, the version-skew fix
//! the CLI already names (`cli/older_daemon.rs`): every terminal keeps
//! running, and the new daemon takes the old one's session and launch. It
//! runs at most once per daemon process, so a build that still lacks the
//! command cannot loop. Anything else keeps the refusal, with the reason.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;

use serde_json::Value;

/// The capability a daemon that serves `computer-use-endpoint` advertises.
pub const COMPUTER_USE_CAPABILITY: &str = "computer-use-v1";

/// What to do about a daemon that refused `computer-use-endpoint`.
#[derive(Debug, PartialEq, Eq)]
pub enum Verdict {
    /// It serves Computer Use: the refusal is its own answer.
    Current,
    /// It is older than the build installed at its own CLI path: restart it
    /// in place with that CLI.
    Restart { cli: PathBuf },
    /// It lacks Computer Use and no newer build is installed to swap in.
    NoNewerBuild(String),
}

/// The verdict for a daemon's `identify` (with `revisions`) and the
/// `--version --json` of the CLI it names (None: it named none, or the CLI
/// did not answer).
pub fn verdict(identity: &Value, installed: Option<&Value>) -> Verdict {
    let serves = identity["capabilities"]
        .as_array()
        .is_some_and(|caps| caps.iter().any(|cap| cap == COMPUTER_USE_CAPABILITY));
    if serves {
        return Verdict::Current;
    }
    let Some(cli) = identity["cli_path"].as_str().map(PathBuf::from).filter(|p| p.is_absolute())
    else {
        return Verdict::NoNewerBuild("the cmux daemon does not name its build's CLI".into());
    };
    let Some(installed) = installed else {
        return Verdict::NoNewerBuild("the cmux daemon's CLI did not report its build".into());
    };
    let installed_id = installed["build_identity"].as_str();
    if installed_id.is_some() && installed_id == identity["build_id"].as_str() {
        return Verdict::NoNewerBuild(
            "the cmux daemon already runs the installed build, which has no Computer Use".into(),
        );
    }
    let installed_time = installed["build_time"].as_u64().unwrap_or(0);
    // A daemon from before `identify` reported its time has no key: older.
    let older = match identity.get("build_time") {
        None => true,
        Some(time) => time.as_u64().is_some_and(|t| t > 0 && t < installed_time),
    };
    if older && installed_time > 0 {
        Verdict::Restart { cli }
    } else {
        Verdict::NoNewerBuild(
            "the cmux daemon lacks Computer Use and the installed cmux is not newer".into(),
        )
    }
}

/// Daemon processes this process already restarted: one restart each.
static RESTARTED: Mutex<Option<HashSet<u64>>> = Mutex::new(None);

/// True the first time for `pid`; a daemon with no pid is restarted once in all.
pub fn first_restart(pid: Option<u64>) -> bool {
    let Ok(mut restarted) = RESTARTED.lock() else { return false };
    restarted.get_or_insert_with(HashSet::new).insert(pid.unwrap_or(0))
}

/// `cli --version --json`, when it answers with JSON.
pub fn installed_build(cli: &Path) -> Option<Value> {
    let output = Command::new(cli).args(["--version", "--json"]).output().ok()?;
    if !output.status.success() {
        return None;
    }
    serde_json::from_slice(&output.stdout).ok()
}

/// `cli daemon restart --socket socket`: swaps the daemon there for `cli`'s
/// build and keeps its terminals. The command bounds its own stop and start.
pub fn restart_in_place(cli: &Path, socket: &Path) -> Result<(), String> {
    let output = Command::new(cli)
        .arg("daemon")
        .arg("restart")
        .arg("--socket")
        .arg(socket)
        .output()
        .map_err(|e| format!("could not run {}: {e}", cli.display()))?;
    if output.status.success() {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        Err(format!(
            "restarting the cmux daemon with the installed build failed ({}): {}",
            output.status,
            stderr.trim()
        ))
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn stale() -> Value {
        json!({
            "build_id": "2bd4478a3a04", "build_time": 1_794_859_912u64,
            "cli_path": "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux",
            "capabilities": ["daemon-build-v1"], "pid": 72464,
        })
    }

    fn installed(id: &str, time: u64) -> Value {
        json!({"build_identity": id, "build_time": time})
    }

    /// The reported case (#48044): the app's daemon kept running from before an update.
    #[test]
    fn an_older_daemon_restarts_with_its_updated_cli() {
        assert_eq!(
            verdict(&stale(), Some(&installed("221e5a18db61", 1_795_171_738))),
            Verdict::Restart {
                cli: PathBuf::from("/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux")
            }
        );
        // A daemon from before identify reported its time is older too.
        let mut untimed = stale();
        untimed.as_object_mut().unwrap().remove("build_time");
        assert!(matches!(
            verdict(&untimed, Some(&installed("221e5a18db61", 1_795_171_738))),
            Verdict::Restart { .. }
        ));
    }

    #[test]
    fn a_daemon_that_serves_computer_use_keeps_its_refusal() {
        let mut current = stale();
        current["capabilities"] = json!(["daemon-build-v1", COMPUTER_USE_CAPABILITY]);
        assert_eq!(verdict(&current, Some(&installed("x", u64::MAX))), Verdict::Current);
    }

    #[test]
    fn nothing_newer_installed_is_never_a_restart() {
        // The same build is installed: a restart would start it again.
        assert!(matches!(
            verdict(&stale(), Some(&installed("2bd4478a3a04", 1_795_171_738))),
            Verdict::NoNewerBuild(_)
        ));
        // An older or untimed install, a CLI that did not answer, no CLI path.
        assert!(matches!(
            verdict(&stale(), Some(&installed("old", 1_700_000_000))),
            Verdict::NoNewerBuild(_)
        ));
        assert!(matches!(
            verdict(&stale(), Some(&json!({"build_identity": "new"}))),
            Verdict::NoNewerBuild(_)
        ));
        assert!(matches!(verdict(&stale(), None), Verdict::NoNewerBuild(_)));
        let mut relative = stale();
        relative["cli_path"] = json!("bin/cmux");
        assert!(matches!(
            verdict(&relative, Some(&installed("new", u64::MAX))),
            Verdict::NoNewerBuild(_)
        ));
        // A daemon whose time is unknown (null) orders nothing.
        let mut null_time = stale();
        null_time["build_time"] = Value::Null;
        assert!(matches!(
            verdict(&null_time, Some(&installed("new", u64::MAX))),
            Verdict::NoNewerBuild(_)
        ));
    }

    #[test]
    fn each_daemon_is_restarted_once() {
        assert!(first_restart(Some(990_001)));
        assert!(!first_restart(Some(990_001)));
        assert!(first_restart(Some(990_002)));
    }
}
