//! The `chiefs` tool answers only the Chief's own turn session, at the tools
//! socket, even to a caller that holds the valid turn seal (2026-10-19: a
//! daemon started from a turn's shell gave the seal to every agent it
//! spawned, and terminals that shell opened keep it).
//!
//! Each caller is the real `optchat-chief chiefs` launcher. An acpmux agent
//! is stood in for by a `/bin/bash` "agent host" whose child is the caller,
//! with the session name acpmux sets on an agent (`ACPMUX_SESSION_NAME`).

mod common;

use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::{Arc, Mutex};

use common::open_chat;
use optchat_chief::chief_profile::{ChiefTools, TURN_KEY_ENV};
use optchat_chief::paths::Paths;
use optchat_chief::tools::{ControlRequest, NOT_THE_TURN};

/// The owner controls the host answered, in order.
type Asked = Arc<Mutex<Vec<ControlRequest>>>;

/// Serves `home`'s tools socket where `optchat-chief --mux-home home` looks
/// for it (`Paths::tools_socket`), as the host does.
fn serve(home: &Path, chief: Arc<ChiefTools>) -> PathBuf {
    serve_recording(home, chief, Asked::default())
}

fn serve_recording(home: &Path, chief: Arc<ChiefTools>, asked: Asked) -> PathBuf {
    let socket = Paths::new(home).tools_socket;
    std::fs::create_dir_all(socket.parent().unwrap()).unwrap();
    optchat_chief::tools::serve_all(
        &socket,
        optchat_chief::tools::Served {
            memory: open_chat(&home.join("memory")),
            orchestrator: None,
            control: Some(Arc::new(move |ask| {
                asked.lock().unwrap().push(ask);
                Ok("owner-control".to_owned())
            })),
            inspector: None,
            chief: Some(chief),
            turn: Some(optchat_chief::turn_caller::TurnBinding {
                turn_prefix: "optchat-home-".to_owned(),
                subagent_prefix: "optchat-sub-home-".to_owned(),
                agent_parent: std::fs::canonicalize("/bin/bash").ok(),
            }),
            peers: None,
        },
    )
    .unwrap();
    socket
}

fn settings(home: &Path, session: Option<&str>) -> Output {
    settings_with(home, session, &["show"])
}

fn settings_with(home: &Path, session: Option<&str>, words: &[&str]) -> Output {
    chief_cli(home, session, &[&["settings"][..], words].concat())
}

/// `optchat-chief WORDS --mux-home home`, under a `/bin/bash` agent host with
/// `session`'s name, or (None) straight from this test as the owner.
fn chief_cli(home: &Path, session: Option<&str>, words: &[&str]) -> Output {
    let exe = env!("CARGO_BIN_EXE_optchat-chief");
    let args: Vec<String> = words
        .iter()
        .copied()
        .chain(["--mux-home"])
        .map(str::to_owned)
        .chain([home.display().to_string()])
        .collect();
    let mut command = match session {
        Some(session) => {
            let mut sh = Command::new("/bin/bash");
            sh.args(["-c", "\"$@\"; status=$?; exit $status", "bash", exe])
                .args(&args)
                .env("ACPMUX_SESSION_NAME", session);
            sh
        }
        None => {
            // Not under any acpmux agent, whatever session runs the tests.
            let mut direct = Command::new(exe);
            direct
                .args(&args)
                .env_remove("ACPMUX_SESSION_NAME")
                .env("ACPMUX_BIN", "/nonexistent/acpmux");
            direct
        }
    };
    command.output().unwrap()
}

fn refused_as_subagent(out: &Output) -> bool {
    !out.status.success()
        && String::from_utf8_lossy(&out.stderr).contains("subagents have no owner controls")
}

/// `optchat-chief chiefs` with `env`, as the child of a `/bin/bash` agent
/// host (`under_host`) or of this test process.
fn chiefs(socket: &Path, env: &[(&str, &str)], under_host: bool) -> Output {
    let exe = env!("CARGO_BIN_EXE_optchat-chief");
    let args = [
        "chiefs",
        "--socket",
        &socket.display().to_string(),
        r#"{"action": "list"}"#,
    ]
    .map(str::to_owned);
    let mut command = if under_host {
        // The shell stays the caller's parent: it runs the caller, then exits.
        let mut sh = Command::new("/bin/bash");
        sh.args(["-c", "\"$@\"; status=$?; exit $status", "bash", exe])
            .args(&args);
        sh
    } else {
        let mut direct = Command::new(exe);
        direct.args(&args);
        direct
    };
    command
        .env_remove(TURN_KEY_ENV)
        .env_remove("OPTCHAT_SUBAGENT")
        .env_remove("ACPMUX_SESSION_NAME")
        .envs(env.iter().copied())
        .output()
        .unwrap()
}

/// Refused as not the turn, or (a caller under a subagent session) as a subagent.
fn refused(out: &Output) -> bool {
    let stderr = String::from_utf8_lossy(&out.stderr);
    !out.status.success() && (stderr.contains(NOT_THE_TURN) || stderr.contains("subagents have no"))
}

#[test]
fn a_non_turn_agent_with_the_valid_seal_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let tools = Arc::new(ChiefTools::none());
    let seal = tools.turn_key().to_owned();
    let socket = serve(&dir.path().join("chief"), tools);
    // A subagent, a compactor and an acpmux sub-session of the turn, each
    // with the leaked seal.
    for name in [
        "optchat-sub-home-a75",
        "optchat-compact-home-2068+1",
        "optchat-home-2079/x1",
    ] {
        let out = chiefs(
            &socket,
            &[(TURN_KEY_ENV, &seal), ("ACPMUX_SESSION_NAME", name)],
            true,
        );
        assert!(refused(&out), "{name}: {out:?}");
    }
    // A shell of a terminal the turn's shell opened (no acpmux agent above
    // it), even with the turn's own session name in its env.
    let out = chiefs(
        &socket,
        &[
            (TURN_KEY_ENV, &seal),
            ("ACPMUX_SESSION_NAME", "optchat-home-2079"),
        ],
        false,
    );
    assert!(refused(&out), "orphan: {out:?}");
    // The turn session itself, with the seal: past the check (this Chief
    // has no record, so its grant then refuses the tool, for that reason).
    let out = chiefs(
        &socket,
        &[
            (TURN_KEY_ENV, &seal),
            ("ACPMUX_SESSION_NAME", "optchat-home-2079"),
        ],
        true,
    );
    assert!(
        !refused(&out)
            && String::from_utf8_lossy(&out.stderr)
                .contains("has not given this Chief the chiefs tool"),
        "turn: {out:?}"
    );
    // The turn session without the seal, or with a wrong one: refused.
    for key in ["", &"0".repeat(64)] {
        let out = chiefs(
            &socket,
            &[
                (TURN_KEY_ENV, key),
                ("ACPMUX_SESSION_NAME", "optchat-home-2079"),
            ],
            true,
        );
        assert!(refused(&out), "turn, key {key:?}: {out:?}");
    }
}

#[test]
fn a_subagent_cannot_reach_owner_controls_on_the_shared_socket() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("chief");
    let socket = serve(&home, Arc::new(ChiefTools::none()));
    assert!(socket.exists());

    let subagent = settings(&home, Some("optchat-sub-home-a1"));
    assert!(
        !subagent.status.success()
            && String::from_utf8_lossy(&subagent.stderr)
                .contains("subagents have no owner controls"),
        "subagent: {subagent:?}"
    );
    let owner = settings(&home, None);
    assert!(owner.status.success(), "owner: {owner:?}");
    assert!(String::from_utf8_lossy(&owner.stdout).contains("owner-control"));
}

/// The write path: a subagent's `settings set` is refused at the socket and
/// never reaches the host's control; the owner's arrives.
#[test]
fn a_subagent_cannot_change_owner_settings_on_the_shared_socket() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("chief");
    let asked = Asked::default();
    serve_recording(&home, Arc::new(ChiefTools::none()), asked.clone());

    let subagent = settings_with(
        &home,
        Some("optchat-sub-home-a1"),
        &["set", "cache.ttl", "1h"],
    );
    assert!(refused_as_subagent(&subagent), "subagent: {subagent:?}");
    assert!(asked.lock().unwrap().is_empty(), "{:?}", asked.lock());

    let owner = settings_with(&home, None, &["set", "cache.ttl", "1h"]);
    assert!(owner.status.success(), "owner: {owner:?}");
    assert_eq!(
        *asked.lock().unwrap(),
        [ControlRequest::Set("cache.ttl".to_owned(), "1h".to_owned())]
    );
}

/// With no host on the socket, the CLI edits the settings file itself (the
/// Mac's own CLI, no turn running). A subagent left running gets no owner
/// controls that way either: it can neither read nor change the file.
#[test]
fn a_subagent_gets_no_owner_settings_when_no_host_answers() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("chief");
    let file = Paths::new(&home).root.join("settings.json");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(&file, r#"{"cache": {"ttl": "5m"}}"#).unwrap();
    let before = std::fs::read(&file).unwrap();

    for words in [&["show"][..], &["set", "cache.ttl", "1h"]] {
        let subagent = settings_with(&home, Some("optchat-sub-home-a1"), words);
        assert!(refused_as_subagent(&subagent), "{words:?}: {subagent:?}");
    }
    assert_eq!(
        std::fs::read(&file).unwrap(),
        before,
        "the file is unchanged"
    );

    let owner = settings_with(&home, None, &["set", "cache.ttl", "1h"]);
    assert!(owner.status.success(), "owner: {owner:?}");
    assert_ne!(
        std::fs::read(&file).unwrap(),
        before,
        "the owner's set is saved"
    );
}

/// `browse` reads the whole chat and memory. The host refuses it to a
/// subagent; the CLI must not answer that refusal (or a missing host) by
/// opening the files itself.
#[test]
fn a_subagent_gets_no_offline_browse_page() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("chief");
    let page = dir.path().join("page.html");
    let browse = ["browse", "--out", page.to_str().unwrap()];

    let no_host = chief_cli(&home, Some("optchat-sub-home-a1"), &browse);
    assert!(refused_as_subagent(&no_host), "no host: {no_host:?}");
    assert!(!page.exists());

    serve(&home, Arc::new(ChiefTools::none()));
    let refused_by_host = chief_cli(&home, Some("optchat-sub-home-a1"), &browse);
    assert!(
        refused_as_subagent(&refused_by_host),
        "host up: {refused_by_host:?}"
    );
    assert!(!page.exists());

    let owner = chief_cli(&home, None, &browse);
    assert!(owner.status.success(), "owner: {owner:?}");
    assert!(page.exists());
}
