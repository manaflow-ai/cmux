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
mod tests {
    use super::*;
    use serde_json::json;

    fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        move |key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
    }

    const TERMINAL: [(&str, &str); 4] = [
        ("CLAUDECODE", "1"),
        ("CLAUDE_CODE_ENTRYPOINT", "cli"),
        ("CLAUDE_CODE_MESSAGING_SOCKET", "/tmp/cc-socks/77.sock"),
        ("CLAUDE_CODE_MESSAGING_TOKEN", "tok"),
    ];
    const SESSION: &str = "9F3A61C2-0b7e-4c55-8d2e-3a1f00c0ffee";

    /// Repro (Leo, 2026-11-25: "why isn't it registered?"): a coordinator Claude Code in a cmux
    /// terminal had no acpmux name, so no `acpmux send` reached it. cmux's hook now takes the
    /// first step for it, under a stable name, and stops once the daemon says it is reached.
    #[test]
    fn a_terminal_claude_code_registers_from_cmuxs_hook_until_it_is_reached() {
        let home = tempfile::tempdir().unwrap();
        let args = hook_args(env(&TERMINAL), Some(SESSION), "cosmic-gray", home.path()).unwrap();
        assert_eq!(args, ["register", "--auto", "claude-cosmic-gray-9f3a61c2", "--json"]);
        // The payload's id wins; the environment's is the fallback.
        let with_env: Vec<_> =
            TERMINAL.iter().copied().chain([("CLAUDE_CODE_SESSION_ID", SESSION)]).collect();
        assert_eq!(hook_args(env(&with_env), None, "cosmic-gray", home.path()), Some(args.clone()));

        // A code went to the inbox: not reached yet, so the next prompt asks again.
        let sock = "/tmp/cc-socks/77.sock";
        mark_if_reached(home.path(), sock, "tok", &json!({"pending": true, "name": "x"}));
        assert_eq!(
            hook_args(env(&TERMINAL), Some(SESSION), "cosmic-gray", home.path()),
            Some(args)
        );

        // Registered with this process: no process for it again.
        mark_if_reached(home.path(), sock, "tok", &json!({"registered": true, "name": "x"}));
        assert_eq!(hook_args(env(&TERMINAL), Some(SESSION), "cosmic-gray", home.path()), None);
        // A restarted Claude Code (a new token) asks again.
        let restarted: Vec<_> = TERMINAL
            .iter()
            .map(|&(k, v)| (k, if k == "CLAUDE_CODE_MESSAGING_TOKEN" { "tok2" } else { v }))
            .collect();
        assert!(hook_args(env(&restarted), Some(SESSION), "cosmic-gray", home.path()).is_some());
    }

    #[test]
    fn a_session_acpmux_runs_or_a_shell_with_no_inbox_asks_nothing() {
        let home = tempfile::tempdir().unwrap();
        let inside: Vec<_> = TERMINAL
            .iter()
            .copied()
            .chain([("ACPMUX_SESSION_ID", "s1"), (crate::hub::person::CALLER_TOKEN_ENV, "t")])
            .collect();
        assert_eq!(hook_args(env(&inside), Some(SESSION), "h", home.path()), None, "acpmux's own");
        for missing in ["CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN"] {
            let without: Vec<_> = TERMINAL.iter().copied().filter(|(k, _)| *k != missing).collect();
            assert_eq!(
                hook_args(env(&without), Some(SESSION), "h", home.path()),
                None,
                "{missing}"
            );
        }
        assert_eq!(hook_args(env(&TERMINAL), None, "h", home.path()), None, "no session id");
        assert_eq!(hook_args(env(&TERMINAL), Some("--"), "h", home.path()), None, "no word");
    }

    #[test]
    fn the_name_is_the_host_and_the_session_ids_first_eight() {
        assert_eq!(
            terminal_name("Cosmic-Gray", SESSION).as_deref(),
            Some("claude-cosmic-gray-9f3a61c2")
        );
        assert_eq!(terminal_name("mac_mini.2", "abc").as_deref(), Some("claude-mac-mini-2-abc"));
        assert_eq!(terminal_name("", SESSION), None);
        assert_eq!(terminal_name("h", "--"), None);
        assert!(reached(&json!({"reachable": true})));
        assert!(reached(&json!({"renewed": true})));
        assert!(!reached(&json!({"renewed": null, "retryable": true})));
        assert!(!reached(&json!({"failed": "x", "repeat": true})));
    }
}
