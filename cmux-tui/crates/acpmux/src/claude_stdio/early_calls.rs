//! A tool call named as its block starts. Claude Code streams a call's input
//! (`input_json_delta`) and sends the whole call only once its block ends, so
//! a long Write or Edit showed nothing for as long as the file took to write
//! (Leo, 2026-10-19: "it doesn't do anything a lot of the time"). The block's
//! start already names the tool: it goes out at once as a pending
//! `tool_call`, and the whole call follows as that call's `tool_call_update`.

use super::*;

/// Tools whose whole call starts a flow of its own (a subagent, the todo list,
/// a question, plan approval): they are not named early.
const OWN_FLOW: &[&str] =
    &["Task", "Agent", "Workflow", "TodoWrite", "AskUserQuestion", "ExitPlanMode"];

impl Translator {
    /// The pending `tool_call` for a `content_block_start` that opens a tool
    /// call in session `sid`, or None for any other block.
    pub(super) async fn announce_tool(&self, event: &Value, sid: &str) -> Option<Value> {
        let block = event.get("content_block")?;
        if block.get("type").and_then(Value::as_str) != Some("tool_use") {
            return None;
        }
        let id = block.get("id").and_then(Value::as_str)?;
        let name = block.get("name").and_then(Value::as_str)?;
        if OWN_FLOW.contains(&name) {
            return None;
        }
        self.announced.lock().await.insert(id.to_owned(), sid.to_owned());
        Some(json!({
            "sessionUpdate": "tool_call",
            "toolCallId": id,
            "title": tool_title(name, &Value::Null).trim(),
            "kind": tool_kind(name),
            "status": "pending",
            "_meta": {"claude": {"tool": name}}
        }))
    }

    /// Whether call `id` went out early: its whole call is then its update.
    pub(super) async fn take_announced(&self, id: &str) -> bool {
        self.announced.lock().await.remove(id).is_some()
    }

    /// The calls named early whose whole call never came (the turn ended while
    /// their input streamed): each ends failed, so none runs on in the chat.
    pub(super) async fn end_announced(&self) -> Vec<Message> {
        self.announced
            .lock()
            .await
            .drain()
            .map(|(id, sid)| {
                Message::notification(
                    method::SESSION_UPDATE,
                    json!({"sessionId": sid, "update": {"sessionUpdate": "tool_call_update", "toolCallId": id, "status": "failed"}}),
                )
            })
            .collect()
    }
}
