//! Claude's dynamic workflows and the live progress of its background tasks.
//!
//! A Workflow tool call runs a script of many agents in the background
//! (code.claude.com/docs/en/workflows): it is a background subagent of kind
//! `workflow`, its tool result is only the launch (naming the run and its
//! transcript dir), and its `task_notification` ends it. Claude's
//! `task_progress` lines, for a workflow and a subagent alike, become
//! `subagent_progress` updates: tokens, tool uses, elapsed time, what it is
//! doing now and, for a workflow, how many of its agents returned.
//!
//! A workflow's `task_progress` carries the run's whole state now and then
//! (`workflow_progress`: one item per phase and per agent, Claude Code
//! 2.1.30x; its own `/workflows` board and remote viewer draw from it). The
//! snapshot is sent when an agent starts or ends, and at least every 10
//! seconds while agents work; the lines between, every 16 ms at most, carry
//! only usage. Each snapshot repeats every agent so far (about 1 KB each), so
//! the update sends only what changed since the last one: the run's
//! `phases` when they change, and in `workflowAgents` each agent whose
//! fields changed, with only those fields (`WorkflowRun::delta`). A client
//! merges them by the workflow's `subagentSessionId` and the agent's `index`:
//! a resumed run is a new task, so a new subagent, with the same `runId`.
//! When the run ends, its last update carries its final usage and every
//! agent whole (`workflowAgentsFull`), so a reader that never saw the run's
//! start (a page of recent history) still has each agent.

use super::*;
use crate::no_panic::JsonExt;
use serde_json::Map;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// The most of a workflow journal read at once for its agent counts.
const JOURNAL_BYTES: u64 = 4 << 20;

/// The least time between two updates of a workflow when a progress line
/// changes only its usage (Claude sends one every 16 ms while agents stream).
const USAGE_EVERY: Duration = Duration::from_secs(1);

/// The longest prompt, result or error preview of a workflow agent sent.
const PREVIEW_CHARS: usize = 240;
/// The folded head a preview is masked from, and the most of its source read.
const PREVIEW_HEAD: usize = PREVIEW_CHARS * 8;
const PREVIEW_SCAN: usize = PREVIEW_CHARS * 64;

/// One running Workflow tool call (`Translator::workflows`).
#[derive(Debug, Default)]
pub(super) struct WorkflowRun {
    /// The run's transcript dir, once its launch named it.
    dir: Option<PathBuf>,
    /// Each agent's item as last seen and its fields as last sent, by
    /// Claude's agent index.
    agents: HashMap<u64, (Value, Map<String, Value>)>,
    /// The phases as last sent.
    phases: Vec<Value>,
    /// The agent counts of the latest snapshot; until one came, none, and
    /// the journal's are read (`journal`).
    counts: Option<Value>,
    /// How far the run's journal was read, and what it counted.
    journal: JournalTail,
    /// When the last update went out.
    sent: Option<Instant>,
    /// A digest of the Workflow call's `args` (`args_digest`): never the args, which may hold
    /// anything; two runs with the same digest ran with the same args.
    args_digest: Option<String>,
    /// The run's id and script path from its launch, which its end sends again (`resume`).
    run_id: Option<String>,
    script_path: Option<String>,
}

/// What a run's `journal.jsonl` said up to `offset`: how many agents started
/// and how many returned.
#[derive(Debug, Default, Clone)]
struct JournalTail {
    offset: u64,
    done: usize,
    started: usize,
}

/// The agents and phases one update carries (`WorkflowRun::delta`,
/// `WorkflowRun::whole`).
struct Rows {
    phases: Option<Vec<Value>>,
    agents: Vec<Value>,
    /// Every agent, each whole: a client replaces what it had.
    full: bool,
}

impl WorkflowRun {
    /// A run for a Workflow call's `input`, keeping a digest of its `args`.
    pub(super) fn new(input: &Value) -> Self {
        Self { args_digest: input.get("args").and_then(args_digest), ..Self::default() }
    }
}

impl Translator {
    /// A Workflow call's tool result: its launch. The run's name and summary
    /// as a `subagent_progress`, or, when the script failed its check and
    /// never ran, the subagent's end as failed.
    pub(super) async fn workflow_launched(
        &self,
        tool: &str,
        is_err: bool,
        line: &Value,
    ) -> Option<Value> {
        if !self.workflows.lock().await.contains_key(tool) {
            return None;
        }
        let launch = line.get("tool_use_result");
        let text = |key: &str| {
            launch.and_then(|l| l.get(key)).and_then(Value::as_str).filter(|v| !v.is_empty())
        };
        let child = self.subagents.lock().await.get(tool)?.clone();
        if is_err || text("error").is_some() {
            self.workflows.lock().await.remove(tool);
            self.background_subagents.lock().await.remove(tool);
            self.subagents.lock().await.remove(tool);
            self.subagent_tasks.lock().await.retain(|_, t| t != tool);
            return Some(json!({
                "sessionUpdate": "subagent_state_update",
                "subagentSessionId": child,
                "state": "failed",
            }));
        }
        if let Some(task) = text("taskId") {
            self.subagent_tasks.lock().await.insert(task.to_owned(), tool.to_owned());
        }
        let digest = match self.workflows.lock().await.get_mut(tool) {
            Some(run) => {
                if let Some(dir) = text("transcriptDir") {
                    run.dir = Some(PathBuf::from(dir));
                }
                run.run_id = text("runId").map(str::to_owned);
                run.script_path = text("scriptPath").map(str::to_owned);
                run.args_digest.clone()
            }
            None => None,
        };
        let mut update = json!({"sessionUpdate": "subagent_progress", "subagentSessionId": child});
        // What a resume names again (`Workflow({scriptPath, resumeFromRunId, args})`): the script
        // path Claude Code returned, the only kind it takes back. The args are never sent (they
        // may hold anything, and updates are not masked): the agent that launched the run has them,
        // and a digest says whether two runs had the same.
        if let Some(path) = text("scriptPath") {
            update.set("scriptPath", json!(path));
        }
        if let Some(digest) = digest {
            update.set("argsDigest", json!(digest));
        }
        if let Some(name) = text("workflowName") {
            update.set("name", json!(name));
        }
        // The run's id (`wf_…`), which a resume of it names again.
        if let Some(run) = text("runId") {
            update.set("runId", json!(run));
        }
        if let Some(summary) = text("summary") {
            update.set("task", json!(summary));
        }
        Some(update)
    }

    /// A `task_progress` line of a running subagent or workflow as its
    /// `subagent_progress`. A workflow's action is its current step
    /// (`<phase>: <agent>`); a subagent's is its progress summary, else its
    /// last tool. A workflow's line with no snapshot that comes within
    /// `USAGE_EVERY` of its last update sends none. A workflow's end (its
    /// `task_notification`, or a `task_updated` that ends it) sends its
    /// final usage and every agent whole, before the end itself
    /// (`subagent_task`).
    pub(super) async fn subagent_progress(&self, sub: &str, line: &Value) -> Option<Value> {
        let ending =
            sub == "task_notification" || (sub == "task_updated" && ended_status(line).is_some());
        if sub != "task_progress" && !ending {
            return None;
        }
        let text = |key: &str| line.get(key).and_then(Value::as_str).filter(|v| !v.is_empty());
        let tool = self.task_tool(line).await?;
        let child = self.subagents.lock().await.get(&tool)?.clone();
        let snapshot = line.get("workflow_progress").and_then(Value::as_array);
        let (workflow, journal, rows, resume) = {
            let mut runs = self.workflows.lock().await;
            match runs.get_mut(&tool) {
                Some(run) => {
                    let now = Instant::now();
                    let usage_only = !ending && snapshot.is_none();
                    if usage_only && run.sent.is_some_and(|at| now - at < USAGE_EVERY) {
                        return None;
                    }
                    run.sent = Some(now);
                    let rows = snapshot.map(|items| run.delta(items));
                    let rows = if ending { Some(run.whole()) } else { rows };
                    // The journal is read only until the first snapshot gives the counts.
                    let journal = match (&run.counts, &run.dir) {
                        (None, Some(dir)) => Some((dir.clone(), run.journal.clone())),
                        _ => None,
                    };
                    let resume = ending.then(|| run.resume());
                    (Some(run.counts.clone()), journal, rows, resume)
                }
                // A background agent's end is its state alone.
                None if ending => return None,
                None => (None, None, None, None),
            }
        };
        let usage = |key: &str| line.pointer(&format!("/usage/{key}")).and_then(Value::as_u64);
        let mut update = json!({"sessionUpdate": "subagent_progress", "subagentSessionId": child});
        for (key, value) in [
            ("tokens", usage("total_tokens")),
            ("toolUses", usage("tool_uses")),
            ("elapsedMs", usage("duration_ms")),
        ] {
            if let Some(value) = value {
                update.set(key, json!(value));
            }
        }
        let action = match &workflow {
            Some(_) if ending => None,
            Some(_) => text("description"),
            None => text("summary").or(text("last_tool_name")),
        };
        if let Some(action) = action {
            update.set("action", json!(action));
        }
        // A run's end repeats what a resume names, for a reader of recent history alone.
        for (key, value) in resume.unwrap_or_default() {
            update.set(&key, value);
        }
        if let Some(rows) = rows {
            if let Some(phases) = rows.phases {
                update.set("phases", Value::Array(phases));
            }
            if !rows.agents.is_empty() {
                update.set("workflowAgents", Value::Array(rows.agents));
                if rows.full {
                    update.set("workflowAgentsFull", json!(true));
                }
            }
        }
        let counts = match (journal, workflow.flatten()) {
            (_, Some(counts)) => Some(counts),
            // Off the stdout loop, and only what was written since the last read.
            (Some((dir, tail)), None) => {
                let read =
                    tokio::task::spawn_blocking(move || tail.read(&dir)).await.ok().flatten();
                match read {
                    Some(tail) => {
                        let counts = json!({"done": tail.done, "started": tail.started});
                        if let Some(run) = self.workflows.lock().await.get_mut(&tool) {
                            run.journal = tail;
                        }
                        Some(counts)
                    }
                    None => None,
                }
            }
            (None, None) => None,
        };
        if let Some(counts) = counts {
            update.set("agents", counts);
        }
        Some(update)
    }

    /// `_acpmux/subagent_stop`: Claude's `stop_task` for the subagent's
    /// task. Claude's answer (`stop_reply`) answers the request; the task's
    /// `task_notification` then ends the subagent as stopped.
    pub(super) async fn subagent_stop(&self, id: &Id, p: &Value) -> Outbound {
        let child = p.get("subagentSessionId").and_then(Value::as_str).unwrap_or("");
        let subagents = self.subagents.lock().await;
        let tool =
            subagents.iter().find(|(_, c)| c.as_str() == child).map(|(tool, _)| tool.clone());
        drop(subagents);
        let tasks = self.subagent_tasks.lock().await;
        let task = tool.and_then(|tool| {
            tasks.iter().find(|(_, t)| t.as_str() == tool).map(|(k, _)| k.clone())
        });
        drop(tasks);
        match task {
            Some(task) => Outbound::Lines(vec![json!({"type": "control_request",
                "request_id": format!("stop-{id}"), "request": {"subtype": "stop_task", "task_id": task}})]),
            None => Outbound::Reply(Message::err(
                id.clone(),
                RpcError::invalid_params(format!("no running subagent {child}")),
            )),
        }
    }
}

impl WorkflowRun {
    /// What a `workflow_progress` snapshot changed since the last one sent:
    /// the phases (`{index, title}`) when they changed, and each agent whose
    /// fields changed as its `index` and those fields (one it no longer has
    /// as null). Takes the snapshot's agent counts too: `done` and `started`
    /// as the journal counts them (an agent that failed before it started did
    /// not start), with `failed` and `queued` when any.
    fn delta(&mut self, items: &[Value]) -> Rows {
        let (mut phases, mut agents) = (Vec::new(), Vec::new());
        let (mut done, mut failed, mut started, mut queued) = (0, 0, 0, 0);
        for item in items {
            let Some(index) = item.get("index").and_then(Value::as_u64) else { continue };
            match item.get("type").and_then(Value::as_str) {
                Some("workflow_phase") => {
                    let title = item.get("title").and_then(Value::as_str).unwrap_or_default();
                    phases.push(json!({"index": index, "title": title}));
                }
                Some("workflow_agent") => {
                    let (seen, sent) = self.agents.entry(index).or_default();
                    // A finished agent's item stays the same: nothing to map or mask again.
                    if *seen != *item {
                        let fields = agent_fields(item);
                        let mut changed: Map<String, Value> = fields
                            .iter()
                            .filter(|(key, value)| sent.get(*key) != Some(*value))
                            .map(|(key, value)| (key.clone(), value.clone()))
                            .collect();
                        for key in sent.keys().filter(|key| !fields.contains_key(*key)) {
                            changed.insert(key.clone(), Value::Null);
                        }
                        if !changed.is_empty() {
                            changed.insert("index".into(), json!(index));
                            agents.push(Value::Object(changed));
                        }
                        *seen = item.clone();
                        *sent = fields;
                    }
                    let state = sent.get("state").and_then(Value::as_str);
                    let began = sent.contains_key("startedAt")
                        || matches!(state, Some("running" | "completed"));
                    match state {
                        Some("queued") => queued += 1,
                        _ if began => started += 1,
                        _ => {}
                    }
                    match state {
                        Some("completed") => done += 1,
                        Some("failed" | "skipped" | "blocked") => failed += 1,
                        _ => {}
                    }
                }
                _ => {}
            }
        }
        phases.sort_by_key(|phase| phase.get("index").and_then(Value::as_u64));
        let phases = (phases != self.phases).then(|| {
            self.phases = phases.clone();
            phases
        });
        let mut counts = json!({"done": done, "started": started});
        if failed > 0 {
            counts.set("failed", json!(failed));
        }
        if queued > 0 {
            counts.set("queued", json!(queued));
        }
        self.counts = Some(counts);
        Rows { phases, agents, full: false }
    }

    /// What a resume of the run names (`runId`, `scriptPath`), and its args'
    /// digest, as its launch sent them: its last update repeats them.
    fn resume(&self) -> Vec<(String, Value)> {
        let mut out = Vec::new();
        if let Some(run) = &self.run_id {
            out.push(("runId".to_owned(), json!(run)));
        }
        if let Some(path) = &self.script_path {
            out.push(("scriptPath".to_owned(), json!(path)));
        }
        if let Some(digest) = &self.args_digest {
            out.push(("argsDigest".to_owned(), json!(digest)));
        }
        out
    }

    /// Every agent as last sent, each whole, and the phases: a run's last
    /// update, for a reader that has not seen it from its start.
    fn whole(&self) -> Rows {
        let mut agents: Vec<(u64, Value)> = self
            .agents
            .iter()
            .map(|(index, (_, sent))| {
                let mut fields = sent.clone();
                fields.insert("index".into(), json!(index));
                (*index, Value::Object(fields))
            })
            .collect();
        agents.sort_by_key(|(index, _)| *index);
        let phases = (!self.phases.is_empty()).then(|| self.phases.clone());
        Rows { phases, agents: agents.into_iter().map(|(_, agent)| agent).collect(), full: true }
    }
}

/// One `workflow_agent` item as the fields acpmux sends: Claude's names as
/// the subagent model's (`subagents.rs`), its state one of `queued`,
/// `running`, `completed`, `failed`, `skipped` or `blocked` (or Claude's own
/// word for a state it adds later), and its prompt,
/// result, error and action as previews (`preview`). `tokens` is what its
/// latest request held, as Claude Code's board counts it, not its spend.
fn agent_fields(item: &Value) -> Map<String, Value> {
    let s = |key: &str| item.get(key).and_then(Value::as_str).filter(|v| !v.is_empty());
    let n = |key: &str| {
        item.get(key).and_then(Value::as_f64).filter(|v| *v >= 0.0).map(|v| v.round() as u64)
    };
    let flag = |key: &str| item.get(key).and_then(Value::as_bool) == Some(true);
    let state = match s("state") {
        Some("done") => "completed",
        Some("error") if flag("skipped") => "skipped",
        Some("error") if flag("blocked") => "blocked",
        Some("error") => "failed",
        Some("start" | "progress") | None
            if n("queuedAt").is_some() && n("startedAt").is_none() =>
        {
            "queued"
        }
        Some("start" | "progress") | None => "running",
        // A state this acpmux does not know, as Claude names it: never a guess.
        Some(other) => other,
    };
    let mut out = Map::new();
    out.insert("state".into(), json!(state));
    for (from, to) in [
        ("label", "label"),
        ("phaseTitle", "phase"),
        ("agentId", "agentId"),
        ("agentType", "kind"),
        ("model", "model"),
        ("fallbackModel", "fallbackModel"),
        ("isolation", "isolation"),
        ("remoteSessionId", "remoteSessionId"),
        ("lastAttemptReason", "retryReason"),
    ] {
        if let Some(value) = s(from) {
            out.insert(to.into(), json!(value));
        }
    }
    for (from, to) in [
        ("phaseIndex", "phaseIndex"),
        ("tokens", "tokens"),
        ("toolCalls", "toolUses"),
        ("durationMs", "elapsedMs"),
        ("queuedAt", "queuedAt"),
        ("startedAt", "startedAt"),
        ("lastProgressAt", "lastProgressAt"),
        ("attempt", "attempt"),
    ] {
        if let Some(value) = n(from) {
            out.insert(to.into(), json!(value));
        }
    }
    if flag("cached") {
        out.insert("cached".into(), json!(true));
    }
    if let Some(action) = s("lastToolSummary").or(s("lastToolName")) {
        out.insert("action".into(), json!(preview(action)));
    }
    for (from, to) in [("promptPreview", "prompt"), ("resultPreview", "result"), ("error", "error")]
    {
        if let Some(value) = s(from) {
            out.insert(to.into(), json!(preview(value)));
        }
    }
    out
}

/// A preview as sent: secrets masked, whitespace folded, at most `PREVIEW_CHARS` characters. At
/// most `PREVIEW_SCAN` characters of `text` are read, folded as they come; a word the read
/// stopped inside is left out, since part of a token could be part of a secret. The folded head
/// (at most `PREVIEW_HEAD`) is masked and then cut, so a cut never leaves part of a secret
/// unmasked (`hub/views.rs` `masked_line`).
fn preview(text: &str) -> String {
    let (mut head, mut word, mut chars) = (String::new(), String::new(), 0usize);
    let mut rest = text.chars();
    for _ in 0..PREVIEW_SCAN {
        match rest.next() {
            None => break,
            Some(c) if c.is_whitespace() => {
                fold_word(&mut head, &mut word, &mut chars);
                if chars >= PREVIEW_HEAD {
                    break;
                }
            }
            Some(c) => word.push(c),
        }
    }
    if rest.next().is_none() {
        fold_word(&mut head, &mut word, &mut chars);
    }
    let text = crate::secret_scan::mask(&head);
    if text.chars().count() <= PREVIEW_CHARS {
        return text;
    }
    let mut out: String = text.chars().take(PREVIEW_CHARS).collect();
    out.push('…');
    out
}

/// Moves `word` onto `head` after a space, up to `PREVIEW_HEAD` characters in all.
fn fold_word(head: &mut String, word: &mut String, chars: &mut usize) {
    if word.is_empty() {
        return;
    }
    if *chars > 0 {
        head.push(' ');
        *chars += 1;
    }
    let taken: String = word.chars().take(PREVIEW_HEAD.saturating_sub(*chars)).collect();
    *chars += taken.chars().count();
    head.push_str(&taken);
    word.clear();
}

/// A digest of a Workflow call's `args`: the first 16 bytes of an HMAC-SHA-256 of their JSON under
/// a key this daemon draws at random once (`ARGS_KEY`), as hex. Two runs with the same args on this
/// daemon have the same digest; nothing outside it can test a guess at the args against it. None
/// for null args, or when the OS gives no randomness.
fn args_digest(args: &Value) -> Option<String> {
    if args.is_null() {
        return None;
    }
    let key = ARGS_KEY.get_or_init(|| {
        let mut key = [0u8; 32];
        getrandom::fill(&mut key).ok().map(|()| key)
    });
    let mac =
        cmux_local_auth::frontend_proof::hmac_sha256(key.as_ref()?, args.to_string().as_bytes());
    Some(cmux_local_auth::frontend_proof::hex(mac.get(..16)?))
}

/// The key of `args_digest`, drawn once per daemon process; None when the OS gave no randomness.
static ARGS_KEY: std::sync::OnceLock<Option<[u8; 32]>> = std::sync::OnceLock::new();

/// Claude's answer to a `stop-<id>` control request as the reply to request `<id>`.
pub(super) fn stop_reply(acp: &str, ok: bool, resp: &Value) -> Message {
    let id: Id = serde_json::from_str(acp).unwrap_or(Value::String(acp.to_owned()));
    if ok {
        return Message::ok(id, json!({}));
    }
    let why = resp.get("error").and_then(Value::as_str).unwrap_or("Claude did not stop the task");
    Message::err(id, RpcError::internal(why))
}

/// The status a `task_updated` line ends its task with when no notification will (`patch.status`
/// `paused`, which Claude Code sends no notification after, or `killed`), if it does. A completed
/// or failed task ends with its notification, which carries its final usage and result.
pub(super) fn ended_status(line: &Value) -> Option<&str> {
    line.pointer("/patch/status")
        .and_then(Value::as_str)
        .filter(|status| matches!(*status, "killed" | "paused"))
}

impl JournalTail {
    /// The counts with the journal lines written since `offset` added: whole
    /// lines only (one still being written is read next time), at most
    /// `JOURNAL_BYTES` a read, so a big run's journal is read once in all.
    fn read(mut self, dir: &Path) -> Option<Self> {
        use std::io::{Read, Seek, SeekFrom};
        let mut file = std::fs::File::open(dir.join("journal.jsonl")).ok()?;
        file.seek(SeekFrom::Start(self.offset)).ok()?;
        let mut bytes = Vec::new();
        file.take(JOURNAL_BYTES).read_to_end(&mut bytes).ok()?;
        let whole = match bytes.iter().rposition(|b| *b == b'\n') {
            Some(end) => end + 1,
            // One line longer than a read: skip it rather than stall on it.
            None if bytes.len() as u64 == JOURNAL_BYTES => bytes.len(),
            None => 0,
        };
        bytes.truncate(whole);
        for line in bytes.split(|b| *b == b'\n') {
            match serde_json::from_slice::<Value>(line)
                .ok()
                .as_ref()
                .and_then(|v| v.get("type"))
                .and_then(Value::as_str)
            {
                Some("started") => self.started += 1,
                Some("result") => self.done += 1,
                _ => {}
            }
        }
        self.offset += whole as u64;
        Some(self)
    }
}

#[cfg(test)]
mod journal_tests {
    use super::*;
    use std::io::Write;

    /// The journal is read from where the last read stopped, whole lines only.
    #[test]
    fn the_journal_is_read_once_in_all() {
        let dir = std::env::temp_dir().join(format!("acpmux-wf-tail-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("journal.jsonl");
        std::fs::write(
            &path,
            "{\"type\":\"launched\"}\n{\"type\":\"started\"}\n{\"type\":\"started\"}\n",
        )
        .unwrap();
        let tail = JournalTail::default().read(&dir).unwrap();
        assert_eq!((tail.started, tail.done), (2, 0));
        // A line still being written is left for the next read.
        let mut file = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        file.write_all(b"{\"type\":\"result\"}\n{\"type\":\"res").unwrap();
        let tail = tail.read(&dir).unwrap();
        assert_eq!((tail.started, tail.done), (2, 1));
        file.write_all(b"ult\"}\n").unwrap();
        let tail = tail.read(&dir).unwrap();
        assert_eq!((tail.started, tail.done), (2, 2));
        assert_eq!(tail.offset, std::fs::metadata(&path).unwrap().len());
        let _ = std::fs::remove_dir_all(dir);
    }
}
