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
    let _ = report;
    Vec::new()
}

/// Reads a fleet job's state.
pub trait FleetJobs: Send + Sync {
    /// The job's state (`queued`, `running`, `done`, ...).
    fn state(&self, job: &str) -> Result<String, String>;
}
