//! Reads repository facts from the cmux session host's git operations
//! through the bundled cmux CLI (`cmux git status --json`).
//!
//! The sidecar must not grow a second git implementation for branch
//! semantics (plans/cmux-next/diff-host.md, Q1). Until the daemon's git code
//! is a linkable crate (`cmux-git`), the sidecar asks the daemon through its
//! CLI, which talks to the app's session. `git.status` reports `base`, the
//! daemon's base branch: origin's default branch, else origin/main,
//! origin/master, main or master.

use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use serde::Deserialize;
use tokio::io::AsyncReadExt;
use tokio::process::Command;

/// `git.status` replies are a few hundred bytes; anything larger is not one.
const MAX_STATUS_BYTES: u64 = 64 * 1024;

/// The fields of a `git.status` result the sidecar reads.
#[derive(Debug, Deserialize)]
pub(crate) struct RepositoryStatus {
    /// The daemon's base branch, as a short ref (`origin/main`, `main`).
    #[serde(default)]
    pub base: Option<String>,
}

/// Runs `<cmux> git status --path <repo> --json` and parses the result.
/// Returns `None` when the CLI fails, the session host is unreachable, the
/// deadline passes, or the reply is not a `git.status` result.
pub(crate) async fn repository_status(
    cmux: &Path,
    repo: &Path,
    deadline: Duration,
) -> Option<RepositoryStatus> {
    let mut child = Command::new(cmux)
        .arg("git")
        .arg("status")
        .arg("--path")
        .arg(repo)
        .arg("--json")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .ok()?;
    let stdout = child.stdout.take()?;
    let read = async {
        let mut bytes = Vec::new();
        stdout
            .take(MAX_STATUS_BYTES + 1)
            .read_to_end(&mut bytes)
            .await
            .ok()?;
        let status = child.wait().await.ok()?;
        Some((status, bytes))
    };
    let (status, bytes) = tokio::time::timeout(deadline, read).await.ok()??;
    if !status.success() || bytes.len() as u64 > MAX_STATUS_BYTES {
        return None;
    }
    serde_json::from_slice(&bytes).ok()
}

#[cfg(test)]
mod tests {
    use super::RepositoryStatus;

    #[test]
    fn parses_the_git_status_result_shape() {
        let status: RepositoryStatus = serde_json::from_str(
            r#"{"root":"/r","detached":false,"ahead":0,"behind":0,"branch":"feature","head":"abc","base":"origin/main"}"#,
        )
        .expect("git.status result");
        assert_eq!(status.base.as_deref(), Some("origin/main"));

        let detached: RepositoryStatus =
            serde_json::from_str(r#"{"root":"/r","detached":true,"ahead":0,"behind":0}"#)
                .expect("detached git.status result");
        assert!(detached.base.is_none());
    }
}
