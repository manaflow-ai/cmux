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
    /// call in session `sid` (of subagent `parent`, if any), or None for any
    /// other block.
    pub(super) async fn announce_tool(
        &self,
        event: &Value,
        sid: &str,
        parent: Option<&str>,
    ) -> Option<Value> {
        let block = event.get("content_block")?;
        if block.get("type").and_then(Value::as_str) != Some("tool_use") {
            return None;
        }
        let id = block.get("id").and_then(Value::as_str)?;
        let name = block.get("name").and_then(Value::as_str)?;
        if OWN_FLOW.contains(&name) {
            return None;
        }
        self.announced
            .lock()
            .await
            .insert(id.to_owned(), (sid.to_owned(), parent.map(str::to_owned)));
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
    /// their input streamed): each ends failed, so none runs on in the chat. A
    /// background subagent runs on past the turn, and so do its calls.
    pub(super) async fn end_announced(&self) -> Vec<Message> {
        let background = self.background_subagents.lock().await.clone();
        self.fail_announced(|parent| !parent.is_some_and(|p| background.contains(p))).await
    }

    /// The calls named early by background subagent `tool`, which just ended:
    /// their whole calls will not come either.
    pub(super) async fn end_announced_of(&self, tool: &str) -> Vec<Message> {
        self.fail_announced(|parent| parent == Some(tool)).await
    }

    /// Every call named early, when Claude's stdout closed: whatever input was
    /// still streaming, a background subagent's too, ended with it.
    pub(super) async fn end_all_announced(&self) -> Vec<Message> {
        self.fail_announced(|_| true).await
    }

    async fn fail_announced(&self, ends: impl Fn(Option<&str>) -> bool) -> Vec<Message> {
        let mut announced = self.announced.lock().await;
        let mut ended: Vec<(String, String)> = announced
            .iter()
            .filter(|(_, (_, parent))| ends(parent.as_deref()))
            .map(|(id, (sid, _))| (id.clone(), sid.clone()))
            .collect();
        ended.sort();
        for (id, _) in &ended {
            announced.remove(id);
        }
        ended
            .into_iter()
            .map(|(id, sid)| {
                Message::notification(
                    method::SESSION_UPDATE,
                    json!({"sessionId": sid, "update": {"sessionUpdate": "tool_call_update", "toolCallId": id, "status": "failed"}}),
                )
            })
            .collect()
    }
}
