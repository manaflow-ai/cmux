//! The failed GitHub Actions runs a `ci_red` automation waits for
//! (automations.rs): `gh run list --status failure` with the person's own
//! `gh` login. GitHub pushes nothing to this Mac, so the brain reads them
//! every [`CI_EVERY`], off its thread, and only while an active `ci_red`
//! automation exists (brain/automations.rs).

use std::path::PathBuf;
use std::time::Duration;

use serde_json::Value;

use crate::automations::CiRun;

/// How often the brain reads the failed runs of each watched repository.
pub const CI_EVERY: Duration = Duration::from_secs(120);
/// Failed runs read per repository and read.
pub const CI_RUNS_READ: u32 = 20;

/// Reads a repository's failed CI runs, newest first.
pub trait CiRuns: Send + Sync {
    fn failed(&self, repo: &str, branch: Option<&str>) -> Result<Vec<CiRun>, String>;
}

/// The `gh` CLI on this Mac.
pub struct GhRuns {
    pub cmd: PathBuf,
}

impl GhRuns {
    /// `gh` on PATH, else where Homebrew puts it (an app-started host has a
    /// short PATH).
    pub fn find() -> GhRuns {
        let cmd = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            .into_iter()
            .map(PathBuf::from)
            .find(|p| p.exists())
            .unwrap_or_else(|| "gh".into());
        let on_path = std::env::var_os("PATH").is_some_and(|path| {
            std::env::split_paths(&path).any(|dir| dir.join("gh").is_file())
        });
        GhRuns {
            cmd: if on_path { "gh".into() } else { cmd },
        }
    }
}

impl CiRuns for GhRuns {
    fn failed(&self, repo: &str, branch: Option<&str>) -> Result<Vec<CiRun>, String> {
        // automations.rs checked repo and branch: neither reads as a flag.
        let limit = CI_RUNS_READ.to_string();
        let mut args = vec![
            "run",
            "list",
            "--repo",
            repo,
            "--status",
            "failure",
            "--limit",
            &limit,
            "--json",
            "databaseId,workflowName,displayTitle,headBranch,url,createdAt",
        ];
        if let Some(branch) = branch {
            args.extend(["--branch", branch]);
        }
        let out = std::process::Command::new(&self.cmd)
            .args(&args)
            .stdin(std::process::Stdio::null())
            .output()
            .map_err(|e| format!("gh run list: {e}"))?;
        if !out.status.success() {
            let err = String::from_utf8_lossy(&out.stderr);
            return Err(format!(
                "gh run list --repo {repo}: {}",
                err.lines().next().unwrap_or("failed").trim()
            ));
        }
        parse_runs(&out.stdout)
    }
}

/// `gh run list --json ...`'s answer as runs; entries it cannot read are
/// skipped.
pub fn parse_runs(json: &[u8]) -> Result<Vec<CiRun>, String> {
    let v: Value = serde_json::from_slice(json).map_err(|e| format!("gh run list: {e}"))?;
    let Value::Array(items) = v else {
        return Err("gh run list: not a list".into());
    };
    let text = |item: &Value, key: &str| item[key].as_str().unwrap_or_default().to_owned();
    Ok(items
        .iter()
        .filter_map(|item| {
            let id = item["databaseId"].as_u64()?;
            let created_ms = chrono::DateTime::parse_from_rfc3339(item["createdAt"].as_str()?)
                .ok()?
                .timestamp_millis();
            Some(CiRun {
                id,
                workflow: text(item, "workflowName"),
                title: text(item, "displayTitle"),
                branch: text(item, "headBranch"),
                url: text(item, "url"),
                created_ms: u64::try_from(created_ms).ok()?,
            })
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_gh_run_list_json() {
        let json = br#"[
          {"databaseId": 42, "workflowName": "CI", "displayTitle": "fix the build", "headBranch": "main",
           "url": "https://github.com/o/r/actions/runs/42", "createdAt": "2026-10-26T09:00:00Z"},
          {"workflowName": "no id"}
        ]"#;
        let runs = parse_runs(json).unwrap();
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].id, 42);
        assert_eq!(runs[0].branch, "main");
        assert_eq!(runs[0].created_ms, 1_793_005_200_000);
        assert!(parse_runs(b"{}").is_err());
    }
}
