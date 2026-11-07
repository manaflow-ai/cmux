//! Who `acpmux send` names as its sender when given no `--from` (`_meta.acpmux.fromAgent`).
//!
//! An agent in an acpmux session needs none: its caller token, inherited from the session's
//! process tree, proves the session to the daemon that issued it (`client.rs`, `hub/person.rs`
//! (a)). Run outside one, nothing tells an agent from the person, so a send is the person's
//! unless `ACPMUX_FROM` names an agent: `reach` sets it from the caller's session name, the one
//! identity that survives an ssh hop (claude-sr2, 2026-10-24: lanes on other machines sent their
//! reports with `reach cosmic-gray 'acpmux send …'`, and each read as the person's own words).
//!
//! With neither, an agent harness's own shell names its harness ([`harness_name`]): Claude Code
//! (desktop, VS Code or terminal, by `CLAUDE_CODE_ENTRYPOINT`), Codex (`CODEX_THREAD_ID`), or any
//! tool that marks the commands it runs with `AI_AGENT` (`<tool>_<version>_<mode>`), with the
//! machine and the harness's session id. Leo, 2026-11-07: "could it possibly detect that you sent
//! it as the Claude Code desktop?" A desktop chat's `acpmux send` had read as his own words.

/// Names the sender of every `acpmux send` run with it set and no `--from`.
pub const FROM_ENV: &str = "ACPMUX_FROM";

/// The sender this process names, from its environment.
pub fn of_this_process() -> Option<String> {
    implicit(|key| std::env::var(key).ok(), crate::host_pressure::host_name)
}

/// The machine the person's own send ran on (`_meta.acpmux.cliHost`): the transcript says
/// "via CLI on big-red" under their prompt. None for an agent's send, named or in a session.
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
    ["CLAUDECODE", "CODEX_THREAD_ID"]
        .iter()
        .any(|key| env(key).is_some_and(|v| !v.trim().is_empty()))
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
/// daemon proves that one) or is the person's. `ACPMUX_FROM` wins over the harness's own name.
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
mod tests {
    use super::*;

    fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        move |key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
    }

    #[test]
    fn a_claude_code_or_codex_shell_is_an_agent_harness() {
        assert!(harness_in(env(&[("CLAUDECODE", "1")])));
        assert!(harness_in(env(&[("CODEX_THREAD_ID", "t-1")])));
        assert!(!harness_in(env(&[("CLAUDECODE", " ")])));
        assert!(!harness_in(env(&[("TERM", "xterm")])));
    }

    fn implicit(env: impl Fn(&str) -> Option<String>) -> Option<String> {
        super::implicit(env, || "my-mac".to_owned())
    }

    #[test]
    fn acpmux_from_names_the_sender() {
        assert_eq!(implicit(env(&[(FROM_ENV, " codex-lane ")])).as_deref(), Some("codex-lane"));
        let long = "x".repeat(200);
        let sent = implicit(env(&[(FROM_ENV, long.as_str())])).unwrap();
        assert_eq!(sent.chars().count(), crate::hub::MAX_FROM_AGENT_CHARS);
        let named = [(FROM_ENV, "reach-lane"), ("CLAUDECODE", "1")];
        assert_eq!(implicit(env(&named)).as_deref(), Some("reach-lane"), "ACPMUX_FROM wins");
    }

    #[test]
    fn a_harness_shell_names_its_harness_machine_and_session() {
        let desktop = [
            ("CLAUDECODE", "1"),
            ("CLAUDE_CODE_ENTRYPOINT", "claude-desktop"),
            ("CLAUDE_CODE_SESSION_ID", "03214b87-953d-4ecf-98ae-93d337878273"),
        ];
        assert_eq!(
            implicit(env(&desktop)).as_deref(),
            Some("Claude Code desktop on my-mac · 03214b87")
        );
        let vscode = [("CLAUDECODE", "1"), ("CLAUDE_CODE_ENTRYPOINT", "claude-vscode")];
        assert_eq!(implicit(env(&vscode)).as_deref(), Some("Claude Code in VS Code on my-mac"));
        let terminal = [("CLAUDECODE", "1"), ("CLAUDE_CODE_ENTRYPOINT", "cli")];
        assert_eq!(implicit(env(&terminal)).as_deref(), Some("Claude Code on my-mac"));
        let codex = [("CODEX_THREAD_ID", "019a2b3c-4d5e")];
        assert_eq!(implicit(env(&codex)).as_deref(), Some("Codex on my-mac · 019a2b3c"));
        let other = [("AI_AGENT", "grokbot_1-2_agent")];
        assert_eq!(implicit(env(&other)).as_deref(), Some("grokbot on my-mac"));
        assert_eq!(implicit(env(&[("AI_AGENT", "_x")])), None);
    }

    #[test]
    fn with_no_name_and_no_session_the_send_is_the_persons() {
        assert_eq!(implicit(env(&[])), None);
        assert_eq!(
            implicit(env(&[("SSH_CONNECTION", "100.81.77.9 50022 100.84.217.73 22")])),
            None
        );
        assert_eq!(implicit(env(&[(FROM_ENV, "  ")])), None);
        assert_eq!(implicit(env(&[("CLAUDECODE", " ")])), None);
    }

    #[test]
    fn an_agent_sends_when_named_or_in_a_session_and_the_person_otherwise() {
        assert!(agent_in(true, env(&[])), "--from or ACPMUX_FROM");
        let inside = [("ACPMUX_SESSION_ID", "s1"), ("ACPMUX_SESSION_TOKEN", "t")];
        assert!(agent_in(false, env(&inside)), "an agent in an acpmux session");
        assert!(!agent_in(false, env(&[("ACPMUX_SESSION_ID", "s1")])), "no token proves it");
        assert!(!agent_in(false, env(&[])), "the person's terminal");
    }

    #[test]
    fn an_agent_in_a_session_is_proven_by_its_token_not_named() {
        let inside = [
            ("ACPMUX_SESSION_ID", "s1"),
            ("ACPMUX_SESSION_TOKEN", "t"),
            (FROM_ENV, "x"),
            ("CLAUDECODE", "1"),
        ];
        assert_eq!(implicit(env(&inside)), None);
    }
}
