use super::*;

fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
    move |key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
}

#[test]
fn a_claude_code_or_codex_shell_is_an_agent_harness() {
    assert_eq!(harness_of(env(&[("CODEX_THREAD_ID", "t-1")])), Some("codex"));
    assert_eq!(harness_of(env(&[("CLAUDECODE", "1")])), Some("claude"));
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
fn with_no_name_and_no_session_the_send_names_no_one() {
    assert_eq!(implicit(env(&[])), None);
    assert_eq!(implicit(env(&[("SSH_CONNECTION", "100.81.77.9 50022 100.84.217.73 22")])), None);
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

mod agent_messaging {
    use super::*;

    /// A Claude Code subagent inherits its lead's whole environment, so only the hook's mark
    /// tells its send apart, and only inside the session its token proves.
    #[test]
    fn a_subagent_is_named_by_the_hooks_mark_inside_its_leads_session() {
        let lead = [
            ("ACPMUX_SESSION_ID", "07f8556f-1bd9"),
            ("ACPMUX_SESSION_NAME", "claude-17"),
            ("ACPMUX_SESSION_TOKEN", "t"),
            ("CLAUDECODE", "1"),
            ("CLAUDE_CODE_CHILD_SESSION", "1"),
        ];
        assert_eq!(subagent_in(env(&lead)), None, "the lead's own shell has the same env");
        assert_eq!(
            sending_as(env(&lead), None, None, &CodexThread::None).as_deref(),
            Some("claude-17")
        );
        // Renamed after its agent started: the daemon's name now wins over the env's.
        let renamed = sending_as(env(&lead), None, Some("alpha"), &CodexThread::None);
        assert_eq!(renamed.as_deref(), Some("alpha"));
        let mut sub = lead.to_vec();
        sub.push((SUBAGENT_ENV, "general-purpose:a0a68e7af3df5967e"));
        let found = subagent_in(env(&sub)).expect("marked");
        assert_eq!(found.kind, "general-purpose");
        assert_eq!(found.id, "a0a68e7af3df5967e");
        assert_eq!(
            found.to_value(),
            serde_json::json!({"id": "a0a68e7af3df5967e", "type": "general-purpose"})
        );
        let shown = sending_as(env(&sub), None, None, &CodexThread::None).unwrap();
        assert_eq!(
            shown,
            "claude-17's general-purpose subagent a0a68e7a (replies to its sends come back to it after its next Bash command or acpmux MCP call; once it ends they go to claude-17; `acpmux send claude-17` reaches claude-17)"
        );
        sub.push(("LANG", "ja_JP.UTF-8"));
        let shown = sending_as(env(&sub), None, None, &CodexThread::None).unwrap();
        assert_eq!(
            shown,
            "claude-17 の general-purpose サブエージェント a0a68e7a（送信への返信は次の Bash コマンドまたは acpmux MCP 呼び出しの後にこのサブエージェントに届きます。終了後は claude-17 に届きます。`acpmux send claude-17` は claude-17 に届きます）"
        );
        // LC_ALL, set first, wins over LANG.
        sub.push(("LC_ALL", "en_US.UTF-8"));
        let shown = sending_as(env(&sub), None, None, &CodexThread::None).unwrap();
        assert!(shown.starts_with("claude-17's general-purpose subagent a0a68e7a (replies"));
        // No token: no session to be a subagent of. A mark that is no TYPE:ID word pair: none.
        let unproven = [("ACPMUX_SESSION_ID", "s1"), (SUBAGENT_ENV, "general-purpose:a1")];
        assert_eq!(subagent_in(env(&unproven)), None);
        for bad in ["general-purpose", ":a1", "x y:a1", "t:a1;rm", ""] {
            let mut odd = lead.to_vec();
            odd.push((SUBAGENT_ENV, bad));
            assert_eq!(subagent_in(env(&odd)), None, "{bad:?}");
        }
        assert_eq!(
            sending_as(env(&[]), Some("reach-lane"), None, &CodexThread::None).as_deref(),
            Some("reach-lane (a name it gave, not proven)")
        );
        assert_eq!(
            sending_as(env(&[]), None, None, &CodexThread::None),
            None,
            "the person's own send"
        );
    }
}

mod caller_identity {
    use super::*;

    const LEAD: [(&str, &str); 4] = [
        ("ACPMUX_SESSION_ID", "01a1b8f4-session"),
        ("ACPMUX_SESSION_NAME", "coder"),
        ("ACPMUX_SESSION_TOKEN", "t"),
        ("CODEX_SANDBOX", "seatbelt"),
    ];

    fn with(extra: &[(&'static str, &'static str)]) -> Vec<(&'static str, &'static str)> {
        LEAD.iter().copied().chain(extra.iter().copied()).collect()
    }

    /// Codex runs each command with its thread's id, and a subagent in a thread of its own:
    /// the session's own thread is its lead, any other its subagent, and with the session's
    /// thread unknown the send says it cannot tell.
    #[test]
    fn a_codex_thread_other_than_the_sessions_own_is_its_subagent() {
        let lead = with(&[("CODEX_THREAD_ID", "9862c5b9-f316")]);
        assert_eq!(codex_thread_in(env(&lead), Some("9862c5b9-f316")), CodexThread::Lead);
        let shown = sending_as(env(&lead), None, None, &CodexThread::Lead);
        assert_eq!(shown.as_deref(), Some("coder"));

        let sub = with(&[("CODEX_THREAD_ID", "81ef6aa6-0345-4aad")]);
        let found = codex_thread_in(env(&sub), Some("9862c5b9-f316"));
        let expected = Subagent { kind: "codex".into(), id: "81ef6aa6-0345-4aad".into() };
        assert_eq!(found, CodexThread::Subagent(expected.clone()));
        let shown = sending_as(env(&sub), None, None, &found).unwrap();
        assert_eq!(
            shown,
            "coder's codex subagent 81ef6aa6 (only a reply this send waits for reaches it; other replies go to coder; `acpmux send coder` reaches coder)"
        );
        assert_eq!(
            expected.to_value(),
            serde_json::json!({"id": "81ef6aa6-0345-4aad", "type": "codex"})
        );

        let unknown = codex_thread_in(env(&sub), None);
        assert_eq!(unknown, CodexThread::Unknown);
        let shown = sending_as(env(&sub), None, None, &unknown);
        assert_eq!(shown.as_deref(), Some("coder (subagent identity not available for codex)"));
        // A thread id that is no plain word names no subagent.
        let odd = with(&[("CODEX_THREAD_ID", "a b;c")]);
        assert_eq!(codex_thread_in(env(&odd), Some("9862c5b9")), CodexThread::Unknown);
    }

    /// No Codex thread: nothing to tell. A Claude Code subagent's hook mark wins over a Codex
    /// thread its command runs in (`codex exec` from a Claude Code subagent).
    #[test]
    fn without_a_codex_thread_or_with_the_hooks_mark_codex_tells_nothing() {
        assert_eq!(codex_thread_in(env(&LEAD), Some("x")), CodexThread::None);
        let both = with(&[("CODEX_THREAD_ID", "t-2"), (SUBAGENT_ENV, "Explore:a1")]);
        assert_eq!(codex_thread_in(env(&both), Some("t-1")), CodexThread::None);
        let shown = sending_as(env(&both), None, None, &CodexThread::None).unwrap();
        assert!(shown.starts_with("coder's Explore subagent a1"), "{shown}");
    }
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
