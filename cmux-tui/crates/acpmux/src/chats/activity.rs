//! Activity view (meeting 2026-10-08, AV): what a chat's live acpmux session
//! needs from the person, and its latest reply. acpmux owns both the chat
//! index and the sessions, so it joins them here and clients only mirror:
//! a chat value gains `attention` and `preview`, and a session record that
//! can change either reaches every chats watcher as
//! `_acpmux/chat_changed {kind: "activity", key, attention, preview}`
//! (no index read, so a scan holding the index lock never delays it).
//!
//! This half is what the chat lists read: [`ChatActivity`] and which records change it. The
//! sessions' half (reading a session's attention and preview, the hub's cache of the closed
//! sessions' part) is the hub's, `hub/chat_activity.rs`.

use std::collections::HashMap;
use std::sync::Arc;

use serde_json::{Value, json};

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
            // A sub-session below it started or stopped waiting on the person (`hub/asks_below.rs`).
            | "subsessions_waiting"
            | "purged"
            // `spawnedBy` names the chat's parent (`Hub::spawned_by`).
            | "tags"
    )
}

/// One chat's newest session: its `updated_at`, its id (the larger id wins a tie) and its fields.
pub(crate) type Newest = (u64, String, Value);

/// The activity of every chat a session continues, by chat key: the closed sessions' part built
/// once and shared until one of them changes (`ActivityCache`), the live sessions' part read now.
/// Decorating stays one lookup per chat.
#[derive(Default)]
pub struct ChatActivity {
    closed: Arc<HashMap<String, Newest>>,
    live: HashMap<String, Newest>,
    /// When the first session tag that had not expired when this was read expires: past it, a
    /// `parent` or fold read from this may be out of date with no record saying so.
    expires_at: Option<u64>,
}

impl ChatActivity {
    /// The closed sessions' part, the live sessions' part, and when the first tag read for it
    /// expires (the hub builds it, `hub/chat_activity.rs`).
    pub(crate) fn new(
        closed: Arc<HashMap<String, Newest>>,
        live: HashMap<String, Newest>,
        expires_at: Option<u64>,
    ) -> Self {
        Self { closed, live, expires_at }
    }

    /// When the first tag read for this activity expires (`expires_at`).
    pub fn expires_at(&self) -> Option<u64> {
        self.expires_at
    }

    /// The fields of the newest session continuing `key`, closed or live.
    fn fields(&self, key: &str) -> Option<&Value> {
        match (self.closed.get(key), self.live.get(key)) {
            (Some(closed), Some(live)) if (closed.0, &closed.1) > (live.0, &live.1) => {
                Some(&closed.2)
            }
            (_, Some(live)) => Some(&live.2),
            (closed, None) => closed.map(|n| &n.2),
        }
    }

    /// The chat was started by another chat's agent (`parent`): lists fold it under that chat.
    pub fn has_parent(&self, key: &str) -> bool {
        self.fields(key).is_some_and(|fields| !fields.get("parent").is_none_or(Value::is_null))
    }

    /// Adds `attention`, `preview`, `parent`, `displayName` and `icon` to a chat value
    /// (`chat_value`); a chat no session continues gets nulls, so a client clears what it had.
    pub fn decorate(&self, chat: &mut Value) {
        let fields = chat
            .get("key")
            .and_then(Value::as_str)
            .and_then(|key| self.fields(key))
            .cloned()
            .unwrap_or_else(|| {
                json!({"attention": null, "preview": null, "parent": null, "displayName": null,
                       "icon": null})
            });
        if let (Some(chat), Value::Object(fields)) = (chat.as_object_mut(), fields) {
            chat.extend(fields);
        }
    }
}
