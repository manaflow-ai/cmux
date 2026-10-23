//! Claude's dynamic workflows and the live progress of its background tasks.
//!
//! A Workflow tool call runs a script of many agents in the background
//! (code.claude.com/docs/en/workflows): it is a background subagent of kind
//! `workflow`, its tool result is only the launch (naming the run and its
//! transcript dir), and its `task_notification` ends it. Claude's
//! `task_progress` lines, for a workflow and a subagent alike, become
//! `subagent_progress` updates: tokens, tool uses, elapsed time, what it is
//! doing now and, for a workflow, how many of its agents returned.

use super::*;
use crate::no_panic::JsonExt;
use std::path::{Path, PathBuf};

/// The most of a workflow journal one progress line reads (a run has at most 1,000 agents, two
/// short lines each): a line longer than this is passed over.
const JOURNAL_BYTES: u64 = 4 << 20;

/// How far a workflow journal was read, and its agents counted so far.
#[derive(Clone, Copy, Debug, Default)]
pub(super) struct JournalTally {
    offset: u64,
    done: usize,
    started: usize,
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
        if let Some(dir) = text("transcriptDir") {
            self.workflows.lock().await.insert(tool.to_owned(), Some(PathBuf::from(dir)));
        }
        let mut update = json!({"sessionUpdate": "subagent_progress", "subagentSessionId": child});
        if let Some(name) = text("workflowName") {
            update.set("name", json!(name));
        }
        if let Some(summary) = text("summary") {
            update.set("task", json!(summary));
        }
        Some(update)
    }

    /// A `task_progress` line of a running subagent or workflow as its
    /// `subagent_progress`. A workflow's action is its current step
    /// (`<phase>: <agent>`); a subagent's is its progress summary, else its
    /// last tool.
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
        let workflow = self.workflows.lock().await.get(&tool).cloned();
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
        // Off the stdout loop, and only what the run appended since the last progress line: a
        // big run's journal is megabytes, and it was read whole on every one.
        let dir = workflow.flatten();
        let counts = match dir {
            Some(dir) => {
                let journals = self.journals.clone();
                tokio::task::spawn_blocking(move || {
                    let mut tallies = journals.lock().unwrap_or_else(|e| e.into_inner());
                    let tally = tallies.entry(dir.clone()).or_default();
                    journal_counts(&dir, tally)
                })
                .await
                .ok()
                .flatten()
            }
            None => None,
        };
        if let Some((done, started)) = counts {
            update.set("agents", json!({"done": done, "started": started}));
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

/// Claude's answer to a `stop-<id>` control request as the reply to request `<id>`.
pub(super) fn stop_reply(acp: &str, ok: bool, resp: &Value) -> Message {
    let id: Id = serde_json::from_str(acp).unwrap_or(Value::String(acp.to_owned()));
    if ok {
        return Message::ok(id, json!({}));
    }
    let why = resp.get("error").and_then(Value::as_str).unwrap_or("Claude did not stop the task");
    Message::err(id, RpcError::internal(why))
}

/// How many of a workflow run's agents returned and how many started, from the `journal.jsonl`
/// in its transcript dir: the complete lines past `tally`'s offset are counted into it. A journal
/// shorter than the offset was replaced and is counted again from its start.
fn journal_counts(dir: &Path, tally: &mut JournalTally) -> Option<(usize, usize)> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = std::fs::File::open(dir.join("journal.jsonl")).ok()?;
    if file.metadata().ok()?.len() < tally.offset {
        *tally = JournalTally::default();
    }
    file.seek(SeekFrom::Start(tally.offset)).ok()?;
    let mut bytes = Vec::new();
    file.take(JOURNAL_BYTES).read_to_end(&mut bytes).ok()?;
    // Complete lines only: the run may be writing the last one. A line longer than the read is
    // passed over, so the count never stops there.
    let end = match bytes.iter().rposition(|&b| b == b'\n') {
        Some(at) => at + 1,
        None if bytes.len() as u64 == JOURNAL_BYTES => bytes.len(),
        None => 0,
    };
    let text = String::from_utf8_lossy(bytes.get(..end).unwrap_or_default());
    for line in text.lines() {
        match serde_json::from_str::<Value>(line)
            .ok()
            .as_ref()
            .and_then(|v| v.get("type"))
            .and_then(Value::as_str)
        {
            Some("started") => tally.started += 1,
            Some("result") => tally.done += 1,
            _ => {}
        }
    }
    tally.offset += end as u64;
    Some((tally.done, tally.started))
}
