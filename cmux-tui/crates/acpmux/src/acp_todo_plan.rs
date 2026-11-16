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
//! harness's own list. A failed call changes nothing and its row shows again: its result carries
//! the call's own title, kind and input back, since the pane never drew the call. Only that exact
//! title with that exact input shape counts: a title alone could be any tool's. A chat's held calls
//! go when its turn ends ([`forget`]), so a call that never answers holds nothing past its turn.

use serde_json::Value;
use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

pub use acpmux_core::chat::todo::{Watch, entries};

static WATCHES: LazyLock<Mutex<HashMap<String, Watch>>> = LazyLock::new(Default::default);

/// Scoped access for the shared tap stage. The watch is removed from the
/// process map while the closure runs, then retained only while non-empty.
pub(crate) fn with_watch<R>(session: &str, f: impl FnOnce(&mut Option<Watch>) -> R) -> R {
    let mut watches = WATCHES.lock().unwrap_or_else(|e| e.into_inner());
    let mut watch = watches.remove(session);
    let result = f(&mut watch);
    if watch.as_ref().is_some_and(|w| !w.is_empty()) {
        if let Some(watch) = watch {
            watches.insert(session.to_owned(), watch);
        }
    }
    result
}

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
        if watch.is_empty() {
            watches.remove(session);
        }
        return plan;
    }
    if kind != Some("tool_call") || entries(update).is_none() {
        return None;
    }
    let mut watch = Watch::default();
    let plan = watch.observe(update);
    if !watch.is_empty() {
        watches.insert(session.to_owned(), watch);
    }
    plan
}

/// Drops chat `session`'s held calls when its turn ends, however it ends (`hub/turns.rs`): a call
/// whose result never came (a cancelled turn, an agent that exited) holds nothing past its turn,
/// and a late result passes through as any other tool's.
pub fn forget(session: &str) {
    WATCHES.lock().unwrap_or_else(|e| e.into_inner()).remove(session);
}

#[cfg(test)]
#[path = "acp_todo_plan_tests.rs"]
mod tests;
