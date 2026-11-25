//! Where a chat runs, and who may move it: Local, Cloud or AutoCloud, at any point
//! (`_acpmux/chat_move`, `acpmux session place`, `cmux chat move --on`, the agent's `move_chat`).
//!
//! Leo, 2026-11-25: "cli stuff/agents being able to toggle to and from and whatever autocloud and
//! such".
//!
//! The three places are the three states Auto mode already has (`auto_session/`), so a move is
//! one `_acpmux/auto_session/set`: the store's epoch-fenced handoff (RFD 0025's move), never a
//! second one.
//!
//! | place | `autoSession` row | set |
//! | --- | --- | --- |
//! | local | `auto: false` | `{auto: false}` |
//! | auto (AutoCloud) | `auto: true, keepInCloud: false` | `{auto: true, keepInCloud: false}` |
//! | cloud | `auto: true, keepInCloud: true` | `{auto: true, keepInCloud: true}` |
//!
//! Who may ask ([`consent`]):
//!
//! - The person (the app's pane, a proven connection, their own terminal): any move.
//! - A chat's own agent, for its own chat only: off the Mac (to `auto` or `cloud`, or between the
//!   two) only while the person's `cloud.autoCloud` setting is on, since that setting is their
//!   standing yes to the Cloud running their chats. Back to `local` always asks the person: it
//!   writes into their Mac's folder. A move the agent may not make answers `needs_person` with
//!   the command the person runs, and changes nothing.
//! - Anyone else's agent, for another chat: refused.
//!
//! The agent's half has a kill switch: `CMUX_AGENT_CHAT_MOVE=off` (or `0`, `false`) makes every
//! agent ask answer `needs_person`. The person's moves stay.

use serde_json::{Value, json};

/// The agent's half of moves is on unless this says `off`, `0` or `false`.
pub const AGENT_KILL_SWITCH: &str = "CMUX_AGENT_CHAT_MOVE";

/// Where a chat runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Place {
    /// On this machine, Auto off.
    Local,
    /// In the Cloud, staying there when the Mac comes back (Auto on, `keepInCloud`).
    Cloud,
    /// AutoCloud: here while the Mac is up, in the Cloud while it sleeps (Auto on).
    Auto,
}

impl Place {
    pub const ALL: [Place; 3] = [Place::Local, Place::Cloud, Place::Auto];

    /// `local`, `cloud` or `auto`, and the spellings people use for them.
    pub fn parse(word: &str) -> Option<Self> {
        match word.trim().to_ascii_lowercase().as_str() {
            "local" | "here" | "mac" | "laptop" => Some(Self::Local),
            "cloud" => Some(Self::Cloud),
            "auto" | "autocloud" | "auto-cloud" | "auto_cloud" => Some(Self::Auto),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Local => "local",
            Self::Cloud => "cloud",
            Self::Auto => "auto",
        }
    }

    /// The place a chat's `autoSession` row says it is in (`AutoRecord::row`).
    pub fn of_row(row: &Value) -> Self {
        match (row["auto"].as_bool(), row["keepInCloud"].as_bool()) {
            (Some(true), Some(true)) => Self::Cloud,
            (Some(true), _) => Self::Auto,
            _ => Self::Local,
        }
    }

    /// The `_acpmux/auto_session/set` params that put a chat here.
    pub fn set_params(self, session: &str) -> Value {
        match self {
            Self::Local => json!({"sessionId": session, "auto": false}),
            Self::Cloud => json!({"sessionId": session, "auto": true, "keepInCloud": true}),
            Self::Auto => json!({"sessionId": session, "auto": true, "keepInCloud": false}),
        }
    }
}

/// Who asks for a move.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Asker {
    /// The person.
    Person,
    /// An agent: whether the chat is its own, the person's `cloud.autoCloud` setting, and whether
    /// the kill switch is off (agent moves on).
    Agent { own_chat: bool, auto_cloud: bool, enabled: bool },
}

/// What a move ask comes to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Consent {
    /// Already there: nothing to do.
    Already,
    /// Move it.
    Go,
    /// Only the person may: why, for the answer.
    NeedsPerson(&'static str),
    /// Never, for this asker.
    Refused(&'static str),
}

/// Whether `asker` may move a chat from `from` to `to` (module docs).
pub fn consent(from: Place, to: Place, asker: Asker) -> Consent {
    match asker {
        Asker::Person => {
            if from == to {
                Consent::Already
            } else {
                Consent::Go
            }
        }
        Asker::Agent { own_chat: false, .. } => {
            Consent::Refused("an agent may move only its own chat")
        }
        Asker::Agent { own_chat: true, auto_cloud, enabled } => {
            if from == to {
                Consent::Already
            } else if !enabled {
                Consent::NeedsPerson("agent moves are switched off (CMUX_AGENT_CHAT_MOVE=off)")
            } else if to == Place::Local {
                Consent::NeedsPerson(
                    "bringing a chat back to the Mac writes into the person's folder",
                )
            } else if !auto_cloud {
                Consent::NeedsPerson("AutoCloud is off in the person's settings (cloud.autoCloud)")
            } else {
                Consent::Go
            }
        }
    }
}

/// Whether the agent's half of moves is on: [`AGENT_KILL_SWITCH`] unset or anything but off.
pub fn agent_moves_enabled() -> bool {
    agent_moves_enabled_by(std::env::var(AGENT_KILL_SWITCH).ok().as_deref())
}

pub fn agent_moves_enabled_by(value: Option<&str>) -> bool {
    !matches!(
        value.map(|v| v.trim().to_ascii_lowercase()).as_deref(),
        Some("off" | "0" | "false" | "no")
    )
}

/// The command the person runs to make a move themselves.
pub fn person_command(session: &str, to: Place) -> String {
    format!("cmux chat move {session} --on {}", to.as_str())
}

/// The answer for a move that was not made: `already` or `needs_person`.
pub fn not_moved(session: &str, from: Place, to: Place, consent: &Consent) -> Value {
    match consent {
        Consent::NeedsPerson(why) => json!({
            "status": "needs_person",
            "from": from.as_str(),
            "to": to.as_str(),
            "why": why,
            "command": person_command(session, to),
        }),
        _ => json!({"status": "already", "from": from.as_str(), "to": to.as_str()}),
    }
}

#[cfg(test)]
#[path = "chat_place_tests.rs"]
mod tests;
