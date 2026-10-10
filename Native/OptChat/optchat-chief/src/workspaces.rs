//! Each subagent's cmux workspace (Lawrence, 2026-10-05: "subagent
//! orchestration spawns workspaces that have the acp chat, so everything is
//! monitorable and I can jump in deeper using cmux ui"). A workspace named
//! after the subagent's task, whose selected tab is the agent chat of the
//! SAME acpmux session the Chief drives: the user watches its chat and tool
//! calls live and can write to it. The workspace stays after the subagent
//! finishes, renamed with a done mark; closing it only detaches the tab.
//!
//! The app opens it (`agent.openSessionWorkspace` through `action.run` on
//! its control socket, `CMUX_SOCKET_PATH`), with a workspace key chosen
//! here, so the host can rename the workspace later through the session
//! daemon (`rename-workspace` by key).

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};

/// The app action that opens a session's chat in a new workspace.
pub const OPEN_ACTION: &str = "agent.openSessionWorkspace";
/// Marks a finished subagent's workspace name.
pub const DONE_MARK: &str = "✓";
/// Characters of a task kept in a workspace name.
const TITLE_CHARS: usize = 40;

/// Where subagents' workspaces are made.
pub trait Workspaces: Send + Sync {
    /// Opens workspace `key` (a fresh `new_key`, chosen before the session
    /// starts so the session can carry it as CMUX_WORKSPACE_ID) named `name`,
    /// whose tab is acpmux session `session`'s chat (a terminal in `cwd`
    /// beside it); returns its key.
    fn open(&self, key: &str, session: &str, name: &str, cwd: &Path) -> Result<String, String>;
    /// Renames the workspace `key`.
    fn rename(&self, key: &str, name: &str) -> Result<(), String>;
    /// Closes the workspace `key` (`OPTCHAT_SUBAGENT_ON_FINISH=close`): it
    /// goes to the closed history; the agent session stays.
    fn close(&self, _key: &str) -> Result<(), String> {
        Err("closing is not supported here".into())
    }
    /// Where its workspaces live, for the Chief to tell the user (for
    /// example "the cmux app on this Mac").
    fn place(&self) -> String;
}

/// A subagent's workspace name: its id and the task's first words.
pub fn name(id: &str, task: &str) -> String {
    let flat: String = task.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut title: String = flat.chars().take(TITLE_CHARS).collect();
    if flat.chars().count() > TITLE_CHARS {
        title.push('…');
    }
    format!("{id} · {title}")
}

/// The name of a finished subagent's workspace.
pub fn done_name(name: &str) -> String {
    format!("{DONE_MARK} {name}")
}

/// `key` as CMUX_WORKSPACE_ID: the uppercase UUID form a cmux terminal
/// carries (the app's `DaemonConnection.uuidForm`).
pub fn env_id(key: &str) -> String {
    key.to_uppercase()
}

/// A fresh workspace key in the daemon's canonical form (a lowercase UUID v4).
pub fn new_key() -> String {
    let mut bytes = [0u8; 16];
    let read = std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut bytes));
    if read.is_err() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        bytes = (nanos ^ (u128::from(std::process::id()) << 64)).to_le_bytes();
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

/// The app's control socket and the session daemon.
pub struct AppWorkspaces {
    pub control: PathBuf,
    pub daemon: PathBuf,
    /// The Chief home (`MUX_HOME`), whose own acpmux runs the subagents: the
    /// tab's host is `chief:<home id>`, so the app attaches it there.
    pub home: Option<PathBuf>,
}

impl AppWorkspaces {
    /// From the host's env: `CMUX_SOCKET_PATH` (None without it) and the
    /// app's daemon, where the app makes the workspaces.
    pub fn from_env(daemon: &str) -> Option<AppWorkspaces> {
        AppWorkspaces::resolve(daemon, &crate::cli::env)
    }

    /// `CMUX_SOCKET_PATH` from `env`, and the daemon that holds the app's
    /// workspaces: `CMUX_APP_DAEMON_SOCKET` when the app sets it (the host's
    /// `--daemon-socket` is then the Chief's conversation owner), else
    /// `daemon` (cmux_env::app_daemon_socket).
    pub fn resolve(daemon: &str, env: &dyn Fn(&str) -> Option<String>) -> Option<AppWorkspaces> {
        env("CMUX_SOCKET_PATH").map(|control| AppWorkspaces {
            control: control.into(),
            daemon: crate::cmux_env::app_daemon_socket(daemon, env).into(),
            home: None,
        })
    }

    /// The same, for the Chief home `home`.
    pub fn with_home(mut self, home: &Path) -> AppWorkspaces {
        self.home = Some(home.to_owned());
        self
    }
}

/// Where a subagent's workspace goes (E17, schemas/chief-cmux-target).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WorkspaceTarget {
    /// The app runs: its control socket opens the workspace in its daemon.
    App,
    /// No app: the Chief's owner daemon; the app shows it when it connects.
    Owner,
}

/// `App` while both the app's control socket and its daemon exist as
/// sockets, else `Owner`: the same rule as the Chief's `cmux` calls.
pub fn workspace_target(control: &Path, app_daemon: &Path) -> WorkspaceTarget {
    use std::os::unix::fs::FileTypeExt;
    let socket = |p: &Path| std::fs::metadata(p).is_ok_and(|m| m.file_type().is_socket());
    if socket(control) && socket(app_daemon) {
        WorkspaceTarget::App
    } else {
        WorkspaceTarget::Owner
    }
}

/// The opener of a Chief host started by the app or by `cmux chief`: each
/// open picks its target now (the app may start or quit while the host
/// runs); a rename or close goes where that workspace was opened.
pub struct TargetWorkspaces {
    pub app: AppWorkspaces,
    pub owner: DaemonWorkspaces,
    opened: std::sync::Mutex<std::collections::HashMap<String, WorkspaceTarget>>,
}

impl TargetWorkspaces {
    /// `owner_daemon` is the host's `--daemon-socket`; the tabs name the Chief
    /// home `home` (`chief:<home id>`) in both targets.
    pub fn new(
        app: AppWorkspaces,
        owner_daemon: PathBuf,
        home: &Path,
        harness: Option<String>,
    ) -> TargetWorkspaces {
        TargetWorkspaces {
            app: app.with_home(home),
            owner: DaemonWorkspaces {
                daemon: owner_daemon,
                host: chief_host(home),
                host_name: host_name(),
                harness,
            },
            opened: std::sync::Mutex::new(std::collections::HashMap::new()),
        }
    }

    fn target(&self) -> WorkspaceTarget {
        workspace_target(&self.app.control, &self.app.daemon)
    }

    fn of(&self, key: &str) -> WorkspaceTarget {
        let opened = self
            .opened
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        opened.get(key).copied().unwrap_or_else(|| self.target())
    }

    fn backend(&self, target: WorkspaceTarget) -> &dyn Workspaces {
        match target {
            WorkspaceTarget::App => &self.app,
            WorkspaceTarget::Owner => &self.owner,
        }
    }
}

impl Workspaces for TargetWorkspaces {
    fn open(&self, key: &str, session: &str, name: &str, cwd: &Path) -> Result<String, String> {
        let target = self.target();
        let opened = self.backend(target).open(key, session, name, cwd)?;
        self.opened
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(opened.clone(), target);
        Ok(opened)
    }

    fn close(&self, key: &str) -> Result<(), String> {
        self.backend(self.of(key)).close(key)
    }

    fn rename(&self, key: &str, name: &str) -> Result<(), String> {
        self.backend(self.of(key)).rename(key, name)
    }

    fn place(&self) -> String {
        match self.target() {
            WorkspaceTarget::App => self.app.place(),
            WorkspaceTarget::Owner => {
                "the Chief's own cmux session on this Mac (the cmux app shows it when it opens)"
                    .to_owned()
            }
        }
    }
}

/// The Markdown link that names subagent `id` (`[a1](cmux://chief/<home id>/session/<session>)`):
/// the app's deeplink of its session in the Chief home whose `mux.parent` tag is `parent`
/// (`optchat-chief:<home id>`). The app opens the tab that shows that session (host
/// `chief:<home id>`); Home allows the form only for this Chief's own subagents. None when the
/// tag names no home or the session id needs escaping.
pub fn subagent_link(parent: &str, id: &str, session: &str) -> Option<String> {
    let home = parent.strip_prefix("optchat-chief:")?;
    let token = |t: &str| {
        !t.is_empty()
            && t.len() <= 200
            && t.bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
    };
    (home.len() == 8
        && home
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        && token(session))
    .then(|| format!("[{id}](cmux://chief/{home}/session/{session})"))
}

/// The agent tab host of a session in Chief home `home`'s acpmux.
pub fn chief_host(home: &Path) -> String {
    format!("chief:{}", crate::paths::home_id(home))
}

/// `open_request` whose tab names Chief home `home` as its session's host.
pub fn open_request_for(home: &Path, session: &str, name: &str, key: &str, cwd: &Path) -> Value {
    let mut request = open_request(session, name, key, cwd);
    request["params"]["args"]["host"] = json!(chief_host(home));
    request
}

/// The `action.run` request that opens `session` in workspace `key`.
pub fn open_request(session: &str, name: &str, key: &str, cwd: &Path) -> Value {
    json!({
        "id": 1,
        "method": "action.run",
        "params": {
            "action": OPEN_ACTION,
            "args": {"session": session, "name": name, "key": key, "cwd": cwd.display().to_string()},
            "wait": true,
            // A script's run: it never takes focus or switches workspaces.
            "origin": "script",
            "idempotency_key": format!("optchat-subagent-workspace-{key}"),
        }
    })
}

/// One request on the app's control socket; Ok carries its result.
pub fn control_call(socket: &Path, request: &Value, timeout: Duration) -> Result<Value, String> {
    let mut stream = UnixStream::connect(socket)
        .map_err(|e| format!("the app's control socket {}: {e}", socket.display()))?;
    stream
        .set_read_timeout(Some(timeout))
        .map_err(|e| e.to_string())?;
    let mut line = request.to_string().into_bytes();
    line.push(b'\n');
    stream.write_all(&line).map_err(|e| e.to_string())?;
    let mut answer = String::new();
    BufReader::new(stream)
        .read_line(&mut answer)
        .map_err(|e| format!("reading the app's answer: {e}"))?;
    let answer = answer.trim();
    if !answer.starts_with('{') {
        return Err(if answer.is_empty() {
            "the app closed the control socket".to_owned()
        } else {
            answer.to_owned()
        });
    }
    let value: Value = serde_json::from_str(answer).map_err(|e| format!("bad answer: {e}"))?;
    match value.get("ok").and_then(Value::as_bool) {
        Some(true) => Ok(value.get("result").cloned().unwrap_or(Value::Null)),
        _ => Err(value
            .get("error")
            .map(|e| {
                e.get("message")
                    .and_then(Value::as_str)
                    .map_or_else(|| e.to_string(), str::to_owned)
            })
            .unwrap_or_else(|| answer.to_owned())),
    }
}

impl Workspaces for AppWorkspaces {
    fn open(&self, key: &str, session: &str, name: &str, cwd: &Path) -> Result<String, String> {
        let key = key.to_owned();
        match control_call(
            &self.control,
            &match &self.home {
                Some(home) => open_request_for(home, session, name, &key, cwd),
                None => open_request(session, name, &key, cwd),
            },
            Duration::from_secs(60),
        ) {
            Ok(_) => Ok(key),
            // The action declares that it starts a terminal, so the app
            // waits the terminal start deadline and answers once the
            // workspace exists; past even that, its work goes on and the
            // workspace still comes under the key chosen here (a done
            // rename before then fails and is logged).
            Err(e) if still_running(&e) => Ok(key),
            Err(e) => Err(e),
        }
    }

    fn close(&self, key: &str) -> Result<(), String> {
        close_by_key(&self.daemon, key)
    }

    fn rename(&self, key: &str, name: &str) -> Result<(), String> {
        rename_by_key(&self.daemon, key, name)
    }

    fn place(&self) -> String {
        "the cmux app on this Mac".to_owned()
    }
}

/// A host without a cmux app (an always-on brain on a server): each
/// subagent's workspace is made in this host's OWN session daemon. The
/// subagent runs on this machine, so its workspace belongs to this machine's
/// session (data-model.md 1.2); every cmux app connected to that session
/// shows it, also while the user's laptop sleeps. An app on another machine
/// shows the chat tab as running on `host_name` until it can attach to this
/// host's acpmux.
pub struct DaemonWorkspaces {
    /// This host's session daemon.
    pub daemon: PathBuf,
    /// `install:<id>` of this machine: the install whose acpmux runs the session.
    pub host: String,
    /// This machine's display name.
    pub host_name: String,
    /// The subagent harness, shown on the tab.
    pub harness: Option<String>,
}

impl DaemonWorkspaces {
    fn client(&self) -> Result<cmux::raw::Client, String> {
        use cmux::raw::{Client, ClientConfig};
        Client::connect(ClientConfig::from_socket_path(&self.daemon))
            .map_err(|e| format!("the session daemon: {e}"))
    }
}

impl Workspaces for DaemonWorkspaces {
    fn open(&self, key: &str, session: &str, name: &str, cwd: &Path) -> Result<String, String> {
        use cmux::raw::{
            AgentSessionSource, CreateTerminalRequest, CreateWorkspaceRequest,
            NewConversationTabRequest, Optional,
        };
        const TABS: &str = "agent-session-tabs-v1";
        let mut client = self.client()?;
        // Refused before any write: a workspace without its chat tab helps no one.
        let supported = client.identify_server().map(|info| {
            info.capabilities
                .unwrap_or_default()
                .iter()
                .any(|c| c == TABS)
        });
        match supported {
            Ok(true) => {}
            Ok(false) => {
                client.close();
                return Err(format!("this host's session daemon has no {TABS}"));
            }
            Err(e) => {
                client.close();
                return Err(format!("identify: {e}"));
            }
        }
        let key = key.to_owned();
        let result = (|| {
            let workspace = client
                .create_workspace(CreateWorkspaceRequest {
                    key: Optional::Value(key.clone()),
                    name: Optional::Value(name.to_owned()),
                    mutation_id: Optional::Value(format!("optchat-subagent-ws-{key}")),
                    origin: Optional::Value(MUTATION_ORIGIN.to_owned()),
                    ..Default::default()
                })
                .map_err(|e| format!("create-workspace: {e}"))?
                .workspace;
            let placement = client
                .create_terminal(CreateTerminalRequest {
                    workspace: Optional::Value(workspace),
                    cwd: Optional::Value(cwd.display().to_string()),
                    mutation_id: Optional::Value(format!("optchat-subagent-term-{key}")),
                    origin: Optional::Value(MUTATION_ORIGIN.to_owned()),
                    ..Default::default()
                })
                .map_err(|e| format!("create-terminal: {e}"))?;
            let pane = placement
                .pane
                .into_option()
                .ok_or("create-terminal placed no pane")?;
            client
                .new_conversation_tab(NewConversationTabRequest {
                    pane: Optional::Value(pane),
                    agent_session: Optional::Value(AgentSessionSource {
                        host: self.host.clone(),
                        host_name: Optional::Value(self.host_name.clone()),
                        session: Optional::Value(session.to_owned()),
                        harness: self
                            .harness
                            .clone()
                            .map_or(Optional::Missing, Optional::Value),
                    }),
                    mutation_id: Optional::Value(format!("optchat-subagent-tab-{key}")),
                    origin: Optional::Value(MUTATION_ORIGIN.to_owned()),
                    ..Default::default()
                })
                .map_err(|e| format!("new-conversation-tab: {e}"))?;
            Ok::<(), String>(())
        })();
        client.close();
        result.map(|()| key)
    }

    fn close(&self, key: &str) -> Result<(), String> {
        close_by_key(&self.daemon, key)
    }

    fn rename(&self, key: &str, name: &str) -> Result<(), String> {
        rename_by_key(&self.daemon, key, name)
    }

    fn place(&self) -> String {
        format!(
            "the cmux session on {0} (a cmux app shows it only while connected to {0})",
            self.host_name
        )
    }
}

/// This machine's short name (`hostname -s`), for the tabs other apps show.
pub fn host_name() -> String {
    std::process::Command::new("/bin/hostname")
        .arg("-s")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "this machine".into())
}

/// The app's answer to a waiting run whose work goes on past its deadline.
pub fn still_running(error: &str) -> bool {
    error.contains("did not finish within")
}

/// The origin of this host's workspace mutations: the session daemon needs one with every
/// mutation_id (server.rs workspace_mutation), so a retried create replays instead of doubling.
const MUTATION_ORIGIN: &str = "optchat-chief";

/// `rename-workspace` by key on the session daemon at `daemon`.
/// Closes workspace `key` and ends its terminal (the subagent's shell); the
/// agent session is acpmux's and stays.
fn close_by_key(daemon: &Path, key: &str) -> Result<(), String> {
    use cmux::raw::{Client, ClientConfig, CloseWorkspaceRequest, Optional};
    let mut client = Client::connect(ClientConfig::from_socket_path(daemon))
        .map_err(|e| format!("the session daemon: {e}"))?;
    let result = client
        .close_workspace(CloseWorkspaceRequest {
            end_terminals: Some(true),
            expected_generation: Optional::Missing,
            expected_revision: Optional::Missing,
            key: Optional::Value(key.to_owned()),
            mutation_id: Optional::Value(format!("optchat-subagent-close-{key}")),
            origin: Optional::Value(MUTATION_ORIGIN.to_owned()),
            workspace: Optional::Missing,
        })
        .map(|_| ())
        .map_err(|e| format!("close-workspace: {e}"));
    client.close();
    result
}

fn rename_by_key(daemon: &Path, key: &str, name: &str) -> Result<(), String> {
    use cmux::raw::{Client, ClientConfig, Optional, RenameWorkspaceRequest};
    let mut client = Client::connect(ClientConfig::from_socket_path(daemon))
        .map_err(|e| format!("the session daemon: {e}"))?;
    let result = client
        .rename_workspace(RenameWorkspaceRequest {
            expected_generation: Optional::Missing,
            expected_revision: Optional::Missing,
            key: Optional::Value(key.to_owned()),
            mutation_id: Optional::Missing,
            name: name.to_owned(),
            origin: Optional::Missing,
            workspace: Optional::Missing,
        })
        .map(|_| ())
        .map_err(|e| format!("rename-workspace: {e}"));
    client.close();
    result
}

#[cfg(test)]
mod tests {
    /// CLI dogfood 7bf60bcf938a: a Chief that `cmux chief` started without the
    /// app tried the app's missing control socket for every subagent, and no
    /// subagent got a workspace. The opener follows E17
    /// (schemas/chief-cmux-target): the app while its control socket and its
    /// daemon exist, else the Chief's owner daemon, with host chief:<home id>
    /// so the app attaches the tab to the Chief home's acpmux when it opens.
    #[test]
    fn without_the_app_subagent_workspaces_go_to_the_owner_daemon() {
        let dir = tempfile::tempdir().unwrap();
        let control = dir.path().join("app.sock");
        let app_daemon = dir.path().join("app-daemon.sock");
        assert_eq!(
            workspace_target(&control, &app_daemon),
            WorkspaceTarget::Owner
        );
        let _c = std::os::unix::net::UnixListener::bind(&control).unwrap();
        assert_eq!(
            workspace_target(&control, &app_daemon),
            WorkspaceTarget::Owner,
            "both must exist"
        );
        let _d = std::os::unix::net::UnixListener::bind(&app_daemon).unwrap();
        assert_eq!(
            workspace_target(&control, &app_daemon),
            WorkspaceTarget::App
        );
        let home = dir.path().join("mux");
        let w = TargetWorkspaces::new(
            AppWorkspaces {
                control: control.clone(),
                daemon: app_daemon.clone(),
                home: Some(home.clone()),
            },
            dir.path().join("owner.sock"),
            &home,
            None,
        );
        assert_eq!(w.owner.host, chief_host(&home));
        assert_eq!(w.owner.daemon, dir.path().join("owner.sock"));
    }

    /// Live proof subp6: the app showed "This chat isn't available" for every
    /// subagent: its panes attach to the app's acpmux, the subagents run in the
    /// Chief home's. The open request names the Chief home as the tab's host.
    #[test]
    fn the_open_request_names_the_chief_home_as_the_sessions_host() {
        let home = std::path::Path::new("/tmp/mux-home");
        let request = open_request_for(home, "s1", "a1 · x", "k", std::path::Path::new("/tmp"));
        assert_eq!(
            request["params"]["args"]["host"],
            format!("chief:{}", crate::paths::home_id(home))
        );
    }

    /// Live proof subp3: every done mark failed with "unknown workspace key":
    /// the renames went to the Chief's conversation owner (--daemon-socket),
    /// while the app makes the workspaces in its own daemon.
    #[test]
    fn app_workspaces_rename_in_the_apps_daemon() {
        let env = |k: &str| match k {
            "CMUX_SOCKET_PATH" => Some("/tmp/control.sock".to_owned()),
            "CMUX_APP_DAEMON_SOCKET" => Some("/tmp/app-daemon.sock".to_owned()),
            _ => None,
        };
        let app = AppWorkspaces::resolve("/tmp/chief-owner.sock", &env).unwrap();
        assert_eq!(app.daemon, std::path::PathBuf::from("/tmp/app-daemon.sock"));
        let without = |k: &str| (k == "CMUX_SOCKET_PATH").then(|| "/tmp/control.sock".to_owned());
        let app = AppWorkspaces::resolve("/tmp/own.sock", &without).unwrap();
        assert_eq!(app.daemon, std::path::PathBuf::from("/tmp/own.sock"));
    }

    use super::*;

    #[test]
    fn names_and_keys() {
        assert_eq!(
            name("a1", "list the\nfiles in ~/"),
            "a1 · list the files in ~/"
        );
        assert!(name("a2", &"x".repeat(80)).ends_with('…'));
        assert_eq!(done_name("a1 · t"), "✓ a1 · t");
        let key = new_key();
        assert_eq!(key.len(), 36);
        assert_eq!(&key[14..15], "4");
        assert_ne!(key, new_key());
    }

    #[test]
    fn a_run_past_the_apps_wait_budget_still_opens_the_workspace() {
        use std::os::unix::net::UnixListener;
        let dir = tempfile::tempdir().unwrap();
        let control = dir.path().join("control.sock");
        let listener = UnixListener::bind(&control).unwrap();
        let server = std::thread::spawn(move || {
            for answer in [
                r#"{"ok":false,"error":{"message":"action.run did not finish within 1999 ms"}}"#,
                r#"{"ok":false,"error":{"message":"unavailable: no such action"}}"#,
            ] {
                let (mut conn, _) = listener.accept().unwrap();
                let mut line = String::new();
                BufReader::new(conn.try_clone().unwrap())
                    .read_line(&mut line)
                    .unwrap();
                writeln!(conn, "{answer}").unwrap();
            }
        });
        let w = AppWorkspaces {
            control,
            daemon: dir.path().join("daemon.sock"),
            home: None,
        };
        assert_eq!(
            w.open(&new_key(), "s", "n", Path::new("/w"))
                .map(|k| k.len()),
            Ok(36)
        );
        assert!(w.open(&new_key(), "s", "n", Path::new("/w")).is_err());
        server.join().unwrap();
    }

    #[test]
    fn the_open_request_runs_the_app_action_as_a_script() {
        let r = open_request("sess", "a1 · t", "k", Path::new("/w"));
        assert_eq!(r["method"], "action.run");
        assert_eq!(r["params"]["action"], OPEN_ACTION);
        assert_eq!(r["params"]["args"]["session"], "sess");
        assert_eq!(r["params"]["args"]["key"], "k");
        assert_eq!(r["params"]["origin"], "script");
        assert_eq!(r["params"]["wait"], true);
    }
}
