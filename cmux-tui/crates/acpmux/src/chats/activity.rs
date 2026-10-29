//! Activity view (meeting 2026-10-08, AV): what a chat's live acpmux session
//! needs from the person, and its latest reply. acpmux owns both the chat
//! index and the sessions, so it joins them here and clients only mirror:
//! a chat value gains `attention` and `preview`, and a session record that
//! can change either reaches every chats watcher as
//! `_acpmux/chat_changed {kind: "activity", key, attention, preview}`
//! (no index read, so a scan holding the index lock never delays it).

use std::collections::HashMap;

use cmux_chat_index::{AdapterKind, ChatKey};
use serde_json::{Value, json};

use super::key_text;
use crate::hub::{Hub, Session};
use crate::no_panic::JsonExt;
use crate::store::SessionStatus;

/// The longest preview sent, in characters: one sidebar line and some.
const PREVIEW_CHARS: usize = 160;

/// The record kinds after which a session's attention or preview may differ:
/// a status change (running, waiting, read), the end of a turn, and every
/// permission event.
pub fn changes_activity(kind: &str) -> bool {
    matches!(
        kind,
        "status"
            | "turn_result"
            | "turn_end"
            | "turn_error"
            | "permission_request"
            | "permission_decision"
            | "permission_auto"
            | "purged"
            // `spawnedBy` names the chat's parent (`Hub::spawned_by`).
            | "tags"
    )
}

/// The indexed chat a session continues: the store of its profile's family
/// and the agent's session id. Only adoptable families have one.
pub fn session_chat_key(session: &Session) -> Option<ChatKey> {
    let meta = session.meta();
    let harness = match meta.family.as_deref()? {
        "claude" => AdapterKind::ClaudeCode,
        "codex" => AdapterKind::Codex,
        _ => return None,
    };
    Some(ChatKey { harness, session_id: meta.agent_session_id? })
}

/// What the session needs from the person, most urgent first; None while
/// it needs nothing (idle, working, or closed).
pub fn attention(session: &Session) -> Option<&'static str> {
    let meta = session.meta();
    match meta.status {
        SessionStatus::Closed => return None,
        SessionStatus::Waiting => return Some("needsInput"),
        _ if !session.pending_permissions().is_empty() => return Some("needsInput"),
        SessionStatus::Running => return None,
        _ => {}
    }
    let failed = meta.last_turn.as_ref().and_then(|t| t.get("status")).and_then(Value::as_str)
        == Some("failed");
    if failed {
        Some("failed")
    } else if meta.unread {
        Some("unread")
    } else {
        None
    }
}

/// The `attention` and `preview` fields of a session's chat.
pub fn activity_fields(session: &Session) -> Value {
    let preview = session.meta().preview.filter(|p| !p.trim().is_empty()).map(|p| {
        let line = p.split_whitespace().collect::<Vec<_>>().join(" ");
        line.chars().take(PREVIEW_CHARS).collect::<String>()
    });
    json!({"attention": attention(session), "preview": preview})
}

/// The `_acpmux/chat_changed` params of a session's chat activity, when the
/// session continues an indexable chat.
pub fn activity_change(hub: &Hub, session: &Session) -> Option<Value> {
    let key = session_chat_key(session)?;
    let mut change = hub.chat_activity_fields(session);
    change.set("kind", json!("activity"));
    change.set("key", json!(key_text(&key)));
    Some(change)
}

/// The activity of every chat a live session continues, by chat key: built
/// once per page or change, so decorating stays one lookup per chat.
pub struct ChatActivity(HashMap<String, (u64, Value)>);

impl ChatActivity {
    /// Adds `attention`, `preview` and `parent` to a chat value (`chat_value`); a chat
    /// no session continues gets nulls, so a client clears what it had.
    pub fn decorate(&self, chat: &mut Value) {
        let fields = chat
            .get("key")
            .and_then(Value::as_str)
            .and_then(|key| self.0.get(key))
            .map(|(_, fields)| fields.clone())
            .unwrap_or_else(|| json!({"attention": null, "preview": null, "parent": null}));
        if let (Some(chat), Value::Object(fields)) = (chat.as_object_mut(), fields) {
            chat.extend(fields);
        }
    }
}

impl Hub {
    /// A chat's `attention` and `preview`, and `parent`: the chat of the session that started
    /// this one (`Hub::spawned_by`; its chat key, else its session id), so lists fold it under
    /// that chat instead of listing it on its own (Leo 2026-10-13). Null for a chat nobody started.
    pub fn chat_activity_fields(&self, session: &Session) -> Value {
        let mut fields = activity_fields(session);
        let parent = self.spawned_by(&session.meta()).map(|parent| match self.resolve(&parent) {
            Ok(parent_session) => {
                session_chat_key(&parent_session).map_or(parent, |key| key_text(&key))
            }
            Err(_) => parent,
        });
        fields.set("parent", json!(parent));
        fields
    }

    /// Every live session's chat activity; the newest session wins a chat
    /// two sessions continue.
    pub fn chat_activity(&self) -> ChatActivity {
        let mut by_key: HashMap<String, (u64, Value)> = HashMap::new();
        for session in self.sessions() {
            let Some(key) = session_chat_key(&session) else { continue };
            let updated = session.meta().updated_at;
            let key = key_text(&key);
            if by_key.get(&key).is_none_or(|(newest, _)| updated >= *newest) {
                by_key.insert(key, (updated, self.chat_activity_fields(&session)));
            }
        }
        ChatActivity(by_key)
    }
}
