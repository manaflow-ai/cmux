//! Claude Code over its own stdio protocol, presented to the hub as an ACP
//! agent.
//!
//! `claude -p --input-format stream-json --output-format stream-json` keeps
//! one process alive for many turns. This module owns that process and
//! translates in both directions:
//!
//!   hub -> claude   ACP requests become user messages and control_requests
//!   claude -> hub   stream-json becomes session/update notifications,
//!                   session/request_permission requests, and responses to
//!                   the pending ACP request (session/prompt, initialize, ...)
//!
//! Nothing outside this file knows the Claude wire format.

use crate::config::HarnessProfile;
use crate::no_panic::JsonExt;
use crate::rpc::{Id, Message, RpcError, method};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use tokio::sync::Mutex;

/// The session/update variants and ids this translator emits are plain ACP.
pub const AGENT_NAME: &str = "claude-stdio";

/// Whether a chat's saved `agentInfo` names this adapter, which always steers
/// (`_meta.steering.supported` at initialize). A chat saved without `steering`
/// and adopted since never initializes again, so its steering comes from this.
pub fn steers_by_info(info: Option<&Value>) -> bool {
    info.and_then(|i| i.get("name")).and_then(Value::as_str) == Some(AGENT_NAME)
}

/// Claude Code's own permission modes, offered as ACP session modes: id
/// (Claude Code's `--permission-mode` value), label and one-line description,
/// in the order Claude Code's mode menu lists them. acpmux names none of its
/// own: the menu reads these as they come. Auto is the one Claude Code
/// recommends.
/// bypassPermissions is the mode a new chat starts in
/// (`hub/start_mode.rs`, cx-wx93i): Claude Code itself skips every
/// permission check, so nothing asks. Claude Code accepts it only from a
/// process launched with `--allow-dangerously-skip-permissions`
/// (`spawn_plan`, `bypass_allowed`); elsewhere the switch is refused and
/// the chat keeps its mode.
pub(crate) const MODES: [(&str, &str, &str); 5] = [
    ("auto", "Auto", "Claude handles permission decisions"),
    ("default", "Manual", "Always ask before making changes"),
    ("acceptEdits", "Accept edits", "Automatically accept all file edits"),
    ("plan", "Plan", "Create a plan before making changes"),
    ("bypassPermissions", "Bypass permissions", "Accepts all permissions"),
];

/// The launch flag that lets a running Claude Code switch to
/// bypassPermissions (it does not turn the mode on by itself).
pub const ALLOW_BYPASS_FLAG: &str = "--allow-dangerously-skip-permissions";

/// Whether Claude Code accepts `ALLOW_BYPASS_FLAG` for `profile`: it exits
/// at start when the flag comes as root, unless `IS_SANDBOX=1` or
/// `CLAUDE_CODE_BUBBLEWRAP` is set (Claude Code 2.1.296), and the profile
/// must not pass a skip flag of its own.
pub fn bypass_allowed(profile: &HarnessProfile) -> bool {
    let own = profile
        .argv
        .iter()
        .any(|a| a == ALLOW_BYPASS_FLAG || a == "--dangerously-skip-permissions");
    if own {
        return false;
    }
    let env = |k: &str| profile.env.get(k).cloned().or_else(|| std::env::var(k).ok());
    let sandboxed = env("IS_SANDBOX").as_deref() == Some("1")
        || env("CLAUDE_CODE_BUBBLEWRAP").is_some_and(|v| !v.is_empty());
    #[cfg(unix)]
    // SAFETY: geteuid has no preconditions.
    let root = unsafe { libc::geteuid() } == 0;
    #[cfg(not(unix))]
    let root = false;
    !root || sandboxed
}

/// Claude Code's own model aliases (`set_model` and `--model`). Only Claude
/// Code says what an alias runs; the `[1m]` suffix asks for the 1M context
/// window.
const ALIASES: [(&str, &str); 7] = [
    ("default", "Default (Claude Code's choice)"),
    ("opus", "Opus"),
    ("opus[1m]", "Opus · 1M context"),
    ("opusplan", "Opus plan · Sonnet execute"),
    ("sonnet", "Sonnet"),
    ("sonnet[1m]", "Sonnet · 1M context"),
    ("haiku", "Haiku"),
];

/// The choices offered until Claude Code's own list answers (cx-miuo): its
/// aliases, then every Claude release the bundled model catalog names
/// (`catalog/models-v1.json`), which pin a model regardless of alias drift.
static MODELS: std::sync::LazyLock<Vec<(String, String)>> = std::sync::LazyLock::new(|| {
    let mut models: Vec<(String, String)> =
        ALIASES.iter().map(|(id, name)| (id.to_string(), name.to_string())).collect();
    let catalog = crate::catalog::schema::parse(crate::catalog::BUNDLED.as_bytes());
    let releases =
        catalog.iter().flat_map(|catalog| &catalog.harnesses).filter(|h| h.id == "claude");
    for model in releases.flat_map(|harness| &harness.models) {
        if !models.iter().any(|(id, _)| *id == model.id) {
            models.push((model.id.clone(), model.short_name.clone()));
        }
    }
    models
});

/// The Reasoning choices: Claude Code's effort levels (`--effort` and the
/// live `apply_flag_settings` `effortLevel`). "default" leaves the model's
/// own level. The pane offers a model only the levels its `list_models` row
/// supports.
const EFFORTS: [(&str, &str); 6] = [
    ("default", "Default"),
    ("low", "Low"),
    ("medium", "Medium"),
    ("high", "High"),
    ("xhigh", "Extra High"),
    ("max", "Max"),
];

/// The session's effort may also be `ultracode`: Claude Code's workflow
/// orchestration setting, which runs at xhigh. It is not a level, so it is
/// its own On/Off option (`ULTRACODE_OPTION`), not a Reasoning choice.
const ULTRACODE: &str = "ultracode";
pub const ULTRACODE_OPTION: &str = "ultracode";

/// A stored or sent effort as this translator keeps it. `ultrathink` was a
/// Reasoning choice that only prefixed each prompt with a keyword; a saved
/// pick of it now runs the model's own level.
fn effort_value(effort: &str) -> &str {
    match effort {
        "ultrathink" | "" => "default",
        other => other,
    }
}

/// The Reasoning select's value for a session effort: Ultracode runs at xhigh.
fn shown_level(effort: &str) -> &str {
    match effort_value(effort) {
        ULTRACODE => "xhigh",
        level => level,
    }
}

/// The `--effort` a session starts with: Ultracode runs at xhigh, "default"
/// passes none (the model's own level).
fn cli_effort(effort: &str) -> Option<&str> {
    match effort_value(effort) {
        "default" => None,
        level => Some(shown_level(level)),
    }
}

/// The `apply_flag_settings` settings for a session effort. Every level
/// clears `ultracode`.
fn effort_settings(effort: &str) -> Value {
    match effort_value(effort) {
        ULTRACODE => json!({"effortLevel": "xhigh", "ultracode": true}),
        "default" => json!({"effortLevel": "auto", "ultracode": false}),
        level => json!({"effortLevel": level, "ultracode": false}),
    }
}

/// Settings a new process needs on the live channel before its first turn:
/// Ultracode and fast mode have no command-line flag of their own.
fn startup_settings(effort: &str, fast: bool) -> Option<Value> {
    let mut settings = serde_json::Map::new();
    if effort_value(effort) == ULTRACODE {
        settings.insert("effortLevel".into(), json!("xhigh"));
        settings.insert("ultracode".into(), json!(true));
    }
    if fast {
        settings.insert("fastMode".into(), json!(true));
    }
    (!settings.is_empty()).then_some(Value::Object(settings))
}

/// The most items a workflow snapshot can hold and still be logged whole
/// (`logged_line`): a small run's snapshots stay as Claude sent them.
const LOGGED_SNAPSHOT_ITEMS: usize = 16;

/// A raw Claude stdout line as the session's event log keeps it, under its
/// own kind (`claude.<type>[.<subtype>]`). A workflow's `task_progress`
/// snapshot (`workflow_progress`) repeats every agent of the run so far,
/// about 1 KB each, and comes with every agent's start and end, so one run
/// of several hundred agents would log hundreds of megabytes. A snapshot of
/// more than `LOGGED_SNAPSHOT_ITEMS` items is logged as how many it held
/// (`_acpmux.workflowProgressItems`); the translated `subagent_progress`
/// keeps what changed (`workflows.rs`).
pub fn logged_line(raw: &Value) -> Message {
    let kind = format!(
        "claude.{}{}",
        raw.get("type").and_then(Value::as_str).unwrap_or("?"),
        raw.get("subtype").and_then(Value::as_str).map(|s| format!(".{s}")).unwrap_or_default()
    );
    let snapshot = raw.get("workflow_progress").and_then(Value::as_array);
    let line = match (raw.as_object(), snapshot) {
        (Some(fields), Some(items)) if items.len() > LOGGED_SNAPSHOT_ITEMS => {
            let mut kept: serde_json::Map<String, Value> = fields
                .iter()
                .filter(|(key, _)| *key != "workflow_progress")
                .map(|(key, value)| (key.clone(), value.clone()))
                .collect();
            kept.insert("_acpmux".into(), json!({"workflowProgressItems": items.len()}));
            Value::Object(kept)
        }
        _ => raw.clone(),
    };
    Message::notification(&kind, line)
}

/// The model choices offered in pickers before Claude Code's own list answers.
pub fn models() -> &'static [(String, String)] {
    &MODELS
}

pub(crate) mod agent_transcript;
#[cfg(test)]
mod agent_transcript_tests;
#[cfg(test)]
mod background_output_tests;
#[cfg(test)]
mod context_usage_tests;
mod early_calls;
#[cfg(test)]
mod early_calls_tests;
#[cfg(test)]
mod edit_diff_tests;
mod elicitation;
#[cfg(test)]
mod elicitation_tests;
mod inbound;
mod outbound;
#[cfg(test)]
mod steer_now_tests;
// Other sessions' messages steered into one step go in as one line (`steer_batch.rs`).
mod steer_batch;
#[cfg(test)]
mod steer_batch_tests;
mod steer_withdraw;
#[cfg(test)]
mod steer_withdraw_tests;
mod subagent_route;
#[cfg(test)]
mod subagent_tests;
#[cfg(test)]
mod tests;
mod usage_limits;
#[cfg(test)]
mod usage_limits_tests;
#[cfg(test)]
mod workflow_tests;
mod workflows;
pub use usage_limits::merge_usage_limits;

/// Longest failure text a failed subagent's end carries, in characters.
const MAX_FAILURE_CHARS: usize = 600;

/// Most failed subagents remembered for a resume (`failed_agents`); the oldest goes first. A
/// resume of one forgotten still streams under its own session (`subagent_route.rs`); only its
/// `running` again is not said.
const MAX_FAILED_AGENTS: usize = 64;

/// The internal ACP request that stops one of Claude Code's background
/// tasks (`hub/processes.rs`), `{sessionId, taskId}`: Claude Code's
/// `stop_task` control request. The answer is `{}` once Claude Code took it;
/// the task's end arrives as its own event.
pub const STOP_TASK: &str = "_acpmux/claude/stop_task";

/// The internal ACP request that moves Claude Code's running work to the
/// background (Ctrl-B, `hub/processes.rs`), `{sessionId, toolCallId?}`:
/// Claude Code's `background_tasks` control request, for the task the tool
/// call started or, without one, every foreground task. Answers
/// `{backgrounded}`; the shells it moved arrive as their own events, with
/// origin `user_backgrounded`.
pub const BACKGROUND_TASKS: &str = "_acpmux/claude/background_tasks";

/// The internal ACP request that reconnects one of the chat's MCP servers
/// (`hub/tools.rs`), `{sessionId, server}`: Claude Code's `mcp_reconnect`
/// control request. The answer is `{}` once Claude Code connected it again,
/// or Claude Code's error.
pub const MCP_RECONNECT: &str = "_acpmux/claude/mcp_reconnect";

/// The most categories, memory files, MCP tools and skills a context breakdown
/// names (`context_breakdown`; the lists the largest first, categories in Claude Code's order): a chat with hundreds of MCP
/// tools would otherwise log every one at each turn's end.
const BREAKDOWN_ROWS: usize = 50;

/// The refusal of a steered prompt when no turn is running (the turn ended
/// between the hub's check and the adapter).
pub const STEER_NO_TURN: &str = "steer: no turn is running";

/// The answer of a steered prompt taken back before Claude Code read it
/// (`MUX_STEER_WITHDRAW`, `steer_withdraw.rs`).
pub const STEER_WITHDRAWN: &str = "steer: withdrawn before the agent read it";

/// What the hub's request becomes: lines for claude's stdin, or an
/// immediate ACP reply when claude need not be asked.
pub enum Outbound {
    Lines(Vec<Value>),
    Reply(Message),
}

#[derive(Debug, Clone)]
pub struct SpawnPlan {
    pub program: String,
    pub args: Vec<String>,
}

/// Build the claude command line. `resume` reopens an existing Claude
/// session (or forks it); `fresh_id` pins the id of a brand-new one so acpmux
/// knows it before the first turn.
/// `mode` is pinned with `--permission-mode` so the user's Claude settings
/// (often `auto`) cannot silently bypass acpmux's permission policy; the
/// mode chip then always tells the truth. `model` is the session's chosen
/// model, passed as `--model` so forks and respawns keep it.
pub fn spawn_plan(
    profile: &HarnessProfile,
    resume: Option<&str>,
    fork: bool,
    fresh_id: Option<&str>,
    effort: Option<&str>,
    mode: &str,
    model: Option<&str>,
) -> SpawnPlan {
    let program = profile.argv.first().cloned().unwrap_or_else(|| "claude".into());
    // Everything after the program in argv comes first: a wrapper such as
    // `sr claude proxy` needs its own words before Claude's flags, and a
    // plain profile can still pin --model, --settings, --mcp-config, ...
    let mut args: Vec<String> = profile.argv.iter().skip(1).cloned().collect();
    args.extend([
        "-p".into(),
        "--input-format".into(),
        "stream-json".into(),
        "--output-format".into(),
        "stream-json".into(),
        "--verbose".into(),
        "--include-partial-messages".into(),
        // Claude Code echoes each user line when it reads it: a steered
        // message (written during a turn) is confirmed by its echo.
        "--replay-user-messages".into(),
        "--permission-prompt-tool".into(),
        "stdio".into(),
    ]);
    if let Some(sid) = resume {
        args.push("--resume".into());
        args.push(sid.into());
        if fork {
            args.push("--fork-session".into());
        }
    } else if let Some(id) = fresh_id {
        args.push("--session-id".into());
        args.push(id.into());
    }
    if let Some(e) = effort.and_then(cli_effort) {
        args.push("--effort".into());
        args.push(e.into());
    }
    // A later --model wins over one the profile pins in its argv.
    if let Some(m) = model.filter(|m| !m.is_empty() && *m != "default") {
        args.push("--model".into());
        args.push(m.into());
    }
    // Lets the chat switch to bypassPermissions ("Bypass permissions") later; a
    // process that cannot take it is never given bypassPermissions at spawn.
    let bypass = bypass_allowed(profile);
    if bypass {
        args.push(ALLOW_BYPASS_FLAG.into());
    }
    // A profile that passes a skip flag itself takes the mode as it is.
    let own_skip = profile
        .argv
        .iter()
        .any(|a| a == ALLOW_BYPASS_FLAG || a == "--dangerously-skip-permissions");
    let mode = if mode == "bypassPermissions" && !bypass && !own_skip { "default" } else { mode };
    if !profile.argv.iter().any(|a| a == "--permission-mode") && !mode.is_empty() {
        args.push("--permission-mode".into());
        args.push(mode.into());
    }
    SpawnPlan { program, args }
}

/// Per-process translation state.
pub struct Translator {
    /// ACP request id -> what we are waiting on from claude.
    pending: Mutex<HashMap<String, Pending>>,
    /// claude control request_id -> ACP request id we issued to the hub.
    control_out: Mutex<HashMap<String, Id>>,
    /// claude control request_id -> the session rules made from what Claude
    /// suggested with its permission ask (`session_rules`), held until the
    /// answer: an "Allow for this session" hands them back.
    suggestions: Mutex<HashMap<String, Value>>,
    /// claude control request_id -> the tool input of its `can_use_tool`
    /// ask, held until the answer: Claude Code takes an allow only with
    /// `updatedInput` (its permission reply schema), so an allow the hub
    /// did not rewrite hands the input back as it came.
    inputs: Mutex<HashMap<String, Value>>,
    /// claude control request_id -> the MCP elicitation form it asked
    /// (`elicitation.rs`), held until the answer.
    elicitations: Mutex<HashMap<String, elicitation::Form>>,
    next_control: AtomicI64,
    pub session_id: Mutex<Option<String>>,
    pub acp_session_id: String,
    mode: Mutex<String>,
    model: Mutex<String>,
    effort: Mutex<String>,
    /// Claude Code's fast mode (`fastMode`), on or off.
    pub fast: Mutex<bool>,
    in_turn: AtomicBool,
    /// Claude Code wrote something for the prompt (an assistant line, a
    /// conversation reset): its result ends the turn, never startup noise.
    turn_output: AtomicBool,
    /// The `uuid` of the turn's prompt line until Claude Code echoes it
    /// (`isReplay` carries the line's `uuid`).
    prompt_echo: Mutex<Option<String>>,
    /// Prompts still unanswered when the next one went out: acpmux ended
    /// their turn itself (a Stop Claude Code answered late, `hub/cancel.rs`).
    /// Claude Code's result for them comes before it reads the next prompt,
    /// or after its echo but before any of its output.
    abandoned: Mutex<Vec<String>>,
    /// Steered prompts (user lines written during a turn) Claude Code has
    /// not echoed yet, oldest first, as (line uuid, ACP request id): each is
    /// answered at its echo.
    steers: Mutex<std::collections::VecDeque<(String, String)>>,
    /// Each steer's line uuid by the hub's promptId (`_meta.promptId`), so a
    /// withdraw names the line to drop (`steer_withdraw.rs`).
    steer_lines: Mutex<HashMap<String, String>>,
    /// The waiting lines of other sessions' messages, and those being written again with more
    /// (`steer_batch.rs`). Taken before `steers`.
    batches: Mutex<steer_batch::Batches>,
    /// Text streamed so far in the current turn, to build the prompt result.
    pub cancelled: AtomicBool,
    pub slash_commands: Mutex<Vec<Value>>,
    /// The skills Claude Code names in its system/init (`skills`, names
    /// without "/"): their slash commands are tagged as skills.
    skills: Mutex<Vec<String>>,
    /// The `availableCommands` list last sent, so a turn's system/init that
    /// changes nothing sends no new one.
    sent_commands: Mutex<Option<Vec<Value>>>,
    /// Lines for claude's stdin produced while reading its stdout (answers
    /// to control requests acpmux declines). The reader drains them.
    stdin_replies: Mutex<Vec<Value>>,
    /// Running Agent (Task) tool calls: tool_use id -> the subagent session
    /// id their lines stream under.
    subagents: Mutex<HashMap<String, String>>,
    /// Agent tool calls whose subagent runs in the background: their tool
    /// result is only the launch, and their `task_notification` ends them.
    background_subagents: Mutex<HashSet<String>>,
    /// Claude's task ids of running subagents -> their Agent tool call
    /// (`task_updated` names only the task).
    subagent_tasks: Mutex<HashMap<String, String>>,
    /// Subagents that ended failed, oldest first: the agent id SendMessage resumes each by, its
    /// Agent call and its session, so a resume reports that subagent running again.
    failed_agents: Mutex<std::collections::VecDeque<(String, String, String)>>,
    /// Running Workflow tool calls (`workflows.rs`): each run's transcript
    /// dir once its launch named it, and what was last sent of its agents.
    workflows: Mutex<HashMap<String, workflows::WorkflowRun>>,
    /// The chat model's context window as Claude Code last reported it (a
    /// result's `modelUsage`), 0 until then: `usage_update`'s `size`.
    context_window: AtomicU64,
    /// The tokens the chat's context last held (its last `message_delta`; a
    /// compaction resets it).
    context_used: AtomicU64,
    /// A compaction just ended: the synthetic user line Claude writes next
    /// is its summary (`compaction_summary`).
    awaiting_summary: AtomicBool,
    /// Claude Code is compacting the active turn. Compaction can ignore the
    /// interrupt control request, so the hub ends that turn without waiting
    /// for the normal cancel grace period.
    compacting: AtomicBool,
    /// The model id the chat's main loop last ran (its `message_start`): the
    /// `modelUsage` key for its window, which a picker alias is not.
    loop_model: Mutex<String>,
    /// The API message each stream writes now (its `message_start`), by the
    /// Agent tool call of a subagent's stream ("" for the chat's): its text
    /// chunks' `messageId`, so a steer's answer starts its own row (cx-f51kv).
    message_ids: Mutex<HashMap<String, String>>,
    /// The subagents (by Agent tool call) whose text or thinking came as
    /// stream events. Claude Code sends a subagent's output as whole
    /// `assistant` lines only, so for every other subagent those lines carry
    /// its text and thinking; one that streams is not sent them twice.
    streamed_subagents: Mutex<HashSet<String>>,
    /// Running file edits: tool_use id -> their ACP diff content, which their
    /// completion carries again so the diff outlives the tool's text result.
    edits: Mutex<HashMap<String, Value>>,
    /// Tool calls named as their block started (`early_calls.rs`), before
    /// their input streamed: tool_use id -> the session they run in.
    announced: Mutex<HashMap<String, (String, Option<String>)>>,
    /// Running shells by tool_use id (cx-ncc.84): each Bash call until its
    /// result (or, once a `local_bash` task names it, its `task_notification`),
    /// and those in the background (`run_in_background`, or moved there) until
    /// their `task_notification` or Claude's exit ends them.
    background_shells: Mutex<HashMap<String, BackgroundShell>>,
    /// The plan usage limit windows Claude Code reported, newest each, by id
    /// (`usage_limits.rs`).
    usage_limits: Mutex<std::collections::BTreeMap<&'static str, Value>>,
}

/// A running shell: the session its Bash call ran in, its command, Claude's
/// task id once a task event named it, and whether it runs in the background.
#[derive(Debug, Clone)]
struct BackgroundShell {
    sid: String,
    command: String,
    task: Option<String>,
    background: bool,
    /// Started in the background (`run_in_background`), not moved there.
    launched: bool,
    /// The person asked for it to go to the background (`BACKGROUND_TASKS`):
    /// once it moves, its origin is `user_backgrounded`.
    asked: bool,
    /// Its `running` update went out (`inbound.rs` `running`).
    announced: bool,
    /// The file Claude Code writes its output to (`output_file`), once a
    /// task event named it.
    output: Option<String>,
}

#[derive(Debug, Clone)]
enum Pending {
    Initialize,
    NewOrLoad,
    Prompt,
    /// A setting change, applied to the cached value once claude accepts it.
    Control(Setting, String),
    /// A `stop_task` (`STOP_TASK`), answered when claude takes it.
    StopTask,
    /// A `background_tasks` (`BACKGROUND_TASKS`), with the shells it marked
    /// `asked` and when the hub stops waiting for it (its `timeoutMs`):
    /// `end_background_asks` unmarks them when nothing moved, at that
    /// deadline, or when the turn ends.
    Background(Vec<String>, Option<std::time::Instant>),
    /// A steer's take-back (`MUX_STEER_WITHDRAW`), answered when claude takes it.
    Withdraw,
}

#[derive(Debug, Clone, Copy)]
enum Setting {
    Mode,
    Model,
    Effort,
    Fast,
}

impl Translator {
    pub fn new(acp_session_id: String, mode: &str, model: &str, effort: &str) -> Arc<Self> {
        Arc::new(Self {
            pending: Mutex::new(HashMap::new()),
            control_out: Mutex::new(HashMap::new()),
            suggestions: Mutex::new(HashMap::new()),
            inputs: Mutex::new(HashMap::new()),
            elicitations: Mutex::new(HashMap::new()),
            next_control: AtomicI64::new(1),
            session_id: Mutex::new(None),
            acp_session_id,
            mode: Mutex::new(mode.to_owned()),
            model: Mutex::new(model.to_owned()),
            effort: Mutex::new(effort_value(effort).to_owned()),
            fast: Mutex::new(false),
            in_turn: AtomicBool::new(false),
            turn_output: AtomicBool::new(false),
            prompt_echo: Mutex::new(None),
            abandoned: Mutex::new(Vec::new()),
            steers: Mutex::new(std::collections::VecDeque::new()),
            steer_lines: Mutex::new(HashMap::new()),
            batches: Mutex::new(Default::default()),
            cancelled: AtomicBool::new(false),
            slash_commands: Mutex::new(Vec::new()),
            skills: Mutex::new(Vec::new()),
            sent_commands: Mutex::new(None),
            stdin_replies: Mutex::new(Vec::new()),
            subagents: Mutex::new(HashMap::new()),
            background_subagents: Mutex::new(HashSet::new()),
            subagent_tasks: Mutex::new(HashMap::new()),
            failed_agents: Mutex::new(Default::default()),
            workflows: Mutex::new(HashMap::new()),
            background_shells: Mutex::new(HashMap::new()),
            context_window: AtomicU64::new(0),
            context_used: AtomicU64::new(0),
            awaiting_summary: AtomicBool::new(false),
            compacting: AtomicBool::new(false),
            loop_model: Mutex::new(String::new()),
            message_ids: Mutex::new(HashMap::new()),
            streamed_subagents: Mutex::new(HashSet::new()),
            edits: Mutex::new(HashMap::new()),
            announced: Mutex::new(HashMap::new()),
            usage_limits: Mutex::new(Default::default()),
        })
    }

    /// Whether Claude Code has reported that it is currently compacting.
    pub fn is_compacting(&self) -> bool {
        self.compacting.load(Ordering::SeqCst)
    }

    /// Take the lines `inbound` queued for claude's stdin.
    /// Error answers for every ACP request still waiting on Claude, which
    /// are dropped: used when Claude's answer cannot be carried (a line over
    /// the agent host's frame limit), so no turn waits forever.
    pub async fn fail_pending(&self, message: &str) -> Vec<Message> {
        // Under `batches` and `steers`, the order every steer path takes them, and only then
        // `pending`: a withdraw registers its pending entry while it holds `steers`
        // (`steer_withdraw.rs`), so it is either drained here or finds no steer left to take
        // back. A withdrawal reply holds neither lock while it removes its entry.
        let mut batches = self.batches.lock().await;
        // Hold steers while clearing its prompt-id index: an outbound steer either keeps both
        // records or waits until the stale index has been cleared.
        let mut steers = self.steers.lock().await;
        let mut held = Self::end_batches(&mut batches, message);
        let mut ids: Vec<String> = self.pending.lock().await.drain().map(|(id, _)| id).collect();
        ids.extend(steers.drain(..).map(|(_, id)| id));
        self.steer_lines.lock().await.clear();
        drop(steers);
        drop(batches);
        held.extend(ids.into_iter().map(|id| {
            let id: Id = serde_json::from_str(&id).unwrap_or(Value::String(id));
            Message::err(id, RpcError::internal(message))
        }));
        held
    }

    /// Error answers for the steered prompts Claude Code never echoed: the
    /// turn ended without reading them (no echo support).
    async fn fail_steers(&self) -> Vec<Message> {
        let mut batches = self.batches.lock().await;
        let mut steers = self.steers.lock().await;
        // Held for a line being written again, never written: they go in the next turn.
        let held = Self::end_batches(&mut batches, STEER_NO_TURN);
        let failed: Vec<_> = steers.drain(..).collect();
        self.steer_lines.lock().await.clear();
        drop(steers);
        drop(batches);
        let failed = failed.into_iter().map(|(_, id)| {
            let id: Id = serde_json::from_str(&id).unwrap_or(Value::String(id));
            Message::err(
                id,
                RpcError::internal("steer: the turn ended before Claude Code read the message"),
            )
        });
        held.into_iter().chain(failed).collect()
    }

    /// Ends the `background_tasks` requests `ended` picks by ACP id and
    /// deadline (Ctrl-B). When Claude Code `moved` their work, their shells
    /// stay the person's: no other request's end unmarks them. Otherwise
    /// each loses its `asked` mark, unless it is in the background already
    /// (it moved while asked) or a request still waiting names it.
    async fn end_background_asks(
        &self,
        moved: bool,
        ended: impl Fn(&str, Option<std::time::Instant>) -> bool,
    ) {
        let mut pending = self.pending.lock().await;
        let mut shells = Vec::new();
        pending.retain(|id, p| match p {
            Pending::Background(asked, deadline) if ended(id.as_str(), *deadline) => {
                shells.append(asked);
                false
            }
            _ => true,
        });
        let waiting = pending.values_mut().filter_map(|p| match p {
            Pending::Background(asked, _) => Some(asked),
            _ => None,
        });
        if moved {
            for asked in waiting {
                asked.retain(|tool| !shells.contains(tool));
            }
            return;
        }
        let waiting: HashSet<String> = waiting.flat_map(|asked| asked.iter().cloned()).collect();
        drop(pending);
        let mut all = self.background_shells.lock().await;
        for tool in shells.iter().filter(|tool| !waiting.contains(*tool)) {
            if let Some(shell) = all.get_mut(tool).filter(|s| !s.background) {
                shell.asked = false;
            }
        }
    }

    pub async fn take_stdin_replies(&self) -> Vec<Value> {
        std::mem::take(&mut *self.stdin_replies.lock().await)
    }

    /// The `available_commands_update` for Claude's slash commands, an entry
    /// per command with `_meta.kind: "skill"` on a skill's (the pane's picker
    /// labels it "Skill"). Without `always`, a list that is unchanged, or
    /// empty before any was sent, sends nothing.
    async fn commands_update(&self, always: bool) -> Option<Value> {
        let skills = self.skills.lock().await.clone();
        let list: Vec<Value> = self
            .slash_commands
            .lock()
            .await
            .iter()
            .map(|c| {
                let mut entry = json!({"name": c.get("name"), "description": c.get("description")});
                let name = c.get("name").and_then(Value::as_str).unwrap_or("");
                let name = name.strip_prefix('/').unwrap_or(name);
                if !name.is_empty()
                    && skills.iter().any(|s| s.strip_prefix('/').unwrap_or(s.as_str()) == name)
                {
                    entry.set("_meta", json!({"kind": "skill"}));
                }
                entry
            })
            .collect();
        let mut sent = self.sent_commands.lock().await;
        let unchanged = match sent.as_ref() {
            Some(before) => *before == list,
            None => list.is_empty(),
        };
        if !always && unchanged {
            return None;
        }
        *sent = Some(list.clone());
        Some(json!({"sessionUpdate": "available_commands_update", "availableCommands": list}))
    }

    pub async fn modes_value(&self) -> Value {
        json!({
            "currentModeId": *self.mode.lock().await,
            "availableModes": MODES.iter().map(|(id, name, description)| json!({"id": id, "name": name, "description": description})).collect::<Vec<_>>(),
        })
    }

    pub async fn config_options_value(&self) -> Value {
        let effort = self.effort.lock().await.clone();
        json!([
            {"id": "model", "name": "Model", "type": "select", "category": "model", "currentValue": *self.model.lock().await,
             "options": models().iter().map(|(v, n)| json!({"value": v, "name": n})).collect::<Vec<_>>()},
            {"id": "mode", "name": "Permission mode", "type": "select", "category": "mode", "currentValue": *self.mode.lock().await,
             "options": MODES.iter().map(|(v, n, d)| json!({"value": v, "name": n, "description": d})).collect::<Vec<_>>()},
            {"id": "effort", "name": "Reasoning", "type": "select", "category": "thought_level", "currentValue": shown_level(&effort),
             "options": EFFORTS.iter().map(|(v, n)| json!({"value": v, "name": n})).collect::<Vec<_>>()},
            {"id": ULTRACODE_OPTION, "name": "Ultracode", "type": "select", "category": "model_config",
             "currentValue": if effort_value(&effort) == ULTRACODE { "on" } else { "off" },
             "options": [
                 {"value": "off", "name": "Off"},
                 {"value": "on", "name": "On", "description": "Extra High effort plus multi-agent workflow orchestration"},
             ]},
            {"id": "fast-mode", "name": "Fast mode", "type": "select", "category": "model_config",
             "currentValue": if *self.fast.lock().await { "on" } else { "off" },
             "options": [
                 {"value": "off", "name": "Off", "description": "Default speed, normal usage"},
                 {"value": "on", "name": "On", "description": "Faster output, increased usage"},
             ]},
        ])
    }
}

/// A Claude Code `tool_use` as the fields of the ACP `tool_call` a turn sends for it (without
/// its id and status): kind, title, input, and an edit's diffs and file. A live turn
/// (`inbound.rs`) and an adopted chat's past turns (`adopt_tools.rs`) both draw calls from it.
pub(crate) fn tool_call_fields(name: &str, input: &Value) -> Value {
    let mut call = json!({
        "title": tool_title(name, input),
        "kind": tool_kind(name),
        "rawInput": input,
        "_meta": {"claude": {"tool": name}}
    });
    with_edit(&mut call, name, input);
    call
}

/// Adds a file edit's diff and location to its ACP tool call.
fn with_edit(call: &mut Value, name: &str, input: &Value) {
    if let Some(diffs) = edit_diffs(name, input) {
        call.set("content", diffs);
        if let Some(locations) = tool_locations(input) {
            call.set("locations", locations);
        }
    }
}

fn tool_kind(name: &str) -> &'static str {
    match name {
        "Read" | "Glob" | "Grep" | "NotebookRead" => "read",
        "Write" | "Edit" | "MultiEdit" | "NotebookEdit" => "edit",
        "Bash" | "BashOutput" | "KillShell" => "execute",
        "WebFetch" | "WebSearch" => "fetch",
        "Task" | "Agent" => "think",
        "AskUserQuestion" | "ExitPlanMode" => "other",
        _ => "other",
    }
}

/// A file edit's ACP `diff` content: one diff per Edit or MultiEdit
/// replacement, and Write as the whole file (no old text). None for any other
/// tool, or input without a path. A Write is marked a fragment until its result
/// says what it did (`settle_write`): a diff with no old text reads as a file the
/// turn created, which Undo moves to the Trash, and a Write over a file that was
/// there, or one whose result never arrives, must not read that way.
fn edit_diffs(name: &str, input: &Value) -> Option<Value> {
    let path = input.get("file_path").and_then(Value::as_str)?;
    let diff = |old: Option<&Value>, new: Option<&Value>| json!({"type": "diff", "path": path, "oldText": old.cloned().unwrap_or(Value::Null), "newText": new.cloned().unwrap_or_else(|| json!(""))});
    let diffs: Vec<Value> = match name {
        "Edit" => vec![diff(input.get("old_string"), input.get("new_string"))],
        "MultiEdit" => input
            .get("edits")
            .and_then(Value::as_array)?
            .iter()
            .map(|e| diff(e.get("old_string"), e.get("new_string")))
            .collect(),
        "Write" => {
            let mut write = diff(None, input.get("content"));
            write.set("_meta", json!({"acpmux": {"fragment": true}}));
            vec![write]
        }
        _ => return None,
    };
    Some(Value::Array(diffs))
}

/// The most of a Write's old text a settled diff carries: a bigger file stays a
/// fragment rather than doubling a multi-megabyte update (as adopt's limit).
const MAX_WRITE_OLD_TEXT: usize = 64_000;

/// A finished Write's diff, sent as a fragment with no old text (`edit_diffs`)
/// before Claude Code said whether the file was there. `result` is Claude Code's
/// structured result (`tool_use_result` live, `toolUseResult` in a transcript),
/// `text` the tool_result's text. A Write that created its file loses the
/// fragment mark: it reads as new, and Undo may trash it. An overwrite whose
/// result names this file and holds its old text (`originalFile`, within the
/// limit) takes that text and loses the mark. Anything else stays a fragment, so
/// nothing is written back from it.
pub(crate) fn settle_write(mut diffs: Value, text: &str, result: Option<&Value>) -> Value {
    let field = |key: &str| result.and_then(|r| r.get(key)).and_then(Value::as_str);
    let Some(items) = diffs.as_array_mut() else { return diffs };
    let held = |d: &Value| {
        d.get("oldText").is_some_and(Value::is_null)
            && d.pointer("/_meta/acpmux/fragment") == Some(&json!(true))
    };
    for diff in items.iter_mut().filter(|d| held(d)) {
        let ours = field("filePath").is_some()
            && field("filePath") == diff.get("path").and_then(Value::as_str);
        let created = if ours && field("type").is_some() {
            field("type") == Some("create")
        } else {
            text.trim_start().starts_with("File created successfully")
        };
        let original = field("originalFile").filter(|o| ours && o.len() <= MAX_WRITE_OLD_TEXT);
        if !created && original.is_none() {
            continue;
        }
        if let Some(original) = original.filter(|_| !created) {
            diff.set("oldText", json!(original));
        }
        if let Some(fields) = diff.as_object_mut() {
            fields.remove("_meta");
        }
    }
    diffs
}

/// The file a tool reads or writes, as ACP `locations`.
fn tool_locations(input: &Value) -> Option<Value> {
    let path = input.get("file_path").and_then(Value::as_str)?;
    Some(json!([{"path": path}]))
}

fn tool_title(name: &str, input: &Value) -> String {
    let s = |k: &str| input.get(k).and_then(Value::as_str).map(str::to_owned);
    match name {
        "Bash" => s("command")
            .map(|c| c.lines().next().unwrap_or("").chars().take(120).collect())
            .unwrap_or_else(|| "Bash".into()),
        "Read" | "Write" | "Edit" | "MultiEdit" => format!(
            "{name} {}",
            s("file_path")
                .map(|p| Path::new(&p)
                    .file_name()
                    .map(|f| f.to_string_lossy().into_owned())
                    .unwrap_or(p))
                .unwrap_or_default()
        ),
        "Glob" | "Grep" => format!("{name} {}", s("pattern").unwrap_or_default()),
        "WebFetch" => format!("Fetch {}", s("url").unwrap_or_default()),
        "WebSearch" => format!("Search {}", s("query").unwrap_or_default()),
        "Task" | "Agent" => format!("Agent: {}", s("description").unwrap_or_default()),
        "AskUserQuestion" => input
            .pointer("/questions/0/question")
            .and_then(Value::as_str)
            .map(|q| format!("Question: {q}"))
            .unwrap_or_else(|| "Question".into()),
        "ExitPlanMode" => "Approve plan".into(),
        _ => name.to_owned(),
    }
}

/// Whether a raw Claude line answers the `get_context_usage` a turn's result
/// asked (`ctx-*`); its trimmed breakdown is what acpmux keeps.
pub fn is_context_answer(line: &Value) -> bool {
    line.pointer("/response/request_id")
        .and_then(Value::as_str)
        .is_some_and(|id| id.starts_with("ctx-"))
}

/// Claude Code's answer to `get_context_usage` (its `/context`), trimmed to
/// what a client draws: each category's tokens and kind, the memory files,
/// MCP tools and skills by size (at most `BREAKDOWN_ROWS` of each, the
/// largest), and the totals; no grid or colors. None without categories: a
/// Claude Code too old to answer, or one that answered something else.
pub(super) fn context_breakdown(usage: &Value) -> Option<Value> {
    let categories = usage.get("categories")?.as_array()?;
    let count = |v: &Value, key: &str| v.get(key).and_then(Value::as_u64).unwrap_or(0);
    let tokens = |v: &Value| count(v, "tokens");
    let rows = |list: Option<&Value>, fields: &[&str]| -> Vec<Value> {
        let mut rows: Vec<Value> = list
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .map(|row| {
                let mut kept = serde_json::Map::new();
                for field in fields {
                    if let Some(v) = row.get(*field).filter(|v| v.is_string()) {
                        kept.insert((*field).into(), v.clone());
                    }
                }
                kept.insert("tokens".into(), json!(tokens(row)));
                Value::Object(kept)
            })
            .collect();
        rows.sort_by_key(|row| std::cmp::Reverse(tokens(row)));
        rows.truncate(BREAKDOWN_ROWS);
        rows
    };
    // Claude Code names a dozen; the bound keeps a misbehaving answer out of the log.
    let categories: Vec<Value> = categories
        .iter()
        .take(BREAKDOWN_ROWS)
        .map(|c| {
            let mut kept =
                json!({"name": c.get("name"), "tokens": tokens(c), "kind": c.get("kind")});
            if let Some(id) = c.get("id").filter(|id| id.is_string()) {
                kept["id"] = id.clone();
            }
            kept
        })
        .collect();
    let mut breakdown = json!({
        "categories": categories,
        "memoryFiles": rows(usage.get("memoryFiles"), &["path", "type"]),
        "mcpTools": rows(usage.get("mcpTools"), &["name", "serverName"]),
        "totalTokens": count(usage, "totalTokens"),
        "maxTokens": count(usage, "maxTokens"),
    });
    // Claude Code names its skills only when they take context.
    if let Some(skills) = usage.pointer("/skills/skillFrontmatter").filter(|s| s.is_array()) {
        breakdown["skills"] = json!(rows(Some(skills), &["name"]));
    }
    Some(breakdown)
}

/// Claude's permission suggestions as session-only permission updates: each
/// allow rule kept, its destination `session`. None when none is an allow.
pub(super) fn session_rules(suggestions: &Value) -> Option<Value> {
    let rules: Vec<Value> = suggestions
        .as_array()?
        .iter()
        .filter(|s| {
            s.get("type").and_then(Value::as_str) == Some("addRules")
                && s.get("behavior").and_then(Value::as_str) == Some("allow")
        })
        .map(|s| {
            let mut s = s.clone();
            s.set("destination", json!("session"));
            s
        })
        .collect();
    (!rules.is_empty()).then_some(Value::Array(rules))
}
