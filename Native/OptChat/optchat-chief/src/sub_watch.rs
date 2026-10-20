//! What a running subagent is doing now, read from its acpmux events
//! (acp-chief-issues.md #4-#7, #13, #16, #20; a204). Not written yet: the
//! red commit's tests (tests/sub_watch.rs, tests/subagent_watch.rs) show
//! what it must do.

use std::time::Duration;

use cmux_chief::acp::AcpmuxEvent;

/// No event at all for this long: the run is stalled.
pub const STALL_AFTER: Duration = Duration::from_secs(15 * 60);
/// A wait on one fleet run longer than this is overdue.
pub const WAIT_MAX: Duration = Duration::from_secs(3 * 3600);
/// Any other single tool call longer than this is overdue.
pub const TOOL_MAX: Duration = Duration::from_secs(90 * 60);

/// What a waiting tool call waits on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WaitOn {
    Fleet(String),
    GhRun(String),
    Poll,
}

/// What the run does at one moment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Doing {
    Done,
    Thinking {
        silent_ms: u64,
    },
    Tool {
        name: String,
        detail: String,
        for_ms: u64,
        beat_ago_ms: Option<u64>,
    },
    Waiting {
        on: WaitOn,
        detail: String,
        for_ms: u64,
        beat_ago_ms: Option<u64>,
    },
    Stalled {
        silent_ms: u64,
        tool: Option<String>,
    },
}

impl Doing {
    pub fn state(&self) -> &'static str {
        "running"
    }
    pub fn label(&self) -> String {
        String::new()
    }
}

/// Whether a run needs the Chief.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Alarm {
    None,
    Stalled { silent_ms: u64 },
    Overdue { what: String, for_ms: u64 },
}

/// A run's events, folded.
#[derive(Debug, Clone, Default)]
pub struct Watch {
    seq: u64,
}

impl Watch {
    pub fn after(seq: u64) -> Watch {
        Watch { seq }
    }
    pub fn seq(&self) -> u64 {
        self.seq
    }
    pub fn pushed(&self) -> &[String] {
        &[]
    }
    pub fn apply(&mut self, _event: &AcpmuxEvent) {}
    pub fn doing(&self, _now: u64) -> Doing {
        Doing::Thinking { silent_ms: 0 }
    }
    pub fn alarm(&self, _now: u64) -> Alarm {
        Alarm::None
    }
    pub fn resume_note(&self, _now: u64) -> String {
        String::new()
    }
    pub fn summary(&self, _now: u64) -> Vec<String> {
        Vec::new()
    }
}

pub fn wait_on(_command: &str) -> Option<WaitOn> {
    None
}

pub fn task_of(_prompt: &str) -> Option<String> {
    None
}

pub fn is_ack(_report: &str) -> bool {
    false
}
