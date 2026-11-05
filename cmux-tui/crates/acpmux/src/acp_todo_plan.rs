//! An ACP harness's own todo tool as the turn's ACP `plan`, where its adapter sends the call but
//! not the list.
//!
//! DeepSeek Harness (`dsh --profile acp`) keeps its task list with `todo_write`: every call
//! sends the whole list, `{"todos": [{"content", "status"}]}`, with status `pending`,
//! `in_progress` or `completed` (deepseek-ai/deepseek-harness `packages/todo/tool-todo`). Its ACP
//! bridge passes the call through as a generic `tool_call` titled `todo_write` with that input,
//! then a `tool_call_update` that completes or fails, and deliberately sends no `plan` (its
//! web-todo-display note: "the automation-only ACP bridge deliberately omits todo presentation").
//! So a dsh chat in cmux showed a bare `todo_write` row and never the checklist Claude, Codex and
//! Muse draw. Leo, 2026-11-05: "i want us to be able to render it in ours/give the agent tools
//! for that to follow (if it's natively supported by the harness)".
//!
//! The tap watches each live update of the chat's own thread ([`observe`]). A `todo_write` call
//! with a well-formed list is held and marked `_meta.acpmux.planTool`, so the pane draws the
//! checklist in its place; once it completes, its list goes out as one `plan` update, as the
//! harness's own list (a failed call changes nothing and its row shows again). Only that exact
//! title with that exact input shape counts: a title alone could be any tool's.

use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

/// The tool name DeepSeek Harness gives its todo tool (`dsh-tool-todo`).
const TODO_WRITE: &str = "todo_write";

/// The most calls one chat holds waiting on their results; past it the oldest are dropped.
const MAX_HELD: usize = 64;

/// One chat's todo calls still running, by tool call id, each with the list it sends.
#[derive(Debug, Default)]
pub struct Watch {
    calls: Vec<(String, Vec<Value>)>,
}

/// The list a `todo_write` call's input sends, as ACP plan entries; none when it is not one.
fn entries(update: &Value) -> Option<Vec<Value>> {
    if update.get("title").and_then(Value::as_str).map(str::trim) != Some(TODO_WRITE) {
        return None;
    }
    let todos = update.pointer("/rawInput/todos")?.as_array()?;
    todos
        .iter()
        .map(|todo| {
            let content = todo.get("content")?.as_str()?.trim();
            let status = match todo.get("status")?.as_str()? {
                s @ ("pending" | "in_progress" | "completed") => s,
                _ => return None,
            };
            (!content.is_empty())
                .then(|| json!({"content": content, "priority": "medium", "status": status}))
        })
        .collect()
}

/// Marks an update as a todo call the checklist stands for (the pane draws no row for it).
fn mark(update: &mut Value) {
    if let Some(o) = update.as_object_mut() {
        let meta = o.entry("_meta").or_insert_with(|| json!({}));
        if let Some(m) = meta.as_object_mut() {
            let acpmux = m.entry("acpmux").or_insert_with(|| json!({}));
            if let Some(a) = acpmux.as_object_mut() {
                a.insert("planTool".to_owned(), json!(true));
            }
        }
    }
}

impl Watch {
    /// A live `session/update` of the chat's own thread: marks a todo call and its result, and
    /// returns the `plan` update a completed one makes.
    pub fn observe(&mut self, update: &mut Value) -> Option<Value> {
        let kind = update.get("sessionUpdate").and_then(Value::as_str)?;
        if !matches!(kind, "tool_call" | "tool_call_update") {
            return None;
        }
        let id = update.get("toolCallId").and_then(Value::as_str)?.to_owned();
        if kind == "tool_call" {
            // A call under an id seen before is a new call: an adapter may number calls per run.
            self.calls.retain(|(held, _)| *held != id);
            if let Some(list) = entries(update) {
                if self.calls.len() >= MAX_HELD {
                    self.calls.remove(0);
                }
                self.calls.push((id.clone(), list));
            }
        }
        let at = self.calls.iter().position(|(held, _)| *held == id)?;
        mark(update);
        match update.get("status").and_then(Value::as_str) {
            Some("completed") => {
                let (_, list) = self.calls.remove(at);
                Some(json!({"sessionUpdate": "plan", "entries": list}))
            }
            Some("failed") => {
                self.calls.remove(at);
                None
            }
            _ => None,
        }
    }
}

static WATCHES: LazyLock<Mutex<HashMap<String, Watch>>> = LazyLock::new(Default::default);

/// A live update of chat `session`'s own thread (`hub/tap.rs`): see [`Watch::observe`].
pub fn observe(session: &str, update: &mut Value) -> Option<Value> {
    let kind = update.get("sessionUpdate").and_then(Value::as_str);
    if !matches!(kind, Some("tool_call" | "tool_call_update")) {
        return None;
    }
    let mut watches = WATCHES.lock().unwrap_or_else(|e| e.into_inner());
    // A chat holds a watch only while a todo call of its own runs.
    if let Some(watch) = watches.get_mut(session) {
        let plan = watch.observe(update);
        if watch.calls.is_empty() {
            watches.remove(session);
        }
        return plan;
    }
    if kind != Some("tool_call") || entries(update).is_none() {
        return None;
    }
    let mut watch = Watch::default();
    let plan = watch.observe(update);
    if !watch.calls.is_empty() {
        watches.insert(session.to_owned(), watch);
    }
    plan
}

#[cfg(test)]
#[path = "acp_todo_plan_tests.rs"]
mod tests;
