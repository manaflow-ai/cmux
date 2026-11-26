//! One-request foreground catch-up (`cmux_mobile_core::catch_up::service`) for Swift: Rust
//! builds the `catch-up` channel's open args from the cursors the phone holds and reads the
//! one reply frame; Swift only opens the channel and hands the bytes over (Leo, 2026-11-24:
//! "the syncing can arguably happen in the background too, so deltas can be sipped and
//! maintained").
//!
//! One [`PhoneCatchUp`] per Mac. Its cursors are kept by the app ([`PhoneCatchUp::encode`],
//! read back with [`PhoneCatchUp::open`]), so the chat list's `listSeq`/`listEpoch` and each
//! chat's `lastSeq` survive a relaunch.

use std::sync::{Arc, Mutex, PoisonError};

use cmux_mobile_core::catch_up::service::{self as core, Ask, Workspaces};
use cmux_mobile_core::catch_up::{Cursors, Wake};
use serde_json::Value;

/// The link service to open.
#[uniffi::export]
pub fn catch_up_service() -> String {
    core::SERVICE.to_string()
}

/// Whether a refused `catch-up` open (its close code) means the Mac has no such service, so
/// the app asks by today's separate calls.
#[uniffi::export]
pub fn catch_up_falls_back(code: String) -> bool {
    core::falls_back(&code)
}

/// A chat to bring up and the last event the phone holds of it (nil: the kept cursor's).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CatchUpChatAsk {
    pub session_id: String,
    pub last_seq: Option<u64>,
}

/// What a foreground catch-up asks for besides the kept cursors.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CatchUpAsk {
    /// The chat on screen, if any.
    pub on_screen_chat: Option<String>,
    /// The `known` object (JSON) of the tree the phone draws; nil when it draws none.
    pub known_json: Option<String>,
    /// What the phone's `daemon` line lists in `set-client-info`.
    pub capabilities: Vec<String>,
    /// Chats newest screenful first: the one on screen, then the recently opened ones.
    pub chats: Vec<CatchUpChatAsk>,
    /// Bytes the chats may answer with; 0 for the default (64 KiB).
    pub budget_bytes: u64,
}

/// What the reply said of the workspace tree.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CatchUpTree {
    /// The whole tree: `workspaces_json` is the `list-workspaces` reply's `data`.
    Whole,
    /// The tree the phone draws stands.
    Unchanged,
    /// Only the entries changed since a `since` cursor.
    Delta,
}

/// One chat's page.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CatchUpChatPage {
    pub session_id: String,
    /// The `_acpmux/attach` result as JSON.
    pub page_json: String,
    pub through_seq: Option<u64>,
    pub has_more: bool,
    pub older_before: Option<u64>,
}

/// Why a surface was not answered.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CatchUpCut {
    /// `workspaces`, `chatList` or `chats:<id>`.
    pub name: String,
    pub reason: String,
}

/// The reply, after the kept cursors moved past what it answered.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CatchUpAnswer {
    pub tree: Option<CatchUpTree>,
    pub workspaces_json: Option<String>,
    /// The `_acpmux/watch` result as JSON.
    pub chat_list_json: Option<String>,
    pub chats: Vec<CatchUpChatPage>,
    pub cut: Vec<CatchUpCut>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum CatchUpError {
    #[error("{message}")]
    Reply { message: String },
}

/// One Mac's catch-up cursors.
#[derive(Debug, uniffi::Object)]
pub struct PhoneCatchUp {
    cursors: Mutex<Cursors>,
}

impl PhoneCatchUp {
    fn cursors(&self) -> std::sync::MutexGuard<'_, Cursors> {
        self.cursors.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[uniffi::export]
impl PhoneCatchUp {
    /// The cursors `kept` holds ([`PhoneCatchUp::encode`]'s bytes); nothing readable starts
    /// from none, which asks for every surface whole.
    #[uniffi::constructor]
    pub fn open(kept: Option<Vec<u8>>) -> Arc<Self> {
        let cursors = kept.map(|bytes| Cursors::decode(&bytes)).unwrap_or_default();
        Arc::new(Self { cursors: Mutex::new(cursors) })
    }

    /// The bytes to keep.
    pub fn encode(&self) -> Vec<u8> {
        self.cursors().encode()
    }

    /// The person opened a chat: it ranks first among the recent ones.
    pub fn opened_chat(&self, session_id: String, now: u64) {
        self.cursors().opened_chat(&session_id, now);
    }

    /// The `catch-up` channel's open args (a JSON object) for a foreground wake.
    pub fn foreground_request(&self, ask: CatchUpAsk) -> String {
        let mut core_ask = Ask::new(Wake::Foreground { chat: ask.on_screen_chat, terminal: None });
        core_ask.budget = ask.budget_bytes;
        core_ask.known = ask.known_json.and_then(|text| serde_json::from_str::<Value>(&text).ok());
        core_ask.capabilities = ask.capabilities;
        core_ask.chats = ask.chats.into_iter().map(|chat| (chat.session_id, chat.last_seq)).collect();
        core::request(&self.cursors(), &core_ask).to_string()
    }

    /// Reads the reply frame and moves the cursors of what it answered; a cut surface keeps
    /// its cursor.
    pub fn apply(&self, reply: Vec<u8>, now: u64) -> Result<CatchUpAnswer, CatchUpError> {
        let answer =
            core::read(&reply).map_err(|error| CatchUpError::Reply { message: error.to_string() })?;
        self.cursors().apply_catch_up(&answer, now);
        let tree = answer.workspaces.as_ref().map(|tree| match tree {
            Workspaces::Tree(_) => CatchUpTree::Whole,
            Workspaces::Unchanged(_) => CatchUpTree::Unchanged,
            Workspaces::Delta(_) => CatchUpTree::Delta,
        });
        Ok(CatchUpAnswer {
            tree,
            workspaces_json: answer.workspaces.as_ref().map(|tree| tree.data().to_string()),
            chat_list_json: answer.chat_list.as_ref().map(Value::to_string),
            chats: answer
                .chats
                .iter()
                .map(|chat| CatchUpChatPage {
                    session_id: chat.session_id.clone(),
                    page_json: chat.page.to_string(),
                    through_seq: chat.through_seq,
                    has_more: chat.has_more,
                    older_before: chat.older_before,
                })
                .collect(),
            cut: answer
                .cut
                .iter()
                .map(|name| CatchUpCut {
                    name: name.clone(),
                    reason: answer.cut_why.get(name).cloned().unwrap_or_default(),
                })
                .collect(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_request_and_its_reply_round_trip_through_kept_cursors() {
        let catch_up = PhoneCatchUp::open(None);
        let args: Value = serde_json::from_str(&catch_up.foreground_request(CatchUpAsk {
            on_screen_chat: Some("a".into()),
            known_json: Some(r#"{"tree_revision":"r1"}"#.into()),
            capabilities: vec!["page-tabs-v1".into()],
            chats: vec![CatchUpChatAsk { session_id: "a".into(), last_seq: Some(4) }],
            budget_bytes: 0,
        }))
        .unwrap();
        assert_eq!(args["workspaces"]["known"]["tree_revision"], "r1");
        assert_eq!(args["chats"][0]["lastSeq"], 4);

        let reply = br#"{"v":1,"workspaces":{"unchanged":true},
            "chatList":{"listEpoch":"E","listSeq":9,"sessions":[]},
            "chats":[{"sessionId":"a","events":[],"lastSeq":6,"pageThrough":6,"hasMore":false}],
            "cut":["chats:b"],"cutWhy":{"chats:b":"budget"}}"#;
        let answer = catch_up.apply(reply.to_vec(), 1).unwrap();
        assert_eq!(answer.tree, Some(CatchUpTree::Unchanged));
        assert_eq!(answer.chats[0].through_seq, Some(6));
        assert_eq!(answer.cut, vec![CatchUpCut { name: "chats:b".into(), reason: "budget".into() }]);

        // The kept bytes carry the list cursor into the next request.
        let next = PhoneCatchUp::open(Some(catch_up.encode()));
        let args: Value = serde_json::from_str(&next.foreground_request(CatchUpAsk {
            on_screen_chat: None,
            known_json: None,
            capabilities: vec![],
            chats: vec![CatchUpChatAsk { session_id: "a".into(), last_seq: None }],
            budget_bytes: 0,
        }))
        .unwrap();
        assert_eq!(args["chatList"], serde_json::json!({"afterSeq": 9, "listEpoch": "E"}));
        assert_eq!(args["chats"][0]["lastSeq"], 6);
        assert!(catch_up.apply(b"nope".to_vec(), 2).is_err());
        assert!(catch_up_falls_back("unknown_service".into()));
        assert!(!catch_up_falls_back("timeout".into()));
    }
}
