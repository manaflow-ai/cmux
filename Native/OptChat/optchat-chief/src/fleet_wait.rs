//! Cloud subagents wait on Mac-mini fleet jobs paused (cloud-subagents-DESIGN.md
//! v2, "Lifecycle"): a subagent that would wait on a long `cmux-ci` job ends its
//! turn with a `fleet-wait: JOB` line instead; its VM pauses, the host polls
//! the fleet controller, and when the job ends it resumes the VM and tells the
//! subagent the result.

/// What a cloud subagent's first message says about fleet waits.
pub const NOTE: &str = "Waiting on a fleet job: never block on `cmux-ci wait` for a job that runs longer than a minute. Submit it, then end your turn with a line `fleet-wait: JOB_ID` (one line per job) and nothing else to do: your VM pauses while the job runs, and the Chief host wakes you with `fleet job JOB_ID finished: STATE` when it ends. Then read its result (`cmux-ci status JOB_ID`, `cmux-ci log JOB_ID`) and go on.";

/// Whether this host has the fleet client (`cmux-ci`, which [`CommandFleet`] polls
/// fleet-wait jobs with): only then does a cloud subagent's first message carry
/// [`NOTE`], so a person without the fleet gets no fleet instructions (Leo,
/// 2026-11-26: "identify all the weird opinoinated fleet things we shipped into the
/// app and remove them").
pub fn client_here() -> bool {
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    let path = std::env::var_os("PATH");
    client_in(home.as_deref(), path.as_deref())
}

/// Whether `cmux-ci` is in `home`/.local/bin or on `path`.
pub fn client_in(home: Option<&std::path::Path>, path: Option<&std::ffi::OsStr>) -> bool {
    home.is_some_and(|h| h.join(".local/bin/cmux-ci").is_file())
        || path.is_some_and(|p| std::env::split_paths(p).any(|d| d.join("cmux-ci").is_file()))
}

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
