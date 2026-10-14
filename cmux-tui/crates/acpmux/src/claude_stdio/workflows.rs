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
use std::path::{Path, PathBuf};

/// The largest workflow journal read for its agent counts (a run has at most
/// 1,000 agents, two short lines each).
const JOURNAL_BYTES: u64 = 4 << 20;

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
            return Some(json!({
                "sessionUpdate": "subagent_state_update",
                "subagentSessionId": child,
                "state": "failed",
            }));
        }
        if let Some(dir) = text("transcriptDir") {
            self.workflows.lock().await.insert(tool.to_owned(), Some(PathBuf::from(dir)));
        }
        let mut update = json!({"sessionUpdate": "subagent_progress", "subagentSessionId": child});
        if let Some(name) = text("workflowName") {
            update["name"] = json!(name);
        }
        if let Some(summary) = text("summary") {
            update["task"] = json!(summary);
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
                update[key] = json!(value);
            }
        }
        let action = match &workflow {
            Some(_) => text("description"),
            None => text("summary").or(text("last_tool_name")),
        };
        if let Some(action) = action {
            update["action"] = json!(action);
        }
        if let Some((done, started)) = workflow.flatten().and_then(|dir| journal_counts(&dir)) {
            update["agents"] = json!({"done": done, "started": started});
        }
        Some(update)
    }
}

/// How many of a workflow run's agents returned and how many started, from
/// the `journal.jsonl` in its transcript dir.
fn journal_counts(dir: &Path) -> Option<(usize, usize)> {
    use std::io::Read;
    let mut text = String::new();
    std::fs::File::open(dir.join("journal.jsonl"))
        .ok()?
        .take(JOURNAL_BYTES)
        .read_to_string(&mut text)
        .ok()?;
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
