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
