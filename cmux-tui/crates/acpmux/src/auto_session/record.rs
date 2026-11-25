//! What a chat keeps of Auto mode in its own record (`SessionMeta::auto_session`), and the
//! `autoSession` field of its row.
//!
//! The record is the per-chat Auto flag and everything a daemon needs to go on after a restart:
//! whether this machine held the chat, under which epoch, and the last snapshot the store
//! acknowledged. The row is a pure function of it, so the row reads no live state.

use cmux_auto_session::wire::{Blocked, State};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// Changes this machine made after the chat moved to the Cloud, kept aside as a patch beside
/// the chat. The person applies or discards them (`_acpmux/auto_session/leftover`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Leftover {
    /// The files the patch touches, as paths from the folder's top.
    pub files: Vec<String>,
    /// When it was written (epoch ms).
    pub at: u64,
    /// The patch file.
    pub path: String,
    /// The folder the patch applies to (the checkout's top).
    pub top: String,
}

fn local() -> State {
    State::Local
}

/// One chat's Auto mode, as its record keeps it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AutoRecord {
    /// Auto is on for the chat.
    pub auto: bool,
    /// The person asked for the chat to stay in the Cloud when this machine returns.
    #[serde(default)]
    pub keep_in_cloud: bool,
    /// This machine held the chat when the record was written.
    #[serde(default)]
    pub here: bool,
    /// The epoch this machine wrote under, or last heard of.
    #[serde(default)]
    pub epoch: u64,
    /// The newest snapshot in the store that this machine stored or imported; 0 for none.
    #[serde(default)]
    pub snapshot: u64,
    /// Where the chat stands as the Cloud last said.
    #[serde(default = "local")]
    pub state: State,
    /// Why Auto cannot keep the chat going in the Cloud.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blocked: Option<Blocked>,
    /// Changes kept aside. It outlives `auto`: the notice stays until the person settles it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub leftover: Option<Leftover>,
    /// The commit that holds the folder as the last acknowledged snapshot had it (the git form):
    /// what a leftover patch is cut against.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub anchor: Option<String>,
}

impl AutoRecord {
    /// A chat whose Auto was just switched on here: local until the store says otherwise.
    pub fn on() -> AutoRecord {
        AutoRecord {
            auto: true,
            keep_in_cloud: false,
            here: false,
            epoch: 0,
            snapshot: 0,
            state: State::Local,
            blocked: None,
            leftover: None,
            anchor: None,
        }
    }

    /// The row's `autoSession` (the design's "Daemon surface"):
    /// `{auto, state, here, keepInCloud, blocked?, leftover?: {files}}`. `leftover.files` is how
    /// many files the kept changes touch; `leftover show` lists them.
    ///
    /// A chat with Auto off runs here as any chat does, whatever the record last held.
    pub fn row(&self) -> Value {
        let (state, here) = if self.auto { (self.state, self.here) } else { (State::Local, true) };
        let mut row = json!({
            "auto": self.auto,
            "state": state.as_str(),
            "here": here,
            "keepInCloud": self.auto && self.keep_in_cloud,
        });
        if let (Some(blocked), Some(object)) = (self.blocked, row.as_object_mut()) {
            object.insert("blocked".to_owned(), json!(blocked.as_str()));
        }
        if let (Some(leftover), Some(object)) = (&self.leftover, row.as_object_mut()) {
            object.insert("leftover".to_owned(), json!({ "files": leftover.files.len() }));
        }
        row
    }

    /// Nothing is left to keep: Auto is off and no changes wait for the person.
    pub fn spent(&self) -> bool {
        !self.auto && self.leftover.is_none()
    }

    /// The row's `autoSession` for a chat with this record, or with none: every row carries
    /// the field, so the pane tells a chat with Auto off from a daemon that has no Auto.
    pub fn row_of(record: Option<&AutoRecord>) -> Value {
        match record {
            Some(record) => record.row(),
            None => json!({ "auto": false, "state": "local", "here": true, "keepInCloud": false }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_row_carries_what_the_pane_decodes() {
        let mut record = AutoRecord::on();
        record.here = true;
        assert_eq!(
            record.row(),
            json!({ "auto": true, "state": "local", "here": true, "keepInCloud": false })
        );
        record.here = false;
        record.state = State::ComingBack;
        record.blocked = Some(Blocked::NoMachine);
        record.leftover = Some(Leftover {
            files: vec!["a.rs".into(), "b/c.rs".into()],
            at: 1,
            path: "/x/auto-leftover.patch".into(),
            top: "/x".into(),
        });
        assert_eq!(
            record.row(),
            json!({
                "auto": true, "state": "coming_back", "here": false, "keepInCloud": false,
                "blocked": "no_machine", "leftover": { "files": 2 },
            })
        );
    }

    #[test]
    fn a_record_from_an_older_build_reads_with_defaults() {
        let record: AutoRecord = serde_json::from_value(json!({ "auto": true })).unwrap();
        assert_eq!(record, AutoRecord::on());
        assert!(!record.spent());
        let off: AutoRecord = serde_json::from_value(json!({ "auto": false })).unwrap();
        assert!(off.spent());
    }

    #[test]
    fn a_chat_with_auto_off_reads_as_running_here() {
        let off = json!({ "auto": false, "state": "local", "here": true, "keepInCloud": false });
        assert_eq!(AutoRecord::row_of(None), off);
        let mut was_away = AutoRecord::on();
        was_away.auto = false;
        was_away.state = State::Cloud;
        was_away.keep_in_cloud = true;
        assert_eq!(AutoRecord::row_of(Some(&was_away)), off);
    }
}
