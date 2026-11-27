//! A Chief subagent's workspace holds its chat and no shell (Lawrence
//! 2026-10-21). Every subagent workspace used to open a shell in the
//! subagent's folder, and a Chief start re-created one shell for every
//! terminal tab it moved into the user's session (a423): one terminal host
//! and one PTY each, 369 of them on one Mac, with 510 of its 511 PTYs in use.
//!
//! Against real headless cmux-tui daemons (`CMUX_TUI_BIN`):
//! - a new subagent's workspace (`DaemonWorkspaces::open`) adds 0 terminals,
//!   0 terminal hosts and 0 PTYs, and the user can still open a shell in it;
//! - a Chief start (`adopt_owner_workspaces`) that moves a workspace with an
//!   idle shell and a chat adds 0 terminals and hosts to the user's session.
//!
//! Run: `CMUX_TUI_BIN=<cmux-tui target>/debug/cmux-tui cargo test --test
//! no_shell_daemon -- --ignored`.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use optchat_chief::workspaces::{DaemonWorkspaces, Workspaces, adopt_owner_workspaces};
use serde_json::{Value, json};

fn bin() -> PathBuf {
    PathBuf::from(std::env::var("CMUX_TUI_BIN").expect("CMUX_TUI_BIN names a cmux-tui binary"))
}

fn cli(home: &Path) -> Command {
    let mut command = Command::new(bin());
    command
        .env("HOME", home)
        .env("TMPDIR", home)
        .env("CMUX_TUI_STATE_DIR", home.join("state"))
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("MUX_HOME")
        .env_remove("OPTCHAT_SUBAGENT")
        .env("SHELL", "/bin/sh")
        .env("LC_ALL", "C");
    command
}

/// A headless daemon in its own home; stopped (terminals ended) on drop.
struct Daemon {
    dir: tempfile::TempDir,
    socket: PathBuf,
}

impl Daemon {
    fn start() -> Daemon {
        let dir = tempfile::Builder::new()
            .prefix("ons")
            .tempdir_in("/tmp")
            .unwrap();
        let socket = dir.path().join("d.sock");
        let status = cli(dir.path())
            .arg("--socket")
            .arg(&socket)
            .args(["daemon", "ensure"])
            .stdout(Stdio::null())
            .status()
            .unwrap();
        assert!(status.success(), "daemon ensure: {status}");
        Daemon { dir, socket }
    }

    fn request(&self, mut body: Value) -> Value {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        let mut writer = stream.try_clone().unwrap();
        let mut reader = BufReader::new(stream);
        // Read conversation tabs as such, as the app and the Chief do.
        writeln!(
            writer,
            "{}",
            json!({"id": 0, "cmd": "set-client-info", "kind": "automation", "name": "test",
                "capabilities": ["conversation-tabs-v1", "agent-session-tabs-v1", "page-tabs-v1"]})
        )
        .unwrap();
        let mut hello = String::new();
        reader.read_line(&mut hello).unwrap();
        body["id"] = json!(1);
        writeln!(writer, "{body}").unwrap();
        loop {
            let mut line = String::new();
            assert!(
                reader.read_line(&mut line).unwrap() > 0,
                "the daemon closed"
            );
            let value: Value = serde_json::from_str(&line).unwrap();
            if value["id"] == json!(1) {
                assert_eq!(value["ok"], true, "{body} failed: {value}");
                return value["data"].clone();
            }
        }
    }

    fn workspace(&self, key: &str) -> Option<Value> {
        let tree = self.request(json!({"cmd": "list-workspaces"}));
        tree["workspaces"]
            .as_array()?
            .iter()
            .find(|w| w["key"] == key)
            .cloned()
    }

    /// Tabs of workspace `key`, by kind (`pty`, `browser`, conversation ...).
    fn tab_kinds(&self, key: &str) -> Vec<String> {
        let Some(ws) = self.workspace(key) else {
            return Vec::new();
        };
        let mut kinds = Vec::new();
        for screen in ws["screens"].as_array().into_iter().flatten() {
            for pane in screen["panes"].as_array().into_iter().flatten() {
                for tab in pane["tabs"].as_array().into_iter().flatten() {
                    kinds.push(if tab["conversation"].is_object() {
                        "chat".to_owned()
                    } else {
                        tab["kind"].as_str().unwrap_or("?").to_owned()
                    });
                }
            }
        }
        kinds
    }

    /// Running terminals in the registry and live terminal hosts (records).
    fn terminals(&self) -> (usize, usize) {
        let running = self.request(json!({"cmd": "list-workspaces"}))["workspaces"]
            .as_array()
            .into_iter()
            .flatten()
            .flat_map(|w| w["screens"].as_array().into_iter().flatten())
            .flat_map(|s| s["panes"].as_array().into_iter().flatten())
            .flat_map(|p| p["tabs"].as_array().into_iter().flatten())
            .filter(|t| t["kind"] == "pty")
            .count();
        let mut hosts = 0;
        for root in std::fs::read_dir(self.dir.path().join("state"))
            .into_iter()
            .flatten()
            .flatten()
        {
            if !root
                .file_name()
                .to_string_lossy()
                .starts_with("terminal-hosts-")
            {
                continue;
            }
            for entry in std::fs::read_dir(root.path())
                .into_iter()
                .flatten()
                .flatten()
            {
                if entry.path().extension().is_some_and(|ext| ext == "json") {
                    hosts += 1;
                }
            }
        }
        (running, hosts)
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = cli(self.dir.path())
            .arg("--socket")
            .arg(&self.socket)
            .args(["daemon", "stop", "--end-terminals"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}

fn workspaces(daemon: &Daemon) -> DaemonWorkspaces {
    DaemonWorkspaces {
        daemon: daemon.socket.clone(),
        host: "chief:0a1b2c3d".into(),
        host_name: "test".into(),
        harness: Some("claude".into()),
        personal: false,
        fallback: None,
    }
}

#[test]
#[ignore = "needs CMUX_TUI_BIN, a cmux-tui binary"]
fn a_new_subagent_workspace_has_its_chat_and_no_shell() {
    let daemon = Daemon::start();
    let before = daemon.terminals();
    let key = optchat_chief::workspaces::new_key();
    workspaces(&daemon)
        .open(
            &key,
            "sess-1",
            "Finish test",
            "Chief agents",
            Path::new("/tmp"),
        )
        .unwrap();
    assert_eq!(
        daemon.tab_kinds(&key),
        vec!["chat"],
        "the workspace holds its chat tab only"
    );
    assert_eq!(
        daemon.terminals(),
        before,
        "no terminal and no terminal host (no PTY)"
    );

    // The user can still open a shell there.
    let workspace = daemon.workspace(&key).unwrap()["id"].clone();
    let placed = daemon.request(json!({"cmd": "create-terminal", "workspace": workspace}));
    assert!(placed["surface"].is_u64(), "{placed}");
    let deadline = Instant::now() + Duration::from_secs(20);
    while daemon.terminals().1 <= before.1 {
        assert!(Instant::now() < deadline, "the user's shell never started");
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(daemon.tab_kinds(&key).contains(&"pty".to_owned()));
}

#[test]
#[ignore = "needs CMUX_TUI_BIN, a cmux-tui binary"]
fn a_chief_start_moves_a_workspace_without_re_creating_its_idle_shell() {
    let owner = Daemon::start();
    let app = Daemon::start();
    // An older host's subagent workspace on the owner daemon: an idle shell
    // and the chat tab.
    let key = optchat_chief::workspaces::new_key();
    let made = owner.request(json!({"cmd": "create-workspace", "key": key, "name": "Old one"}));
    let workspace = made["workspace"].clone();
    // An idle shell titles itself `user@host:dir`; this one says so and waits.
    let placed = owner.request(json!({"cmd": "create-terminal", "workspace": workspace,
        "argv": ["/bin/sh", "-c", "printf '\\033]0;me@mac:~\\007'; exec cat"]}));
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let titled = owner.workspace(&key).is_some_and(|ws| {
            ws["screens"][0]["panes"][0]["tabs"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|t| t["title"] == "me@mac:~")
        });
        if titled {
            break;
        }
        assert!(Instant::now() < deadline, "the shell never titled itself");
        std::thread::sleep(Duration::from_millis(50));
    }
    owner.request(
        json!({"cmd": "new-conversation-tab", "pane": placed["pane"],
        "agent_session": {"host": "chief:0a1b2c3d", "session": "sess-old"}}),
    );
    // An idle shell titles itself `user@host:dir`; busy_terminal reads an
    // untitled live terminal as busy.
    let app_before = app.terminals();

    let moved = adopt_owner_workspaces(&owner.socket, &app.socket).unwrap();
    assert_eq!(moved, 1, "the workspace moved");
    assert_eq!(
        app.tab_kinds(&key),
        vec!["chat"],
        "the chat moved; the idle shell was not re-created"
    );
    assert_eq!(
        app.terminals(),
        app_before,
        "no terminal and no terminal host in the user's session"
    );
}
