//! A Chief subagent's workspace makes no sidebar group (#27712). `spawn` used to file every
//! subagent workspace into a topic group ("Browser & parity", "Panes & layout", "Cloud & fleet"),
//! made when the sidebar had none, even when the task named no group.
//!
//! Against real headless cmux-tui daemons (`CMUX_TUI_BIN`), in the user's session (personal
//! groups, the app's daemon) and in a host's own session (the daemon's groups):
//! - no group asked: the workspace stays ungrouped and no group is made;
//! - `Chief agents`, which the sidebar has: the workspace joins it, and no group is made;
//! - any other name ("Browser & parity", one the sidebar has or not): ignored, ungrouped, no group
//!   made;
//! - `Chief agents` when the sidebar has none: ungrouped, the group is not made;
//! - each workspace holds its chat tab only (no terminal).
//!
//! Run: `CMUX_TUI_BIN=<cmux-tui target>/debug/cmux-tui cargo test --test
//! spawn_groups_daemon -- --ignored`.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use optchat_chief::workspaces::{DaemonWorkspaces, Workspaces, new_key, resource_call};
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

/// A headless daemon in its own home; stopped on drop.
struct Daemon {
    dir: tempfile::TempDir,
    socket: PathBuf,
}

impl Daemon {
    fn start() -> Daemon {
        let dir = tempfile::Builder::new()
            .prefix("osg")
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

    /// One JSON-lines request; its `data`.
    fn request(&self, mut body: Value) -> Value {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        let mut writer = stream.try_clone().unwrap();
        let mut reader = BufReader::new(stream);
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

    fn tree(&self) -> Value {
        self.request(json!({"cmd": "list-workspaces"}))
    }

    fn workspace(&self, key: &str) -> Value {
        self.tree()["workspaces"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|w| w["key"] == key)
            .cloned()
            .unwrap_or_else(|| panic!("no workspace {key}"))
    }

    /// Tabs of workspace `key`: `chat` for a conversation tab, else its kind.
    fn tab_kinds(&self, key: &str) -> Vec<String> {
        let ws = self.workspace(key);
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

    fn here() -> Value {
        json!({"machine": "current", "session": "current"})
    }

    /// The user's session: its personal groups `(id, name)`.
    fn personal_groups(&self) -> Vec<(String, String)> {
        let listed = resource_call(&self.socket, "workspace_group.list", Self::here(), None)
            .expect("workspace_group.list");
        listed
            .as_array()
            .into_iter()
            .flatten()
            .map(|g| {
                (
                    g["id"].as_str().unwrap().to_owned(),
                    g["name"].as_str().unwrap().to_owned(),
                )
            })
            .collect()
    }

    /// The person makes a personal group named `name`; its id.
    fn make_personal_group(&self, name: &str) -> String {
        let mut params = Self::here();
        params["name"] = json!(name);
        let made = resource_call(
            &self.socket,
            "workspace_group.create",
            params,
            Some(&format!("test-group-{name}")),
        )
        .expect("workspace_group.create");
        made["value"]["id"].as_str().unwrap().to_owned()
    }

    /// The personal group of workspace `key` (None: ungrouped).
    fn personal_group_of(&self, key: &str) -> Option<String> {
        let id = self.workspace(key)["resource_id"]
            .as_str()
            .unwrap()
            .to_owned();
        let order = resource_call(&self.socket, "workspace.placement.list", Self::here(), None)
            .expect("workspace.placement.list");
        let row = order
            .as_array()
            .into_iter()
            .flatten()
            .find(|row| row["workspace"]["workspace_id"] == id.as_str())
            .cloned()
            .unwrap_or_else(|| panic!("{id} is not placed: {order}"));
        row["group_id"].as_str().map(str::to_owned)
    }

    /// The daemon's own groups `(id, name)` (a host's own session).
    fn shared_groups(&self) -> Vec<(String, String)> {
        self.tree()["groups"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|g| {
                (
                    g["id"].as_str().unwrap().to_owned(),
                    g["name"].as_str().unwrap().to_owned(),
                )
            })
            .collect()
    }

    fn make_shared_group(&self, name: &str) -> String {
        let slug: String = name
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() {
                    c.to_ascii_lowercase()
                } else {
                    '-'
                }
            })
            .collect();
        let id = format!("test-{slug}");
        self.request(json!({"cmd": "create-workspace-group", "group": id, "name": name}));
        id
    }

    fn shared_group_of(&self, key: &str) -> Option<String> {
        self.workspace(key)["group"].as_str().map(str::to_owned)
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

fn workspaces(daemon: &Daemon, personal: bool) -> DaemonWorkspaces {
    DaemonWorkspaces {
        daemon: daemon.socket.clone(),
        host: "chief:0a1b2c3d".into(),
        host_name: "test".into(),
        harness: Some("claude".into()),
        personal,
        fallback: None,
    }
}

/// Opens a subagent workspace asked into `group` (empty: none); its key.
fn spawn_into(daemon: &Daemon, personal: bool, group: &str) -> String {
    let key = new_key();
    workspaces(daemon, personal)
        .open(&key, "sess-1", "Spawned", group, Path::new("/tmp"))
        .unwrap();
    assert_eq!(
        daemon.tab_kinds(&key),
        vec!["chat"],
        "the workspace holds its chat tab only, no terminal"
    );
    key
}

#[test]
#[ignore = "needs CMUX_TUI_BIN, a cmux-tui binary"]
fn spawn_in_the_users_session_makes_no_group_and_joins_only_chief_agents() {
    let daemon = Daemon::start();

    // No group asked, and `Chief agents` while the sidebar has none: no group is made.
    for asked in ["", "Chief agents", "Browser & parity"] {
        let key = spawn_into(&daemon, true, asked);
        assert_eq!(daemon.personal_group_of(&key), None, "asked {asked:?}");
        assert_eq!(
            daemon.personal_groups(),
            vec![],
            "asked {asked:?}: a group was made"
        );
    }

    // The person's own groups: `Chief agents` is joined, any other name is ignored.
    let agents = daemon.make_personal_group("Chief agents");
    let browser = daemon.make_personal_group("Browser & parity");
    let before = daemon.personal_groups();
    let key = spawn_into(&daemon, true, "Chief agents");
    assert_eq!(daemon.personal_group_of(&key), Some(agents));
    for asked in ["Browser & parity", "Browser", "Panes & layout", ""] {
        let key = spawn_into(&daemon, true, asked);
        assert_eq!(daemon.personal_group_of(&key), None, "asked {asked:?}");
    }
    assert_eq!(daemon.personal_groups(), before, "no group was made");
    assert!(before.iter().any(|(id, _)| *id == browser));
}

#[test]
#[ignore = "needs CMUX_TUI_BIN, a cmux-tui binary"]
fn spawn_in_a_hosts_own_session_makes_no_group_and_joins_only_chief_agents() {
    let daemon = Daemon::start();

    for asked in ["", "Chief agents", "Cloud & fleet"] {
        let key = spawn_into(&daemon, false, asked);
        assert_eq!(daemon.shared_group_of(&key), None, "asked {asked:?}");
        assert_eq!(
            daemon.shared_groups(),
            vec![],
            "asked {asked:?}: a group was made"
        );
    }

    let agents = daemon.make_shared_group("Chief agents");
    daemon.make_shared_group("Cloud & fleet");
    let before = daemon.shared_groups();
    let key = spawn_into(&daemon, false, "Chief agents");
    assert_eq!(daemon.shared_group_of(&key), Some(agents));
    for asked in ["Cloud & fleet", "Cloud", ""] {
        let key = spawn_into(&daemon, false, asked);
        assert_eq!(daemon.shared_group_of(&key), None, "asked {asked:?}");
    }
    assert_eq!(daemon.shared_groups(), before, "no group was made");
}
