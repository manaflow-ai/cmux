//! Who `acpmux send` names as its sender when given no `--from` (`_meta.acpmux.fromAgent`).
//!
//! An agent in an acpmux session needs none: its caller token, inherited from the session's
//! process tree, proves the session to the daemon that issued it (`client.rs`, `hub/person.rs`
//! (a)). Run outside one, nothing tells an agent from the person, so a send is the person's
//! unless `ACPMUX_FROM` names an agent: `reach` sets it from the caller's session name, the one
//! identity that survives an ssh hop (claude-sr2, 2026-10-24: lanes on other machines sent their
//! reports with `reach cosmic-gray 'acpmux send …'`, and each read as the person's own words).
//!
//! An agent harness's own shell outside acpmux (Claude Code in a terminal, the Codex desktop app)
//! is no person either: its send names `<harness>@<host>` and its harness (`fromHarness`), so the
//! receiver shows that agent's card, never the person's bubble (Leo, 2026-11-05: "why is it
//! sending it as if it were me?").

/// Names the sender of every `acpmux send` run with it set and no `--from`.
pub const FROM_ENV: &str = "ACPMUX_FROM";

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
/// once (`run/standard.rs` `send_queues`). It says nothing about who sent it.
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
/// daemon proves that one) or is the person's. `ACPMUX_FROM` names it; else an agent harness's
/// own shell is `<harness>@<host>`.
pub fn implicit(
    env: impl Fn(&str) -> Option<String>,
    host: impl FnOnce() -> String,
) -> Option<String> {
    let set = |key: &str| env(key).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
    if in_session(&env) {
        return None;
    }
    let named = set(FROM_ENV)
        .or_else(|| harness_of(&env).map(|harness| format!("{harness}@{}", host())))?;
    // What the daemon accepts as a sender (`hub/digest.rs` `declared_sender`): one line, at most
    // its length.
    let name: String =
        named.chars().filter(|c| !c.is_control()).take(crate::hub::MAX_FROM_AGENT_CHARS).collect();
    Some(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        move |key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
    }

    fn host() -> String {
        "workstation".to_owned()
    }

    #[test]
    fn a_claude_code_or_codex_shell_names_itself_as_its_harness_on_its_host() {
        assert_eq!(
            implicit(env(&[("CODEX_THREAD_ID", "t-1")]), host).as_deref(),
            Some("codex@workstation")
        );
        assert_eq!(
            implicit(env(&[("CLAUDECODE", "1")]), host).as_deref(),
            Some("claude@workstation")
        );
        assert_eq!(harness_of(env(&[("CODEX_THREAD_ID", "t-1")])), Some("codex"));
        // ACPMUX_FROM still names it; a session's own send needs no name (its token proves it).
        assert_eq!(
            implicit(env(&[("CODEX_THREAD_ID", "t-1"), (FROM_ENV, "audit")]), host).as_deref(),
            Some("audit")
        );
        let in_session = [
            ("CLAUDECODE", "1"),
            ("ACPMUX_SESSION_ID", "s-1"),
            (crate::hub::person::CALLER_TOKEN_ENV, "t"),
        ];
        assert_eq!(implicit(env(&in_session), host), None);
    }

    #[test]
    fn a_claude_code_or_codex_shell_is_an_agent_harness() {
        assert!(harness_in(env(&[("CLAUDECODE", "1")])));
        assert!(harness_in(env(&[("CODEX_THREAD_ID", "t-1")])));
        assert!(!harness_in(env(&[("CLAUDECODE", " ")])));
        assert!(!harness_in(env(&[("TERM", "xterm")])));
    }

    #[test]
    fn acpmux_from_names_the_sender() {
        assert_eq!(
            implicit(env(&[(FROM_ENV, " codex-lane ")]), host).as_deref(),
            Some("codex-lane")
        );
        let long = "x".repeat(200);
        let sent = implicit(env(&[(FROM_ENV, long.as_str())]), host).unwrap();
        assert_eq!(sent.chars().count(), crate::hub::MAX_FROM_AGENT_CHARS);
    }

    #[test]
    fn with_no_name_and_no_session_the_send_is_the_persons() {
        assert_eq!(implicit(env(&[]), host), None);
        assert_eq!(
            implicit(env(&[("SSH_CONNECTION", "100.81.77.9 50022 100.84.217.73 22")]), host),
            None
        );
        assert_eq!(implicit(env(&[(FROM_ENV, "  ")]), host), None);
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
        let inside = [("ACPMUX_SESSION_ID", "s1"), ("ACPMUX_SESSION_TOKEN", "t"), (FROM_ENV, "x")];
        assert_eq!(implicit(env(&inside)), None);
    }
}
