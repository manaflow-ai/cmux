//! The marks `acpmux register --auto` leaves, one per Claude Code process (its inbox and token),
//! once the daemon's answer settles the chat: reached with this process, or no code coming.
//!
//! cmux's prompt hook (`cmux-tui-hook`, UserPromptSubmit) ran `register --auto` at every prompt
//! of a terminal Claude Code chat from 2026-11-25, and the daemon delivered a one-time code into
//! the chat as a prompt each time the last one expired (Lawrence, 2026-11-28: "who keeps sending
//! this to the claude code TUIs??"; 201 codes in a day into one chat that ran no send). The hook
//! no longer asks, and the daemon sends a code only for `acpmux send` from the chat's own shell
//! (`hub/register.rs` `auto_why`).

use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The folder of marks, in acpmux's home.
const MARKS: &str = "hook-registered";

/// How long a mark is kept: past it, a Claude Code process still running asks once more (the
/// daemon answers from memory), so the folder holds about a week of processes, not every one.
const MARK_TTL: Duration = Duration::from_secs(7 * 24 * 3600);

/// The mark for the Claude Code process whose inbox is `socket`, opened with `token`.
pub fn mark_path(home: &Path, socket: &str, token: &str) -> PathBuf {
    let mut hash = Sha256::new();
    hash.update(socket.as_bytes());
    hash.update([0]);
    hash.update(token.as_bytes());
    let digest = hash.finalize();
    let name: String = digest.iter().take(16).map(|b| format!("{b:02x}")).collect();
    home.join(MARKS).join(name)
}

/// Whether the daemon's `answer` says the chat is reached with this process: registered with
/// its token, reachable through the bridge, or renewed after a restart.
pub fn reached(answer: &Value) -> bool {
    ["registered", "reachable", "renewed"]
        .iter()
        .any(|key| answer.get(*key).and_then(Value::as_bool) == Some(true))
}

/// Whether the daemon's `answer` says this process gets no code from another ask: reached, or
/// an automatic code already went to the chat (`offered`), so a later prompt has nothing to ask.
pub fn settled(answer: &Value) -> bool {
    reached(answer) || answer.get("offered").and_then(Value::as_bool).is_some()
}

/// Leaves the mark for `socket` and `token` when `answer` is [`settled`], and drops marks older
/// than [`MARK_TTL`]. Best effort: a mark not written only costs another ask.
pub(crate) fn mark_if_reached(home: &Path, socket: &str, token: &str, answer: &Value) {
    if !settled(answer) {
        return;
    }
    let path = mark_path(home, socket, token);
    let Some(dir) = path.parent() else { return };
    if crate::home_fs::create_dir_all(dir, 0o700).is_err() {
        return;
    }
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let old = entry
                .metadata()
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.elapsed().ok())
                .is_some_and(|age| age > MARK_TTL);
            if old {
                let _ = crate::home_fs::remove_file(entry.path());
            }
        }
    }
    let _ = crate::home_fs::write(&path, b"");
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// Repro (Lawrence, 2026-11-28): an ask after a code expired delivered a new one. An
    /// answer that settles the chat (reached, or no code coming) leaves the mark; a waiting
    /// code does not.
    #[test]
    fn only_a_settled_answer_leaves_the_mark() {
        let home = tempfile::tempdir().unwrap();
        let sock = "/tmp/cc-socks/77.sock";
        let mark = mark_path(home.path(), sock, "tok");
        mark_if_reached(home.path(), sock, "tok", &json!({"pending": true, "name": "x"}));
        assert!(!mark.exists());
        mark_if_reached(home.path(), sock, "tok", &json!({"offered": false, "reason": "r"}));
        assert!(mark.exists());
        assert!(!mark_path(home.path(), sock, "tok2").exists(), "a restarted process");
        assert!(settled(&json!({"offered": true})));
        assert!(!settled(&json!({"pending": true, "resent": false})));
        assert!(reached(&json!({"reachable": true})));
        assert!(reached(&json!({"renewed": true})));
        assert!(!reached(&json!({"renewed": null, "retryable": true})));
        assert!(!reached(&json!({"failed": "x", "repeat": true})));
    }
}
