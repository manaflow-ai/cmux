//! Loosening an approval gate is the owner's alone (review of 44ba8784):
//! the tools socket passes a loosening `settings` line to the host only
//! from the owner path, the cmux daemon that forwards the owner's
//! `chief.settings.set`, recognized as the process listening on the
//! host's daemon socket. The Chief's own turns, its subagents, another
//! agent and a plain terminal may only tighten a gate; nothing in the
//! request changes that.
//!
//! An acpmux agent is stood in for by a `/bin/bash` "agent host" whose child
//! is the caller, with the session name acpmux sets (`ACPMUX_SESSION_NAME`),
//! as in turn_seal_binding.rs. The daemon is this test process: it listens
//! on the owner daemon socket and sends its line itself.

mod common;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::{Arc, Mutex};

use common::open_chat;
use optchat_chief::chief_profile::{ChiefTools, TURN_KEY_ENV};
use optchat_chief::paths::Paths;
use optchat_chief::tools::ControlRequest;

const LOOSEN: (&str, &str) = ("approvals.autoApproveAll", "true");
const TIGHTEN: (&str, &str) = ("approvals.autoApproveAll", "false");

/// The other loosening lines, each refused the same way.
const OTHER_LOOSENINGS: [(&str, &str); 3] = [
    ("remote.autoApprove", "true"),
    ("remote.ask", "false"),
    ("home.ask", "false"),
];

struct Host {
    home: PathBuf,
    daemon: PathBuf,
    socket: PathBuf,
    /// What reached the host's control.
    seen: Arc<Mutex<Vec<ControlRequest>>>,
    _listener: UnixListener,
    _dir: tempfile::TempDir,
}

fn serve() -> Host {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("chief");
    let paths = Paths::new(&home);
    std::fs::create_dir_all(paths.tools_socket.parent().unwrap()).unwrap();
    // The cmux daemon of this host: this test process listens on it.
    let daemon = dir.path().join("daemon.sock");
    let listener = UnixListener::bind(&daemon).unwrap();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let record = seen.clone();
    optchat_chief::tools::serve_all(
        &paths.tools_socket,
        optchat_chief::tools::Served {
            memory: open_chat(&home.join("memory")),
            orchestrator: None,
            control: Some(Arc::new(move |request| {
                record.lock().unwrap().push(request);
                Ok("written".to_owned())
            })),
            inspector: None,
            chief: Some(Arc::new(ChiefTools::none())),
            turn: Some(
                optchat_chief::turn_caller::TurnBinding {
                    turn_prefix: "optchat-home-".to_owned(),
                    subagent_prefix: "optchat-sub-home-".to_owned(),
                    agent_parent: std::fs::canonicalize("/bin/bash").ok(),
                    owner_daemons: Vec::new(),
                }
                .with_owner_daemons(vec![daemon.clone()]),
            ),
        },
    )
    .unwrap();
    Host {
        home,
        daemon,
        socket: paths.tools_socket,
        seen,
        _listener: listener,
        _dir: dir,
    }
}

/// The daemon's own `chief.settings.set` line (chief_control.rs `tool_line`).
fn as_daemon(host: &Host, (key, value): (&str, &str)) -> serde_json::Value {
    let mut conn = UnixStream::connect(&host.socket).unwrap();
    let line = serde_json::json!({"tool": "settings", "key": key, "value": value});
    writeln!(conn, "{line}").unwrap();
    let mut answer = String::new();
    BufReader::new(conn).read_line(&mut answer).unwrap();
    serde_json::from_str(&answer).unwrap()
}

/// `optchat-chief settings set key value`, run under acpmux session
/// `session` (a `/bin/bash` agent host its parent), or as a plain child.
fn cli(home: &Path, session: Option<&str>, (key, value): (&str, &str)) -> Output {
    let exe = env!("CARGO_BIN_EXE_optchat-chief");
    let args = [
        "settings".to_owned(),
        "set".to_owned(),
        key.to_owned(),
        value.to_owned(),
        "--mux-home".to_owned(),
        home.display().to_string(),
    ];
    let mut command = match session {
        Some(session) => {
            let mut sh = Command::new("/bin/bash");
            sh.args(["-c", "\"$@\"; status=$?; exit $status", "bash", exe])
                .args(&args)
                .env("ACPMUX_SESSION_NAME", session);
            sh
        }
        None => {
            let mut direct = Command::new(exe);
            direct.args(&args).env_remove("ACPMUX_SESSION_NAME");
            direct
        }
    };
    command
        .env_remove("ACPMUX_SESSION_ID")
        .env_remove(TURN_KEY_ENV)
        .env_remove("OPTCHAT_SUBAGENT")
        .output()
        .unwrap()
}

fn sets(host: &Host) -> Vec<(String, String)> {
    host.seen
        .lock()
        .unwrap()
        .iter()
        .filter_map(|r| match r {
            ControlRequest::Set(k, v) => Some((k.clone(), v.clone())),
            _ => None,
        })
        .collect()
}

fn stderr(out: &Output) -> String {
    String::from_utf8_lossy(&out.stderr).into_owned()
}

#[test]
fn only_the_daemon_loosens_a_gate_and_every_caller_tightens_one() {
    let host = serve();
    let turn = Some("optchat-home-2079");
    let other_agent = Some("codex-session-7");
    for (who, session) in [
        ("turn", turn),
        ("other agent", other_agent),
        ("terminal", None),
    ] {
        for loosen in std::iter::once(LOOSEN).chain(OTHER_LOOSENINGS) {
            let out = cli(&host.home, session, loosen);
            assert!(
                !out.status.success() && stderr(&out).contains("refused"),
                "{who} {loosen:?}: {out:?}"
            );
        }
        assert!(
            sets(&host).is_empty(),
            "{who}: nothing loosening reached the host"
        );
        let out = cli(&host.home, session, TIGHTEN);
        assert!(out.status.success(), "{who} tightens: {out:?}");
        assert_eq!(
            sets(&host).pop(),
            Some((TIGHTEN.0.to_owned(), TIGHTEN.1.to_owned())),
            "{who}"
        );
        host.seen.lock().unwrap().clear();
    }
    // A subagent reaches no owner control at all, a tightening included
    // (the existing rule).
    for line in [LOOSEN, TIGHTEN] {
        let out = cli(&host.home, Some("optchat-sub-home-a1"), line);
        assert!(
            !out.status.success() && stderr(&out).contains("subagents have no owner controls"),
            "subagent {line:?}: {out:?}"
        );
    }
    assert!(sets(&host).is_empty());
    // The owner path: the daemon's forwarded line loosens and tightens.
    for line in std::iter::once(LOOSEN)
        .chain(OTHER_LOOSENINGS)
        .chain([TIGHTEN])
    {
        let answer = as_daemon(&host, line);
        assert_eq!(answer["text"], "written", "{line:?}: {answer}");
    }
    assert_eq!(sets(&host).len(), 5);
}

#[test]
fn a_caller_that_is_not_the_daemons_listener_is_not_the_owner_path() {
    let host = serve();
    // The daemon socket's listener is this process; another process that
    // connects to the daemon socket (and so knows it) is still not it.
    let binding = optchat_chief::turn_caller::TurnBinding {
        turn_prefix: "optchat-home-".to_owned(),
        subagent_prefix: "optchat-sub-home-".to_owned(),
        agent_parent: std::fs::canonicalize("/bin/bash").ok(),
        owner_daemons: vec![host.daemon.clone()],
    };
    assert!(binding.is_owner_daemon(std::process::id() as i32));
    let child = Command::new("sleep").arg("5").spawn().unwrap();
    let pid = child.id() as i32;
    assert!(!binding.is_owner_daemon(pid));
    let mut child = child;
    let _ = child.kill();
    let _ = child.wait();
    // No owner daemon configured, or one nothing listens on: no owner path.
    let none = optchat_chief::turn_caller::TurnBinding {
        owner_daemons: vec![host.home.join("no-such.sock")],
        ..binding
    };
    assert!(!none.is_owner_daemon(std::process::id() as i32));
}

#[test]
fn with_no_host_the_cli_of_an_agent_only_tightens_and_the_persons_loosens() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("chief");
    std::fs::create_dir_all(home.join("optchat")).unwrap();
    let file = home.join("optchat").join("settings.json");
    let saved = || -> serde_json::Value {
        std::fs::read_to_string(&file)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or(serde_json::Value::Null)
    };
    for session in [
        "optchat-home-2079",
        "optchat-sub-home-a1",
        "codex-session-7",
    ] {
        let out = cli(&home, Some(session), LOOSEN);
        assert!(
            !out.status.success() && stderr(&out).contains("refused"),
            "{session}: {out:?}"
        );
        assert_ne!(saved()["approvals"]["autoApproveAll"], true, "{session}");
        let out = cli(&home, Some(session), TIGHTEN);
        assert!(out.status.success(), "{session} tightens: {out:?}");
    }
    // A turn seal in the env alone marks an agent too.
    let exe = env!("CARGO_BIN_EXE_optchat-chief");
    let out = Command::new(exe)
        .args(["settings", "set", LOOSEN.0, LOOSEN.1, "--mux-home"])
        .arg(&home)
        .env_remove("ACPMUX_SESSION_NAME")
        .env_remove("ACPMUX_SESSION_ID")
        .env(TURN_KEY_ENV, "0".repeat(64))
        .output()
        .unwrap();
    assert!(
        !out.status.success() && stderr(&out).contains("refused"),
        "{out:?}"
    );
    assert_ne!(saved()["approvals"]["autoApproveAll"], true);
    // The person's own terminal, with no host: the file changes.
    let out = cli(&home, None, LOOSEN);
    assert!(out.status.success(), "{out:?}");
    assert_eq!(saved()["approvals"]["autoApproveAll"], true);
}
