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
//! merges them by `index`.

use super::*;
use crate::no_panic::JsonExt;
use serde_json::Map;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// The largest workflow journal read for its agent counts (a run has at most
/// 1,000 agents, two short lines each).
const JOURNAL_BYTES: u64 = 4 << 20;

/// The least time between two updates of a workflow when a progress line
/// changes only its usage (Claude sends one every 16 ms while agents stream).
const USAGE_EVERY: Duration = Duration::from_secs(1);

/// The longest prompt, result or error preview of a workflow agent sent.
const PREVIEW_CHARS: usize = 240;

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
    /// The agent counts of the latest snapshot; until one came, the journal's.
    counts: Option<Value>,
    /// When the last update went out.
    sent: Option<Instant>,
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
        if let Some(dir) = text("transcriptDir")
            && let Some(run) = self.workflows.lock().await.get_mut(tool)
        {
            run.dir = Some(PathBuf::from(dir));
        }
        let mut update = json!({"sessionUpdate": "subagent_progress", "subagentSessionId": child});
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
    /// `USAGE_EVERY` of its last update sends none.
    pub(super) async fn subagent_progress(&self, sub: &str, line: &Value) -> Option<Value> {
        if sub != "task_progress" {
            return None;
        }
        let text = |key: &str| line.get(key).and_then(Value::as_str).filter(|v| !v.is_empty());
        let tool = match text("tool_use_id") {
            Some(tool) => tool.to_owned(),
            None => self.subagent_tasks.lock().await.get(text("task_id")?)?.clone(),
        };
        let child = self.subagents.lock().await.get(&tool)?.clone();
        let snapshot = line.get("workflow_progress").and_then(Value::as_array);
        // The journal is read only until the first snapshot gives the counts.
        let (workflow, journal, rows) = {
            let mut runs = self.workflows.lock().await;
            match runs.get_mut(&tool) {
                Some(run) => {
                    let now = Instant::now();
                    if snapshot.is_none() && run.sent.is_some_and(|at| now - at < USAGE_EVERY) {
                        return None;
                    }
                    run.sent = Some(now);
                    let rows = snapshot.map(|items| run.delta(items));
                    let journal = run.counts.is_none().then(|| run.dir.clone()).flatten();
                    (Some(run.counts.clone()), journal, rows)
                }
                None => (None, None, None),
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
            Some(_) => text("description"),
            None => text("summary").or(text("last_tool_name")),
        };
        if let Some(action) = action {
            update.set("action", json!(action));
        }
        if let Some((phases, agents)) = rows {
            if let Some(phases) = phases {
                update.set("phases", Value::Array(phases));
            }
            if !agents.is_empty() {
                update.set("workflowAgents", Value::Array(agents));
            }
        }
        let counts = match (journal, workflow.flatten()) {
            (_, Some(counts)) => Some(counts),
            // Off the stdout loop: a big run's journal is megabytes.
            (Some(dir), None) => tokio::task::spawn_blocking(move || journal_counts(&dir))
                .await
                .ok()
                .flatten()
                .map(|(done, started)| json!({"done": done, "started": started})),
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
    /// as the journal counts them, with `failed` and `queued` when any.
    fn delta(&mut self, items: &[Value]) -> (Option<Vec<Value>>, Vec<Value>) {
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
                    match sent.get("state").and_then(Value::as_str) {
                        Some("queued") => queued += 1,
                        state => {
                            started += 1;
                            match state {
                                Some("completed") => done += 1,
                                Some("failed" | "skipped" | "blocked") => failed += 1,
                                _ => {}
                            }
                        }
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
        (phases, agents)
    }
}

/// One `workflow_agent` item as the fields acpmux sends: Claude's names as
/// the subagent model's (`subagents.rs`), its state one of `queued`,
/// `running`, `completed`, `failed`, `skipped` or `blocked`, and its prompt,
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
        _ if n("queuedAt").is_some() && n("startedAt").is_none() => "queued",
        _ => "running",
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

/// A preview as sent: secrets masked, whitespace folded, at most
/// `PREVIEW_CHARS` characters.
fn preview(text: &str) -> String {
    let text = crate::secret_scan::mask(text).split_whitespace().collect::<Vec<_>>().join(" ");
    if text.chars().count() <= PREVIEW_CHARS {
        return text;
    }
    let mut out: String = text.chars().take(PREVIEW_CHARS).collect();
    out.push('…');
    out
}

/// Claude's answer to a `stop-<id>` control request as the reply to request `<id>`.
pub(super) fn stop_reply(acp: &str, ok: bool, resp: &Value) -> Message {
    let id: Id = serde_json::from_str(acp).unwrap_or(Value::String(acp.to_owned()));
    if ok {
        return Message::ok(id, json!({}));
    }
    let why = resp.get("error").and_then(Value::as_str).unwrap_or("Claude did not stop the task");
    Message::err(id, RpcError::internal(why))
}

/// How many of a workflow run's agents returned and how many started, from
/// the `journal.jsonl` in its transcript dir.
fn journal_counts(dir: &Path) -> Option<(usize, usize)> {
    use std::io::Read;
    let mut bytes = Vec::new();
    std::fs::File::open(dir.join("journal.jsonl"))
        .ok()?
        .take(JOURNAL_BYTES)
        .read_to_end(&mut bytes)
        .ok()?;
    // A cut at the limit may split a character; the lines before it still count.
    let text = String::from_utf8_lossy(&bytes);
    let (mut done, mut started) = (0, 0);
    for line in text.lines() {
        match serde_json::from_str::<Value>(line)
            .ok()
            .as_ref()
            .and_then(|v| v.get("type"))
            .and_then(Value::as_str)
        {
            Some("started") => started += 1,
            Some("result") => done += 1,
            _ => {}
        }
    }
    Some((done, started))
}
