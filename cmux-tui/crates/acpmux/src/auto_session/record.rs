//! What a chat keeps of Auto mode in its own record (`SessionMeta::auto_session`), and the
//! `autoSession` field of its row.
//!
//! The record is the per-chat Auto flag and everything a daemon needs to go on after a restart:
//! whether this machine held the chat, under which epoch, and the last snapshot the store
//! acknowledged. The row is a pure function of it, so the row reads no live state.

use cmux_auto_session::wire::{Blocked, MoveTo, State};
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
    /// Where the person moved the chat, while it is not there yet: its holder is giving it, or
    /// the Cloud still tells the wish.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub moving: Option<MoveTo>,
    /// The person set the chat to run on this machine only while the Cloud held it: Auto goes
    /// off once the chat is home, this machine has stored a copy of its own and has taken the
    /// chat's Cloud inbox. It lasts only while the store says the chat is coming here or is
    /// here: a pick of Cloud or Auto from another device, or a move home that did not happen,
    /// ends it (`runtime/chats.rs`).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub local_wanted: bool,
}

/// Where a chat runs, as the person chose it: the record's three states (`auto`,
/// `keepInCloud`), in the place picker's words.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// On this machine only. Nothing is copied to the Cloud.
    Local,
    /// On this machine while it is there, on the Cloud machine when it is not.
    Auto,
    /// In the Cloud, always.
    Cloud,
}

impl Mode {
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Local => "local",
            Mode::Auto => "auto",
            Mode::Cloud => "cloud",
        }
    }

    /// The mode a word names; None for any other word.
    pub fn parse(word: &str) -> Option<Mode> {
        [Mode::Local, Mode::Auto, Mode::Cloud].into_iter().find(|mode| mode.as_str() == word)
    }
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
            moving: None,
            local_wanted: false,
        }
    }

    /// Where the chat runs, as the person chose it. A chat set to this machine only reads so
    /// from the moment it was set, also while it is still on its way home.
    pub fn mode(&self) -> Mode {
        match (self.auto, self.local_wanted, self.keep_in_cloud) {
            (false, _, _) | (true, true, _) => Mode::Local,
            (true, false, false) => Mode::Auto,
            (true, false, true) => Mode::Cloud,
        }
    }

    /// The row's `autoSession` (the design's "Daemon surface"):
    /// `{auto, mode, state, here, keepInCloud, moving?, blocked?, leftover?: {files}}`. `mode` is
    /// `local`, `auto` or `cloud`; `moving` is `cloud` or `local` while the chat is on its way
    /// there. `leftover.files` is how many files the kept changes touch; `leftover show` lists
    /// them.
    ///
    /// A chat with Auto off runs here as any chat does, whatever the record last held.
    pub fn row(&self) -> Value {
        let (state, here) = if self.auto { (self.state, self.here) } else { (State::Local, true) };
        let mut row = json!({
            "auto": self.auto,
            "mode": self.mode().as_str(),
            "state": state.as_str(),
            "here": here,
            "keepInCloud": self.auto && self.keep_in_cloud,
        });
        let moving = self.moving.filter(|_| self.auto);
        if let (Some(to), Some(object)) = (moving, row.as_object_mut()) {
            object.insert("moving".to_owned(), json!(to.as_str()));
        }
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
            None => json!({
                "auto": false, "mode": "local", "state": "local", "here": true,
                "keepInCloud": false,
            }),
        }
    }
}

#[cfg(test)]
#[path = "record_tests.rs"]
mod tests;
