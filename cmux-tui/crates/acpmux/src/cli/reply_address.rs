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
// timeout: a cap on a side step, not on the send: past it the send goes on and the daemon still delivers the code.
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

/// How long a send waits for the first step: none when the daemon does not take `auto` (an
/// older one delivers a code on every send), and at most half of what is left of the send's own
/// `--timeout`, so the send itself always keeps the other half.
fn wait_for(
    lists_auto: bool,
    deadline: Option<tokio::time::Instant>,
    now: tokio::time::Instant,
) -> Option<Duration> {
    if !lists_auto {
        return None;
    }
    let half = deadline.map_or(WAIT, |d| d.saturating_duration_since(now) / 2);
    Some(half.min(WAIT)).filter(|w| !w.is_zero())
}

/// Starts `want` on `client` and says on stderr what the chat must do, within [`wait_for`].
pub async fn start(
    client: &crate::client::Client,
    want: &AutoRegister,
    deadline: Option<tokio::time::Instant>,
) {
    let lists = client.daemon_lists(crate::hub::register::AUTO_FEATURE);
    let Some(wait) = wait_for(lists, deadline, tokio::time::Instant::now()) else { return };
    let params = json!({
        "name": want.name, "socket": want.socket, "token": want.token, "auto": true,
    });
    let answer =
        tokio::time::timeout(wait, client.request(crate::rpc::method::MUX_REGISTER, params));
    let outcome = match answer.await {
        Ok(Ok(v)) => Outcome::Answer(v),
        Ok(Err(e)) => Outcome::Refused(e.to_string()),
        Err(_) => Outcome::NoAnswer,
    };
    if let Some(line) = line(&want.name, &crate::host_pressure::host_name(), outcome) {
        eprintln!("{line}");
    }
}

/// How long `acpmux register --renew` waits for the daemon: a hook runs it at every session's
/// start and turn end, so it must never hold Claude Code up.
// timeout: a hook's side step; past it the session goes on, and the next hook asks again.
const RENEW_WAIT: Duration = Duration::from_secs(3);

/// `acpmux register --renew`, from a Claude Code hook: hands the session's new token to this
/// machine's daemon, which takes it only for a chat registered before a restart with `--resume`
/// (`hub/register.rs` `renewed_name`), so `acpmux send NAME` reaches the restarted session with
/// no one running `register` in it (Leo, 2026-11-20: "isn't one I can message through acpmux /
/// well figure out a way then"). Starts no daemon and delivers no code; the daemon's answer, or
/// why there was none, for `--json`.
pub async fn renew() -> Value {
    let Some(want) = of_this_process(false) else {
        return json!({"renewed": false, "reason": "not a Claude Code shell acpmux did not start"});
    };
    let ask = async {
        let client = crate::client::Client::connect(&crate::config::socket_path()).await?;
        let params = json!({
            "name": want.name, "socket": want.socket, "token": want.token, "renew": true,
        });
        client.request(crate::rpc::method::MUX_REGISTER, params).await
    };
    match tokio::time::timeout(RENEW_WAIT, ask).await {
        Ok(Ok(v)) => v,
        Ok(Err(e)) => json!({"renewed": false, "reason": e.to_string()}),
        Err(_) => json!({"renewed": false, "reason": "the daemon did not answer in time"}),
    }
}

/// What the daemon did with the first step.
#[derive(Debug)]
enum Outcome {
    Answer(Value),
    /// It refused it, saying why: no code went.
    Refused(String),
    /// No answer in time: the daemon may still deliver the code.
    NoAnswer,
}

/// The line a send prints for `outcome`: none once the chat has an address, or for a failure
/// the daemon already reported to an earlier send (`repeat`).
fn line(name: &str, host: &str, outcome: Outcome) -> Option<String> {
    let program = crate::cli::entry::program();
    let v = match outcome {
        Outcome::Answer(v) => v,
        Outcome::Refused(why) => {
            return Some(format!(
                "the receiver cannot reply to this chat: it has no acpmux address, and registering it did not start ({why}); run `{program} register {name}` in this shell, then the `--code` line it delivers"
            ));
        }
        // A manual `register` now would send a second code, which replaces the first.
        Outcome::NoAnswer => {
            return Some(format!(
                "the receiver cannot reply to this chat until it is registered; registering it did not answer within {}s, and a one-time code may still arrive in this chat's inbox (a message from acpmux): run the `{program} register ... --code ...` line it gives",
                WAIT.as_secs()
            ));
        }
    };
    let flag = |k: &str| v.get(k).and_then(Value::as_bool) == Some(true);
    if flag("registered") || flag("reachable") || flag("repeat") {
        return None;
    }
    // The daemon's name wins: a chat that has one keeps it, and a code another `register` asked
    // for is the one to finish. A step another send started has none yet.
    match v.get("name").and_then(Value::as_str) {
        Some(name) => Some(format!(
            "the receiver cannot reply to this chat until it is registered: a one-time code is in this chat's inbox (a message from acpmux); run the `{program} register {name} --code ...` it gives, and replies then reach {host}/{name}"
        )),
        None => Some(format!(
            "the receiver cannot reply to this chat until it is registered: a one-time code is coming to this chat's inbox (a message from acpmux); run the `{program} register ... --code ...` line it gives, and replies then reach the name it names on this machine"
        )),
    }
}

#[cfg(test)]
#[path = "reply_address_tests.rs"]
mod tests;
