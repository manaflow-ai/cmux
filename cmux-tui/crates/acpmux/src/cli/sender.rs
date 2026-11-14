//! Who `acpmux send` names as its sender when given no `--from` (`_meta.acpmux.fromAgent`): a
//! claimed label only, never proof (`prompt_provenance.rs` `verified`).
//!
//! An agent in an acpmux session needs none: its caller token, inherited from the session's
//! process tree, proves the session to the daemon that issued it (`client.rs`, `hub/person.rs`
//! (a)). Run outside one, the shared Unix account proves nobody, so the CLI says what it can
//! tell: an agent harness's shell names itself and its harness (below), and the daemon records
//! that send as the agent's (Leo, 2026-11-05: "why is it sending it as if it were me?"). A send
//! that names no one and claims no harness is the owner's own terminal send, recorded as the
//! person's prompt (`server/requests.rs` `owner_terminal`). `ACPMUX_FROM` names an agent: `reach` sets it from the
//! caller's session name, the one identity that survives an ssh hop (claude-sr2, 2026-10-24).
//!
//! With neither, an agent harness's own shell names its harness ([`harness_name`]): Claude Code
//! (desktop, VS Code or terminal, by `CLAUDE_CODE_ENTRYPOINT`), Codex (`CODEX_THREAD_ID`), or any
//! tool that marks the commands it runs with `AI_AGENT` (`<tool>_<version>_<mode>`), with the
//! machine and the harness's session id. Leo, 2026-11-07: "could it possibly detect that you sent
//! it as the Claude Code desktop?" A desktop chat's `acpmux send` had read as his own words. Its
//! harness family goes along too (`fromHarness`, [`harness_of_this_process`]), so the receiver
//! shows that agent's mark; both are claims.

/// Names the sender of every `acpmux send` run with it set and no `--from`.
pub const FROM_ENV: &str = "ACPMUX_FROM";

/// Set by acpmux's Bash hook (`bg_hook.rs` [`crate::bg_hook::subagent_mark`]) on a command a
/// Claude Code subagent runs that may run the acpmux CLI (`bg_hook::may_run_acpmux`: not only one
/// that names acpmux; a wrapper, an alias or another path too): `TYPE:ID`, from the hook input's `agent_type` and
/// `agent_id`. A subagent runs in its lead's process and inherits the lead's whole environment
/// (`ACPMUX_SESSION_*`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_CHILD_SESSION` too: read on a real
/// Claude Code 2.1.319, 2026-11-08), so nothing else tells its send from its lead's. A label
/// within the session its caller token proves, never a proof of its own.
pub const SUBAGENT_ENV: &str = "ACPMUX_CALLER_SUBAGENT";

/// A Claude Code subagent that runs an `acpmux` command inside its lead's session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Subagent {
    /// Its type (`general-purpose`, `Explore`, a custom agent's name).
    pub kind: String,
    /// Claude Code's agent id (`a0a68e7af3df5967e`).
    pub id: String,
}

impl Subagent {
    /// `_meta.acpmux.callerSubagent`, which the daemon stamps on the provenance it binds.
    pub fn to_value(&self) -> serde_json::Value {
        serde_json::json!({"id": self.id, "type": self.kind})
    }

    /// "general-purpose subagent a0a68e7a".
    pub fn label(&self) -> String {
        format!("{} subagent {}", self.kind, self.id.chars().take(8).collect::<String>())
    }
}

/// A word the hook may put in a shell command unquoted, and the daemon in a provenance: 1 to 64
/// of `A-Za-z0-9._-`.
pub fn subagent_word(word: &str) -> bool {
    !word.is_empty()
        && word.len() <= 64
        && word.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// The subagent this process runs in, when it runs in an acpmux session and the hook marked it.
pub fn subagent_of_this_process() -> Option<Subagent> {
    subagent_in(|key| std::env::var(key).ok())
}

fn subagent_in(env: impl Fn(&str) -> Option<String>) -> Option<Subagent> {
    if !in_session(&env) {
        return None;
    }
    let raw = env(SUBAGENT_ENV)?;
    let (kind, id) = raw.trim().split_once(':')?;
    (subagent_word(kind) && subagent_word(id))
        .then(|| Subagent { kind: kind.to_owned(), id: id.to_owned() })
}

/// Who an agent's send goes out as: the line `acpmux send` prints after `sending as`, and the
/// subagent of the session that sends it (`_meta.acpmux.callerSubagent`), when one is known.
#[derive(Debug, Default)]
pub struct SendingAs {
    /// The `sending as …` text; `None` for the person's own send.
    pub shown: Option<String>,
    /// The subagent: the Bash hook's mark (Claude Code), else a Codex thread that is not the
    /// session's own ([`codex_thread_in`]).
    pub subagent: Option<Subagent>,
}

/// Who an agent's send on `client` goes out as: the session its caller token proved at
/// initialize, by its name as the daemon has it now (`ACPMUX_SESSION_NAME` is the name when its
/// agent started; `acpmux run -n` and a rename change it), and the subagent in it; a token this
/// daemon does not know; or the name it gave, which proves nothing. `shown` is `None` for the
/// person's own send.
pub async fn sending_as_on(client: &crate::client::Client, named: Option<&str>) -> SendingAs {
    let env = |key: &str| std::env::var(key).ok();
    if !in_session(env) {
        return SendingAs {
            shown: sending_as(env, named, None, &CodexThread::None),
            subagent: None,
        };
    }
    let Some(id) = client.proven_caller_session() else {
        return SendingAs { shown: Some(UNPROVEN.to_owned()), subagent: subagent_in(env) };
    };
    // Only the session list's fields (its name, its harness's own session id): no log wait.
    let params = serde_json::json!({"sessionId": id, "waitLogs": false});
    let ask = client.request(crate::rpc::method::MUX_INFO, params);
    // timeout: a wedged daemon must not hold the send; the line goes without the session's name.
    let info = tokio::time::timeout(std::time::Duration::from_secs(2), ask).await;
    let info = info.ok().and_then(Result::ok);
    let field = |key: &str| {
        info.as_ref()
            .and_then(|i| i.get(key))
            .and_then(serde_json::Value::as_str)
            .filter(|v| !v.is_empty())
    };
    let codex = codex_thread_in(env, field("agentSessionId"));
    let subagent = subagent_in(env).or(match &codex {
        CodexThread::Subagent(sub) => Some(sub.clone()),
        _ => None,
    });
    SendingAs { shown: sending_as(env, named, field("name"), &codex), subagent }
}

/// `sending as` for a session whose caller token the daemon did not prove.
const UNPROVEN: &str = "no proven session: this daemon does not know this session's caller token, \
    so the receiver cannot tell who sent it (`acpmux session restart @` gives the agent a new one)";

/// What `CODEX_THREAD_ID` tells of who runs a command in an acpmux session.
///
/// Codex has no hook that could mark a subagent's command as Claude Code's Bash hook does, but it
/// runs every command with `CODEX_THREAD_ID`, the id of the thread that runs it, and a subagent
/// it spawns (`spawn_agent`) runs in a thread of its own (read on Codex 0.167.0, 2026-11-08: the
/// lead's command printed 9862c5b9-…, its subagent's 81ef6aa6-…). acpmux knows the lead's thread
/// as the session's own id in its harness (`agentSessionId`), so another thread is a subagent. A
/// label within the session its caller token proves, as the hook's mark is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CodexThread {
    /// No Codex thread runs this command (or the hook marked a Claude Code subagent).
    None,
    /// The session's own thread: its lead.
    Lead,
    /// Another thread of the session's Codex: a subagent, `codex` and its thread id.
    Subagent(Subagent),
    /// A Codex thread, but the session's own thread id is not known: who it is cannot be told.
    Unknown,
}

/// What `CODEX_THREAD_ID` in `env` tells, against `lead`, the session's own thread id.
pub fn codex_thread_in(env: impl Fn(&str) -> Option<String>, lead: Option<&str>) -> CodexThread {
    let set = |key: &str| env(key).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
    let Some(thread) = set("CODEX_THREAD_ID") else { return CodexThread::None };
    if set(SUBAGENT_ENV).is_some() {
        return CodexThread::None;
    }
    match lead.map(str::trim) {
        Some(lead) if lead == thread => CodexThread::Lead,
        Some(_) if subagent_word(&thread) => {
            CodexThread::Subagent(Subagent { kind: "codex".to_owned(), id: thread })
        }
        _ => CodexThread::Unknown,
    }
}

/// The note `sending as` adds when a Codex thread cannot be told from its session's lead.
pub const CODEX_UNKNOWN: &str = "subagent identity not available for codex";

fn sending_as(
    env: impl Fn(&str) -> Option<String>,
    named: Option<&str>,
    current: Option<&str>,
    codex: &CodexThread,
) -> Option<String> {
    let set = |key: &str| env(key).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
    if in_session(&env) {
        let id = set("ACPMUX_SESSION_ID").unwrap_or_default();
        let name = current
            .map(str::to_owned)
            .or_else(|| set("ACPMUX_SESSION_NAME"))
            .unwrap_or_else(|| id.chars().take(8).collect());
        // The hook's mark names a Claude Code subagent; a Codex thread, one with no hook.
        let sub = subagent_in(&env).map(|sub| (sub, true)).or(match codex {
            CodexThread::Subagent(sub) => Some((sub.clone(), false)),
            _ => None,
        });
        return Some(match sub {
            Some((sub, hooked)) => subagent_line(&name, &sub, hooked, japanese(&env)),
            None if *codex == CodexThread::Unknown => format!("{name} ({CODEX_UNKNOWN})"),
            None => name,
        });
    }
    named.map(|name| format!("{name} (a name it gave, not proven)"))
}

/// `sending as` for subagent `sub` of session `name`, in English or Japanese: where the replies
/// to its sends go. A Claude Code subagent (`hooked`: acpmux's hook marked it) takes the reports
/// of the turns it asks for after its next Bash or acpmux MCP call, until it ends
/// (`hub/lane_report_subagents.rs`); a Codex one has no hook to take them, so only a reply its
/// send waits for reaches it.
fn subagent_line(name: &str, sub: &Subagent, hooked: bool, japanese: bool) -> String {
    let (label, kind) = (sub.label(), &sub.kind);
    let id = sub.id.chars().take(8).collect::<String>();
    match (hooked, japanese) {
        (true, false) => format!(
            "{name}'s {label} (replies to its sends come back to it after its next Bash command or acpmux MCP call; once it ends they go to {name}; `acpmux send {name}` reaches {name})"
        ),
        (true, true) => format!(
            "{name} の {kind} サブエージェント {id}（送信への返信は次の Bash コマンドまたは acpmux MCP 呼び出しの後にこのサブエージェントに届きます。終了後は {name} に届きます。`acpmux send {name}` は {name} に届きます）"
        ),
        (false, false) => format!(
            "{name}'s {label} (only a reply this send waits for reaches it; other replies go to {name}; `acpmux send {name}` reaches {name})"
        ),
        (false, true) => format!(
            "{name} の {kind} サブエージェント {id}（この送信が待つ返信だけがこのサブエージェントに届きます。他の返信は {name} に届きます。`acpmux send {name}` は {name} に届きます）"
        ),
    }
}

/// Whether `env`'s locale (LC_ALL, LC_MESSAGES, LANG, the first set) is Japanese, as
/// `cli/harness.rs` `add_help` reads it.
pub(crate) fn japanese(env: impl Fn(&str) -> Option<String>) -> bool {
    ["LC_ALL", "LC_MESSAGES", "LANG"]
        .iter()
        .find_map(|k| env(k).filter(|v| !v.is_empty()))
        .is_some_and(|locale| locale.to_ascii_lowercase().starts_with("ja"))
}

/// The sender this process names, from its environment.
pub fn of_this_process() -> Option<String> {
    implicit(|key| std::env::var(key).ok(), crate::host_pressure::host_name)
}

/// The harness family this process runs in when it is an agent harness's own shell outside
/// acpmux (`_meta.acpmux.fromHarness`), else `None`.
pub fn harness_of_this_process() -> Option<&'static str> {
    let env = |key: &str| std::env::var(key).ok();
    if in_session(env) { None } else { harness_of(env) }
}

/// The machine a send naming no sender ran on (`_meta.acpmux.cliHost`), a claimed label the
/// daemon keeps on the recorded client (and on an `unverified` provenance). None for an agent's send, named or in a session.
pub fn person_host(named: bool) -> Option<String> {
    (!from_an_agent(named)).then(crate::host_pressure::host_name)
}

/// An agent sends it: one that names itself (`named`: `--from`, `ACPMUX_FROM`) or one running in
/// an acpmux session. Its send steers into a running turn by default (`run/standard.rs`).
pub fn from_an_agent(named: bool) -> bool {
    agent_in(named, |key| std::env::var(key).ok())
}

/// It runs in an agent harness's own shell outside acpmux (a Claude Code or Codex session in a
/// terminal): its `acpmux send` is a message to another agent, so it is queued and returns at
/// once (`run/standard.rs` `send_queues`). Who sent it is [`harness_name`]'s.
pub fn in_an_agent_harness() -> bool {
    harness_in(|key| std::env::var(key).ok())
}

fn harness_in(env: impl Fn(&str) -> Option<String>) -> bool {
    harness_of(env).is_some()
}

/// The harness whose shell this is, by the variable each sets in its commands' environment.
fn harness_of(env: impl Fn(&str) -> Option<String>) -> Option<&'static str> {
    [("CLAUDECODE", "claude"), ("CODEX_THREAD_ID", "codex")]
        .into_iter()
        .find(|(key, _)| env(key).is_some_and(|v| !v.trim().is_empty()))
        .map(|(_, harness)| harness)
}

fn agent_in(named: bool, env: impl Fn(&str) -> Option<String>) -> bool {
    named || in_session(env)
}

/// It runs in an acpmux session that its caller token proves to the daemon.
fn in_session(env: impl Fn(&str) -> Option<String>) -> bool {
    let set = |key: &str| env(key).is_some_and(|v| !v.trim().is_empty());
    set("ACPMUX_SESSION_ID") && set(crate::hub::person::CALLER_TOKEN_ENV)
}

/// The sender a send names with no `--from`: `None` when it runs in an acpmux session (the
/// daemon proves that one) or names no one (the owner's own send, `owner_terminal`). `ACPMUX_FROM`
/// wins over the harness's own name.
pub fn implicit(
    env: impl Fn(&str) -> Option<String>,
    host: impl FnOnce() -> String,
) -> Option<String> {
    let set = |key: &str| env(key).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
    if in_session(&env) {
        return None;
    }
    let name = set(FROM_ENV).or_else(|| harness_name(&env, host))?;
    // What the daemon accepts as a sender (`hub/digest.rs` `declared_sender`): one line, at most
    // its length.
    let name: String =
        name.chars().filter(|c| !c.is_control()).take(crate::hub::MAX_FROM_AGENT_CHARS).collect();
    Some(name.trim().to_owned())
}

/// The harness whose shell this is, on `host`, with its session id's first 8 characters when it
/// sets one: "Claude Code desktop on my-mac · 03214b87". `None` outside a known harness.
fn harness_name(
    env: impl Fn(&str) -> Option<String>,
    host: impl FnOnce() -> String,
) -> Option<String> {
    let set = |key: &str| env(key).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
    let (harness, session) = if set("CLAUDECODE").is_some() {
        let harness = match set("CLAUDE_CODE_ENTRYPOINT").as_deref() {
            Some("claude-desktop") => "Claude Code desktop",
            Some("claude-vscode") => "Claude Code in VS Code",
            _ => "Claude Code",
        };
        (harness.to_owned(), set("CLAUDE_CODE_SESSION_ID"))
    } else if let Some(thread) = set("CODEX_THREAD_ID") {
        ("Codex".to_owned(), Some(thread))
    } else {
        // `AI_AGENT` is `<tool>_<version>_<mode>` (`claude-code_2-1-310_agent`): the tool.
        let agent = set("AI_AGENT")?;
        let tool = agent.split('_').next().unwrap_or_default().trim().to_owned();
        (tool, None)
    };
    if harness.is_empty() {
        return None;
    }
    let mut name = format!("{harness} on {}", host());
    if let Some(session) = session {
        name.push_str(" · ");
        name.extend(session.chars().take(8));
    }
    Some(name)
}

#[cfg(test)]
mod tests;
