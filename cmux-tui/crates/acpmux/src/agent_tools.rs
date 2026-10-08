//! cmux's own tools for every agent session this daemon starts on this Mac:
//! the cmux Computer Use MCP server (`cmux-cua mcp`), the cmux MCP server
//! with the browser REPL tools (`cmux mcp serve`), and the `cmux-browser`
//! and `cmux-cua` skills. One place decides them; the hub applies them at
//! each spawn and `session/new|load|fork`, so the app pane, the TUI, the CLI,
//! the Chief, pooled sessions and forks all get the same set.
//!
//! - MCP servers: an ACP harness gets them in `mcpServers` of
//!   `session/new`, `session/load` and `session/fork`; Claude Code (the
//!   claude-stdio adapter) gets one `--mcp-config` (not strict, so the
//!   user's own servers stay).
//! - Skills: Claude Code gets a session-only plugin named `cmux`
//!   (`--plugin-dir`) whose skills are `cmux:cmux-browser` and
//!   `cmux:cmux-cua`. The skill text is compiled in from `skills/` and
//!   written once per content hash under `<ACPMUX_HOME>/agent-tools/`.
//!   Only the skill descriptions reach the prompt (progressive disclosure);
//!   `cmux-cua` keeps `disable-model-invocation`, so only the user starts it.
//!   Known limit: `skills/` is not a cmux-tui tree-key input
//!   (scripts/cmux-next/cmux-tui-tree-inputs.txt), so a skills-only change
//!   reaches a published cmux-tui build with the next cmux-tui change.
//! - Computer use: when the cmux app exported its tag's helper socket
//!   (`CMUX_NEXT_CUA_SOCKET`, `cua_socket.rs`), `cmux-cua mcp` gets it as
//!   `--socket` plus the agent token in its env; this daemon starts no
//!   helper. The tools refuse the user's cmux and other terminals; a profile
//!   or preset env with `CMUX_CUA_ALLOWED_TARGET_BUNDLE_IDS` (for example
//!   the session's own tagged `com.cmuxterm.app.debug.<tag>`) unlocks exact
//!   bundle ids for that session only.
//! - Binaries are found next to this executable (the app's
//!   `Contents/Resources/bin`), or in `CMUX_AGENT_TOOLS_BIN_DIR`. A missing
//!   binary leaves its server out. `cmux mcp serve` refuses unless
//!   cmux.json sets `mcp.enabled`, so its server is added only then.
//! - Left out (`left_out`): remote-origin sessions (`remote_sandbox.rs`
//!   keeps their MCP config empty on purpose), a profile or preset whose env
//!   sets `ACPMUX_AGENT_TOOLS=0` (isolated sessions such as the Chief's
//!   compactor), and Claude args with `--strict-mcp-config`.
//!   `ACPMUX_AGENT_TOOLS=0` on the daemon turns all of it off.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

/// Directory that overrides where the cmux binaries are looked up.
pub const BIN_DIR_ENV: &str = "CMUX_AGENT_TOOLS_BIN_DIR";
/// `0` turns the agent tools off for this daemon.
pub const SWITCH_ENV: &str = "ACPMUX_AGENT_TOOLS";
/// A session env key passed to `cmux-cua mcp`: exact bundle ids the
/// session's computer use may target although the guard refuses them.
pub const CUA_SCOPE_ENV: &str = "CMUX_CUA_ALLOWED_TARGET_BUNDLE_IDS";
/// The plugin name Claude Code shows before each skill (`cmux:cmux-browser`).
pub const PLUGIN_NAME: &str = "cmux";

/// The skill files, as `(path inside the plugin's skills/, text)`.
const SKILL_FILES: &[(&str, &str)] = &[
    ("cmux-browser/SKILL.md", include_str!("../../../../skills/cmux-browser/SKILL.md")),
    ("cmux-browser/references/repl-guide.md", include_str!("../../cmux-browser-host/js/guide.md")),
    (
        "cmux-browser/references/authentication.md",
        include_str!("../../../../skills/cmux-browser/references/authentication.md"),
    ),
    (
        "cmux-browser/references/commands.md",
        include_str!("../../../../skills/cmux-browser/references/commands.md"),
    ),
    (
        "cmux-browser/references/proxy-support.md",
        include_str!("../../../../skills/cmux-browser/references/proxy-support.md"),
    ),
    (
        "cmux-browser/references/session-management.md",
        include_str!("../../../../skills/cmux-browser/references/session-management.md"),
    ),
    (
        "cmux-browser/references/snapshot-refs.md",
        include_str!("../../../../skills/cmux-browser/references/snapshot-refs.md"),
    ),
    (
        "cmux-browser/references/surface-discovery.md",
        include_str!("../../../../skills/cmux-browser/references/surface-discovery.md"),
    ),
    (
        "cmux-browser/references/video-recording.md",
        include_str!("../../../../skills/cmux-browser/references/video-recording.md"),
    ),
    (
        "cmux-browser/templates/authenticated-session.sh",
        include_str!("../../../../skills/cmux-browser/templates/authenticated-session.sh"),
    ),
    (
        "cmux-browser/templates/capture-workflow.sh",
        include_str!("../../../../skills/cmux-browser/templates/capture-workflow.sh"),
    ),
    (
        "cmux-browser/templates/form-automation.sh",
        include_str!("../../../../skills/cmux-browser/templates/form-automation.sh"),
    ),
    ("cmux-cua/SKILL.md", include_str!("../../../../skills/cmux-cua/SKILL.md")),
];

/// One stdio MCP server.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpServer {
    pub name: String,
    pub command: PathBuf,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
}

/// What every local session gets.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AgentTools {
    pub servers: Vec<McpServer>,
    /// The Claude Code plugin folder holding the skills.
    pub plugin_dir: Option<PathBuf>,
}

/// Where the tools come from; `current()` reads them from this process.
#[derive(Debug, Clone)]
pub struct Inputs {
    pub enabled: bool,
    pub bin_dir: Option<PathBuf>,
    /// The text of cmux.json, if the file exists.
    pub cmux_json: Option<String>,
    /// `<ACPMUX_HOME>/agent-tools`.
    pub state_dir: PathBuf,
    /// The tag's helper socket the cmux app exported, if any.
    pub cua: Option<crate::cua_socket::Socket>,
    /// The helper v2 endpoint folder, only while the helper v2 runs
    /// (`endpoint.json` exists): sessions then get `acpmux cua-mcp`.
    pub cua_v2: Option<PathBuf>,
    /// This acpmux executable (the `cua-mcp` bridge command).
    pub acpmux: Option<PathBuf>,
}

impl Inputs {
    pub fn current() -> Self {
        let var = |name: &str| std::env::var_os(name).filter(|v| !v.is_empty());
        let bin_dir = var(BIN_DIR_ENV).map(PathBuf::from).or_else(|| {
            std::env::current_exe().ok().and_then(|exe| exe.parent().map(Path::to_path_buf))
        });
        let config = match var("CMUX_NEXT_CONFIG_FILE") {
            Some(path) => PathBuf::from(path),
            None => dirs::home_dir().unwrap_or_default().join(".config/cmux/cmux.json"),
        };
        Inputs {
            enabled: var(SWITCH_ENV).is_none_or(|v| v != "0"),
            bin_dir,
            cmux_json: std::fs::read_to_string(config).ok(),
            state_dir: crate::config::home().join("agent-tools"),
            cua: crate::cua_socket::from_env(),
            cua_v2: crate::cua_v2::active_dir(crate::cua_v2::dir_from_env()),
            acpmux: std::env::current_exe().ok(),
        }
    }
}

/// The tools for this daemon's local sessions, read now (a new app build or
/// a cmux.json change applies to the next spawn).
pub fn current() -> AgentTools {
    resolve(&Inputs::current())
}

/// Whether a session gets no tools: a remote origin, a profile or preset env
/// with `ACPMUX_AGENT_TOOLS=0` (an isolated session such as a compactor),
/// or Claude Code args with `--strict-mcp-config` (only the servers that
/// profile names).
pub fn left_out(remote_origin: bool, env: &BTreeMap<String, String>, args: &[String]) -> bool {
    remote_origin
        || env.get(SWITCH_ENV).is_some_and(|v| v == "0")
        || args.iter().any(|a| a == "--strict-mcp-config")
}

/// `mcpServers` for a session's ACP harness.
pub fn acp_servers_for(remote_origin: bool, env: &BTreeMap<String, String>) -> Value {
    if left_out(remote_origin, env, &[]) { json!([]) } else { current().scoped(env).acp_servers() }
}

/// Extra Claude Code flags for session `session_id` whose command line is
/// `args`. The MCP config goes to [`mcp_config_path`], never into argv.
pub fn claude_args_for(
    remote_origin: bool,
    env: &BTreeMap<String, String>,
    args: &[String],
    session_id: &str,
) -> Vec<String> {
    if left_out(remote_origin, env, args) {
        Vec::new()
    } else {
        current().scoped(env).claude_args(&mcp_config_path(&crate::config::home(), session_id))
    }
}

/// The session's Claude Code MCP config file: `<home>/run/mcp/<session>.json`.
/// It holds the helper's agent token, so it is 0600 in a 0700 folder and
/// never on a command line, where any process of the user can read it.
pub fn mcp_config_path(home: &Path, session_id: &str) -> PathBuf {
    let safe: String = session_id
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
        .collect();
    home.join("run").join("mcp").join(format!("{safe}.json"))
}

/// Remove the session's MCP config when the session ends.
pub fn remove_mcp_config(home: &Path, session_id: &str) {
    let _ = std::fs::remove_file(mcp_config_path(home, session_id));
}

pub fn resolve(inputs: &Inputs) -> AgentTools {
    if !inputs.enabled {
        return AgentTools::default();
    }
    let mut servers = Vec::new();
    let executable = |name: &str| {
        inputs.bin_dir.as_ref().map(|dir| dir.join(name)).filter(|path| is_executable(path))
    };
    if let (Some(dir), Some(acpmux)) = (&inputs.cua_v2, &inputs.acpmux) {
        // The helper v2: this acpmux as the agent's MCP server. Only the
        // folder goes in its env; the bridge reads the socket and secret
        // from endpoint.json there when it connects.
        servers.push(McpServer {
            name: crate::cua_v2::SERVER_NAME.into(),
            command: acpmux.clone(),
            args: vec!["cua-mcp".into()],
            env: vec![(crate::cua_v2::ENDPOINT_DIR_ENV.into(), dir.to_string_lossy().into_owned())],
        });
    } else if let Some(cua) = executable("cmux-cua") {
        let mut args = vec!["mcp".to_owned()];
        let mut socket_env: Vec<(String, String)> = Vec::new();
        if let Some(socket) = &inputs.cua {
            args.push("--socket".into());
            args.push(socket.path.to_string_lossy().into_owned());
            if !socket.token.is_empty() {
                socket_env.push(("CMUX_CUA_SOCKET_AUTH_TOKEN".into(), socket.token.clone()));
            }
        }
        servers.push(McpServer {
            name: "cmux-cua".into(),
            command: cua,
            args,
            env: [
                // Always the signed helper over its socket, never in-process
                // computer use with this agent's TCC identity.
                ("CMUX_CUA_MCP_FORCE_PROXY", "1"),
                ("CMUX_CUA_TELEMETRY_ENABLED", "false"),
                ("CMUX_CUA_UPDATE_CHECK", "false"),
                ("CMUX_CUA_CURSOR_GRADIENT", "#12c7f5,#2d8cff,#6c5cff"),
                ("CMUX_CUA_CURSOR_BLOOM", "#2d8cff"),
                ("CMUX_CUA_CURSOR_LABEL", "cmux"),
            ]
            .into_iter()
            .map(|(k, v)| (k.to_owned(), v.to_owned()))
            .chain(socket_env)
            .collect(),
        });
    }
    if let Some(cmux) = executable("cmux")
        && inputs.cmux_json.as_deref().is_some_and(mcp_enabled)
    {
        servers.push(McpServer {
            name: "cmux".into(),
            command: cmux,
            args: vec!["mcp".into(), "serve".into()],
            env: vec![],
        });
    }
    let plugin_dir = match materialize(&inputs.state_dir) {
        Ok(dir) => Some(dir),
        Err(e) => {
            tracing::warn!("agent tools: the skills plugin was not written: {e:#}");
            None
        }
    };
    AgentTools { servers, plugin_dir }
}

impl AgentTools {
    /// The tools for one session: its env's [`CUA_SCOPE_ENV`] reaches only
    /// the computer use server. Without one the server gets the key empty,
    /// so a value inherited from the daemon's env never widens the guard.
    pub fn scoped(mut self, session_env: &BTreeMap<String, String>) -> Self {
        let scope = session_env.get(CUA_SCOPE_ENV).cloned().unwrap_or_default();
        for server in &mut self.servers {
            server.env.retain(|(k, _)| k != CUA_SCOPE_ENV);
            if server.name == "cmux-cua" {
                server.env.push((CUA_SCOPE_ENV.to_owned(), scope.clone()));
            }
        }
        self
    }

    /// `mcpServers` for an ACP `session/new`, `session/load` or `session/fork`.
    pub fn acp_servers(&self) -> Value {
        Value::Array(
            self.servers
                .iter()
                .map(|s| {
                    let env: Vec<Value> =
                        s.env.iter().map(|(k, v)| json!({"name": k, "value": v})).collect();
                    json!({"name": s.name, "command": s.command, "args": s.args, "env": env})
                })
                .collect(),
        )
    }

    /// The servers as one Claude Code MCP config, or `None` without servers.
    pub fn mcp_config(&self) -> Option<Value> {
        if self.servers.is_empty() {
            return None;
        }
        let mut servers = Map::new();
        for s in &self.servers {
            let env: Map<String, Value> =
                s.env.iter().map(|(k, v)| (k.clone(), json!(v))).collect();
            servers.insert(
                s.name.clone(),
                json!({"type": "stdio", "command": s.command, "args": s.args, "env": env}),
            );
        }
        Some(json!({"mcpServers": servers}))
    }

    /// Claude Code flags: the servers as `--mcp-config <config_file>` (the
    /// file is written here), the skills as a session-only plugin.
    pub fn claude_args(&self, config_file: &Path) -> Vec<String> {
        let mut args = Vec::new();
        if let Some(config) = self.mcp_config() {
            match write_private(config_file, config.to_string().as_bytes()) {
                Ok(()) => {
                    args.push("--mcp-config".into());
                    args.push(config_file.to_string_lossy().into_owned());
                }
                // Never fall back to inline JSON: that puts the token in argv.
                Err(e) => tracing::warn!(
                    "agent tools: MCP config {} not written, session gets no MCP servers: {e:#}",
                    config_file.display()
                ),
            }
        }
        if let Some(dir) = &self.plugin_dir {
            args.push("--plugin-dir".into());
            args.push(dir.to_string_lossy().into_owned());
        }
        args
    }
}

/// Write `bytes` to `path` as a 0600 file in a 0700 folder (to a temporary
/// file first, then renamed, so claude never reads half a config).
fn write_private(path: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
    let dir = path.parent().ok_or_else(|| anyhow::anyhow!("no parent folder"))?;
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    let tmp = dir.join(format!(".tmp-{}", uuid::Uuid::now_v7()));
    let written = (|| -> std::io::Result<()> {
        let mut f =
            std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        std::fs::rename(&tmp, path)
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    Ok(written?)
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// Same rule as `cmux mcp serve` (cmux-tui `cli/mcp/config.rs`): on only when
/// `mcp.enabled` is `true`; comments are allowed, anything unreadable is off.
fn mcp_enabled(text: &str) -> bool {
    let plain: String = text
        .lines()
        .filter(|line| !line.trim_start().starts_with("//"))
        .collect::<Vec<_>>()
        .join("\n");
    serde_json::from_str::<Value>(&plain)
        .ok()
        .and_then(|doc| doc.pointer("/mcp/enabled").and_then(Value::as_bool))
        .unwrap_or(false)
}

/// The plugin folder for the compiled-in skills, written once per content
/// hash (to a temporary folder, then renamed, so a reader never sees half).
fn materialize(state_dir: &Path) -> anyhow::Result<PathBuf> {
    let mut all = Vec::new();
    for (path, text) in SKILL_FILES {
        all.extend_from_slice(path.as_bytes());
        all.push(0);
        all.extend_from_slice(text.as_bytes());
        all.push(0);
    }
    let hash = crate::sha256::sha256_hex(&all);
    let dir = state_dir.join(&hash[..16]);
    if dir.join(".claude-plugin/plugin.json").is_file() {
        return Ok(dir);
    }
    std::fs::create_dir_all(state_dir)?;
    let tmp = state_dir.join(format!(".tmp-{}", uuid::Uuid::now_v7()));
    let manifest = json!({
        "name": PLUGIN_NAME,
        "description": "cmux browser and computer use skills for agents cmux starts",
        "version": env!("CARGO_PKG_VERSION"),
    });
    let mut files = vec![(".claude-plugin/plugin.json".to_owned(), manifest.to_string())];
    files.extend(SKILL_FILES.iter().map(|(p, t)| (format!("skills/{p}"), (*t).to_owned())));
    for (path, text) in files {
        let file = tmp.join(path);
        if let Some(parent) = file.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(file, text)?;
    }
    match std::fs::rename(&tmp, &dir) {
        Ok(()) => Ok(dir),
        // Another spawn wrote the same content first.
        Err(_) if dir.join(".claude-plugin/plugin.json").is_file() => {
            let _ = std::fs::remove_dir_all(&tmp);
            Ok(dir)
        }
        Err(e) => {
            let _ = std::fs::remove_dir_all(&tmp);
            Err(e.into())
        }
    }
}

#[cfg(test)]
#[path = "agent_tools_tests.rs"]
mod tests;
