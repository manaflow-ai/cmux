//! `acpmux host self-update --fast-patch [--commit SHA]`: RFD 0060's
//! fast-patch contract for the acpmux daemon. The self-update timer waits up
//! to 15 minutes for its next run and then up to an hour for the restart
//! window (merge to live p50 5,337 s); a fast-patch run skips both: it reads
//! the channel now, takes its build (a commit on the channel's branch, never
//! a lane's), downloads and checks it into `update/<sha256>/` beside the
//! installed one, and hands over with the update's own restart (the daemon has
//! no socket hand-over yet; the restart's gap is about 0.86 s, agents kept).
//! The update's health read waits until the daemon answers on the new build,
//! with its deadline, and rolls back to `acpmux.prev` and restarts again when
//! it does not. Each run appends one line to the fast-patch runs file
//! (`$FAST_PATCH_STATE`, else `~/.local/state/fast-patch`, `runs.jsonl`), the
//! shape leo-workspace's `tools/fast-patch` writes, so NOW counts this
//! service's `live` runs beside the others'.

use super::{Outcome, PeerUpdate, build_commit, embedded_build};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::Instant;

/// The service name a line carries.
pub(crate) const SERVICE: &str = "acpmux-daemon";
/// The repository the channel's builds come from.
const REPO: &str = "manaflow-ai/cmux";
const RUNS: &str = "runs.jsonl";

/// One fast-patch run, from its start to its line.
pub(crate) struct Run {
    at: String,
    started: Instant,
    /// The commit asked for (`--commit`), when one was.
    asked: Option<String>,
    /// The installed build's commit before the run.
    prev: Option<String>,
    /// The channel's commit, once it is read.
    commit: Option<String>,
    state: PathBuf,
}

impl Run {
    /// Starts a run: the time, and the commit of the binary at `installed`.
    pub(crate) fn start(asked: Option<String>, installed: &Path) -> Run {
        let prev = std::fs::read(installed)
            .ok()
            .and_then(|bytes| embedded_build(&bytes))
            .and_then(|build| build_commit(&build).map(str::to_owned));
        Run {
            at: chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
            started: Instant::now(),
            asked,
            prev,
            commit: None,
            state: state_dir(),
        }
    }

    /// The channel names `commit`. A run that asked for another commit is
    /// refused: only the channel's build of a commit is published, so an
    /// older or newer one cannot be installed by this host now.
    pub(crate) fn check_commit(&mut self, commit: &str) -> Result<(), String> {
        self.commit = Some(commit.to_owned());
        match self.asked.as_deref() {
            Some(asked) if !same_commit(asked, commit) => Err(format!(
                "the channel's build is of commit {commit}, not {asked}: its build is not published yet (or a newer one replaced it); run again once the channel names it"
            )),
            _ => Ok(()),
        }
    }

    /// Appends the run's line and returns it.
    pub(crate) fn finish(self, outcome: &str, detail: &str) -> Value {
        let line = self.line(outcome, detail);
        if let Err(e) = append(&self.state, &line) {
            eprintln!("acpmux: fast-patch: writing its line to {}: {e}", self.state.display());
        }
        line
    }

    fn line(&self, outcome: &str, detail: &str) -> Value {
        json!({
            "at": self.at,
            "host": crate::hand::pair::hostname(),
            "service": SERVICE,
            "repo": REPO,
            "asked": self.asked.as_deref().unwrap_or("main"),
            "commit": self.commit,
            "prev": self.prev,
            "outcome": outcome,
            "seconds": (self.started.elapsed().as_secs_f64() * 100.0).round() / 100.0,
            "detail": detail,
            "swap": "restart",
        })
    }
}

/// A full or abbreviated hash names the same commit.
fn same_commit(a: &str, b: &str) -> bool {
    let (a, b) = (a.to_ascii_lowercase(), b.to_ascii_lowercase());
    a.len() >= 7 && b.len() >= 7 && (a.starts_with(&b) || b.starts_with(&a))
}

/// `$FAST_PATCH_STATE`, else `~/.local/state/fast-patch`.
fn state_dir() -> PathBuf {
    match std::env::var_os("FAST_PATCH_STATE").filter(|v| !v.is_empty()) {
        Some(dir) => PathBuf::from(dir),
        None => dirs::home_dir().unwrap_or_default().join(".local/state/fast-patch"),
    }
}

fn append(state: &Path, line: &Value) -> std::io::Result<()> {
    use std::io::Write;
    crate::home_fs::create_dir_all(state, 0o700)?;
    let mut file =
        crate::home_fs::OpenOptions::new().create(true).append(true).open(state.join(RUNS))?;
    // One write per line, so concurrent runs of other services never interleave.
    file.write_all(format!("{line}\n").as_bytes())
}

/// The run's outcome for the update's row: `live` (the daemon answers on the
/// new build), `current` (it already ran it: nothing went live, so NOW does
/// not count it), `rolled-back` (it did not come back on it and runs the
/// previous build again), `rollback-unhealthy` (the rollback failed too), or
/// `refused` (nothing changed: busy, held, no binary, a restart refused before
/// it stopped anything).
pub(crate) fn outcome(up: &PeerUpdate) -> &'static str {
    match up.outcome {
        Outcome::Updated => "live",
        Outcome::Current => "current",
        Outcome::RolledBack => "rolled-back",
        Outcome::Failed if rollback_failed(up.error.as_deref().unwrap_or("")) => {
            "rollback-unhealthy"
        }
        Outcome::Failed | Outcome::Busy | Outcome::NeedsBinary | Outcome::Held => "refused",
    }
}

/// The update's error says the rollback did not bring the previous build
/// back (`update_peer`'s texts).
fn rollback_failed(error: &str) -> bool {
    error.contains("the rollback failed too")
        || error.contains("the rollback stopped nothing")
        || error.contains("cannot move it back")
}

/// The line's detail for the update's row.
pub(crate) fn detail(up: &PeerUpdate) -> String {
    let mut parts = vec![up.outcome.as_str().to_owned()];
    if let Some(build) = &up.build {
        parts.push(format!("daemon on {build}"));
    }
    if let Some(reason) = &up.reason {
        parts.push(reason.clone());
    }
    if let Some(error) = &up.error {
        parts.push(error.clone());
    }
    parts.join("; ")
}

#[cfg(test)]
#[path = "host_self_update_fast_patch_tests.rs"]
mod tests;
