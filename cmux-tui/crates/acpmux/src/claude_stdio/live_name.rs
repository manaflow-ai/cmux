//! A running Claude Code's own session name, changed when acpmux renames the session (`RENAME`).
//! acpmux starts Claude Code under the session's name (`--name`, `agent/command.rs`), which is
//! what Claude Code's peer list and a held message's "From:" show; a rename after that reached
//! it only at its next start. Claude Code 2.1.310 has no control request for its name, so this
//! writes its `/rename <name>` line between turns: a local command, no model call. Its echo, its
//! `session_title_changed`, its synthetic reply and its result never reach the chat; the result
//! answers the request.

use super::*;

/// The refusal of a rename while Claude Code runs a turn, compacts or renames already: the hub
/// asks again when the turn ends (`hub/live_name.rs`).
pub const RENAME_BUSY: &str = "rename: a turn is running";

/// The refusal of a rename by a Claude Code whose commands list no `/rename`: written anyway, the
/// line would be a prompt to the model.
pub const RENAME_UNSUPPORTED: &str = "rename: this Claude Code has no /rename";

/// A `/rename` with no result after this long is given up on (the hub stopped waiting at 10 s):
/// the next rename is written, and a late result answers nothing.
const STALE: std::time::Duration = std::time::Duration::from_secs(30);

impl Translator {
    /// `RENAME {sessionId, name}`: Claude Code's `/rename` line for `name`, between turns only.
    pub(super) async fn rename(&self, id: &Id, p: &Value) -> Outbound {
        let name = p.get("name").and_then(Value::as_str).map(str::trim).unwrap_or_default();
        if name.is_empty() || name.contains(['\n', '\r']) {
            return Outbound::Reply(Message::err(
                id.clone(),
                RpcError::invalid_params("rename needs a one-line name"),
            ));
        }
        if !self.lists_rename().await {
            return Outbound::Reply(Message::err(
                id.clone(),
                RpcError::new(-32601, RENAME_UNSUPPORTED),
            ));
        }
        let mut renaming = self.renaming.lock().await;
        if renaming.take_if(|(_, _, at)| at.elapsed() > STALE).is_some() {
            tracing::debug!("rename: the last /rename had no result; writing the next");
        }
        if renaming.is_some()
            || self.in_turn.load(Ordering::SeqCst)
            || self.compacting.load(Ordering::SeqCst)
        {
            return Outbound::Reply(Message::err(
                id.clone(),
                RpcError::invalid_params(RENAME_BUSY),
            ));
        }
        let uuid = uuid::Uuid::now_v7().to_string();
        *renaming = Some((uuid.clone(), id.clone(), std::time::Instant::now()));
        let content = format!("/rename {name}");
        Outbound::Lines(vec![json!({
            "type": "user",
            "uuid": uuid,
            "message": {"role": "user", "content": content},
        })])
    }

    /// Whether Claude Code's commands (its `initialize` answer, or a later `commands_changed`) list
    /// `rename`, by name or as a `{name}` entry.
    async fn lists_rename(&self) -> bool {
        self.slash_commands
            .lock()
            .await
            .iter()
            .any(|c| c.as_str().or_else(|| c.get("name").and_then(Value::as_str)) == Some("rename"))
    }

    /// One of Claude Code's lines for the rename in flight: nothing for the chat, and its result
    /// answers `RENAME`. None for any other line, which the translator reads as before.
    pub(super) async fn rename_line(&self, line: &Value) -> Option<Vec<Message>> {
        let mut renaming = self.renaming.lock().await;
        let (uuid, _, _) = renaming.as_ref()?;
        if line.get("parent_tool_use_id").and_then(Value::as_str).is_some() {
            return None;
        }
        let text = |key: &str| line.get(key).and_then(Value::as_str).unwrap_or_default();
        let kind = text("type");
        let ours = match kind {
            "user" => {
                line.get("isReplay").and_then(Value::as_bool) == Some(true) && text("uuid") == uuid
            }
            "system" => text("subtype") == "session_title_changed",
            "assistant" => {
                line.pointer("/local_command_run/command").and_then(Value::as_str) == Some("rename")
            }
            "result" => text("local_command") == "rename",
            _ => false,
        };
        if !ours {
            return None;
        }
        if kind != "result" {
            return Some(Vec::new());
        }
        let (_, id, _) = renaming.take()?;
        let answer = if line.get("is_error").and_then(Value::as_bool) == Some(true) {
            Message::err(id, RpcError::internal(format!("rename: {}", text("result"))))
        } else {
            Message::ok(id, json!({"renamed": true}))
        };
        Some(vec![answer])
    }
}
