//! Claude Code's task list as the turn's ACP `plan` (cx-ncc.80).
//!
//! Claude Code 2.1 dropped TodoWrite from `-p` sessions; with
//! `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` (set at launch, `agent/command.rs`) it
//! keeps its list with `TaskCreate` and `TaskUpdate` instead. Each call names
//! one task, so the whole list is kept here and sent again, as one `plan`
//! update, whenever a call that changed it succeeds: clients draw the list as
//! one checklist (the agent pane pins it under the running turn). A call is
//! applied on its result, not its input, so a create gets the id Claude gave
//! it and a refused update changes nothing.

use serde_json::{Value, json};
use std::collections::HashMap;

/// One task as the checklist shows it.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Task {
    id: String,
    subject: String,
    status: &'static str,
}

/// A call waiting on its result.
#[derive(Debug, Clone)]
enum Call {
    Create { subject: String },
    Update { id: String, status: Option<&'static str>, subject: Option<String>, delete: bool },
}

/// The session's task list and its calls in flight.
#[derive(Debug, Default)]
pub struct TaskPlan {
    calls: HashMap<String, Call>,
    tasks: Vec<Task>,
}

/// Claude's status as ACP names it; nil for one the list does not show.
fn acp_status(status: &str) -> Option<&'static str> {
    match status {
        "pending" => Some("pending"),
        "in_progress" => Some("in_progress"),
        "completed" => Some("completed"),
        _ => None,
    }
}

fn text(input: &Value, key: &str) -> Option<String> {
    input
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

impl TaskPlan {
    /// Whether `name` is one of the task tools this list follows.
    pub fn follows(name: &str) -> bool {
        matches!(name, "TaskCreate" | "TaskUpdate")
    }

    /// A task tool call as it is made: held until its result.
    pub fn call(&mut self, name: &str, tool_id: &str, input: &Value) {
        let call = match name {
            "TaskCreate" => match text(input, "subject") {
                Some(subject) => Call::Create { subject },
                None => return,
            },
            "TaskUpdate" => {
                let Some(id) = input.get("taskId").and_then(|v| {
                    v.as_str().map(str::to_owned).or_else(|| v.as_u64().map(|n| n.to_string()))
                }) else {
                    return;
                };
                let status = input.get("status").and_then(Value::as_str);
                Call::Update {
                    id,
                    status: status.and_then(acp_status),
                    subject: text(input, "subject"),
                    delete: status == Some("deleted"),
                }
            }
            _ => return,
        };
        self.calls.insert(tool_id.to_owned(), call);
    }

    /// A call's result: the whole list as a `plan` update when the call
    /// changed it, nil otherwise (a failed call, or one this list never held).
    pub fn result(&mut self, tool_id: &str, failed: bool, result: Option<&Value>) -> Option<Value> {
        let call = self.calls.remove(tool_id)?;
        if failed {
            return None;
        }
        match call {
            Call::Create { subject } => {
                // Claude's own id, which its later updates name.
                let id = result.and_then(|r| r.pointer("/task/id")).and_then(|v| {
                    v.as_str().map(str::to_owned).or_else(|| v.as_u64().map(|n| n.to_string()))
                })?;
                if self.tasks.iter().any(|task| task.id == id) {
                    return None;
                }
                self.tasks.push(Task { id, subject, status: "pending" });
            }
            Call::Update { id, status, subject, delete } => {
                let at = self.tasks.iter().position(|task| task.id == id)?;
                if delete {
                    self.tasks.remove(at);
                } else {
                    let task = self.tasks.get_mut(at)?;
                    let before = task.clone();
                    if let Some(status) = status {
                        task.status = status;
                    }
                    if let Some(subject) = subject {
                        task.subject = subject;
                    }
                    if *task == before {
                        return None;
                    }
                }
            }
        }
        Some(self.plan())
    }

    /// The list as one ACP `plan` update.
    fn plan(&self) -> Value {
        let entries: Vec<Value> = self
            .tasks
            .iter()
            .map(|task| json!({"content": task.subject, "status": task.status, "priority": "medium"}))
            .collect();
        json!({"sessionUpdate": "plan", "entries": entries})
    }
}
