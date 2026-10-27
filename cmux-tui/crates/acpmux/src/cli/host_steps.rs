//! The step contract shared by `host enroll`, `host doctor` and the app's
//! Add Machine sheet (plans/cmux-next/add-machine-DESIGN.md): each step
//! is one JSON line `{"step","state","detail","fix"}`, plus `"reason"` for
//! a failure the app acts on.

use serde::Serialize;
use serde_json::{Value, json};

/// The steps, in the order they run.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Step {
    Reach,
    Install,
    Daemon,
    Harness,
    Peer,
    PeerBack,
    Identity,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum StepState {
    /// The check passed with nothing to do.
    Ok,
    /// The check failed and `--fix` (or enroll) repaired it.
    Fixed,
    /// The check failed; `fix` says what a person can do.
    Fail,
    /// Works from this side but not fully (a host that cannot ssh back).
    Warn,
    /// Not run: an earlier step it depends on failed, or it was not asked for.
    Skip,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct StepResult {
    pub step: Step,
    pub state: StepState,
    pub detail: String,
    /// A sentence for a person; never a command acpmux runs for them.
    pub fix: Option<String>,
    /// Why it failed, for a failure the app acts on itself; a stable word
    /// ([`REASON_WRONG_PLATFORM`], [`REASON_NOT_THIS_PROGRAM`]).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<&'static str>,
    /// Machine-readable recovery advice for callers and scripts.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

/// `install`: this build is for another OS or CPU than the host's, so the
/// app installs the right one (its own install path).
pub const REASON_WRONG_PLATFORM: &str = "wrong-platform";
/// `install`: the binary the host needs is not one this program can stand
/// in for (the app's cmux-tui), so the app installs it.
pub const REASON_NOT_THIS_PROGRAM: &str = "not-this-program";

impl StepResult {
    pub fn new(step: Step, state: StepState, detail: impl Into<String>) -> Self {
        Self { step, state, detail: detail.into(), fix: None, reason: None, data: None }
    }

    pub fn with_reason(mut self, reason: &'static str) -> Self {
        self.reason = Some(reason);
        self
    }

    pub fn with_fix(mut self, fix: impl Into<String>) -> Self {
        self.fix = Some(fix.into());
        self
    }

    pub fn with_try(mut self, command: impl Into<String>) -> Self {
        self.data = Some(json!({"try": command.into()}));
        self
    }

    /// Whether the machine still counts as healthy after this step.
    pub fn healthy(&self) -> bool {
        matches!(self.state, StepState::Ok | StepState::Fixed | StepState::Skip | StepState::Warn)
    }
}

/// The final line: `{"report":{...}}`.
#[derive(Clone, Debug, Serialize)]
pub struct Report {
    pub name: String,
    pub host: String,
    pub ok: bool,
    pub steps: Vec<StepResult>,
}

impl Report {
    pub fn new(name: impl Into<String>, host: impl Into<String>, steps: Vec<StepResult>) -> Self {
        let ok = steps.iter().all(StepResult::healthy);
        Self { name: name.into(), host: host.into(), ok, steps }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn step_line_shape() {
        let line = serde_json::to_value(
            StepResult::new(Step::PeerBack, StepState::Warn, "no route back").with_fix("add a key"),
        )
        .unwrap();
        assert_eq!(line["step"], "peer-back");
        assert_eq!(line["state"], "warn");
        assert_eq!(line["fix"], "add a key");
    }

    #[test]
    fn report_ok_ignores_warn_and_skip() {
        let r = Report::new(
            "hb",
            "huge-blue",
            vec![
                StepResult::new(Step::Reach, StepState::Ok, ""),
                StepResult::new(Step::PeerBack, StepState::Warn, ""),
                StepResult::new(Step::Identity, StepState::Skip, ""),
            ],
        );
        assert!(r.ok);
        let r = Report::new(
            "hb",
            "huge-blue",
            vec![StepResult::new(Step::Daemon, StepState::Fail, "")],
        );
        assert!(!r.ok);
    }
}
