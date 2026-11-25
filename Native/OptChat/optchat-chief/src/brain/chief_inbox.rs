//! One stable acpmux session per Chief on this Mac (Leo: Chief-to-Chief
//! messaging between Chief, Codex Chief and Hybrid Chief, both ways, with
//! the sender shown and replies routed back into the sender's chat).
//!
//! Each Chief keeps a listed session named [`name`] (`chief-codex-chief`)
//! on acpmux's built-in `chief` harness, `cmux chief acp`, with its
//! participant id in the session env (`CMUX_CHIEF_PARTICIPANT`). A message
//! sent to it with #30082's `acpmux_send` lands in this Chief's own
//! conversation as the sender's (`[from chief:<sender>]` or `[from <lane>]`,
//! `cmux_conversation::agent_sender`), so this Chief reads it under the ask
//! floor. When another Chief's turn sent it (acpmux names that Chief in
//! `_meta.acpmux.sender.chief`), `cmux chief acp` posts this Chief's reply
//! back into the sender's conversation as a `result`, which is never
//! answered again. A turn under the ask floor may not use `acpmux_send`, so
//! two Chiefs cannot loop.
//!
//! The session carries no `cmux.chief` tag: it is not one of the Chief's
//! turn or compactor sessions, which acpmux and the app keep out of sight.

use std::collections::BTreeMap;

use super::Brain;
use crate::acpmux::SessionSpec;

/// The tag naming the Chief a stable Chief session relays to.
pub const INBOX_TAG: &str = "cmux.chief.inbox";
/// The session env `cmux chief acp` reads its Chief from (acpmux
/// session_env.rs).
pub const PARTICIPANT_ENV: &str = "CMUX_CHIEF_PARTICIPANT";
/// acpmux's built-in Chief harness (`cmux chief acp`).
const HARNESS: &str = crate::harness_gate::CHIEF_HARNESS_FAMILY;

/// `name` lowercased, each run of characters other than ASCII letters,
/// digits, `.` and `_` as one `-`; `chief` when nothing is left.
fn handle(name: &str) -> String {
    let mut out = String::new();
    for c in name.trim().chars().flat_map(char::to_lowercase) {
        if c.is_ascii_alphanumeric() || c == '.' || c == '_' {
            out.push(c);
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    let out = out.trim_matches('-');
    if out.is_empty() {
        "chief".to_owned()
    } else {
        out.to_owned()
    }
}

/// The stable session's name for Chief `participant` called `title`:
/// `chief` for the default Chief (agent_mux, whatever its localized name),
/// `chief-codex-chief` for "Codex Chief".
pub fn name(participant: &str, title: &str) -> String {
    if participant == cmux_chief::rules::AGENT_MUX {
        return "chief".to_owned();
    }
    let handle = handle(title);
    if handle == "chief" || handle.starts_with("chief-") {
        handle
    } else {
        format!("chief-{handle}")
    }
}

impl Brain {
    /// At each link up: makes this Chief's stable session when acpmux lists
    /// none by its name (`listed`); a failure is logged and tried again at
    /// the next link up.
    pub(super) fn ensure_chief_inbox(&mut self, listed: &[String]) {
        let Some(title) = self.settings.chief_inbox.clone() else {
            return;
        };
        let participant = self.settings.membership.participant.clone();
        let session = name(&participant, &title);
        if listed.contains(&session) {
            return;
        }
        let spec = SessionSpec {
            name: session.clone(),
            cwd: self.settings.session_dir.clone(),
            harness: HARNESS.to_owned(),
            // The relay runs no tools; nothing it asks is allowed.
            policy: crate::approval::ASK.to_owned(),
            model: None,
            effort: None,
            preset: None,
            tags: BTreeMap::from([
                (INBOX_TAG.to_owned(), participant.clone()),
                (cmux_chief::rules::LABEL_TAG.to_owned(), title),
            ]),
            env: BTreeMap::from([(PARTICIPANT_ENV.to_owned(), participant)]),
            fast: false,
            peer: None,
        };
        match self.agents.new_plain_session(&spec) {
            Ok(_) => (self.log)(&format!("chief inbox: made acpmux session {session}")),
            Err(e) => (self.log)(&format!("chief inbox: acpmux session {session}: {e}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_chiefs_session_is_named_after_it() {
        let other = "agent_codex";
        assert_eq!(name(cmux_chief::rules::AGENT_MUX, "Chef"), "chief");
        assert_eq!(name(other, "Codex Chief"), "chief-codex-chief");
        assert_eq!(name(other, "Hybrid Chief"), "chief-hybrid-chief");
        assert_eq!(name(other, "Chief 2"), "chief-2");
        assert_eq!(name(other, "  "), "chief");
    }
}
