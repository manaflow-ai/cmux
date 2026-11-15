//! A reply address for a Claude Code chat acpmux did not start, from its first `acpmux send`.
//!
//! Leo, 2026-11-15, on a desktop chat that sent the coordinator a question and said it would wait
//! for the answer: "it cant answer to you... you need to think of how it can do something". Such
//! a send names its harness (`cli/sender.rs` `harness_name`), a claimed label, not an address:
//! nothing can reply until the chat registers (`hub/register.rs`), and the chat did not know to.
//!
//! So `acpmux send` from that chat's own shell starts the registration itself: the first step of
//! `acpmux register NAME` (`_acpmux/register`, `auto`), under a name its session id gives, which
//! delivers a one-time code into the chat's own inbox. The chat's model reads that message and
//! runs the `--code` line it gives; then the receiver's replies reach it, and its sends carry the
//! address. Every proof `register` makes is kept: the daemon checks the caller's process tree and
//! inbox, and the code must come back from the same process. The daemon sends no second code
//! while one waits, and none to a chat already registered with the caller's token, so a chat that
//! sends often is not flooded. The send itself never waits on any of it for long, and never fails
//! because of it.

use serde_json::{Value, json};
use std::time::Duration;

/// How long a send waits for the daemon's answer: the first step's proof runs `codesign` once.
const WAIT: Duration = Duration::from_secs(3);

/// What a send from an unregistered chat's shell asks the daemon to register.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AutoRegister {
    /// The name it registers as: `claude-desktop-03214b87` (the harness, then the first 8
    /// characters of `CLAUDE_CODE_SESSION_ID`), so a send after a send asks for the same one.
    pub name: String,
    /// `CLAUDE_CODE_MESSAGING_SOCKET`.
    pub socket: String,
    /// `CLAUDE_CODE_MESSAGING_TOKEN`.
    pub token: String,
}

/// Whether a send run with `env` starts its chat's registration, and with which name: a Claude
/// Code shell (`CLAUDECODE`) outside any acpmux session, naming no sender (`named`: `--from`, a
/// relay's or a notice's; `ACPMUX_FROM`), with the inbox Claude Code exports to its commands and
/// a session id to name it by. Anything else already has an address, or is the person's send.
pub fn auto_register_in(env: impl Fn(&str) -> Option<String>, named: bool) -> Option<AutoRegister> {
    let set = |key: &str| env(key).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
    if named || crate::cli::sender::in_session(&env) || set(crate::cli::sender::FROM_ENV).is_some()
    {
        return None;
    }
    set("CLAUDECODE")?;
    let socket = set("CLAUDE_CODE_MESSAGING_SOCKET")?;
    let token = set("CLAUDE_CODE_MESSAGING_TOKEN")?;
    let short: String = set("CLAUDE_CODE_SESSION_ID")?
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .take(8)
        .collect::<String>()
        .to_ascii_lowercase();
    if short.is_empty() {
        return None;
    }
    let harness = match set("CLAUDE_CODE_ENTRYPOINT").as_deref() {
        Some("claude-desktop") => "claude-desktop",
        Some("claude-vscode") => "claude-vscode",
        _ => "claude-code",
    };
    let name = format!("{harness}-{short}");
    crate::session_name::validate(&name).ok()?;
    Some(AutoRegister { name, socket, token })
}

/// The registration this process's send starts. Only on macOS: elsewhere no code signature
/// proves a process is Claude Code, so the daemon refuses every `register`.
pub fn of_this_process(named: bool) -> Option<AutoRegister> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    auto_register_in(|key| std::env::var(key).ok(), named)
}

/// Starts `want` on `client` and says on stderr what the chat must do; at most [`WAIT`].
pub async fn start(client: &crate::client::Client, want: &AutoRegister) {
    let params = json!({
        "name": want.name, "socket": want.socket, "token": want.token, "auto": true,
    });
    let answer =
        tokio::time::timeout(WAIT, client.request(crate::rpc::method::MUX_REGISTER, params));
    let answer = match answer.await {
        Ok(Ok(v)) => Ok(v),
        Ok(Err(e)) => Err(e.to_string()),
        Err(_) => Err(format!("the daemon did not answer within {}s", WAIT.as_secs())),
    };
    if let Some(line) = line(&want.name, &crate::host_pressure::host_name(), answer) {
        eprintln!("{line}");
    }
}

/// The line a send prints for the daemon's `answer`: none once the chat is registered.
fn line(name: &str, host: &str, answer: Result<Value, String>) -> Option<String> {
    let v = match answer {
        Ok(v) => v,
        Err(why) => {
            return Some(format!(
                "the receiver cannot reply to this chat: it has no acpmux address, and registering it did not start ({why}); run `acpmux register {name}` in this shell, then the `--code` line it delivers"
            ));
        }
    };
    if v.get("registered").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    // A code another `register` asked for, under its own name, is the one to finish.
    let name = v.get("name").and_then(Value::as_str).unwrap_or(name);
    Some(format!(
        "the receiver cannot reply to this chat until it is registered: a one-time code is in this chat's inbox (a message from acpmux); run the `acpmux register {name} --code ...` it gives, and replies then reach {host}/{name}"
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        move |key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
    }

    const DESKTOP: [(&str, &str); 5] = [
        ("CLAUDECODE", "1"),
        ("CLAUDE_CODE_ENTRYPOINT", "claude-desktop"),
        ("CLAUDE_CODE_SESSION_ID", "03214B87-953d-4ecf-98ae-93d337878273"),
        ("CLAUDE_CODE_MESSAGING_SOCKET", "/tmp/cc-socks/42.sock"),
        ("CLAUDE_CODE_MESSAGING_TOKEN", "tok"),
    ];

    fn with(extra: &[(&'static str, &'static str)]) -> Vec<(&'static str, &'static str)> {
        DESKTOP.iter().copied().chain(extra.iter().copied()).collect()
    }

    fn swap(key: &str, value: &'static str) -> Vec<(&'static str, &'static str)> {
        DESKTOP.iter().map(|&(k, v)| (k, if k == key { value } else { v })).collect()
    }

    /// Repro (ask-828b64b532): a desktop chat on cosmic-gray that never registered sent the
    /// coordinator a question, and nothing could answer it. Its send now starts registering it,
    /// under the same name on every send.
    #[test]
    fn an_unregistered_claude_code_chats_send_starts_its_registration() {
        let want = auto_register_in(env(&DESKTOP), false).expect("registers");
        assert_eq!(want.name, "claude-desktop-03214b87");
        assert_eq!(want.socket, "/tmp/cc-socks/42.sock");
        assert_eq!(want.token, "tok");
        assert_eq!(auto_register_in(env(&DESKTOP), false), Some(want), "the same name again");
        let vscode = swap("CLAUDE_CODE_ENTRYPOINT", "claude-vscode");
        assert_eq!(auto_register_in(env(&vscode), false).unwrap().name, "claude-vscode-03214b87");
        let cli = swap("CLAUDE_CODE_ENTRYPOINT", "cli");
        assert_eq!(auto_register_in(env(&cli), false).unwrap().name, "claude-code-03214b87");
    }

    /// A sender with an address, a named one, the person's own send, or a shell with no inbox
    /// starts nothing.
    #[test]
    fn a_send_with_an_address_or_no_inbox_starts_nothing() {
        assert_eq!(auto_register_in(env(&DESKTOP), true), None, "--from");
        let from = with(&[(crate::cli::sender::FROM_ENV, "reach-lane")]);
        assert_eq!(auto_register_in(env(&from), false), None, "ACPMUX_FROM");
        let inside = with(&[("ACPMUX_SESSION_ID", "s1"), ("ACPMUX_SESSION_TOKEN", "t")]);
        assert_eq!(auto_register_in(env(&inside), false), None, "an acpmux session");
        for missing in [
            "CLAUDECODE",
            "CLAUDE_CODE_MESSAGING_SOCKET",
            "CLAUDE_CODE_MESSAGING_TOKEN",
            "CLAUDE_CODE_SESSION_ID",
        ] {
            let without: Vec<_> = DESKTOP.iter().copied().filter(|(k, _)| *k != missing).collect();
            assert_eq!(auto_register_in(env(&without), false), None, "no {missing}");
        }
        let odd = swap("CLAUDE_CODE_SESSION_ID", "--");
        assert_eq!(auto_register_in(env(&odd), false), None, "no word to name it by");
        assert_eq!(auto_register_in(env(&[("CODEX_THREAD_ID", "t-1")]), false), None, "Codex");
        assert_eq!(auto_register_in(env(&[]), false), None, "the person's terminal");
    }

    #[test]
    fn the_send_says_what_the_chat_must_do_until_it_is_registered() {
        let pending = json!({"pending": true, "name": "claude-desktop-03214b87"});
        let shown = line("claude-desktop-03214b87", "cosmic-gray", Ok(pending)).unwrap();
        assert_eq!(
            shown,
            "the receiver cannot reply to this chat until it is registered: a one-time code is in this chat's inbox (a message from acpmux); run the `acpmux register claude-desktop-03214b87 --code ...` it gives, and replies then reach cosmic-gray/claude-desktop-03214b87"
        );
        // A code `acpmux register desktop-zoe` asked for still waits: that name is the one.
        let other = json!({"pending": true, "resent": false, "name": "desktop-zoe"});
        let shown = line("claude-desktop-03214b87", "cosmic-gray", Ok(other)).unwrap();
        assert!(shown.ends_with("reach cosmic-gray/desktop-zoe"), "{shown}");
        let done = json!({"registered": true, "name": "desktop-zoe"});
        assert_eq!(line("claude-desktop-03214b87", "cosmic-gray", Ok(done)), None);
        let failed = line("claude-desktop-03214b87", "h", Err("register.unproven: x".into()));
        assert_eq!(
            failed.as_deref(),
            Some(
                "the receiver cannot reply to this chat: it has no acpmux address, and registering it did not start (register.unproven: x); run `acpmux register claude-desktop-03214b87` in this shell, then the `--code` line it delivers"
            )
        );
    }
}
