//! cmux's own tools for every agent session this daemon starts on this Mac:
//! the cmux Computer Use MCP server (`cmux-cua mcp`), the cmux MCP server
//! with the browser REPL tools (`cmux mcp serve`), the render server
//! (`cmux mcp serve --render-only`, render_mcp.rs), and the `cmux-browser`
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
//! - Binaries are found next to this executable (the app's
//!   `Contents/Resources/bin`), or in `CMUX_AGENT_TOOLS_BIN_DIR`. A missing
//!   binary leaves its server out. `cmux mcp serve` refuses unless
//!   cmux.json sets `mcp.enabled`, so its server is added only then.
//!   The render server needs no setting: its one tool reaches nothing, and
//!   Claude Code is allowed to call it without a prompt.
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
    if left_out(remote_origin, env, &[]) { json!([]) } else { current().acp_servers() }
}

/// Extra Claude Code flags for a session whose command line is `args`.
pub fn claude_args_for(
    remote_origin: bool,
    env: &BTreeMap<String, String>,
    args: &[String],
) -> Vec<String> {
    if left_out(remote_origin, env, args) { Vec::new() } else { current().claude_args() }
}

pub fn resolve(inputs: &Inputs) -> AgentTools {
    if !inputs.enabled {
        return AgentTools::default();
    }
    let mut servers = Vec::new();
    let executable = |name: &str| {
        inputs.bin_dir.as_ref().map(|dir| dir.join(name)).filter(|path| is_executable(path))
    };
    if let Some(cua) = executable("cmux-cua") {
        servers.push(McpServer {
            name: "cmux-cua".into(),
            command: cua,
            args: vec!["mcp".into()],
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
    // The render server (render_mcp.rs) reaches nothing, so it needs no setting.
    if let Some(cmux) = executable("cmux") {
        servers.push(McpServer {
            name: crate::render_mcp::SERVER_NAME.into(),
            command: cmux,
            args: crate::render_mcp::ARGS.iter().map(|a| (*a).into()).collect(),
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

    /// Claude Code flags: the render tool allowed (when its server is on), the
    /// servers as one `--mcp-config`, the skills as a session-only plugin.
    pub fn claude_args(&self) -> Vec<String> {
        let mut args = Vec::new();
        // The render tool shows a page and reaches nothing: a permission card per page would
        // only be noise.
        if self.servers.iter().any(|s| s.name == crate::render_mcp::SERVER_NAME) {
            args.push("--allowedTools".into());
            args.push(crate::render_mcp::CLAUDE_TOOL.into());
        }
        if !self.servers.is_empty() {
            let mut servers = Map::new();
            for s in &self.servers {
                let env: Map<String, Value> =
                    s.env.iter().map(|(k, v)| (k.clone(), json!(v))).collect();
                servers.insert(
                    s.name.clone(),
                    json!({"type": "stdio", "command": s.command, "args": s.args, "env": env}),
                );
            }
            args.push("--mcp-config".into());
            args.push(json!({"mcpServers": servers}).to_string());
        }
        if let Some(dir) = &self.plugin_dir {
            args.push("--plugin-dir".into());
            args.push(dir.to_string_lossy().into_owned());
        }
        args
    }
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
