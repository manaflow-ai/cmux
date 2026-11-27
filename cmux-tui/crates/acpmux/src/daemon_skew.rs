//! A cmux-tui daemon older than the acpmux that calls it (cmux#48044).
//!
//! An app update replaces the bundle on disk, and acpmux takes over from the
//! new bundle at once, but the app's own daemon keeps running the old build
//! until the app relaunches and hands it off (`DaemonVersionHandoff.swift`).
//! Until then every command newer than that build met "bad request: unknown
//! variant `...`": first `computer-use-endpoint`, and the next new command
//! the same way. The protocol number (12 on both builds) does not show it.
//!
//! So every raw request acpmux sends the daemon goes through [`request`]. On
//! an "unknown variant" refusal it reads the daemon's `identify`; a daemon
//! whose own CLI (`cli_path`, the binary that started it, now replaced by the
//! update) reports a newer build is swapped for that build in place with
//! `cmux daemon restart`, the version-skew fix the CLI already names
//! (`cli/older_daemon.rs`): every terminal keeps running, and the new daemon
//! takes the old one's session and launch. Then the request is sent again.
//! It runs at most once per daemon process, so a build that still lacks the
//! command cannot loop. Any other refusal is returned as it came, and one no
//! restart can fix carries the reason.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;

use serde_json::{Value, json};

use crate::computer_use::client::DaemonError;

/// The daemon command that names its build (with `revisions`).
pub const IDENTIFY: &str = "identify";

/// A cmux-tui daemon reached by raw `{"cmd": ...}` requests.
pub trait RawDaemon {
    /// One request as sent, with no restart.
    fn send_once(&self, cmd: &str, params: Value) -> Result<Value, DaemonError>;
    /// `cli --version --json`, when it answers with JSON.
    fn installed_build(&self, cli: &Path) -> Option<Value> {
        installed_build(cli)
    }
    /// Swap this daemon for `cli`'s build, keeping its terminals.
    fn restart_in_place(&self, cli: &Path) -> Result<(), String>;
}

/// `cmd` on `daemon`. A daemon too old to know it is restarted once with
/// the installed build, then asked again.
pub fn request(daemon: &impl RawDaemon, cmd: &str, params: Value) -> Result<Value, DaemonError> {
    let first = daemon.send_once(cmd, params.clone());
    let Err(DaemonError::Refused { code, message }) = &first else { return first };
    if cmd == IDENTIFY || !unknown_command(message) {
        return first;
    }
    match update(daemon) {
        Ok(()) => daemon.send_once(cmd, params),
        Err(why) => {
            Err(DaemonError::Refused { code: code.clone(), message: format!("{message}. {why}") })
        }
    }
}

/// A refusal that says the daemon's build has no such command (or value).
pub fn unknown_command(message: &str) -> bool {
    message.contains("unknown variant")
}

/// Restart `daemon` with the installed build, or why that cannot help.
fn update(daemon: &impl RawDaemon) -> Result<(), String> {
    let identity =
        daemon.send_once(IDENTIFY, json!({"revisions": true})).map_err(|e| e.to_string())?;
    let installed = identity
        .get("cli_path")
        .and_then(Value::as_str)
        .and_then(|cli| daemon.installed_build(Path::new(cli)));
    match verdict(&identity, installed.as_ref()) {
        Verdict::NoNewerBuild(why) => Err(why),
        Verdict::Restart { cli } => {
            if !first_restart(identity.get("pid").and_then(Value::as_u64)) {
                return Err("the cmux daemon still refuses it after a restart".into());
            }
            daemon.restart_in_place(&cli)
        }
    }
}

/// What to do about a daemon that refused a command it does not know.
#[derive(Debug, PartialEq, Eq)]
pub enum Verdict {
    /// It is older than the build installed at its own CLI path: restart it
    /// in place with that CLI.
    Restart { cli: PathBuf },
    /// No newer build is installed to swap in.
    NoNewerBuild(String),
}

/// The verdict for a daemon's `identify` (with `revisions`) and the
/// `--version --json` of the CLI it names (None: it named none, or the CLI
/// did not answer).
pub fn verdict(identity: &Value, installed: Option<&Value>) -> Verdict {
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
            "the cmux daemon already runs the installed build, which does not have it".into(),
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
        Verdict::NoNewerBuild("the installed cmux is not newer than its daemon".into())
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
#[path = "daemon_skew_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "daemon_skew_lint_tests.rs"]
mod lint_tests;
