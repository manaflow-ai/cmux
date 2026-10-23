//! Cloud subagents wait on Mac-mini fleet jobs paused (cloud-subagents-DESIGN.md
//! v2, "Lifecycle"): a subagent that would wait on a long `cmux-ci` job ends its
//! turn with a `fleet-wait: JOB` line instead; its VM pauses, the host polls
//! the fleet controller, and when the job ends it resumes the VM and tells the
//! subagent the result.

/// What a cloud subagent's first message says about fleet waits.
pub const NOTE: &str = "Waiting on a fleet job: never block on `cmux-ci wait` for a job that runs longer than a minute. Submit it, then end your turn with a line `fleet-wait: JOB_ID` (one line per job) and nothing else to do: your VM pauses while the job runs, and the Chief host wakes you with `fleet job JOB_ID finished: STATE` when it ends. Then read its result (`cmux-ci status JOB_ID`, `cmux-ci log JOB_ID`) and go on.";

/// The final states of a fleet job or step (cmuxterm-hq build-fleet
/// `STEP_TERMINAL`).
pub const FINAL: [&str; 3] = ["done", "failed", "cancelled"];

/// The fleet job ids a report waits on: its `fleet-wait: ID` lines (ids are
/// 24 lowercase hex characters).
pub fn waits(report: &str) -> Vec<String> {
    report
        .lines()
        .filter_map(|l| l.trim().strip_prefix("fleet-wait:"))
        .map(str::trim)
        .filter(|id| id.len() == 24 && id.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')))
        .map(str::to_owned)
        .collect()
}

/// Reads a fleet job's state.
pub trait FleetJobs: Send + Sync {
    /// The job's state (`queued`, `running`, `done`, ...).
    fn state(&self, job: &str) -> Result<String, String>;
}

/// The fleet client on this Mac: `cmux-ci status JOB` (`~/.local/bin/cmux-ci`
/// when it is there, else `cmux-ci` on PATH).
pub struct CommandFleet {
    pub cmd: std::path::PathBuf,
}

impl CommandFleet {
    pub fn in_home(home: &std::path::Path) -> CommandFleet {
        let local = home.join(".local/bin/cmux-ci");
        CommandFleet {
            cmd: if local.exists() {
                local
            } else {
                "cmux-ci".into()
            },
        }
    }
}

impl FleetJobs for CommandFleet {
    fn state(&self, job: &str) -> Result<String, String> {
        let out = std::process::Command::new(&self.cmd)
            .args(["status", job])
            .stdin(std::process::Stdio::null())
            .output()
            .map_err(|e| format!("cmux-ci status {job}: {e}"))?;
        if !out.status.success() {
            return Err(format!(
                "cmux-ci status {job}: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
        let v: serde_json::Value = serde_json::from_slice(&out.stdout)
            .map_err(|e| format!("cmux-ci status {job}: {e}"))?;
        v["state"]
            .as_str()
            .map(str::to_owned)
            .ok_or_else(|| format!("cmux-ci status {job}: no state"))
    }
}
