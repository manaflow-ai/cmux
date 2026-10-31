//! What a running subagent is doing now, read from its acpmux events
//! (acp-chief-issues.md #4-#7, #13, #16, #20; a204, 2026-10-20).
//!
//! The host used to call a subagent "stuck" when its acpmux session summary
//! had not changed for 15 minutes. A summary changes on status and
//! permission records only, so an agent inside one long tool call (`sleep
//! 1500; cmux-ci status ...`, `cmux-ci wait ID`) looked stuck although
//! Claude Code sent a `tool_progress` heartbeat every 30 seconds: 77 of the
//! 80 alerts of 2026-10-19 were such waits. A [`Watch`] folds the events of
//! the current run and tells a live wait from a silent harness:
//!
//! - an event (any: a heartbeat, a stream chunk) within [`STALL_AFTER`]:
//!   alive; a tool in flight is "running" or, for a fleet run, a GitHub run
//!   or a sleep loop, "waiting on ...";
//! - no event for [`STALL_AFTER`]: stalled (a hung model request or a dead
//!   tool), unless the harness never sends heartbeats for tools (codex), in
//!   which case the tool's own limit holds;
//! - a wait on one fleet run longer than [`WAIT_MAX`] or another tool
//!   longer than [`TOOL_MAX`]: overdue, worth one note.
//!
//! It also keeps what a status or a stopped report should say: the last
//! line the agent wrote, the commits it pushed and the fleet runs it used.

use std::collections::BTreeMap;
use std::time::Duration;

use cmux_chief::acp::AcpmuxEvent;
use serde_json::Value;

/// No event at all for this long: the run is stalled.
pub const STALL_AFTER: Duration = Duration::from_secs(15 * 60);
/// A wait on one fleet run (or one sleep loop) longer than this is overdue.
pub const WAIT_MAX: Duration = Duration::from_secs(3 * 3600);
/// Any other single tool call longer than this is overdue.
pub const TOOL_MAX: Duration = Duration::from_secs(90 * 60);
/// Characters kept of a command or a line in a label.
const SHOWN: usize = 120;

/// What a waiting tool call waits on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WaitOn {
    /// A build-fleet job (`cmux-ci wait|status ID`), by its id.
    Fleet(String),
    /// A GitHub Actions run (`gh run watch|view ID`), by its id.
    GhRun(String),
    /// A sleep or polling loop on something else (a log file, a process).
    Poll,
}

impl WaitOn {
    fn label(&self) -> String {
        match self {
            WaitOn::Fleet(id) => format!("fleet run {id}"),
            WaitOn::GhRun(id) => format!("GitHub run {id}"),
            WaitOn::Poll => "a polling loop".to_owned(),
        }
    }
}

/// What the run does at one moment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Doing {
    /// Its turn ended; it waits for a message.
    Done,
    /// No tool in flight and events are fresh: the model is working.
    Thinking { silent_ms: u64 },
    /// A tool call is in flight.
    Tool {
        name: String,
        detail: String,
        for_ms: u64,
        beat_ago_ms: Option<u64>,
    },
    /// A tool call that waits on a run or a loop is in flight.
    Waiting {
        on: WaitOn,
        detail: String,
        for_ms: u64,
        beat_ago_ms: Option<u64>,
    },
    /// No event for [`STALL_AFTER`] or more.
    Stalled {
        silent_ms: u64,
        tool: Option<String>,
    },
}

impl Doing {
    /// The one-word state `control status` shows.
    pub fn state(&self) -> &'static str {
        match self {
            Doing::Done => "done",
            Doing::Thinking { .. } => "thinking",
            Doing::Tool { .. } => "running-tool",
            Doing::Waiting { .. } => "waiting",
            Doing::Stalled { .. } => "stalled",
        }
    }

    /// One line: what it does and for how long.
    pub fn label(&self) -> String {
        let beat = |b: &Option<u64>| match b {
            Some(ms) => format!(", alive (heartbeat {} ago)", minutes(*ms)),
            None => String::new(),
        };
        match self {
            Doing::Done => "its turn ended; it waits for a message".to_owned(),
            Doing::Thinking { silent_ms } => {
                format!("thinking (last event {} ago)", minutes(*silent_ms))
            }
            Doing::Tool {
                name,
                detail,
                for_ms,
                beat_ago_ms,
            } => format!(
                "running {name} for {}{}: {detail}",
                minutes(*for_ms),
                beat(beat_ago_ms)
            ),
            Doing::Waiting {
                on,
                detail,
                for_ms,
                beat_ago_ms,
            } => format!(
                "waiting on {} for {}{}: {detail}",
                on.label(),
                minutes(*for_ms),
                beat(beat_ago_ms)
            ),
            Doing::Stalled { silent_ms, tool } => match tool {
                Some(t) => format!("stalled: no event for {} inside {t}", minutes(*silent_ms)),
                None => format!(
                    "stalled: no event for {} (no tool in flight: a hung model request)",
                    minutes(*silent_ms)
                ),
            },
        }
    }
}

/// Whether a run needs the Chief.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Alarm {
    /// Healthy, waiting or done.
    None,
    /// Silent for [`STALL_AFTER`]: continue it automatically first.
    Stalled { silent_ms: u64 },
    /// Alive, but one wait or tool runs past its limit.
    Overdue { what: String, for_ms: u64 },
}

/// One tool call in flight.
#[derive(Debug, Clone, Default)]
struct ToolRun {
    name: String,
    command: String,
    started_ms: u64,
    beat_ms: u64,
}

/// A run's events, folded for status and stuck detection.
#[derive(Debug, Clone, Default)]
pub struct Watch {
    seq: u64,
    tools: BTreeMap<String, ToolRun>,
    last_event_ms: u64,
    talk: String,
    last_line: Option<String>,
    pushed: Vec<String>,
    /// Each fleet job the run named, with when it was first named.
    fleet: Vec<(String, u64)>,
    ended: bool,
    /// The tool in flight when the turn ended (a stop cut it).
    stopped_in: Option<String>,
    told_by_chief: bool,
    /// The harness sends tool heartbeats (Claude Code).
    beats: bool,
}

impl Watch {
    /// A watch of the events after `seq` (the run's floor).
    pub fn after(seq: u64) -> Watch {
        Watch {
            seq,
            ..Watch::default()
        }
    }

    /// The highest seq folded: fetch the events after it next.
    pub fn seq(&self) -> u64 {
        self.seq
    }

    /// When the last event came (ms since the epoch; 0: none yet).
    pub fn last_event_ms(&self) -> u64 {
        self.last_event_ms
    }

    /// The last line the agent wrote.
    pub fn last_line(&self) -> Option<&str> {
        self.last_line.as_deref()
    }

    /// Pushes the run made, as git printed them (`a1b2c3d..e4f5a6b -> feat-cmux-next`).
    pub fn pushed(&self) -> &[String] {
        &self.pushed
    }

    /// The fleet job ids the run named, oldest first.
    pub fn fleet_runs(&self) -> Vec<String> {
        self.fleet.iter().map(|(id, _)| id.clone()).collect()
    }

    /// The current turn was started by a Chief `tell` (not the task, the
    /// user or an auto-resume).
    pub fn told_by_chief(&self) -> bool {
        self.told_by_chief
    }

    /// Folds one event; replays (seq at or below the last) are skipped.
    pub fn apply(&mut self, event: &AcpmuxEvent) {
        if !event.valid {
            return;
        }
        if event.seq > 0 {
            if event.seq <= self.seq {
                return;
            }
            self.seq = event.seq;
        }
        let at = event.at.unwrap_or(0);
        self.last_event_ms = self.last_event_ms.max(at);
        let params = event.msg.get("params");
        // Claude Code's own subagents (Task) report under `<session>/<tool>`:
        // they prove the run is alive, but their tools are not its own.
        let inner = params
            .and_then(|p| p.get("sessionId"))
            .and_then(Value::as_str)
            .is_some_and(|s| s.contains('/'));
        let update = params.and_then(|p| p.get("update"));
        match (event.dir.as_str(), event.kind.as_str()) {
            ("mux", "user_message") => {
                self.ended = false;
                self.stopped_in = None;
                self.tools.clear();
                let prompt_id = event
                    .msg
                    .get("promptId")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                let p = crate::subagents::PROMPT_PREFIX;
                self.told_by_chief = prompt_id.starts_with(&format!("{p}tell:"))
                    || prompt_id.starts_with(&format!("{p}fyi:"));
            }
            ("mux", "turn_end" | "turn_error") => {
                self.close_talk();
                self.ended = true;
                self.stopped_in = self
                    .current()
                    .map(|t| format!("`{}`", clip(&t.command, SHOWN)));
                self.tools.clear();
            }
            (_, "claude.tool_progress") => {
                self.beats = true;
                if let Some(id) = event.msg.get("parent_tool_use_id").and_then(Value::as_str)
                    && let Some(tool) = self.tools.get_mut(id)
                {
                    tool.beat_ms = tool.beat_ms.max(at);
                }
            }
            (_, "agent_message_chunk") if !inner => {
                if let Some(text) = update
                    .and_then(|u| u.get("content"))
                    .and_then(|c| c.get("text"))
                    .and_then(Value::as_str)
                {
                    self.talk.push_str(text);
                }
            }
            (_, "tool_call") if !inner => {
                self.close_talk();
                let Some(update) = update else { return };
                let Some(id) = update.get("toolCallId").and_then(Value::as_str) else {
                    return;
                };
                let command = command_of(update);
                self.note_fleet(&command, at);
                let tool = self.tools.entry(id.to_owned()).or_default();
                tool.started_ms = if tool.started_ms == 0 {
                    at
                } else {
                    tool.started_ms
                };
                tool.beat_ms = tool.beat_ms.max(at);
                if let Some(name) = name_of(update) {
                    tool.name = name;
                }
                if !command.is_empty() {
                    tool.command = command;
                }
            }
            (_, "tool_call_update") if !inner => {
                let Some(update) = update else { return };
                let Some(id) = update.get("toolCallId").and_then(Value::as_str) else {
                    return;
                };
                // Only a real input: an update's title is not the command.
                if let Some(command) = update
                    .pointer("/rawInput/command")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                {
                    self.note_fleet(&command, at);
                    if let Some(tool) = self.tools.get_mut(id) {
                        tool.command = command;
                    }
                }
                let status = update.get("status").and_then(Value::as_str).unwrap_or("");
                if matches!(status, "completed" | "failed") {
                    let ran = self.tools.remove(id).map(|t| t.command).unwrap_or_default();
                    let text = result_text(update);
                    self.pushed.extend(pushes(&text));
                    if ran.contains("cmux-ci") {
                        for job in fleet_ids(&text) {
                            self.add_fleet(job, at);
                        }
                    }
                }
            }
            _ => {}
        }
    }

    fn close_talk(&mut self) {
        let talk = std::mem::take(&mut self.talk);
        if let Some(line) = talk.lines().rev().find(|l| !l.trim().is_empty()) {
            self.last_line = Some(clip(line.trim(), 300));
        }
    }

    fn note_fleet(&mut self, command: &str, at: u64) {
        if command.contains("cmux-ci") {
            for job in fleet_ids(command) {
                self.add_fleet(job, at);
            }
        }
    }

    fn add_fleet(&mut self, job: String, at: u64) {
        if !self.fleet.iter().any(|(j, _)| *j == job) {
            self.fleet.push((job, at));
        }
    }

    /// The tool in flight that started last.
    fn current(&self) -> Option<&ToolRun> {
        self.tools.values().max_by_key(|t| t.started_ms)
    }

    /// What the run does at `now` (ms since the epoch).
    pub fn doing(&self, now: u64) -> Doing {
        if self.ended {
            return Doing::Done;
        }
        let silent_ms = now.saturating_sub(self.last_event_ms);
        let stall = STALL_AFTER.as_millis() as u64;
        let tool = self.current();
        if silent_ms >= stall {
            // A harness without heartbeats (codex) is silent in any long
            // tool: the tool's own limit decides there (`alarm`).
            if self.beats || tool.is_none() {
                return Doing::Stalled {
                    silent_ms,
                    tool: tool.map(|t| format!("{} `{}`", t.name, clip(&t.command, SHOWN))),
                };
            }
        }
        let Some(tool) = tool else {
            return Doing::Thinking { silent_ms };
        };
        let for_ms = now.saturating_sub(tool.started_ms);
        let beat_ago_ms = (self.beats && tool.beat_ms > tool.started_ms)
            .then(|| now.saturating_sub(tool.beat_ms));
        let detail = format!("`{}`", clip(&tool.command, SHOWN));
        match wait_on(&tool.command) {
            Some(on) => Doing::Waiting {
                on,
                detail,
                for_ms,
                beat_ago_ms,
            },
            None => Doing::Tool {
                name: if tool.name.is_empty() {
                    "a tool".to_owned()
                } else {
                    tool.name.clone()
                },
                detail,
                for_ms,
                beat_ago_ms,
            },
        }
    }

    /// Whether the run needs attention at `now`.
    pub fn alarm(&self, now: u64) -> Alarm {
        match self.doing(now) {
            Doing::Stalled { silent_ms, .. } => Alarm::Stalled { silent_ms },
            Doing::Waiting { on, for_ms, .. } => {
                // A wait on one fleet run counts from when the run first
                // named it, across the agent's repeated `sleep; status` calls.
                let since = match &on {
                    WaitOn::Fleet(id) => self
                        .fleet
                        .iter()
                        .find(|(j, _)| j == id)
                        .map_or(for_ms, |(_, at)| now.saturating_sub(*at).max(for_ms)),
                    _ => for_ms,
                };
                if since >= WAIT_MAX.as_millis() as u64 {
                    Alarm::Overdue {
                        what: format!("waiting on {}", on.label()),
                        for_ms: since,
                    }
                } else {
                    Alarm::None
                }
            }
            Doing::Tool { name, for_ms, .. } if for_ms >= TOOL_MAX.as_millis() as u64 => {
                Alarm::Overdue {
                    what: format!("running {name}"),
                    for_ms,
                }
            }
            _ => Alarm::None,
        }
    }

    /// What a continue prompt must carry so no work is lost or run twice
    /// (#16): the tool it was in, the fleet runs it already started, and
    /// to keep uncommitted edits.
    pub fn resume_note(&self, now: u64) -> String {
        let mut out = String::from(
            "Before anything else: run `git status` in your worktree and keep any uncommitted edits.",
        );
        if let Some(tool) = self.current() {
            out.push_str(&format!(
                " You were stopped inside `{}` (running for {}).",
                clip(&tool.command, 200),
                minutes(now.saturating_sub(tool.started_ms))
            ));
        }
        let runs = self.fleet_runs();
        if !runs.is_empty() {
            out.push_str(&format!(
                " Fleet runs you already started may still be going: {}. Wait on the same ids again (`cmux-ci wait ID`); do not submit them again.",
                runs.join(", ")
            ));
        }
        out
    }

    /// The lines a status or a stopped report adds: doing, last line,
    /// pushes and fleet runs.
    pub fn summary(&self, now: u64) -> Vec<String> {
        let mut out = vec![format!("doing: {}", self.doing(now).label())];
        if self.ended
            && let Some(tool) = &self.stopped_in
        {
            out.push(format!("stopped inside: {tool}"));
        }
        if let Some(line) = &self.last_line {
            out.push(format!("last said: {}", clip(line, 200)));
        }
        if !self.pushed.is_empty() {
            out.push(format!("pushed: {}", self.pushed.join("; ")));
        }
        let runs = self.fleet_runs();
        if !runs.is_empty() {
            out.push(format!("fleet runs: {}", runs.join(", ")));
        }
        out
    }
}

/// What `command` waits on, when it is a wait.
pub fn wait_on(command: &str) -> Option<WaitOn> {
    let words: Vec<&str> = command
        .split(|c: char| c.is_whitespace() || matches!(c, ';' | '&' | '|' | '(' | ')' | '"' | '\''))
        .filter(|w| !w.is_empty())
        .collect();
    let after = |pat: &[&str]| -> Option<String> {
        words.windows(pat.len() + 1).find_map(|w| {
            (w[..pat.len()]
                .iter()
                .zip(pat)
                .all(|(a, b)| a == b || a.ends_with(&format!("/{b}"))))
            .then(|| w[pat.len()].to_owned())
            .filter(|id| !id.starts_with('-'))
        })
    };
    if let Some(id) = after(&["cmux-ci", "wait"]) {
        return Some(WaitOn::Fleet(id));
    }
    if let Some(id) = after(&["gh", "run", "watch"]) {
        return Some(WaitOn::GhRun(id));
    }
    let sleeps = words.contains(&"sleep") || words.iter().any(|w| matches!(*w, "until" | "while"));
    if !sleeps {
        return None;
    }
    if let Some(id) = after(&["cmux-ci", "status"]) {
        return Some(WaitOn::Fleet(id));
    }
    if command.contains("cmux-ci")
        && let Some(id) = fleet_ids(command).into_iter().next()
    {
        return Some(WaitOn::Fleet(id));
    }
    if let Some(id) = after(&["gh", "run", "view"]) {
        return Some(WaitOn::GhRun(id));
    }
    Some(WaitOn::Poll)
}

/// Build-fleet job ids in `text`: 24 lowercase hex characters.
fn fleet_ids(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for word in text.split(|c: char| !c.is_ascii_hexdigit()) {
        if word.len() == 24
            && word
                .chars()
                .all(|c| c.is_ascii_digit() || c.is_ascii_lowercase())
            && !out.iter().any(|w| w == word)
        {
            out.push(word.to_owned());
        }
    }
    out
}

/// The `old..new -> branch` lines of git push output in `text`.
fn pushes(text: &str) -> Vec<String> {
    text.lines()
        .filter_map(|line| {
            let line = line.trim();
            let (range, rest) = line.split_once(char::is_whitespace)?;
            let (old, new) = range.split_once("..")?;
            let hex = |s: &str| s.len() >= 7 && s.chars().all(|c| c.is_ascii_hexdigit());
            let new = new.trim_start_matches('.');
            if !(hex(old) && hex(new)) {
                return None;
            }
            let (_, to) = rest.split_once("->")?;
            Some(format!("{old}..{new} -> {}", to.trim()))
        })
        .collect()
}

fn command_of(update: &Value) -> String {
    let input = update.get("rawInput");
    input
        .and_then(|i| i.get("command"))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .or_else(|| {
            input
                .and_then(|i| i.get("description"))
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .or_else(|| {
            update
                .get("title")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .unwrap_or_default()
}

fn name_of(update: &Value) -> Option<String> {
    update
        .pointer("/_meta/claude/tool")
        .or_else(|| update.pointer("/_meta/claudeCode/toolName"))
        .or_else(|| update.get("kind"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

fn result_text(update: &Value) -> String {
    let mut parts: Vec<String> = Vec::new();
    for item in update
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let content = item.get("content").unwrap_or(item);
        if let Some(text) = content.get("text").and_then(Value::as_str) {
            parts.push(text.to_owned());
        }
    }
    if parts.is_empty()
        && let Some(Value::String(text)) = update.get("rawOutput")
    {
        return text.clone();
    }
    parts.join("\n")
}

/// The task of a subagent's first prompt: what follows its "Your task:"
/// label (the view before it is the Chief's chat, not the task).
pub fn task_of(prompt: &str) -> Option<String> {
    let (_, task) = prompt.rsplit_once("Your task:")?;
    let task = task.trim();
    (!task.is_empty()).then(|| task.to_owned())
}

/// A short reply that only acknowledges a Chief message ("Understood, I'm
/// stopping", "I renamed a199 ..."): it reaches the Chief quietly, without
/// a turn of its own (#20). Anything that asks, reports a failure or a
/// commit, or names a link is never one.
pub fn is_ack(report: &str) -> bool {
    let text = report.trim();
    if text.is_empty() || text.chars().count() > 600 || text.starts_with('(') {
        return false;
    }
    let lower = text.to_lowercase();
    const LOUD: [&str; 16] = [
        "?",
        "needs you",
        "need you",
        "decision",
        "blocked",
        "fail",
        "error",
        "can't",
        "cannot",
        "couldn't",
        "approve",
        "credential",
        "login",
        "password",
        "http",
        "reply `",
    ];
    if LOUD.iter().any(|w| lower.contains(w)) {
        return false;
    }
    // A commit sha means it reports work, not an acknowledgement.
    let sha = text.split(|c: char| !c.is_ascii_alphanumeric()).any(|w| {
        w.len() >= 7
            && w.chars().all(|c| c.is_ascii_hexdigit())
            && w.chars().any(|c| c.is_ascii_digit())
            && w.chars().any(|c| c.is_ascii_alphabetic())
    });
    if sha {
        return false;
    }
    const ACK: [&str; 10] = [
        "understood",
        "stopping",
        "i'm stopping",
        "i stopped",
        "will do",
        "noted",
        "acknowledged",
        "got it",
        "renamed",
        "i'll wait",
    ];
    ACK.iter().any(|w| lower.contains(w))
}

/// `ms` as `12s`, `5m` or `1h05m`.
/// Landing follow-ups per subagent before its report reaches the Chief.
pub const LAND_FOLLOWUPS: u32 = 1;

/// The host's landing follow-up (a676, Lawrence 2026-10-26: "it follows every
/// open task until done ... with no model call").
pub const LAND_FOLLOWUP: &str = "[follow-up] Your report says your work is not landed yet. Finish it now: rebase on the branch's latest remote, make it green, plain push, then report the landed range (OLD..NEW) and how you checked it. If only the user can clear what blocks it (money, legal, destructive, sign-in), or your task said not to land, say that in one line instead.";

/// Whether a subagent `report` says code it made is not landed: a word that
/// implies code waits (unpushed, unlanded, a red check), or a weaker one
/// (not landed, nothing landed) next to a commit sha. A report with no code
/// in it ("nothing committed, nothing landed") never counts.
pub fn unlanded(report: &str) -> bool {
    // A leading space so " is red" never matches inside "this red".
    let text = format!(" {}", report.to_lowercase());
    const STRONG: [&str; 5] = [
        "unpushed",
        "not pushed",
        "unlanded",
        " is red",
        " still red",
    ];
    const WEAK: [&str; 5] = [
        "not landed",
        "nothing landed",
        "not yet landed",
        "did not land",
        "didn't land",
    ];
    if STRONG.iter().any(|w| text.contains(w)) {
        return true;
    }
    WEAK.iter().any(|w| text.contains(w))
        && text.split(|c: char| !c.is_ascii_alphanumeric()).any(|w| {
            (7..=40).contains(&w.len())
                && w.chars().all(|c| c.is_ascii_hexdigit())
                && w.chars().any(|c| c.is_ascii_digit())
                && w.chars().any(|c| c.is_ascii_alphabetic())
        })
}

/// Whether a subagent's report ends a turn that leaves its task open: it asks the user
/// something (an interview's questions, a decision) or waits on a build, a test or an
/// answer. Such a subagent runs on when told, so its workspace must stay where the user
/// can find it; the short-task close of a "finished" one closed a6's interview and a8's
/// build wait (2026-10-30: "none of them are actually discoverable").
pub fn awaits_more(report: &str) -> bool {
    let text = report.to_lowercase();
    // A question to the user: a `?` that ends a sentence (never one inside a URL).
    let bytes = text.as_bytes();
    let asks = bytes.iter().enumerate().any(|(i, &c)| {
        c == b'?' && bytes.get(i + 1).is_none_or(|n| n.is_ascii_whitespace() || *n == b')')
    });
    if asks {
        return true;
    }
    const OPEN: [&str; 16] = [
        "waiting on",
        "waiting for",
        "waits on",
        "awaiting",
        "await your",
        "questions for you",
        "your answers",
        "needs your",
        "let me know",
        "still running",
        "still in progress",
        "still pending",
        "not finished",
        "nothing pushed",
        "built nothing",
        "is queued",
    ];
    // "not waiting on anything", "nothing pending": a negated phrase is not a wait.
    const NEGATED: [&str; 4] = ["not ", "no ", "nothing ", "never "];
    OPEN.iter().any(|w| {
        text.match_indices(w).any(|(at, _)| {
            let before = &text[..at];
            !NEGATED.iter().any(|n| before.ends_with(n))
        })
    })
}

#[cfg(test)]
mod awaits_more_tests {
    use super::awaits_more;

    #[test]
    fn open_reports_count() {
        for r in [
            "Built nothing yet. Which host should it build on?",
            "Fix written; waiting on the fleet build, nothing pushed yet.",
            "Seven questions for you before I start.",
            "Tests still running on the fleet.",
        ] {
            assert!(awaits_more(r), "{r}");
        }
    }

    #[test]
    fn finished_reports_do_not() {
        for r in [
            "Done: landed 5c64fec..7b69729, see https://github.com/o/r/pull/1?tab=checks",
            "Done. Not waiting on anything; nothing pending.",
            "Replied on the PR and answered your question; merged.",
            "Once the cache warmed it took 3s. Landed.",
        ] {
            assert!(!awaits_more(r), "{r}");
        }
    }
}

pub fn minutes(ms: u64) -> String {
    let s = ms / 1000;
    if s < 60 {
        format!("{s}s")
    } else if s < 3600 {
        format!("{}m", s / 60)
    } else {
        format!("{}h{:02}m", s / 3600, (s % 3600) / 60)
    }
}

fn clip(text: &str, n: usize) -> String {
    let one: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if one.chars().count() <= n {
        one
    } else {
        let mut cut: String = one.chars().take(n).collect();
        cut.push('…');
        cut
    }
}

#[cfg(test)]
mod unlanded_tests {
    use super::unlanded;

    #[test]
    fn reports_that_leave_code_open_count() {
        assert!(unlanded(
            "Fix in 1a2b3c4d5e6, unpushed (VM token rejected)."
        ));
        assert!(unlanded("Pushed to a scratch branch; unlanded."));
        assert!(unlanded(
            "Commit 9e8f6d9b59 is ready but not landed: CI on it is red."
        ));
        assert!(unlanded("CI is red on fa90c797a82."));
    }

    #[test]
    fn reports_without_open_code_do_not() {
        assert!(!unlanded("Landed 5c6369c..c3c07ba on feat-cmux-next."));
        assert!(!unlanded(
            "Filed ticket 4906279. Nothing committed, nothing landed."
        ));
        assert!(!unlanded("Nothing landed and why: research only."));
        assert!(!unlanded(
            "I made this red button bigger; landed 1a2b3c4..5d6e7f8."
        ));
    }
}
