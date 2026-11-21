//! What a chat's log keeps of Claude Code's raw `system/init` lines.
//!
//! Claude Code writes its whole `system/init` at the start of every turn: the tools, MCP servers,
//! slash commands, agents, skills and plugins, ~79 KB in a big session (84 KB of one was
//! `slash_commands`). Consecutive inits of one session differ only in `uuid` and
//! `user_message_uuids`, so on Leo's Mac (2026-11-08) the kind was ~99 MB a day of acpmux's log,
//! 1,256 lines a day of the same sections.
//!
//! The log keeps a session's first init whole and, after it, each list or object section only
//! when it differs from the one last logged; every scalar (`session_id`, `model`, `cwd`, `uuid`,
//! ...) stays, as readers take the session id from the line (leo-workspace `leo-asks`). The line
//! names the sections it left out as `_acpmux.sameAsLastInit`, so a reader finds each in the
//! nearest earlier init that has it. Only hashes of the sections are held, not the sections.

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashMap;

/// The raw kind whose repeated sections the log leaves out.
const KIND: &str = "claude.system.init";

/// The sections of the last `system/init` a session logged, as hashes of their JSON.
#[derive(Default)]
pub struct LoggedInit {
    sections: HashMap<String, [u8; 32]>,
}

/// The sections of one init that differ from the last logged: recorded only once the line is
/// logged ([`LoggedInit::note_logged`]), so a line whose write failed and is retried is compared
/// with what the log holds, not with what it never kept.
#[derive(Default)]
#[must_use]
pub struct InitSections(Vec<(String, [u8; 32])>);

impl LoggedInit {
    /// `line`, a raw Claude line of `kind` as it is about to be logged, without the list and object
    /// sections the session's last logged init had the same, and the sections it keeps. Other
    /// kinds are left as they are.
    pub fn leave_out_repeats(&self, kind: &str, line: &mut Value) -> InitSections {
        let mut changed = InitSections::default();
        if kind != KIND {
            return changed;
        }
        let Some(fields) = line.as_object_mut() else { return changed };
        let mut repeated = Vec::new();
        fields.retain(|key, value| {
            if !(value.is_array() || value.is_object()) || key == "_acpmux" {
                return true;
            }
            let hash = hash(value);
            let same = self.sections.get(key) == Some(&hash);
            if same {
                repeated.push(Value::from(key.clone()));
            } else {
                changed.0.push((key.clone(), hash));
            }
            !same
        });
        if !repeated.is_empty() {
            let note = fields.entry("_acpmux").or_insert_with(|| json!({}));
            if let Some(note) = note.as_object_mut() {
                note.insert("sameAsLastInit".into(), Value::Array(repeated));
            }
        }
        changed
    }

    /// The line [`Self::leave_out_repeats`] trimmed is in the log: its sections are the last logged.
    pub fn note_logged(&mut self, sections: InitSections) {
        self.sections.extend(sections.0);
    }
}

/// A section's JSON, hashed.
fn hash(value: &Value) -> [u8; 32] {
    let bytes = serde_json::to_vec(value).unwrap_or_default();
    Sha256::digest(bytes).into()
}

#[cfg(test)]
#[path = "logged_init_tests.rs"]
mod tests;
