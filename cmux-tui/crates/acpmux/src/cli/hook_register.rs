//! A Claude Code session started in a cmux terminal takes an acpmux name with no one running
//! `acpmux register` in it: cmux's own hook (`cmux-tui-hook`, at `UserPromptSubmit`) runs
//! `acpmux register --auto NAME`, the first step a send from an unregistered chat already takes
//! (`reply_address.rs`, `hub/register_auto.rs`).
//!
//! Leo, 2026-11-25, about a coordinator in a cmux terminal that no one could message: "why isn't
//! it registered?" Only a chat acpmux started, or one that ran `register` (or sent once and then
//! ran the `--code` line), had an address; a terminal `claude` had neither.
//!
//! Every proof `register` makes is kept: the daemon checks the caller's process tree (the hook
//! runs under the Claude Code process) and inbox, and the chat's model echoes the one-time code
//! delivered into its inbox. What the hook adds is only that the first step happens without a
//! send. The daemon decides the name: a chat it already shows keeps its name; any other gets
//! [`terminal_name`], `claude-<host>-<first 8 of the session id>`.
//!
//! Once the daemon answers that the chat is registered with this process (or the bridge reaches
//! it), the CLI leaves a mark for the inbox and token ([`mark_path`]); the hook then starts no
//! process for that Claude Code process again, so a prompt costs one file check.

use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The folder of marks, in acpmux's home.
const MARKS: &str = "hook-registered";

/// How long a mark is kept: past it, a Claude Code process still running asks once more (the
/// daemon answers from memory), so the folder holds about a week of processes, not every one.
const MARK_TTL: Duration = Duration::from_secs(7 * 24 * 3600);

/// The name a terminal Claude Code chat registers as when acpmux shows none for it.
pub fn terminal_name(host: &str, session_id: &str) -> Option<String> {
    let short: String = session_id
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .take(8)
        .collect::<String>()
        .to_ascii_lowercase();
    let host: String = host
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' { c.to_ascii_lowercase() } else { '-' })
        .collect();
    let host = host.trim_matches('-');
    if short.is_empty() || host.is_empty() {
        return None;
    }
    let name = format!("claude-{host}-{short}");
    crate::session_name::validate(&name).ok()?;
    Some(name)
}

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

/// The `acpmux` words the hook runs for a Claude Code session with `env` (the hook's own
/// environment) and `session_id` (the hook payload's), or `None`: a session acpmux runs (it has
/// its address), a shell without Claude Code's inbox, or a process already marked.
pub fn hook_args(
    env: impl Fn(&str) -> Option<String>,
    session_id: Option<&str>,
    host: &str,
    home: &Path,
) -> Option<Vec<String>> {
    let set = |key: &str| env(key).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
    if crate::cli::sender::in_session(&env) {
        return None;
    }
    let socket = set("CLAUDE_CODE_MESSAGING_SOCKET")?;
    let token = set("CLAUDE_CODE_MESSAGING_TOKEN")?;
    if mark_path(home, &socket, &token).exists() {
        return None;
    }
    let id = session_id
        .map(str::trim)
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
        .or_else(|| set("CLAUDE_CODE_SESSION_ID"))?;
    let name = terminal_name(host, &id)?;
    Some(["register", "--auto", &name, "--json"].map(str::to_owned).to_vec())
}

/// Whether the daemon's `answer` says the chat is reached with this process: registered with
/// its token, reachable through the bridge, or renewed after a restart.
pub fn reached(answer: &Value) -> bool {
    ["registered", "reachable", "renewed"]
        .iter()
        .any(|key| answer.get(*key).and_then(Value::as_bool) == Some(true))
}

/// Leaves the mark for `socket` and `token` when `answer` says the chat is reached, and drops
/// marks older than [`MARK_TTL`]. Best effort: a mark not written only costs another ask.
pub(crate) fn mark_if_reached(home: &Path, socket: &str, token: &str, answer: &Value) {
    if !reached(answer) {
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
#[path = "hook_register_tests.rs"]
mod tests;
