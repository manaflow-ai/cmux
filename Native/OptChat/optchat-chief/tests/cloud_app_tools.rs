//! Cloud Chief Mac boundary (2026-10-20): a Chief host with no cmux app of
//! its own names a diagnostics-only relay with `CMUX_CHIEF_APP_SOCKET`.
//! App actions remain denied even when a current or last-known catalog lists
//! them, and an unreadable catalog fails closed.

use std::collections::BTreeMap;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use optchat_chief::cmux_env::REMOTE_APP_KEY;
use optchat_chief::session_dir::{cmux_tool_denials, cmux_tool_names};

fn inherited(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
    let map: BTreeMap<String, String> = pairs
        .iter()
        .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
        .collect();
    move |key: &str| map.get(key).cloned()
}

fn turn_env(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    let home = Path::new("/tmp/chief-home");
    optchat_chief::host::session_env(
        home,
        "/tmp/vm-daemon.sock",
        Path::new("/tmp/acpmux.sock"),
        Path::new("/nonexistent/optchat-chief"),
        &inherited(pairs),
    )
}

#[test]
fn the_remote_app_socket_reaches_the_turn_as_its_app_socket() {
    let env = turn_env(&[
        (REMOTE_APP_KEY, "/home/chief/mac-app.sock"),
        ("PATH", "/usr/bin"),
    ]);
    assert_eq!(
        env.get("CMUX_SOCKET_PATH").map(String::as_str),
        Some("/home/chief/mac-app.sock")
    );
    // The daemon stays the host's own: only app requests go to the relay.
    assert_eq!(
        env.get("CMUX_TUI_SOCKET").map(String::as_str),
        Some("/tmp/vm-daemon.sock")
    );
}

#[test]
fn an_app_terminal_socket_wins_over_the_remote_app_socket() {
    let env = turn_env(&[
        ("CMUX_SOCKET_PATH", "/tmp/local-app.sock"),
        (REMOTE_APP_KEY, "/home/chief/mac-app.sock"),
    ]);
    assert_eq!(
        env.get("CMUX_SOCKET_PATH").map(String::as_str),
        Some("/tmp/local-app.sock")
    );
}

#[test]
fn without_a_remote_app_socket_the_turn_has_no_app_socket() {
    let env = turn_env(&[("PATH", "/usr/bin")]);
    assert_eq!(env.get("CMUX_SOCKET_PATH"), None);
}

/// A fake `cmux` on the env's PATH that answers `--json mcp tools` from
/// `answer.json` (exit 0) or fails with `answer.err` on stderr (exit 1).
struct FakeCli {
    dir: tempfile::TempDir,
}

impl FakeCli {
    fn new() -> FakeCli {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("cmux");
        std::fs::write(
            &script,
            "#!/bin/sh\nd=$(dirname \"$0\")\nif [ -f \"$d/answer.err\" ]; then cat \"$d/answer.err\" >&2; exit 1; fi\n\
             [ -f \"$d/answer.note\" ] && cat \"$d/answer.note\" >&2\ncat \"$d/answer.json\"\n",
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        FakeCli { dir }
    }

    fn answer(&self, names: &[&str], app: bool, note: Option<&str>) {
        let tools: Vec<_> = names
            .iter()
            .map(|n| serde_json::json!({ "name": n }))
            .collect();
        let body = serde_json::json!({ "app_actions": app, "tools": tools });
        std::fs::write(self.dir.path().join("answer.json"), body.to_string()).unwrap();
        let _ = std::fs::remove_file(self.dir.path().join("answer.err"));
        match note {
            Some(note) => std::fs::write(self.dir.path().join("answer.note"), note).unwrap(),
            None => {
                let _ = std::fs::remove_file(self.dir.path().join("answer.note"));
            }
        }
    }

    fn fail(&self, stderr: &str) {
        std::fs::write(self.dir.path().join("answer.err"), stderr).unwrap();
    }

    fn env(&self) -> BTreeMap<String, String> {
        let path = format!("{}:/usr/bin:/bin", self.dir.path().display());
        BTreeMap::from([("PATH".to_owned(), path)])
    }
}

const FULL: [&str; 4] = [
    "agents_snapshot",
    "app_show_pane",
    "app_workspace_rename",
    "workspace_list",
];

#[test]
fn a_failed_tool_list_says_why() {
    let cli = FakeCli::new();
    cli.fail("cmux mcp: cannot reach the Mac gate at http://100.82.214.112:7420");
    let err = cmux_tool_names(&cli.env()).unwrap_err();
    assert!(err.contains("cannot reach the Mac gate"), "{err}");
}

#[test]
fn a_failed_first_tool_list_denies_the_whole_cmux_server() {
    let cli = FakeCli::new();
    let session = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(session.path().join(".claude")).unwrap();
    cli.fail("cmux mcp: cannot reach the app");
    let denied = cmux_tool_denials(session.path(), &cli.env());
    assert!(
        denied.contains(&"mcp__cmux".to_owned()),
        "an unknown catalog must fail closed: {denied:?}"
    );
}

#[test]
fn a_list_without_the_app_says_why() {
    let cli = FakeCli::new();
    cli.answer(
        &["workspace_list"],
        false,
        Some("cmux mcp: the cmux app's actions are unavailable: no cmux app found"),
    );
    let list = cmux_tool_names(&cli.env()).unwrap();
    assert!(!list.app_actions);
    assert!(
        list.note
            .as_deref()
            .unwrap_or("")
            .contains("no cmux app found"),
        "{:?}",
        list.note
    );
}

#[test]
fn the_last_known_list_stays_when_the_list_fails_or_loses_the_app() {
    let cli = FakeCli::new();
    let session = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(session.path().join(".claude")).unwrap();
    let deny = "mcp__cmux__app_workspace_rename".to_owned();

    cli.answer(&FULL, true, None);
    let first = cmux_tool_denials(session.path(), &cli.env());
    assert!(first.contains(&deny), "{first:?}");
    assert!(
        first.contains(&"mcp__cmux__app_show_pane".to_owned()),
        "remote app actions must be denied even when the catalog lists them: {first:?}"
    );

    // The Mac is asleep: the list fails. The app-action denials stay.
    cli.fail("cmux mcp: cannot reach the Mac gate");
    let failed = cmux_tool_denials(session.path(), &cli.env());
    assert!(
        failed.contains(&deny),
        "the last known list must stay: {failed:?}"
    );
    assert!(
        failed.contains(&"mcp__cmux__workspace_list".to_owned()),
        "{failed:?}"
    );

    // The list answers without the app's action tools: the same.
    cli.answer(
        &["agents_snapshot", "workspace_list"],
        false,
        Some("no cmux app found"),
    );
    let no_app = cmux_tool_denials(session.path(), &cli.env());
    assert!(
        no_app.contains(&deny),
        "the last known app tools must stay denied: {no_app:?}"
    );
}

/// A turn's app requests name the Home chat as their caller
/// (`CMUX_CALLER_HOME_CHAT`), so its tabs open beside the Chief's chat when
/// no target is given; a subagent (the pinned subset) does not.
#[test]
fn a_turn_names_the_home_chat_and_a_subagent_does_not() {
    let env = turn_env(&[(REMOTE_APP_KEY, "/home/chief/mac-app.sock")]);
    assert_eq!(
        env.get(optchat_chief::cmux_env::HOME_CHAT_KEY)
            .map(String::as_str),
        Some("1")
    );
    let pinned = optchat_chief::cmux_env::pinned_subset(&env);
    assert_eq!(pinned.get(optchat_chief::cmux_env::HOME_CHAT_KEY), None);
}

/// A Chief turn messages the agent chats the user started (#25571): the cmux chat tools that
/// send to, read and check a chat stay allowed; starting or interrupting one stays denied.
#[test]
fn a_chief_turn_keeps_the_tools_that_message_agent_chats() {
    let cli = FakeCli::new();
    let session = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(session.path().join(".claude")).unwrap();
    cli.answer(
        &[
            "agents_snapshot",
            "agents_chat_send",
            "agents_chat_read",
            "agents_chat_state",
            "agents_chat_new",
            "agents_chat_interrupt",
            "app_show_pane",
        ],
        true,
        None,
    );
    let denied = cmux_tool_denials(session.path(), &cli.env());
    for kept in ["agents_chat_send", "agents_chat_read", "agents_chat_state"] {
        assert!(
            !denied.contains(&format!("mcp__cmux__{kept}")),
            "{kept} must reach the Chief's turn: {denied:?}"
        );
    }
    for gone in ["agents_chat_new", "agents_chat_interrupt", "app_show_pane"] {
        assert!(
            denied.contains(&format!("mcp__cmux__{gone}")),
            "{gone} stays denied: {denied:?}"
        );
    }
}

#[test]
fn a_chief_turn_keeps_coordinator_tools_but_not_background_tasks() {
    let cli = FakeCli::new();
    let session = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(session.path().join(".claude")).unwrap();
    let kept = [
        "acpmux_send",
        "acpmux_ls",
        "acpmux_last",
        "acpmux_info",
        "acpmux_inbox_read",
        "acpmux_inbox_reply",
    ];
    let gone = [
        "acpmux_bg_start",
        "acpmux_bg_list",
        "acpmux_bg_output",
        "acpmux_bg_stop",
        "cmux_exec",
        "cmux_docs",
    ];
    let names: Vec<_> = kept.iter().chain(gone.iter()).copied().collect();
    cli.answer(&names, true, None);
    let denied = cmux_tool_denials(session.path(), &cli.env());
    for name in kept {
        assert!(
            !denied.contains(&format!("mcp__cmux__{name}")),
            "{denied:?}"
        );
    }
    for name in gone {
        assert!(denied.contains(&format!("mcp__cmux__{name}")), "{denied:?}");
    }
}
