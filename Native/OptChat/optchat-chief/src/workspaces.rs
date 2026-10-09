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
}

impl AppWorkspaces {
    /// From the host's env: `CMUX_SOCKET_PATH` (None without it) and the
    /// daemon socket.
    pub fn from_env(daemon: &str) -> Option<AppWorkspaces> {
        crate::cli::env("CMUX_SOCKET_PATH").map(|control| AppWorkspaces {
            control: control.into(),
            daemon: daemon.into(),
        })
    }
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
            &open_request(session, name, &key, cwd),
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
