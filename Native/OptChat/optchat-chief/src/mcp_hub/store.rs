//! What the hub keeps on disk. Two folders:
//!
//! - The machine's shared store ([`shared_dir`], `<acpmux home>/mcp/`): one file per
//!   server in `servers/<name>.json`, and its secrets (headers, env, OAuth
//!   tokens) in `secrets/<name>.json` (0600 in a 0700 folder). Every Chief home
//!   on this machine and acpmux's connect card read and write it, so a server
//!   connected anywhere in cmux is there for all of them, signed in once.
//!   A server file never holds a secret, so it can be shown, listed and backed
//!   up as it is.
//! - The Chief's own folder (`<optchat root>/mcp/`): its event subscriptions
//!   and tasks (`servers.json`, which wake that one Chief), the code-mode
//!   declarations, logs and scripts. A server list left in an older
//!   `servers.json` moves to the shared store on the first load.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// How the hub reaches a server.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Transport {
    /// Streamable HTTP (`https://...`, or `http://` to this machine).
    Http { url: String },
    /// A local process speaking newline-delimited JSON-RPC on stdin/stdout.
    Stdio {
        command: String,
        #[serde(default)]
        args: Vec<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
    },
}

impl Transport {
    /// One line for lists: the URL, or the command as typed.
    pub fn label(&self) -> String {
        match self {
            Transport::Http { url } => url.clone(),
            Transport::Stdio { command, args, .. } => std::iter::once(command.as_str())
                .chain(args.iter().map(String::as_str))
                .collect::<Vec<_>>()
                .join(" "),
        }
    }
}

/// One server the Chief added.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Server {
    /// `[a-z0-9_]`, unique: the code-mode namespace (`mcp.<name>`).
    pub name: String,
    pub transport: Option<Transport>,
    /// The publisher's domain, or "local".
    #[serde(default)]
    pub publisher: String,
    /// The URL is exactly a registry entry's (cmux-mcp-connect).
    #[serde(default)]
    pub verified: bool,
    #[serde(default)]
    pub added_ms: u64,
    /// Who asked for it (the Chief, or a subagent id).
    #[serde(default)]
    pub added_by: String,
    /// The names (never the values) of the secret headers and env vars.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub secret_names: Vec<String>,
    /// Who may use it, as the person chose on a connect card (`chat`,
    /// `chief`, `allChiefs`, `agents`, `everywhere`); none when a Chief added it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
    /// Whose `scope` it is: the chat's session id (`chat`), the Chief's home
    /// id (`chief`). Kept as read, so a Chief that updates the record never
    /// widens who sees it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    /// The last tool list (cached so search and describe need no connect).
    #[serde(default)]
    pub tools: Vec<Value>,
    #[serde(default)]
    pub prompts: Vec<Value>,
    /// Tools whose text the screen flagged (descriptions withheld).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub flagged: Vec<String>,
    /// The server's protocol version and capabilities at the last connect.
    #[serde(default)]
    pub protocol: String,
    #[serde(default)]
    pub capabilities: Value,
    /// `connected`, `needs sign-in`, or `failed: why`.
    #[serde(default)]
    pub state: String,
}

impl Server {
    /// Whether `viewer` may see and use it (the person's scope on the card).
    pub fn visible_to(&self, viewer: &cmux_mcp_connect::shared::Viewer) -> bool {
        cmux_mcp_connect::shared::visible(self.scope.as_deref(), self.owner.as_deref(), viewer)
    }
}

/// One event subscription: a resource URI, or a notification method.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Subscription {
    /// `e<N>`.
    pub id: String,
    pub server: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uri: Option<String>,
    /// A notification method (`notifications/message`, `*`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub method: Option<String>,
    #[serde(default)]
    pub note: String,
    #[serde(default)]
    pub by: String,
}

/// One task: a server-side MCP task, or a call the hub runs off the turn.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Task {
    /// `t<N>`.
    pub id: String,
    pub server: String,
    pub tool: String,
    /// The server's task id; None for a call the hub runs itself.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote: Option<String>,
    pub status: String,
    #[serde(default)]
    pub message: String,
    #[serde(default)]
    pub note: String,
    #[serde(default)]
    pub by: String,
    pub started_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_ms: Option<u64>,
    /// The result as text, once it ended.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<String>,
}

impl Task {
    /// True once the hub has finished the task (and sent its one note);
    /// a terminal `status` read from the server alone does not end it.
    pub fn ended(&self) -> bool {
        self.ended_ms.is_some()
    }
}

/// `servers.json`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct State {
    #[serde(default)]
    pub servers: Vec<Server>,
    #[serde(default)]
    pub subscriptions: Vec<Subscription>,
    #[serde(default)]
    pub tasks: Vec<Task>,
    #[serde(default)]
    pub last_subscription: u64,
    #[serde(default)]
    pub last_task: u64,
}

/// Ended tasks kept for `tasks` and `task` after they woke the Chief.
pub const ENDED_TASKS_KEPT: usize = 20;

impl State {
    pub fn server(&self, name: &str) -> Option<&Server> {
        self.servers.iter().find(|s| s.name == name)
    }

    pub fn server_mut(&mut self, name: &str) -> Option<&mut Server> {
        self.servers.iter_mut().find(|s| s.name == name)
    }

    /// Drops the oldest ended tasks past [`ENDED_TASKS_KEPT`].
    pub fn trim_tasks(&mut self) {
        let ended = self.tasks.iter().filter(|t| t.ended()).count();
        let mut drop = ended.saturating_sub(ENDED_TASKS_KEPT);
        self.tasks.retain(|t| {
            if drop > 0 && t.ended() {
                drop -= 1;
                false
            } else {
                true
            }
        });
    }
}

/// A server's secrets.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Secrets {
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub headers: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub env: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub oauth: Option<OAuthTokens>,
}

/// What a finished OAuth sign-in left.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct OAuthTokens {
    pub access_token: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refresh_token: Option<String>,
    /// Unix ms; 0: no expiry given.
    #[serde(default)]
    pub expires_ms: u64,
    pub client_id: String,
    pub token_endpoint: String,
    /// The issuer the client id belongs to (credentials are keyed by it).
    #[serde(default)]
    pub issuer: String,
    pub resource: String,
}

/// The machine's shared MCP store (cmux-mcp-connect's `shared`: one
/// definition for the Chief and acpmux): `$CMUX_MCP_HOME`, else the mcp
/// folder of this build's acpmux home.
pub fn shared_dir() -> PathBuf {
    cmux_mcp_connect::shared::dir(&crate::acpmux_daemon::home(), &|k: &str| {
        std::env::var(k).ok()
    })
}

/// The hub's folders: the Chief's own, and the machine's shared store.
#[derive(Clone, Debug)]
pub struct Dir {
    pub own: PathBuf,
    pub shared: PathBuf,
}

impl Dir {
    pub fn new(own: PathBuf, shared: PathBuf) -> Self {
        Self { own, shared }
    }

    /// This Chief's subscriptions and tasks.
    pub fn state_path(&self) -> PathBuf {
        self.own.join("servers.json")
    }

    /// The shared server records, one file each.
    pub fn servers_dir(&self) -> PathBuf {
        self.shared.join("servers")
    }

    pub fn server_path(&self, name: &str) -> PathBuf {
        cmux_mcp_connect::shared::server_path(&self.shared, name)
    }

    pub fn secrets_path(&self, name: &str) -> PathBuf {
        cmux_mcp_connect::shared::secrets_path(&self.shared, name)
    }

    /// The code-mode declarations of one server (`api/<name>.d.ts`).
    pub fn api_path(&self, name: &str) -> PathBuf {
        self.own.join("api").join(format!("{name}.d.ts"))
    }

    pub fn log_path(&self, name: &str) -> PathBuf {
        self.own.join("logs").join(format!("{name}.log"))
    }

    /// The shared servers as they are on disk now, by name.
    pub fn load_servers(&self) -> BTreeMap<String, Server> {
        let mut out = BTreeMap::new();
        let Ok(entries) = std::fs::read_dir(self.servers_dir()) else {
            return out;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            let Some(server) = std::fs::read(&path)
                .ok()
                .and_then(|b| serde_json::from_slice::<Server>(&b).ok())
            else {
                continue;
            };
            // The file's name is the server's name.
            if path.file_stem().and_then(|s| s.to_str()) == Some(server.name.as_str()) {
                out.insert(server.name.clone(), server);
            }
        }
        out
    }

    /// The Chief's state with the shared servers in it. Servers an older
    /// `servers.json` holds (and their secrets) move to the shared store
    /// unless a server of that name is there already.
    pub fn load(&self) -> State {
        let mut state: State = std::fs::read(self.state_path())
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        let legacy = std::mem::take(&mut state.servers);
        let mut shared = self.load_servers();
        for server in legacy {
            if shared.contains_key(&server.name) {
                continue;
            }
            let old_secret = self
                .own
                .join("secrets")
                .join(format!("{}.json", server.name));
            if let Ok(bytes) = std::fs::read(&old_secret)
                && let Ok(secrets) = serde_json::from_slice::<Secrets>(&bytes)
                && self.save_secrets(&server.name, &secrets).is_ok()
            {
                let _ = std::fs::remove_file(&old_secret);
            }
            if self.save_server(&server).is_ok() {
                shared.insert(server.name.clone(), server);
            }
        }
        state.servers = shared.into_values().collect();
        // Rewrite the Chief's file without the moved servers.
        let _ = self.save_own(&state);
        state
    }

    /// The Chief's own part of `state` (subscriptions and tasks).
    pub fn save_own(&self, state: &State) -> Result<(), String> {
        let own = State {
            servers: Vec::new(),
            ..state.clone()
        };
        let text = serde_json::to_vec_pretty(&own).map_err(|e| e.to_string())?;
        write_atomic(&self.state_path(), &text, 0o644)
    }

    /// One shared server record.
    pub fn save_server(&self, server: &Server) -> Result<(), String> {
        let text = serde_json::to_vec_pretty(server).map_err(|e| e.to_string())?;
        write_atomic(&self.server_path(&server.name), &text, 0o644)
    }

    pub fn secrets(&self, name: &str) -> Secrets {
        std::fs::read(self.secrets_path(name))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    pub fn save_secrets(&self, name: &str, secrets: &Secrets) -> Result<(), String> {
        let path = self.secrets_path(name);
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
        }
        let text = serde_json::to_vec(secrets).map_err(|e| e.to_string())?;
        write_atomic(&path, &text, 0o600)
    }

    /// Runs `f` holding the machine-wide lock of `name`'s secrets (a token
    /// refresh: two processes must not both spend one refresh token).
    pub fn with_secret_lock<T>(&self, name: &str, f: impl FnOnce() -> T) -> T {
        use std::os::unix::io::AsRawFd;
        let path = self.shared.join("secrets").join(format!(".{name}.lock"));
        let file = path.parent().and_then(|d| {
            std::fs::create_dir_all(d).ok()?;
            std::fs::OpenOptions::new()
                .create(true)
                .truncate(false)
                .write(true)
                .open(&path)
                .ok()
        });
        if let Some(file) = &file {
            // SAFETY: flock on an open descriptor we own; released on close.
            unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) };
        }
        let out = f();
        drop(file);
        out
    }

    /// Removes a server everywhere on this machine: its record, secrets and
    /// this Chief's declarations.
    pub fn forget(&self, name: &str) {
        let _ = std::fs::remove_file(self.server_path(name));
        let _ = std::fs::remove_file(self.secrets_path(name));
        let _ = std::fs::remove_file(self.api_path(name));
    }
}

fn write_atomic(path: &Path, bytes: &[u8], mode: u32) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let dir = path.parent().ok_or("no parent folder")?;
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let tmp = dir.join(format!(
        ".{}.{}.{}.tmp",
        path.file_name().and_then(|n| n.to_str()).unwrap_or("f"),
        std::process::id(),
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(mode)
        .open(&tmp)
        .map_err(|e| e.to_string())?;
    f.write_all(bytes).map_err(|e| e.to_string())?;
    f.sync_all().map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}
