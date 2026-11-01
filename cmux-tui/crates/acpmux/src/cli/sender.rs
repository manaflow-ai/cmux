//! Who `acpmux send` names as its sender when given no `--from` (`_meta.acpmux.fromAgent`).
//!
//! An agent in an acpmux session needs none: its caller token, inherited from the session's
//! process tree, proves the session to the daemon that issued it (`client.rs`, `hub/person.rs`
//! (a)). Run outside one, nothing tells an agent from the person, so a send is the person's
//! unless `ACPMUX_FROM` names an agent: `reach` sets it from the caller's session name, the one
//! identity that survives an ssh hop (claude-sr2, 2026-10-24: lanes on other machines sent their
//! reports with `reach cosmic-gray 'acpmux send …'`, and each read as the person's own words).

/// Names the sender of every `acpmux send` run with it set and no `--from`.
pub const FROM_ENV: &str = "ACPMUX_FROM";

/// The sender this process names, from its environment.
pub fn of_this_process() -> Option<String> {
    implicit(|key| std::env::var(key).ok())
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

fn agent_in(named: bool, env: impl Fn(&str) -> Option<String>) -> bool {
    named || in_session(env)
}

/// It runs in an acpmux session that its caller token proves to the daemon.
fn in_session(env: impl Fn(&str) -> Option<String>) -> bool {
    let set = |key: &str| env(key).is_some_and(|v| !v.trim().is_empty());
    set("ACPMUX_SESSION_ID") && set(crate::hub::person::CALLER_TOKEN_ENV)
}

/// The sender a send names with no `--from`: `None` when it runs in an acpmux session (the
/// daemon proves that one) or is the person's.
pub fn implicit(env: impl Fn(&str) -> Option<String>) -> Option<String> {
    let set = |key: &str| env(key).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
    if in_session(&env) {
        return None;
    }
    // What the daemon accepts as a sender (`hub/digest.rs` `declared_sender`): one line, at most
    // its length.
    let name: String = set(FROM_ENV)?
        .chars()
        .filter(|c| !c.is_control())
        .take(crate::hub::MAX_FROM_AGENT_CHARS)
        .collect();
    Some(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        move |key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
    }

    #[test]
    fn acpmux_from_names_the_sender() {
        assert_eq!(implicit(env(&[(FROM_ENV, " codex-lane ")])).as_deref(), Some("codex-lane"));
        let long = "x".repeat(200);
        let sent = implicit(env(&[(FROM_ENV, long.as_str())])).unwrap();
        assert_eq!(sent.chars().count(), crate::hub::MAX_FROM_AGENT_CHARS);
    }

    #[test]
    fn with_no_name_and_no_session_the_send_is_the_persons() {
        assert_eq!(implicit(env(&[])), None);
        assert_eq!(
            implicit(env(&[("SSH_CONNECTION", "100.81.77.9 50022 100.84.217.73 22")])),
            None
        );
        assert_eq!(implicit(env(&[(FROM_ENV, "  ")])), None);
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
