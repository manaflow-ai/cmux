//! What the hub keeps on disk (`<optchat root>/mcp/`): the servers the Chief
//! added, its event subscriptions and its tasks in `servers.json`, and each
//! server's secrets (headers, env, OAuth tokens) in `secrets/<name>.json`
//! (0600 in a 0700 folder). `servers.json` never holds a secret, so it can be
//! shown, listed and backed up as it is.

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
    pub fn ended(&self) -> bool {
        matches!(self.status.as_str(), "completed" | "failed" | "cancelled")
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

/// The hub's folder.
#[derive(Clone, Debug)]
pub struct Dir(pub PathBuf);

impl Dir {
    pub fn state_path(&self) -> PathBuf {
        self.0.join("servers.json")
    }

    pub fn secrets_path(&self, name: &str) -> PathBuf {
        self.0.join("secrets").join(format!("{name}.json"))
    }

    /// The code-mode declarations of one server (`api/<name>.d.ts`).
    pub fn api_path(&self, name: &str) -> PathBuf {
        self.0.join("api").join(format!("{name}.d.ts"))
    }

    pub fn log_path(&self, name: &str) -> PathBuf {
        self.0.join("logs").join(format!("{name}.log"))
    }

    pub fn load(&self) -> State {
        std::fs::read(self.state_path())
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, state: &State) -> Result<(), String> {
        let text = serde_json::to_vec_pretty(state).map_err(|e| e.to_string())?;
        write_atomic(&self.state_path(), &text, 0o644)
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

    pub fn forget(&self, name: &str) {
        let _ = std::fs::remove_file(self.secrets_path(name));
        let _ = std::fs::remove_file(self.api_path(name));
    }
}

fn write_atomic(path: &Path, bytes: &[u8], mode: u32) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let dir = path.parent().ok_or("no parent folder")?;
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let tmp = dir.join(format!(
        ".{}.{}.tmp",
        path.file_name().and_then(|n| n.to_str()).unwrap_or("f"),
        std::process::id()
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
