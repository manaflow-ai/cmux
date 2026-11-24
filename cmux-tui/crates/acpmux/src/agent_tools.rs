//! cmux's own tools for every agent session this daemon starts on this Mac:
//! the cmux Computer Use MCP server (`acpmux computer-use-mcp`), the cmux MCP
//! server with the browser REPL tools (`cmux mcp serve`), and the
//! `cmux-browser` and `cmux-computer-use` skills. One place decides them; the hub applies them at
//! each spawn and `session/new|load|fork`, so the app pane, the TUI, the CLI,
//! the Chief, pooled sessions and forks all get the same set.
//!
//! - MCP servers: an ACP harness gets them in `mcpServers` of
//!   `session/new`, `session/load` and `session/fork`; Claude Code (the
//!   claude-stdio adapter) gets one `--mcp-config` (not strict, so the
//!   user's own servers stay).
//! - Skills: Claude Code gets a session-only plugin named `cmux`
//!   (`--plugin-dir`) whose skills are `cmux:cmux-browser`,
//!   `cmux:cmux-computer-use`, `cmux:cmux-customization` (settings, and a view of the
//!   person's own that an agent writes as the customize app) and
//!   `cmux:acpmux` (the acpmux CLI guide, for driving sessions from a shell) and
//!   `cmux:cmux-chat` (plans, sub-sessions, links and the recap; `agent_guidance.rs`, which
//!   also adds the person's own skills as a `cmux-user` plugin). The skill text is compiled in from `skills/` and
//!   written once per content hash under `<ACPMUX_HOME>/agent-tools/`.
//!   Only the skill descriptions reach the prompt (progressive disclosure).
//!   `cmux-computer-use` is model-invocable: its description claims tasks
//!   in a desktop app; the person's Computer Use settings decide what runs.
//!   Known limit: `skills/` is not a cmux-tui tree-key input
//!   (scripts/cmux-next/cmux-tui-tree-inputs.txt), so a skills-only change
//!   reaches a published cmux-tui build with the next cmux-tui change.
//! - Computer Use (`computer_use/mcp.rs`): every session gets
//!   `acpmux computer-use-mcp` (server `cmux-computer-use`), whatever
//!   `computerUse.mode` says: tools are fixed when a chat spawns, and Computer
//!   Use may be turned on later (each call then says it is off). The bridge
//!   serves the tool list itself and finds the worker through the cmux-tui
//!   daemon at each call, so no file and no running worker decides whether a
//!   session gets it.
//!   Per-workspace displays (`agent_displays.rs`) leave it out: the worker
//!   drives the machine's one desktop, never a session's own display.
//!   With the `cmux` server on, `folded` puts it behind that server as the
//!   `cu_*` tools, so the agent has one server and scripts Computer Use in
//!   `cmux_exec` (`cu.click({...})`); a Claude Code or Codex typed into a cmux
//!   terminal gets the same through its shim (cmux-tui `agent_computer_use.rs`).
//! - Binaries are found next to this executable (the app's
//!   `Contents/Resources/bin`), or in `CMUX_AGENT_TOOLS_BIN_DIR`.
//!   A missing binary leaves its server out.
//! - The `cmux` server (`cmux mcp serve`, [`cmux_server`]): one definition for
//!   every agent cmux starts, built by [`cmux_server`] for these sessions and
//!   for a Claude Code or Codex typed into a cmux terminal (cmux-tui
//!   `agent_computer_use.rs`), so the two cannot drift: the name `cmux`, the
//!   CLI, `mcp serve`, and the settings file the app runs on
//!   (`CMUX_NEXT_CONFIG_FILE`). A session gets it unless the person turned
//!   cmux's tools off for agents started in cmux (`agents.cmuxMcp` is `off`,
//!   [`agents_get_cmux`]; on by default), the same setting the terminal
//!   shims follow; a Chief turn (a preset with its own cmux tool list,
//!   [`MCP_TOOLS_ENV`]) keeps it either way, being cmux's own orchestrator.
//!   The settings file's `"mcp": {"enabled": false}` turns it off too (`cmux
//!   mcp serve` refuses then). Without it the session's other servers stay
//!   standalone (`folded`). cmux never writes an agent's own config for it.
//! - Left out (`left_out`): remote-origin sessions (`remote_sandbox.rs`
//!   keeps their MCP config empty on purpose), a profile or preset whose env
//!   sets `ACPMUX_AGENT_TOOLS=0` (isolated sessions such as the Chief's
//!   compactor), and Claude args with `--strict-mcp-config`.
//!   `ACPMUX_AGENT_TOOLS=0` on the daemon turns all of it off.
//! - A project's own MCP servers (`project_mcp.rs`): a Claude Code start on a checkout that
//!   still fills (at its head) gets each `.mcp.json` stdio server Claude would start, under its
//!   name, as `cmux repo mcp-lazy`, which waits for the whole checkout. Left-out sessions too,
//!   except under `--strict-mcp-config` and for a remote origin.
//! - Agent memory (`cmux-agent-memory`, cmux#21611): `optchat-chief
//!   agent-memory mcp`, long-term memory the user's Codex and Claude Code
//!   sessions share, only when cmux.json sets `agents.memory.enabled` to
//!   `true` (default off; the server reads its other `agents.memory.*` keys
//!   itself). It gets the session as [`AGENT_SESSION_ENV`], the provenance
//!   of the notes it saves.
//! - Hosted MCP (`cmux-hosted`, `hosted_mcp.rs`): cmux's hosted MCP server with the signed-in
//!   person's GitHub connectors and their own remote MCP servers, only while the daemon's
//!   `CMUX_HOSTED_MCP` is `1` (default off) and not on a cmux Cloud VM. Its env holds only the
//!   `cmux` CLI's path; the person's token never enters a config, an env or argv.
//! - Kept servers (`ACPMUX_AGENT_TOOL_SERVERS`, a profile or preset env):
//!   only the named MCP servers; the Chief's turns keep `cmux` (cx-4a5w2).

pub mod prompt_sources;
pub mod skill_index;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

pub mod claude_plugin_dirs;
mod cmux_mcp;
pub mod project_mcp;
mod upstreams;

pub use claude_plugin_dirs::{CLAUDE_PLUGIN_DIRS_ENV, without_cmux_tui_plugins};
pub use upstreams::{HTTP_FIELD, SHARED_FIELD, takes_http};

/// Directory that overrides where the cmux binaries are looked up.
pub const BIN_DIR_ENV: &str = "CMUX_AGENT_TOOLS_BIN_DIR";
/// `0` turns the agent tools off for this daemon.
pub const SWITCH_ENV: &str = "ACPMUX_AGENT_TOOLS";
/// The agent session the cmux CLI and `cmux mcp serve` name as their caller
/// (`caller.agent_session`), so the app opens their tabs beside its chat.
pub const AGENT_SESSION_ENV: &str = "CMUX_AGENT_SESSION";

/// Caller ids an agent must not inherit from the daemon's own environment
/// (a daemon an agent started carries that agent's session too, and a
/// terminal Claude's answer to cmux's tools, [`TOOLS_ANSWER_ENV`]; a chat's own
/// answer comes from its session env, applied after).
pub const INHERITED_CALLER_ENV: [&str; 5] = [
    "CMUX_TUI_TERMINAL_ID",
    "CMUX_SURFACE_ID",
    "CMUX_PANEL_ID",
    AGENT_SESSION_ENV,
    TOOLS_ANSWER_ENV,
];

/// The harness families whose ACP server refuses `mcpServers` in `session/new` and
/// `session/load`: OpenClaw's bridge answers "ACP bridge mode does not support per-session MCP
/// servers", so the whole start failed. They get no per-session servers; the Chief registers
/// cmux's servers in that brain's own config instead (optchat-chief `brain_home.rs`).
pub const NO_SESSION_MCP_FAMILIES: [&str; 1] = ["openclaw"];

/// Whether harness `name` (profile `profile`) takes cmux's MCP servers in its ACP session
/// requests ([`NO_SESSION_MCP_FAMILIES`]).
pub fn takes_session_mcp(name: &str, profile: &crate::config::HarnessProfile) -> bool {
    !NO_SESSION_MCP_FAMILIES.contains(&crate::config::derive_family(name, profile).as_str())
}

/// Harness families that start a stdio MCP server with a scrubbed environment: Hermes passes a
/// child only PATH, HOME, USER, LANG, LC_ALL, TERM, SHELL and TMPDIR plus the entry's own `env`
/// (`tools/mcp_tool_config.py` `_SAFE_ENV_KEYS`). The cmux server then cannot find the session's
/// socket and every cmux tool fails ("the cmux session socket is unavailable", cmux-ci step
/// 20724a44bada). [`with_routing_env`] writes the routing variables into each stdio entry.
pub const SCRUBBED_ENV_FAMILIES: [&str; 1] = ["hermes"];

/// Environment names a cmux-owned MCP server reads to reach this session's daemons: the sockets
/// and state folders of cmux, the mux and acpmux, and the Chief's tool list. Values only, never a
/// key or a token.
pub const ROUTING_ENV: [&str; 9] = [
    "CMUX_TUI_SOCKET",
    "CMUX_SOCKET_PATH",
    "CMUX_MUX_SOCKET",
    "CMUX_TUI_STATE_DIR",
    "CMUX_TUI_CHIEF_TOOLS_SOCKET",
    "CMUX_MCP_TOOLS",
    "MUX_HOME",
    "ACPMUX_HOME",
    "XDG_RUNTIME_DIR",
];

/// `servers` (an ACP `mcpServers` array) with [`ROUTING_ENV`] added to each stdio entry's `env`
/// for a harness in [`SCRUBBED_ENV_FAMILIES`]: the value from `env` (the harness's own spawn env)
/// or else this process's. An entry's own value wins; HTTP entries and other harnesses are
/// unchanged.
pub fn with_routing_env(
    mut servers: Value,
    name: &str,
    profile: &crate::config::HarnessProfile,
    env: &BTreeMap<String, String>,
) -> Value {
    if !SCRUBBED_ENV_FAMILIES.contains(&crate::config::derive_family(name, profile).as_str()) {
        return servers;
    }
    let routing: Vec<(&str, String)> = ROUTING_ENV
        .iter()
        .filter_map(|k| {
            env.get(*k)
                .cloned()
                .or_else(|| std::env::var(k).ok())
                .filter(|v| !v.is_empty())
                .map(|v| (*k, v))
        })
        .collect();
    for entry in servers.as_array_mut().into_iter().flatten() {
        let Some(list) = entry.get_mut("env").and_then(Value::as_array_mut) else { continue };
        for (k, v) in &routing {
            if !list.iter().any(|e| e.get("name").and_then(Value::as_str) == Some(*k)) {
                list.push(json!({"name": k, "value": v}));
            }
        }
    }
    servers
}

/// The agent memory server's name (`optchat-chief agent-memory mcp`).
pub const MEMORY_SERVER_NAME: &str = "cmux-agent-memory";
/// The person's saved MCP servers (`optchat-chief integrations serve`): one `mcp_servers` tool
/// that lists, signs in to and calls the servers of the machine's store this chat may use (the
/// scope the person picked on the connect card, `cmux_mcp_connect::shared::visible`). Off with
/// `agents.mcpServers.enabled` false in cmux.json.
pub const SAVED_SERVERS_NAME: &str = "cmux-mcp";
/// The cmux.json switch for the saved servers (Settings > MCP Servers), on when absent.
pub const SAVED_SERVERS_SETTING: &str = "agents.mcpServers.enabled";

/// A session env key passed to the `cmux` server: the comma-separated cmux
/// MCP tools the session may use (the Chief's turn presets). `cmux mcp
/// serve` then lists only those and refuses every other call; unset, it
/// speaks code mode. Only a preset sets it (a session's own env may
/// not, `session_env`); the daemon's own value never reaches an agent
/// (`agent::command`).
pub const MCP_TOOLS_ENV: &str = "CMUX_MCP_TOOLS";

/// A session env key passed to the `cmux` server: the path of the Chief's `engine.json`, whose
/// `computer` (`machine:<id>`) is the default machine of `cloud_computer` (cmux mcp
/// `cloud_tools`). Only the Chief's turn preset sets it (optchat-chief `host::turn_preset`).
pub const CHIEF_ENGINE_ENV: &str = "CMUX_CHIEF_ENGINE";

/// The env of the `cmux` server that carries the session's other agent
/// tool servers (`AgentTools::folded`): a JSON array of `{name, command,
/// args, env}`. `cmux mcp serve` runs them behind its code mode, so an
/// agent sees two tools for everything cmux gives it.
pub const UPSTREAMS_ENV: &str = "CMUX_MCP_UPSTREAMS";

/// A spawn env key (`hub/spawn.rs`) with the comma-separated agent tool
/// servers this chat turned off (`hub/tools.rs`): a folded server has no
/// `mcp__<server>` tools for `--disallowedTools` to name, so it leaves the
/// fold instead. `agent/command.rs` removes the key before the harness starts.
pub const OFF_ENV: &str = "ACPMUX_AGENT_TOOLS_OFF";

/// The cmux MCP tools of a Chief turn, for the built-in turn presets
/// (`config::chief_builtins`). Keep equal to optchat-chief's
/// `session_dir::CHIEF_CMUX_TOOLS`, which sets the same in its own presets.
pub const CHIEF_TURN_TOOLS: &str = "agents_snapshot,agents_workspace_create,\
    agents_workspace_select,agents_terminal_split,agents_terminal_focus,agents_tab_select,\
    agents_dialog_list,agents_dialog_answer,agents_events,agents_wait,render,\
    agents_terminal_list,agents_terminal_send,agents_chat_send,agents_chat_read,\
    agents_chat_state,acpmux_send,acpmux_send_status,acpmux_ls,acpmux_last,acpmux_info,\
    acpmux_inbox_read,acpmux_inbox_reply,cloud_machines,cloud_chat_start,cloud_chat_send,\
    cloud_chat_status,cloud_computer,cloud_computer_control,workspace_list,workspace_rename,workspace_move,\
    workspace_place,workspace_group_list,workspace_group_create,workspace_group_update";
/// What every agent chat is told about asking the person, in the cmux MCP
/// server's `instructions` (`cmux mcp serve`, both modes). Chats start in
/// Full access (`hub/policy_mode.rs`), and an agent there asked Leo a
/// multiple-choice question that read "Waiting for you: allow this?" (Leo
/// 2026-10-21: decide, say why, continue). The bundled acpmux skill and the
/// cmux skill say the same. Claude Code may cut server instructions past
/// 2048 characters, so both compact rules stay under that.
pub const ASKING_RULE: &str = "Asking the person: Full access already permits harness tool calls; never ask them to allow or confirm one. Decide, say why, continue. This never widens the task: respect user-only skill steps and consent cards; never bypass refusals. Ask only unresolved product taste, not permission.";

/// The small cmux-owned coordination block: in the system prompt or developer instructions of
/// a Claude Code or Codex chat, else sent once as hidden first-turn context.
/// Keep it canonical so the Context viewer shows and edits exactly what new sessions receive.
/// It says only what the harnesses leave weak: models often fetch the reads a task implies
/// (rather than names) one per turn, and the "list what you need, then request every
/// independent item in this one response" step is the published fix for that. Concise
/// reporting is left to the harness prompt and the recap guidance (`agent_guidance.rs`).
pub const CONCURRENT_WORK_RULE: &str = "Before each tool step, privately list what you need next, then request every read, search and command that does not depend on another's result in that one response, starting with the first: the files and instructions the task names or implies. Run long builds, tests and waits in the background when the tool allows it, and check the result before relying on it.";

/// The cmux MCP server's name in every agent cmux starts ([`cmux_server`]).
pub const CMUX_SERVER: &str = "cmux";

/// The person's answer to "should agents you start in cmux get cmux's tools?".
pub const AGENTS_CMUX_MCP_KEY: &str = "agents.cmuxMcp";

/// A session env key: the answer (`on` or `off`) of the Mac that started this chat on another
/// machine (`hub/cmux_tools_answer.rs`), which the chat follows over this machine's
/// [`AGENTS_CMUX_MCP_KEY`]: in its tool list ([`AgentTools::scoped`]) and in any `cmux mcp serve`
/// it starts (cmux-tui `cli/mcp.rs` `refusal`).
pub const TOOLS_ANSWER_ENV: &str = "CMUX_AGENT_TOOLS_ANSWER";

/// Whether agents cmux starts get the `cmux` server: yes unless
/// `agents.cmuxMcp` is `off`, in the settings text (nested or flat, JSONC; an
/// `off` in either form wins) or as an administrator set it
/// ([`cmux_config::managed::applied_to`]: a forced value wins over the file).
/// No file, no key, `on`, another value or a file that does not parse: yes
/// (on by default). cmux-tui's `AgentsCmuxMcp` reads the same key for the
/// terminal shims.
pub fn agents_get_cmux(settings: Option<&str>) -> bool {
    let off = Value::String("off".into());
    let file = settings.and_then(crate::user_settings::document).and_then(|doc| {
        let nested = doc.pointer("/agents/cmuxMcp").cloned();
        match doc.get(AGENTS_CMUX_MCP_KEY).cloned() {
            Some(flat) if flat != off && nested.as_ref() == Some(&off) => nested,
            flat => flat.or(nested),
        }
    });
    cmux_config::managed::applied_to(AGENTS_CMUX_MCP_KEY, file) != Some(off)
}

/// The per-agent switch under [`AGENTS_CMUX_MCP_KEY`] (cmux#49395): `agents.cmuxMcpClaude` for a
/// Claude Code chat, `agents.cmuxMcpCodex` for a Codex one; `None` for another harness, which
/// follows the answer alone. cmux-tui's `AgentsCmuxMcp::agent_key` names the same keys.
pub fn agent_switch_key(agent: &str) -> Option<&'static str> {
    match agent {
        "claude" => Some("agents.cmuxMcpClaude"),
        "codex" => Some("agents.cmuxMcpCodex"),
        _ => None,
    }
}

/// Whether the person switched `agent` off: `false` at [`agent_switch_key`]. No file, no key,
/// `true`, another value or a file that does not parse: not switched off.
pub fn agent_switched_off(settings: Option<&str>, agent: &str) -> bool {
    let Some(key) = agent_switch_key(agent) else { return false };
    settings
        .and_then(crate::user_settings::document)
        .and_then(|doc| crate::user_settings::value(&doc, key))
        .is_some_and(|value| value == Value::Bool(false))
}

/// A chat of `agent` (`claude` or `codex`) the person switched off gets the answer `off` in its
/// env ([`TOOLS_ANSWER_ENV`]) when it has none of its own, so every path that reads the answer
/// (the tool list, the pool key, a person's own `cmux` entry) leaves cmux's server out.
pub fn agent_switch_answer(
    env: &mut BTreeMap<String, String>,
    settings: Option<&str>,
    agent: Option<&str>,
) {
    if agent.is_some_and(|agent| agent_switched_off(settings, agent)) {
        env.entry(TOOLS_ANSWER_ENV.to_owned()).or_insert_with(|| "off".to_owned());
    }
}

/// The agent a harness name or family names for [`agent_switch_key`]: `codex…` is Codex,
/// `claude…` is Claude Code; `None` for another.
pub fn switch_agent(harness: &str) -> Option<&'static str> {
    let harness = harness.trim().to_ascii_lowercase();
    if harness.starts_with("codex") {
        Some("codex")
    } else if harness.starts_with("claude") {
        Some("claude")
    } else {
        None
    }
}

/// The `cmux` server every agent cmux starts gets: this cmux CLI's `mcp
/// serve` (`--all-tools` lists every tool instead of code mode) under the
/// name [`CMUX_SERVER`]. Its env always names `settings_file`, the settings
/// file the launch resolved (`CMUX_NEXT_CONFIG_FILE`, the default file
/// too), so the server reads the settings the app runs on even where the
/// harness passes a stdio server no env of its own (Codex). It also always
/// sends [`crate::desktop_link::GUEST_ENV`] empty: Codex merges these keys
/// into a person's own `[mcp_servers.cmux]`, and one `cmux acp desktop link`
/// wrote carries the acpmux server's guest mode there, which would reach the
/// acpmux server folded behind this one and hide its tools. The one
/// definition for acpmux's sessions and cmux-tui's terminal shims; each adds
/// only its own routing env.
pub fn cmux_server(cmux: &Path, all_tools: bool, settings_file: &Path) -> McpServer {
    let mut args = vec!["mcp".to_owned(), "serve".to_owned()];
    if all_tools {
        args.push("--all-tools".to_owned());
    }
    let env = vec![
        (
            crate::user_settings::CONFIG_OVERRIDE.to_owned(),
            settings_file.to_string_lossy().into_owned(),
        ),
        (crate::desktop_link::GUEST_ENV.to_owned(), String::new()),
    ];
    McpServer { name: CMUX_SERVER.into(), command: cmux.to_path_buf(), args, env }
}

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
    ("cmux-computer-use/SKILL.md", include_str!("../../../../skills/cmux-computer-use/SKILL.md")),
    ("cmux-customization/SKILL.md", include_str!("../../../../skills/cmux-customization/SKILL.md")),
    (
        "cmux-customization/references/examples.md",
        include_str!("../../../../skills/cmux-customization/references/examples.md"),
    ),
    (
        "cmux-customization/references/local-app-views.md",
        include_str!("../../../../skills/cmux-customization/references/local-app-views.md"),
    ),
    (
        "cmux-customization/references/viewer-types.md",
        include_str!("../../../../skills/cmux-customization/references/viewer-types.md"),
    ),
    ("cmux-live/SKILL.md", include_str!("../../../../skills/cmux-live/SKILL.md")),
    // Diagrams, charts, math, decks, documents and opening pages beside the chat (hq
    // docs/design/next-rich-output.md). The deck template is a file the agent copies.
    ("cmux-rich-output/SKILL.md", include_str!("../skills/cmux-rich-output/SKILL.md")),
    (
        "cmux-rich-output/templates/deck.html",
        include_str!("../skills/cmux-rich-output/templates/deck.html"),
    ),
    ("acpmux/SKILL.md", include_str!("../skills/acpmux/SKILL.md")),
    // How the chat draws a plan, sub-sessions, links and a recap (`agent_guidance.rs`).
    ("cmux-chat/SKILL.md", include_str!("../skills/cmux-chat/SKILL.md")),
    // Waiting and cleaning up without wasting the person's GitHub quota, CPU or disk: one shared
    // CI waiter (`acpmux pr-wait`, `cli/pr_wait.rs`), rate limits by their reset, deadlines,
    // own processes and regenerable caches only.
    ("cmux-quota/SKILL.md", include_str!("../skills/cmux-quota/SKILL.md")),
    // When and how to ask for one root command (`request_elevation`, `hub/elevation.rs`).
    ("cmux-sudo/SKILL.md", include_str!("../skills/cmux-sudo/SKILL.md")),
];

/// The skills that are only about one MCP server's tools, and that server. A session without
/// the server gets no listing for the skill: each listing is in every turn's prompt, and a
/// skill for a tool the chat lacks sends the agent to read it for nothing (a Linux or Cloud
/// chat has no computer use; a chat without `cmux-secrets` has no `request_elevation`).
const SKILL_SERVERS: &[(&str, &str)] = &[
    ("cmux-computer-use", crate::computer_use::mcp::SERVER_NAME),
    ("cmux-sudo", crate::secret_mcp::SERVER_NAME),
];

/// The skill a path in [`SKILL_FILES`] belongs to (`cmux-browser/references/x.md` is
/// `cmux-browser`).
fn skill_of(path: &str) -> &str {
    path.split('/').next().unwrap_or(path)
}

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
    /// The person's own skills (`~/.config/cmux/skills`) as a second plugin, `cmux-user`
    /// (`agent_guidance.rs`), while `agents.guidance.userSkills` is on and there are any.
    pub user_plugin_dir: Option<PathBuf>,
    /// The display allocation folder, only in per-workspace display mode
    /// (`agent_displays.rs`): [`AgentTools::scoped`] then leaves the
    /// Computer Use server out.
    pub displays: Option<PathBuf>,
    /// cmux's tools are on for agents started in cmux (not turned off,
    /// [`agents_get_cmux`]): [`AgentTools::scoped`] keeps the `cmux` server.
    pub cmux_for_agents: bool,
    /// Claude Code only: the project's own servers, wrapped for a start at a repository's head
    /// ([`project_mcp`]). A name of cmux's own servers keeps cmux's.
    pub project_servers: Map<String, Value>,
    /// Servers the daemon serves for this chat over loopback HTTP ([`AgentTools::via_gateway`]),
    /// by name: the harness reaches them there instead of starting their stdio launch.
    pub http: BTreeMap<String, crate::mcp_gateway::Endpoint>,
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
    /// This acpmux binary (`self_command.rs`): the Computer Use bridge and the
    /// secret, offer and sub-session servers are its subcommands, under its
    /// prefix (`acp` inside cmux-tui, whose `current_exe` a Linux `acpmux`
    /// link resolves to).
    pub acpmux: Option<crate::self_command::SelfCommand>,
    /// The app shows the secret card ([`SECRET_TOOLS_ENV`] is `1`): sessions
    /// get `request_secret` (`secret_mcp.rs`). Without the card an ask would
    /// wait with nothing to answer it.
    pub secrets: bool,
    /// Sessions get `offer_session` and `suggest_tasks` (`offer_mcp.rs`),
    /// whose offers cmux NEXT draws as cards: on unless [`OFFER_TOOLS_ENV`]
    /// is `0`, so a daemon on another machine or under its own unit offers
    /// too, not only the one the Mac app starts.
    pub offers: bool,
    /// Sub-session tools are on (settings `agents.subsessions.enabled`, on
    /// by default): sessions get `start_session` and the rest
    /// (`subsession_mcp.rs`, `hub/subsessions.rs`).
    pub subsessions: bool,
    /// The display allocation folder when this daemon runs with
    /// per-workspace displays (`agent_displays.rs`), else `None`.
    pub displays: Option<PathBuf>,
    /// Sessions get cmux's hosted MCP server with the signed-in person's tools
    /// (`hosted_mcp.rs`): [`crate::hosted_mcp::SWITCH_ENV`] is `1` (default off).
    pub hosted: bool,
    /// Sessions get GitHub's own MCP server through the team's cmux GitHub connection
    /// (`github_mcp.rs`): on a cmux Cloud machine whose Cloud agent mints GitHub tokens, or a
    /// machine a Mac lends GitHub (`github_session_env.rs`).
    pub github: bool,
    /// The `desktop-lease` binary when [`DESKTOP_LEASE_ENV`] names one (default off):
    /// sessions get [`DESKTOP_LEASE_SERVER`], computer use on a leased desktop the host's
    /// pool suspends while the model thinks (crates/desktop-lease, cmuxterm-hq#8741).
    pub desktop_lease: Option<PathBuf>,
}

/// Set to `1` by an app that shows the secret card (cx-ncc.42).
pub const SECRET_TOOLS_ENV: &str = "ACPMUX_SECRET_TOOLS";
/// `0` turns the offer tools off (cx-807da); the Mac app sets it from the
/// `sessions.promptSuggestions` setting. Unset or anything else leaves them
/// on: Leo, 2026-11-05, on Claude desktop's suggested-session card, "I want
/// to be able to, like, recommend Claude to be able to do that as well. in
/// our cmux-next app", and a Claude chat on a remote host never had the tool.
pub const OFFER_TOOLS_ENV: &str = "ACPMUX_OFFER_TOOLS";
/// A profile or preset env key: the comma-separated MCP server names of
/// these tools a session keeps (`cmux`: only `cmux mcp serve`). Unset or
/// empty keeps every server. The Chief's built-in turn presets set `cmux`
/// (`config/chief_builtins.rs`, cx-4a5w2): a turn's tool names and server
/// instructions come after its cache mark, so each extra server is
/// uncached input on every turn.
pub const SERVERS_ENV: &str = "ACPMUX_AGENT_TOOL_SERVERS";
/// Opt in to leased desktops: the path of a `desktop-lease` binary. Unset (the default)
/// gives sessions no such server. Its pool socket comes from `DESKTOP_LEASE_SOCKET` when set.
pub const DESKTOP_LEASE_ENV: &str = "ACPMUX_DESKTOP_LEASE";
/// The leased-desktop server's name (`desktop-lease mcp`).
pub const DESKTOP_LEASE_SERVER: &str = "cmux-desktop";
/// The lease owner the leased-desktop server reads: the session id, so a session's slots
/// are its own and go back when it ends.
const DESKTOP_LEASE_OWNER_ENV: &str = "DESKTOP_LEASE_OWNER";
const DESKTOP_LEASE_SOCKET_ENV: &str = "DESKTOP_LEASE_SOCKET";

/// The `cmux` CLI next to this executable (the app's bundle), as sessions get it: None when
/// there is none there.
pub fn cmux_cli() -> Option<PathBuf> {
    let dir = std::env::var_os(BIN_DIR_ENV).filter(|v| !v.is_empty()).map(PathBuf::from).or_else(
        || std::env::current_exe().ok().and_then(|exe| exe.parent().map(Path::to_path_buf)),
    )?;
    Some(dir.join("cmux")).filter(|path| is_executable(path))
}

impl Inputs {
    pub fn current() -> Self {
        let var = |name: &str| std::env::var_os(name).filter(|v| !v.is_empty());
        let bin_dir = var(BIN_DIR_ENV).map(PathBuf::from).or_else(|| {
            std::env::current_exe().ok().and_then(|exe| exe.parent().map(Path::to_path_buf))
        });
        Inputs {
            enabled: var(SWITCH_ENV).is_none_or(|v| v != "0"),
            bin_dir,
            cmux_json: crate::user_settings::text(),
            state_dir: crate::config::home().join("agent-tools"),
            acpmux: crate::self_command::SelfCommand::current().ok(),
            secrets: var(SECRET_TOOLS_ENV).is_some_and(|v| v == "1"),
            offers: var(OFFER_TOOLS_ENV).is_none_or(|v| v != "0"),
            subsessions: crate::subsession_settings::enabled(),
            displays: crate::agent_displays::per_workspace()
                .then(|| crate::agent_displays::dir(&crate::config::home())),
            hosted: crate::hosted_mcp::enabled(),
            github: crate::github_mcp::available() || crate::github_session_env::lent(),
            desktop_lease: var(DESKTOP_LEASE_ENV).map(PathBuf::from).filter(|p| is_executable(p)),
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

/// The env Claude Code reads to defer MCP tools behind its tool search.
/// It turns that off by itself when `ANTHROPIC_BASE_URL` is not
/// Anthropic's (our routers), and then sends every schema in every turn.
pub const TOOL_SEARCH_ENV: &str = "ENABLE_TOOL_SEARCH";

/// The profile env for cmux's code mode (one tool, `cmux_exec`): the default for every agent
/// since Lawrence's 2026-10-23 call; `0` lists every tool instead. (The agent evals,
/// tests/agent-evals RESULTS codemode-vs-all, had every tool pass 8/12 Claude Code tasks to code
/// mode's 6/12, tied for Codex.)
pub const CODE_MODE_ENV: &str = "CMUX_MCP_CODE_MODE";

/// Whether a profile opted out of code mode (`CODE_MODE_ENV=0`): only then
/// does its cmux server list every tool. Every other agent sees one cmux
/// tool, `cmux_exec` (Lawrence 2026-10-23); on Claude Code 2.1.305 the 773
/// names cost a bare request 11.4k of 36.3k prompt tokens.
pub fn all_tools_opted_in(env: &BTreeMap<String, String>) -> bool {
    env.get(CODE_MODE_ENV).is_some_and(|v| v.trim() == "0")
}

/// Whether a harness defers MCP tools behind its own tool search, so its
/// cmux server lists every tool (`cmux mcp serve --all-tools`) and the
/// harness loads the ones a turn needs. Every other harness gets cmux's
/// code mode (two tools). Measured 2026-10-19, one-word turn with all 641
/// cmux tools: Claude Code 34k prompt tokens with [`TOOL_SEARCH_ENV`]
/// (315k without), Codex 20k (the same as with two tools). OpenCode 1.19
/// and the others send every schema.
/// `name` is the profile's name: its family comes from it when the profile
/// declares none (`config::derive_family`); `env` is the env the harness
/// starts with, its route applied. Fail safe: an unknown harness, a Claude
/// Code whose env turns tool search off, or a session that a route or
/// profile sends to another provider (`own_provider`) gets code mode, never
/// every schema in every turn.
pub fn lists_all_tools(
    name: &str,
    profile: &crate::config::HarnessProfile,
    env: &BTreeMap<String, String>,
    cwd: &Path,
) -> bool {
    // Code mode for every agent (Lawrence 2026-10-23: an agent sees only
    // cmux_exec); a profile lists every tool only with `CODE_MODE_ENV=0`.
    if !all_tools_opted_in(env) {
        return false;
    }
    if is_claude_code(name, profile) {
        return claude_lists_all_tools(env, cwd);
    }
    own_provider(env) && crate::config::derive_family(name, profile) == "codex"
}

/// Claude Code in folder `cwd` with process env `env` lists every cmux tool:
/// tool search on in the env and in every settings file Claude Code reads
/// env from (`settings_turn_off`), and its own provider.
pub fn claude_lists_all_tools(env: &BTreeMap<String, String>, cwd: &Path) -> bool {
    tool_search_on(env) && own_provider(env) && !settings_turn_off(env, cwd)
}

/// Whether a settings file Claude Code reads `env` from sets
/// [`TOOL_SEARCH_ENV`] to something other than on: the managed settings,
/// the Claude home's `settings.json` (`CLAUDE_CONFIG_DIR`, else
/// `~/.claude`), and the folder's `.claude/settings.json` and
/// `.claude/settings.local.json`. Their env wins over the process env, so
/// any one that turns it off means every schema in every turn.
pub fn settings_turn_off(env: &BTreeMap<String, String>, cwd: &Path) -> bool {
    // The same Claude home the harness config reader resolves: the spawn
    // env, the daemon's, the imported login env, else ~/.claude.
    let home = crate::harness_config::config_dir("CLAUDE_CONFIG_DIR", ".claude", &[env]);
    let managed = if cfg!(target_os = "macos") {
        "/Library/Application Support/ClaudeCode/managed-settings.json"
    } else {
        "/etc/claude-code/managed-settings.json"
    };
    let mut files = vec![PathBuf::from(managed)];
    files.extend(home.map(|h| h.join("settings.json")));
    files.push(cwd.join(".claude").join("settings.json"));
    files.push(cwd.join(".claude").join("settings.local.json"));
    files.iter().any(|file| {
        let Ok(bytes) = std::fs::read(file) else { return false };
        let Ok(json) = serde_json::from_slice::<Value>(&bytes) else { return false };
        match &json["env"][TOOL_SEARCH_ENV] {
            Value::Null => false,
            Value::String(v) => !matches!(v.trim(), "true" | "1"),
            Value::Bool(on) => !on,
            Value::Number(n) => n.as_u64() != Some(1),
            _ => true,
        }
    })
}

/// Whether the harness talks to the provider of the user's own setup (the
/// one measured with tool search): its env names no other endpoint. A route
/// (`routes::SCRUBBED`) or a profile that sets one, such as the `cmux`
/// profile's open-source model router, may not forward deferred tools
/// (`tool_reference`), so it keeps code mode. Anthropic's own API is fine.
pub fn own_provider(env: &BTreeMap<String, String>) -> bool {
    let set = |key: &str| env.get(key).is_some_and(|v| !v.trim().is_empty());
    let anthropic = env.get("ANTHROPIC_BASE_URL").is_none_or(|url| {
        let host = url.split("://").nth(1).unwrap_or(url).split(['/', ':']).next().unwrap_or("");
        url.trim().is_empty() || host == "anthropic.com" || host.ends_with(".anthropic.com")
    });
    anthropic
        && !set("OPENAI_BASE_URL")
        && !set("CLAUDE_CODE_USE_BEDROCK")
        && !set("CLAUDE_CODE_USE_VERTEX")
        && !set("CLAUDE_CODE_USE_FOUNDRY")
}

/// Whether Claude Code's tool search is on for a process with `env`:
/// unset (acpmux sets it, `hub/spawn.rs`), `true` or `1`. `false`, `auto`
/// (which turns it off behind a router) or anything else is off.
pub fn tool_search_on(env: &BTreeMap<String, String>) -> bool {
    env.get(TOOL_SEARCH_ENV).is_none_or(|v| matches!(v.trim(), "true" | "1"))
}

/// Whether the harness is Claude Code (directly or through an ACP adapter):
/// its process gets [`TOOL_SEARCH_ENV`].
pub fn is_claude_code(name: &str, profile: &crate::config::HarnessProfile) -> bool {
    profile.kind == crate::config::HarnessKind::ClaudeStdio
        || crate::config::derive_family(name, profile).starts_with("claude")
}

/// The env `gh` signs in and finds its host with: the `acpmux` server's `pr_state` needs the
/// agent's (`gh_env`).
pub(crate) const GH_ENV: [&str; 6] = [
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "GH_CONFIG_DIR",
    "GH_HOST",
    "GH_ENTERPRISE_TOKEN",
    "GITHUB_ENTERPRISE_TOKEN",
];

/// The [`GH_ENV`] values the agent itself starts with: the session's literal profile value,
/// else the one every local child gets (`every_child`: the allow-listed login values,
/// `loginEnvAllow`, the vault's and the machine's). Never the daemon's own env, which keeps a
/// token from agents unless the person lets it through (`login_env::allowed`), and never a
/// `${env:...}` or keychain reference, which only the launch resolves.
pub(crate) fn gh_env(
    session_env: &BTreeMap<String, String>,
    every_child: impl FnOnce() -> Vec<(String, String)>,
) -> Vec<(String, String)> {
    let child = every_child();
    GH_ENV
        .iter()
        .filter_map(|&key| {
            // A profile that sets the key decides it, a reference too (left out, not replaced).
            let value = match session_env.get(key) {
                Some(v) => (!v.contains("${")).then(|| v.clone()),
                None => child.iter().rev().find(|(k, _)| k == key).map(|(_, v)| v.clone()),
            };
            value.filter(|v| !v.is_empty()).map(|v| (key.to_owned(), v))
        })
        .collect()
}

/// `mcpServers` for acpmux session `session_id`'s ACP harness: [`acp_servers_with`] over
/// [`current`], none for a session [`left_out`]. An agent that takes HTTP servers
/// ([`takes_http`]) gets cmux's servers through the daemon's gateway (`mcp_gateway.rs`).
pub fn acp_servers_for(
    remote_origin: bool,
    env: &BTreeMap<String, String>,
    session_id: &str,
    all_tools: bool,
    http: bool,
    cwd: &Path,
    codex: Option<CodexLaunch<'_>>,
) -> Value {
    if left_out(remote_origin, env, &[]) {
        return json!([]);
    }
    let tools = acp_tools_with(current(), env, session_id, all_tools, codex);
    let tools = if http { tools.via_gateway(session_id, cwd) } else { tools };
    tools.acp_servers()
}

/// The person's own stdio `cmux` entry, whole, with the env keys, for a Codex chat whose servers
/// (`servers`, as [`acp_servers_for`] gave them) hold no `cmux` of cmux's own (the answer is not
/// on, the HTTP rule, or a chat started from another machine): `{"cmux": {command, args, env:
/// {CMUX_AGENT_SESSION, CMUX_AGENT_TOOLS_ANSWER}}}`, which cmux-codex-acp
/// (`_meta.cmux.mcpServerEntry`) sends as `mcp_servers.cmux.{command,args,env.*}` overrides. The
/// command and args are exactly the ones Codex itself loads for the launch
/// ([`persons_cmux_entry`]), so it is the same entry with the keys added. Codex passes a stdio
/// server only its own env and an allowlist, so without them the entry's `cmux mcp serve` cannot
/// tell it runs in a chat, and counts as a caller outside cmux (cmux-tui `cli/mcp.rs`
/// `refusal`). The answer is `off` for a session cut off from cmux's tools, else the session's
/// own (a chat another Mac started, `TOOLS_ANSWER_ENV`), else this machine's. The pool key
/// carries it (`hub/pool` `tool_servers`). `None` unless Codex answers a stdio entry (none, HTTP,
/// an error or no answer in time: nothing is sent).
pub fn person_entry_env(
    servers: &Value,
    launch: CodexLaunch<'_>,
    env: &BTreeMap<String, String>,
    session_id: &str,
) -> Option<Value> {
    let gives_cmux =
        servers.as_array().is_some_and(|list| list.iter().any(|s| s["name"] == CMUX_SERVER));
    if gives_cmux {
        return None;
    }
    let crate::codex_cmux_entry::CmuxEntry::Stdio { command, args } =
        persons_cmux_entry(launch, env)
    else {
        return None;
    };
    // A session cut off from cmux's tools gets the off server from the person's entry too.
    let answer = match env.get(TOOLS_ANSWER_ENV).map(String::as_str) {
        _ if cut_off(env) => "off",
        Some("on") => "on",
        Some(_) => "off",
        None if agents_get_cmux(crate::user_settings::text().as_deref()) => "on",
        None => "off",
    };
    // The entry Codex loads, as Codex itself gives it, with the keys: the same entry, never env
    // keys with no command (`codex_cmux_entry`).
    Some(json!({CMUX_SERVER: {
        "command": command,
        "args": args,
        "env": {AGENT_SESSION_ENV: session_id, TOOLS_ANSWER_ENV: answer},
    }}))
}

/// The person's own `cmux` entry for a Codex chat's `launch`, as Codex itself answers it
/// (`codex_cmux_entry::resolve`): the launch's program (the profile's `CODEX_PATH`, else its argv's
/// program), its config options, the chat's folder and the Codex child's environment
/// (`login_env::effective_for`, with the profile env's `${keychain:…}` and `${env:…}` references
/// resolved, as the launch resolves them). An ACP adapter (not a `codex ... app-server` launch)
/// loads the person's config through the Codex this machine runs (`managed_codex::codex_binary`),
/// asked with no options; none is no answer. Codex is asked once per start
/// (`CodexLaunch::answer`: one chat start, shared by its tool rows, its pool spec and its
/// `session/new`; one fork), never across starts, so a config the person changes counts at the
/// next one; how long Codex took is logged. Run it off the runtime ([`warm_codex_answer`]).
pub fn persons_cmux_entry(
    launch: CodexLaunch<'_>,
    env: &BTreeMap<String, String>,
) -> crate::codex_cmux_entry::CmuxEntry {
    use crate::codex_cmux_entry::CmuxEntry;
    let ask = || {
        let mut env = env.clone();
        if crate::config::profiles::has_env_refs(&env)
            && crate::config::profiles::resolve_env_refs(
                &mut env,
                &crate::login_env::reference_var,
                &crate::config::profiles::keychain_lookup,
            )
            .is_err()
        {
            return CmuxEntry::Unknown;
        }
        let effective = crate::login_env::effective_for(Some("codex"), &env);
        let app_server = crate::codex_app_server::is_profile_launch(launch.argv);
        let program = if app_server {
            effective
                .get("CODEX_PATH")
                .filter(|p| !p.is_empty())
                .cloned()
                .or_else(|| launch.argv.first().cloned())
        } else {
            // The `codex` on the adapter's PATH, else the one this machine runs.
            effective
                .get("PATH")
                .and_then(|path| {
                    std::env::split_paths(path)
                        .map(|dir| dir.join("codex"))
                        .find(|file| file.is_file())
                        .map(|file| file.to_string_lossy().into_owned())
                })
                .or_else(crate::managed_codex::codex_binary)
        };
        let Some(program) = program.filter(|p| !p.is_empty()) else { return CmuxEntry::Unknown };
        let args: Vec<std::ffi::OsString> = if app_server {
            launch.argv.iter().skip(1).map(std::ffi::OsString::from).collect()
        } else {
            Vec::new()
        };
        let child_env: Vec<(std::ffi::OsString, std::ffi::OsString)> =
            effective.iter().map(|(k, v)| (k.into(), v.into())).collect();
        let (entry, took) = crate::codex_cmux_entry::resolve(
            std::path::Path::new(&program),
            &args,
            launch.cwd,
            &child_env,
        );
        tracing::info!(
            target: "acpmux::codex_cmux_entry",
            ms = took.as_millis() as u64,
            entry = ?entry,
            "codex mcp get cmux"
        );
        entry
    };
    match launch.answer {
        Some(cell) => cell.get_or_init(ask).clone(),
        None => ask(),
    }
}

/// One start's answer for the person's own `cmux` entry ([`persons_cmux_entry`]), shared by
/// everything that start reads it for: its tool rows, its pool spec (and the spare that spec
/// starts), its `session/new` or `session/load`.
pub type CodexAnswer = std::sync::Arc<std::sync::OnceLock<crate::codex_cmux_entry::CmuxEntry>>;

/// A start's answer ([`CodexAnswer`]) with the launch it was asked for: a later read for the same
/// start reuses it only for that same launch (folder, argv and env), never for another. Nothing
/// is cached across starts.
#[derive(Clone, Debug)]
pub struct AskedFor {
    pub cwd: std::path::PathBuf,
    pub argv: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub answer: CodexAnswer,
}

impl AskedFor {
    /// The answer, when it was asked for exactly this launch.
    pub fn for_launch(
        &self,
        cwd: &Path,
        argv: &[String],
        env: &BTreeMap<String, String>,
    ) -> Option<CodexAnswer> {
        (self.cwd == cwd && self.argv == argv && &self.env == env).then(|| self.answer.clone())
    }
}

/// Asks Codex for `answer` ([`persons_cmux_entry`] for a launch in `cwd` with `argv` and `env`)
/// on a blocking thread, so the runtime never waits on Codex; a later read of `answer` is
/// immediate. Nothing when it is already answered.
pub async fn warm_codex_answer(
    cwd: &Path,
    argv: &[String],
    env: &BTreeMap<String, String>,
    answer: &CodexAnswer,
) {
    if answer.get().is_some() {
        return;
    }
    let (cwd, argv, env, answer) = (cwd.to_owned(), argv.to_vec(), env.clone(), answer.clone());
    let _ = tokio::task::spawn_blocking(move || {
        persons_cmux_entry(CodexLaunch { cwd: &cwd, argv: &argv, answer: Some(&answer) }, &env);
    })
    .await;
}

/// Whether a session whose profile, preset and session env is `env` is cut off from cmux's
/// tools: `ACPMUX_AGENT_TOOLS=0` ([`SWITCH_ENV`]), or a server list ([`SERVERS_ENV`]) that leaves
/// `cmux` out. A person's own `cmux` entry such a session starts gets the answer `off`
/// ([`person_entry_env`] for Codex; the harness env for Claude Code, `hub/spawn.rs`).
pub fn cut_off(env: &BTreeMap<String, String>) -> bool {
    let kept = env.get(SERVERS_ENV).map(|v| v.trim()).filter(|v| !v.is_empty());
    env.get(SWITCH_ENV).is_some_and(|v| v == "0")
        || kept.is_some_and(|keep| !keep.split(',').any(|name| name.trim() == CMUX_SERVER))
}

/// A remote-origin session's answer when it has none of its own: `off` ([`TOOLS_ANSWER_ENV`] in
/// `env`). A chat a phone or a Web client started gets none of cmux's servers ([`left_out`]), so
/// its person's own `cmux` entry is the off server too, for Codex (`person_entry_env`) and Claude
/// Code (the harness env) alike. A chat another Mac's daemon started has that Mac's answer
/// (`hub/cmux_tools_answer.rs`), which stays.
pub fn remote_origin_answer(env: &mut BTreeMap<String, String>, remote_origin: bool) {
    if remote_origin {
        env.entry(TOOLS_ANSWER_ENV.to_owned()).or_insert_with(|| "off".to_owned());
    }
}

/// Puts [`person_entry_env`]'s entry on ACP session params as `_meta.cmux.mcpServerEntry`
/// (cmux-codex-acp: `mcp_servers.cmux.{command,args,env.KEY}`).
pub fn send_person_entry_env(params: &mut Value, entry_env: Option<Value>) {
    let Some(entry_env) = entry_env else { return };
    if params.is_null() {
        *params = json!({});
    }
    // Params that are not an object carry no `_meta`; leave them as they are.
    let Some(root) = params.as_object_mut() else { return };
    let meta = root.entry("_meta").or_insert_with(|| json!({}));
    if !meta.is_object() {
        *meta = json!({});
    }
    let Some(meta) = meta.as_object_mut() else { return };
    let cmux = meta.entry("cmux").or_insert_with(|| json!({}));
    if !cmux.is_object() {
        *cmux = json!({});
    }
    if let Some(cmux) = cmux.as_object_mut() {
        cmux.insert("mcpServerEntry".to_owned(), entry_env);
    }
}

/// A Codex session's launch, for [`persons_cmux_entry`]: its folder, its profile's argv (the
/// program first), whose config options Codex reads too, and where the answer is kept once asked
/// (`answer`: one per chat start, fork, pool spec or tool-rows read; `None` asks each time).
#[derive(Clone, Copy, Debug)]
pub struct CodexLaunch<'a> {
    pub cwd: &'a Path,
    pub argv: &'a [String],
    pub answer: Option<&'a CodexAnswer>,
}

/// `mcpServers` from `tools` for acpmux session `session_id`'s ACP harness; `all_tools`
/// from [`lists_all_tools`]. `codex` is the session's launch when the
/// harness is Codex: cmux-codex-acp gives Codex these servers as its thread's
/// `mcp_servers.<name>` override, which Codex merges into the person's own
/// entry of that name, and where that is an HTTP server named `cmux` the
/// merged entry has a command and a url, which Codex refuses
/// ([`without_cmux_beside_an_http_entry`]).
pub fn acp_servers_with(
    tools: AgentTools,
    env: &BTreeMap<String, String>,
    session_id: &str,
    all_tools: bool,
    codex: Option<CodexLaunch<'_>>,
) -> Value {
    acp_tools_with(tools, env, session_id, all_tools, codex).acp_servers()
}

/// [`acp_servers_with`]'s servers before they become `mcpServers`.
fn acp_tools_with(
    tools: AgentTools,
    env: &BTreeMap<String, String>,
    session_id: &str,
    all_tools: bool,
    codex: Option<CodexLaunch<'_>>,
) -> AgentTools {
    let tools = tools.scoped(env);
    let tools = match codex {
        Some(launch) => tools.without_cmux_beside_an_http_entry(launch, env),
        None => tools,
    };
    tools.for_session(session_id).listing(all_tools).folded()
}

/// Whether `meta`'s harness is Codex: its family as recorded, else as `profile` derives it (a
/// session an older build recorded has none). Its MCP servers become Codex config overrides
/// ([`acp_servers_for`]).
pub fn is_codex(
    meta: &crate::store::SessionMeta,
    profile: Option<&crate::config::HarnessProfile>,
) -> bool {
    meta.family
        .clone()
        .or_else(|| profile.map(|p| crate::config::derive_family(&meta.harness, p)))
        .is_some_and(|family| family.starts_with("codex"))
}

/// Extra Claude Code flags for session `session_id` whose command line is
/// `args`. The MCP config goes to [`mcp_config_path`], never into argv. With them, the
/// instructions of acpmux's own servers for the system prompt
/// ([`AgentTools::instructions_in_prompt`]), which those servers then leave out: the caller
/// puts them in the appended system prompt ([`append_system_prompt`]).
pub fn claude_args_for(
    remote_origin: bool,
    env: &BTreeMap<String, String>,
    args: &[String],
    session_id: &str,
    cwd: &Path,
) -> (Vec<String>, Option<String>) {
    let (args, prompt, _) = claude_args_and_hooks_for(remote_origin, env, args, session_id, cwd);
    (args, prompt)
}

/// Whether the session included cmux’s own plugin also controls its stream callbacks.
pub(crate) fn claude_args_and_hooks_for(
    remote_origin: bool,
    env: &BTreeMap<String, String>,
    args: &[String],
    session_id: &str,
    cwd: &Path,
) -> (Vec<String>, Option<String>, bool) {
    // Under `--strict-mcp-config` Claude starts no project server; a remote origin's config
    // stays empty (`left_out`).
    let strict = args.iter().any(|a| a == "--strict-mcp-config");
    let project_servers =
        if remote_origin || strict { Map::new() } else { project_servers_at_head(env, cwd) };
    let mut prompt = None;
    let tools = if left_out(remote_origin, env, args) {
        if project_servers.is_empty() {
            return (Vec::new(), None, false);
        }
        AgentTools::default()
    } else {
        let mut tools = current()
            .scoped(env)
            .for_session(session_id)
            // Claude Code has tool search unless its env or settings turn
            // it off, send it to another provider, or opt in to code mode.
            .listing(all_tools_opted_in(env) && claude_lists_all_tools(env, cwd))
            .without_off(env)
            .fit_skills()
            .folded();
        if takes_appended_prompt(args) {
            prompt = tools.instructions_in_prompt();
        }
        tools.via_gateway(session_id, cwd)
    };
    let callbacks = tools.plugin_dir.is_some();
    let args = AgentTools { project_servers, ..tools }
        .claude_args(&mcp_config_path(&crate::config::home(), session_id));
    (args, prompt, callbacks)
}

/// The heading Claude Code gives MCP server instructions (2.1.330), so the moved text reads as
/// it did in its own section.
const INSTRUCTIONS_HEADING: &str = "# MCP Server Instructions\n\nThe following MCP servers have \
provided instructions for how to use their tools and resources:";

/// Whether a Claude Code command line `args` can take more appended system prompt in its
/// `--append-system-prompt <text>`: not when it uses the file or `=` form, which
/// [`append_system_prompt`] does not edit.
pub fn takes_appended_prompt(args: &[String]) -> bool {
    !args.iter().any(|a| a.starts_with("--append-system-prompt") && a != "--append-system-prompt")
}

/// `text` at the end of Claude Code's appended system prompt in `args`: after the value of its
/// last `--append-system-prompt` (Claude Code takes only the last), else as a new one.
pub fn append_system_prompt(args: &mut Vec<String>, text: &str) {
    let at = args.iter().rposition(|a| a == "--append-system-prompt").map(|i| i + 1);
    match at.and_then(|i| args.get_mut(i)) {
        Some(value) if !value.trim().is_empty() => *value = format!("{value}\n\n{text}"),
        Some(value) => *value = text.to_owned(),
        None => args.extend(["--append-system-prompt".to_owned(), text.to_owned()]),
    }
}

/// The project's own servers wrapped to wait for the checkout ([`project_mcp`]), for a Claude
/// Code start in `cwd` while that checkout still fills (a start at its head); none once it is in.
fn project_servers_at_head(env: &BTreeMap<String, String>, cwd: &Path) -> Map<String, Value> {
    // A linked chat folder probes as the folder it names, as `wrapped` walks it.
    if !project_mcp::filling(&cwd.canonicalize().unwrap_or_else(|_| cwd.to_path_buf())) {
        return Map::new();
    }
    let Some(cmux) = project_mcp::cmux_program() else {
        tracing::warn!("agent tools: no cmux-tui beside acpmux; project MCP servers start at once");
        return Map::new();
    };
    project_mcp::wrapped(cwd, &project_mcp::Claude::of(env, cwd), &cmux, project_mcp::filling)
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
    let path = mcp_config_path(home, session_id);
    let _ = crate::home_fs::remove_file(crate::bg_hook::denied_path(&path));
    let _ = crate::home_fs::remove_file(path);
    crate::mcp_gateway::forget(home, session_id);
}

/// The tools; no file or running process decides whether a session gets
/// Computer Use. A joined machine's control consent (`cli/cloud_join.rs`) is
/// enforced where a call runs (the worker's host, and the remote relay), so
/// the tool list stays the same whatever the consent says.
pub fn resolve(inputs: &Inputs) -> AgentTools {
    resolve_servers(inputs)
}

fn resolve_servers(inputs: &Inputs) -> AgentTools {
    if !inputs.enabled {
        return AgentTools::default();
    }
    let mut servers = Vec::new();
    let executable = |name: &str| {
        inputs.bin_dir.as_ref().map(|dir| dir.join(name)).filter(|path| is_executable(path))
    };
    if let Some(acpmux) = &inputs.acpmux {
        // Also when the mode is off: the worker refuses each call then, and
        // a chat keeps its tools once the person turns Computer Use on.
        // `for_session` names the session; the bridge asks the cmux-tui
        // daemon for the worker at each call.
        servers.push(McpServer {
            name: crate::computer_use::mcp::SERVER_NAME.into(),
            command: acpmux.exe.clone(),
            args: acpmux.args_lossy(&[crate::computer_use::mcp::COMMAND]),
            env: vec![],
        });
    }
    if let (true, Some(acpmux)) = (inputs.secrets, &inputs.acpmux) {
        // request_secret and run_with_secret (`secret_mcp.rs`): `for_session`
        // names the session and this daemon's socket in its env.
        servers.push(McpServer {
            name: crate::secret_mcp::SERVER_NAME.into(),
            command: acpmux.exe.clone(),
            args: acpmux.args_lossy(&["secret-mcp"]),
            env: vec![],
        });
    }
    if let (true, Some(acpmux)) = (inputs.offers, &inputs.acpmux) {
        // offer_session (`offer_mcp.rs`): `for_session` names the session.
        servers.push(McpServer {
            name: crate::offer_mcp::SERVER_NAME.into(),
            command: acpmux.exe.clone(),
            args: acpmux.args_lossy(&["offer-mcp"]),
            env: vec![],
        });
    }
    if let (true, Some(acpmux)) = (inputs.subsessions, &inputs.acpmux) {
        // start_session and the rest (`subsession_mcp.rs`): `for_session`
        // gives it the session's id, caller token and this daemon's socket.
        servers.push(McpServer {
            name: crate::subsession_mcp::SERVER_NAME.into(),
            command: acpmux.exe.clone(),
            args: acpmux.args_lossy(&["subsession-mcp"]),
            env: vec![],
        });
    }
    if crate::cloud_repo_mcp::is_cloud_machine()
        && let Some(acpmux) = &inputs.acpmux
    {
        // Cloud repository tools run on Cloud machines only. They forward
        // the session caller token to the daemon action bridge.
        servers.push(McpServer {
            name: crate::cloud_repo_mcp::SERVER_NAME.into(),
            command: acpmux.exe.clone(),
            args: acpmux.args_lossy(&["repo-mcp"]),
            env: executable("cmux")
                .map(|path| ("CMUX_BIN".into(), path.to_string_lossy().into_owned()))
                .into_iter()
                .chain(
                    std::env::var("CMUX_SOCKET_PATH")
                        .ok()
                        .map(|path| ("CMUX_SOCKET_PATH".into(), path)),
                )
                .collect(),
        });
    }
    if let Some(acpmux) = &inputs.acpmux {
        // announce, rules and ack (`forum_mcp.rs`, hq#2570): acts as the
        // session with its caller token, like the sub-session server.
        servers.push(McpServer {
            name: crate::forum_mcp::SERVER_NAME.into(),
            command: acpmux.exe.clone(),
            args: acpmux.args_lossy(&["forum-mcp"]),
            env: vec![],
        });
        // send, ls, last and info (`acpmux_mcp.rs`): messages another session as this one,
        // instead of `acpmux send` in a shell; and the chat's daemon-owned background tasks.
        servers.push(McpServer {
            name: crate::acpmux_mcp_names::SERVER_NAME.into(),
            command: acpmux.exe.clone(),
            args: acpmux.args_lossy(&["acpmux-mcp"]),
            env: vec![],
        });
    }
    if let (true, Some(acpmux)) = (inputs.github, &inputs.acpmux) {
        // GitHub's own MCP server through the team's GitHub connection (`github_mcp.rs`): the
        // machine's Cloud agent mints each call's token; nothing goes in its env.
        servers.push(McpServer {
            name: crate::github_mcp::SERVER_NAME.into(),
            command: acpmux.exe.clone(),
            args: acpmux.args_lossy(&["github-mcp"]),
            env: vec![],
        });
    }
    if inputs.hosted
        && let (Some(acpmux), Some(cmux)) = (&inputs.acpmux, executable("cmux"))
    {
        // cmux's hosted MCP (`hosted_mcp.rs`): only the `cmux` CLI's path goes in its env; the
        // server asks the app for the person's token itself and keeps it in memory.
        servers.push(McpServer {
            name: crate::hosted_mcp::SERVER_NAME.into(),
            command: acpmux.exe.clone(),
            args: acpmux.args_lossy(&["hosted-mcp"]),
            env: vec![(
                crate::hosted_mcp::CMUX_BIN_ENV.into(),
                cmux.to_string_lossy().into_owned(),
            )],
        });
    }
    if let Some(lease) = &inputs.desktop_lease {
        // Leased desktops (`desktop-lease mcp`): `for_session` names the owner.
        servers.push(McpServer {
            name: DESKTOP_LEASE_SERVER.into(),
            command: lease.clone(),
            args: vec!["mcp".into()],
            env: std::env::var(DESKTOP_LEASE_SOCKET_ENV)
                .ok()
                .filter(|s| !s.is_empty())
                .map(|s| (DESKTOP_LEASE_SOCKET_ENV.to_owned(), s))
                .into_iter()
                .collect(),
        });
    }
    if let Some(cmux) = executable("cmux").filter(|cmux| cmux_mcp::serves_mcp(cmux))
        && !inputs.cmux_json.as_deref().is_some_and(mcp_disabled)
    {
        servers.push(cmux_server(&cmux, false, &crate::user_settings::resolved_path()));
    }
    if let Some(chief) = executable("optchat-chief")
        && inputs.cmux_json.as_deref().is_some_and(memory_enabled)
    {
        servers.push(McpServer {
            name: MEMORY_SERVER_NAME.into(),
            command: chief,
            args: vec!["agent-memory".into(), "mcp".into()],
            env: vec![],
        });
    }
    if let Some(chief) = executable("optchat-chief")
        && !inputs.cmux_json.as_deref().is_some_and(saved_servers_off)
    {
        servers.push(McpServer {
            name: SAVED_SERVERS_NAME.into(),
            command: chief,
            args: vec!["integrations".into(), "serve".into()],
            env: vec![],
        });
    }
    // `agents.guidance.claude` off leaves `cmux-chat` out of the plugin, not only the pointer.
    let chat_skill = crate::agent_guidance::Switches::current().claude;
    let plugin_dir =
        match materialize(&inputs.state_dir, |skill| chat_skill || skill != "cmux-chat") {
            Ok(dir) => Some(dir),
            Err(e) => {
                tracing::warn!("agent tools: the skills plugin was not written: {e:#}");
                None
            }
        };
    let user_plugin_dir = user_plugin(&inputs.state_dir);
    AgentTools {
        servers,
        plugin_dir,
        user_plugin_dir,
        displays: inputs.displays.clone(),
        cmux_for_agents: agents_get_cmux(inputs.cmux_json.as_deref()),
        project_servers: Map::new(),
        http: BTreeMap::new(),
    }
}

impl AgentTools {
    /// The tools for one session: the servers its env keeps
    /// ([`SERVERS_ENV`]) and the cmux tool list it may use ([`MCP_TOOLS_ENV`]).
    ///
    /// In per-workspace display mode the session gets no Computer Use
    /// server (fail closed: the worker drives the machine's desktop, never
    /// the session's own display).
    pub fn scoped(mut self, session_env: &BTreeMap<String, String>) -> Self {
        // No `cmux` server once the person turned it off ([`agents_get_cmux`]),
        // except for a Chief turn (a preset that names its own cmux tools,
        // `MCP_TOOLS_ENV`; `config/chief_builtins.rs`). The Chief is cmux's own
        // orchestrator, not one of the person's agents: its turns work only
        // through those tools (agents_snapshot, agents_terminal_send, …), and its
        // preset already limits them to that list, so it keeps the server
        // whatever the answer (decided 2026-11-14).
        // A chat started from another Mac follows that Mac's answer (`TOOLS_ANSWER_ENV`).
        let yes = match session_env.get(TOOLS_ANSWER_ENV).map(String::as_str) {
            Some("on") => true,
            Some(_) => false,
            None => self.cmux_for_agents,
        };
        if !yes && !session_env.contains_key(MCP_TOOLS_ENV) {
            self.servers.retain(|s| s.name != CMUX_SERVER);
        }
        let keep = session_env.get(SERVERS_ENV).map(|v| v.trim()).filter(|v| !v.is_empty());
        if let Some(keep) = keep {
            let keep: Vec<&str> = keep.split(',').map(str::trim).collect();
            self.servers.retain(|s| keep.contains(&s.name.as_str()));
        }
        let tools = session_env.get(MCP_TOOLS_ENV);
        let engine = session_env.get(CHIEF_ENGINE_ENV);
        let gh = if self.servers.iter().any(|s| s.name == crate::acpmux_mcp_names::SERVER_NAME) {
            gh_env(session_env, || crate::login_env::every_child_pairs(Some(session_env)))
        } else {
            Vec::new()
        };
        for server in &mut self.servers {
            server.env.retain(|(k, _)| k != MCP_TOOLS_ENV && k != CHIEF_ENGINE_ENV);
            if server.name == "cmux"
                && let Some(engine) = engine
            {
                server.env.push((CHIEF_ENGINE_ENV.to_owned(), engine.clone()));
            }
            // The `acpmux` server's `pr_state` runs the agent's own `gh`: it gets the agent's gh
            // sign-in, which a client that passes a stdio server only an allowlisted env (Codex)
            // leaves out.
            if server.name == crate::acpmux_mcp_names::SERVER_NAME {
                server.env.retain(|(k, _)| !GH_ENV.contains(&k.as_str()));
                server.env.extend(gh.iter().cloned());
            }
            // The `acpmux` server gets the list too: folded, `cmux` filters its
            // tools by the same names; standalone (cmux off or missing, so no
            // fold) the server's own filter is the only one (`acpmux_mcp::allowed`).
            if (server.name == "cmux" || server.name == crate::acpmux_mcp_names::SERVER_NAME)
                && let Some(tools) = tools
            {
                server.env.push((MCP_TOOLS_ENV.to_owned(), tools.clone()));
            }
        }
        if self.displays.is_some() {
            self.servers.retain(|s| s.name != crate::computer_use::mcp::SERVER_NAME);
        }
        self
    }

    /// The tools for acpmux session `session_id`: the cmux server gets it as
    /// [`AGENT_SESSION_ENV`] in its own env, because a client may pass only
    /// an allowlisted env to a stdio MCP server (Codex does).
    pub fn for_session(mut self, session_id: &str) -> Self {
        for server in &mut self.servers {
            // What survives the env reset below: the Cloud repo route, and the
            // `acpmux` server's tool allowlist (`scoped`), its only filter when
            // there is no `cmux` server to fold into.
            let kept: Vec<_> = server
                .env
                .iter()
                .filter(|(k, _)| match server.name.as_str() {
                    crate::cloud_repo_mcp::SERVER_NAME => {
                        matches!(k.as_str(), "CMUX_BIN" | "CMUX_SOCKET_PATH")
                    }
                    crate::acpmux_mcp_names::SERVER_NAME => {
                        k == MCP_TOOLS_ENV || GH_ENV.contains(&k.as_str())
                    }
                    _ => false,
                })
                .cloned()
                .collect();
            server.env.retain(|(k, _)| k != AGENT_SESSION_ENV);
            if server.name == "cmux"
                || server.name == MEMORY_SERVER_NAME
                || server.name == SAVED_SERVERS_NAME
            {
                server.env.push((AGENT_SESSION_ENV.to_owned(), session_id.to_owned()));
            }
            if server.name == DESKTOP_LEASE_SERVER {
                server.env.retain(|(k, _)| k != DESKTOP_LEASE_OWNER_ENV);
                server.env.push((DESKTOP_LEASE_OWNER_ENV.to_owned(), session_id.to_owned()));
            }
            let session_env = match server.name.as_str() {
                crate::secret_mcp::SERVER_NAME => Some(crate::secret_mcp::SESSION_ENV),
                crate::offer_mcp::SERVER_NAME => Some(crate::offer_mcp::SESSION_ENV),
                crate::cloud_repo_mcp::SERVER_NAME => Some(crate::cloud_repo_mcp::SESSION_ENV),
                _ => None,
            };
            if session_env.is_some() {
                let socket = crate::config::socket_path().to_string_lossy().into_owned();
                server.env = vec![
                    (
                        session_env.unwrap_or(crate::subsession_mcp::SESSION_ENV).to_owned(),
                        session_id.to_owned(),
                    ),
                    ("ACPMUX_SOCKET".to_owned(), socket),
                    ("ACPMUX_HOME".to_owned(), home_env()),
                ];
            }
            // The sub-session server acts as the session: its caller token
            // and the one socket the CLI sends it to (`hub/person.rs` (a)).
            // The harness already holds the same token in its env; a Claude
            // Code config with it is a 0600 file (`claude_args`).
            if server.name == crate::subsession_mcp::SERVER_NAME
                || server.name == crate::forum_mcp::SERVER_NAME
                || server.name == crate::acpmux_mcp_names::SERVER_NAME
                || server.name == crate::cloud_repo_mcp::SERVER_NAME
            {
                let socket = crate::config::socket_path().to_string_lossy().into_owned();
                server.env = vec![
                    (
                        session_env.unwrap_or(crate::subsession_mcp::SESSION_ENV).to_owned(),
                        session_id.to_owned(),
                    ),
                    ("ACPMUX_SOCKET".to_owned(), socket),
                    ("ACPMUX_HOME".to_owned(), home_env()),
                ];
                server.env.extend(
                    crate::person_tokens::caller_env(session_id)
                        .into_iter()
                        .map(|(k, v)| (k.to_owned(), v)),
                );
            }
            if server.name == crate::cloud_repo_mcp::SERVER_NAME {
                server.env.push(("ACPMUX_SESSION_ID".to_owned(), session_id.to_owned()));
            }
            if server.name == crate::computer_use::mcp::SERVER_NAME {
                // The session key, this daemon (remote machines go through
                // its peer links) and the cmux-tui daemon that names the worker.
                server.env = vec![
                    (crate::computer_use::mcp::SESSION_ENV.to_owned(), session_id.to_owned()),
                    (
                        "ACPMUX_SOCKET".to_owned(),
                        crate::config::socket_path().to_string_lossy().into_owned(),
                    ),
                    ("ACPMUX_HOME".to_owned(), home_env()),
                ];
                let socket = std::env::var_os(crate::computer_use::client::DAEMON_SOCKET_ENV)
                    .filter(|s| !s.is_empty())
                    .map(std::path::PathBuf::from)
                    .or_else(app_daemon_socket);
                if let Some(socket) = socket {
                    server.env.push((
                        crate::computer_use::client::DAEMON_SOCKET_ENV.to_owned(),
                        socket.to_string_lossy().into_owned(),
                    ));
                }
            }
            server.env.extend(kept);
        }
        self
    }

    /// The chat's tool list rows for these tools (`hub/tools.rs`): each MCP
    /// server, which `toggles` says the harness turns on or off mid-session,
    /// and for Claude Code (`claude`) each skill of the plugin.
    pub fn tool_rows(&self, claude: bool, toggles: bool) -> Vec<crate::store::ToolRow> {
        let row = |id: String, name: &str, can_toggle: bool| crate::store::ToolRow {
            id,
            name: name.to_owned(),
            kind: "cmux".into(),
            source: "cmux".into(),
            enabled: true,
            can_toggle,
            status: None,
        };
        let mut rows: Vec<_> =
            self.servers.iter().map(|s| row(format!("mcp:{}", s.name), &s.name, toggles)).collect();
        if claude && self.plugin_dir.is_some() {
            let skills = SKILL_FILES
                .iter()
                .filter_map(|(p, _)| p.strip_suffix("/SKILL.md"))
                .filter(|n| self.lists_skill(n));
            rows.extend(skills.map(|n| row(format!("skill:{PLUGIN_NAME}:{n}"), n, false)));
        }
        rows
    }

    /// Whether these servers need the `cmux` plugin's skill `name` ([`SKILL_SERVERS`]).
    pub fn lists_skill(&self, name: &str) -> bool {
        SKILL_SERVERS
            .iter()
            .find(|(skill, _)| *skill == name)
            .is_none_or(|(_, server)| self.servers.iter().any(|s| s.name == *server))
    }

    /// The plugin with only the skills these servers need: call it once the session's
    /// servers are final (after `scoped` and `without_off`, before `folded`). Each set of
    /// skills is its own content-hashed folder next to the full one; the chat skill stays
    /// in or out as the full folder has it. A folder that cannot be written keeps the full one.
    pub fn fit_skills(mut self) -> Self {
        let Some(dir) = &self.plugin_dir else { return self };
        if SKILL_FILES.iter().all(|(p, _)| self.lists_skill(skill_of(p))) {
            return self;
        }
        let Some(state_dir) = dir.parent() else { return self };
        let chat = dir.join("skills/cmux-chat").exists();
        let fit = materialize(state_dir, |skill| {
            (chat || skill != "cmux-chat") && self.lists_skill(skill)
        });
        match fit {
            Ok(fit) => self.plugin_dir = Some(fit),
            Err(e) => {
                tracing::warn!("agent tools: the fitted skills plugin was not written: {e:#}")
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
                    if let Some(at) = self.http.get(&s.name) {
                        let headers = [json!({"name": "Authorization", "value": at.authorization})];
                        return json!({"type": "http", "name": s.name, "url": at.url, "headers": headers});
                    }
                    let env: Vec<Value> =
                        s.env.iter().map(|(k, v)| json!({"name": k, "value": v})).collect();
                    json!({"name": s.name, "command": s.command, "args": s.args, "env": env})
                })
                .collect(),
        )
    }

    /// The cmux server lists every tool (`all`) or speaks code mode.
    pub fn listing(mut self, all: bool) -> Self {
        for server in self.servers.iter_mut().filter(|s| s.name == "cmux") {
            server.args.retain(|a| a != "--all-tools");
            if all {
                server.args.push("--all-tools".into());
            }
        }
        self
    }

    /// Without the `cmux` server for a Codex chat whose person's own server named `cmux` is HTTP,
    /// as Codex itself answers for the launch ([`persons_cmux_entry`], the rule the `codex`
    /// terminal shim follows): Codex would refuse the merged entry and the chat would not start.
    /// Skip on doubt: also when what the launch loads is in doubt (no answer from Codex, or a
    /// project file its answer does not show it loads: `CmuxEntry::skips`), and no env keys go
    /// either ([`person_entry_env`] needs a stdio answer). The chat then has no cmux tools and
    /// nothing is said, as with no answer to the question. The person's server keeps the name;
    /// the session's other servers stay, standalone.
    pub fn without_cmux_beside_an_http_entry(
        mut self,
        launch: CodexLaunch<'_>,
        env: &BTreeMap<String, String>,
    ) -> Self {
        if persons_cmux_entry(launch, env).skips() {
            self.servers.retain(|s| s.name != CMUX_SERVER);
        }
        self
    }

    /// The instructions of acpmux's own servers in the list (not folded behind `cmux`) as one
    /// system prompt section, each under its server's name as Claude Code heads them, and those
    /// servers told to leave them out of `initialize`
    /// ([`crate::tools_mcp::INSTRUCTIONS_IN_PROMPT_ENV`]). Claude Code 2.1.330 puts MCP
    /// instructions in the first turn's system message, after its last cached system block, so
    /// every new chat wrote them (about 1.7k tokens) to the prompt cache again; in the appended
    /// system prompt they are part of the prefix all chats share. The text comes from each
    /// server's env as it will run (its tool allowlist), never from the session or folder, so
    /// two chats' prompts stay byte-identical. None, and nothing changed, without any.
    pub fn instructions_in_prompt(&mut self) -> Option<String> {
        let mut parts: Vec<(String, String)> = Vec::new();
        for server in &mut self.servers {
            if !crate::tools_mcp::owns(&server.name, &server.args) {
                continue;
            }
            let env = server.env.iter().cloned().collect();
            let Some(text) = crate::tool_env::sync_scope(env, || {
                crate::tools_mcp::instructions_of(&server.name)
            }) else {
                continue;
            };
            server.env.retain(|(k, _)| k != crate::tools_mcp::INSTRUCTIONS_IN_PROMPT_ENV);
            server.env.push((crate::tools_mcp::INSTRUCTIONS_IN_PROMPT_ENV.to_owned(), "1".into()));
            parts.push((server.name.clone(), text));
        }
        if parts.is_empty() {
            return None;
        }
        parts.sort();
        let sections: Vec<String> =
            parts.iter().map(|(name, text)| format!("## {name}\n{text}")).collect();
        Some(format!("{INSTRUCTIONS_HEADING}\n\n{}", sections.join("\n\n")))
    }

    /// Without the servers [`OFF_ENV`] names (the chat turned them off).
    pub fn without_off(mut self, env: &BTreeMap<String, String>) -> Self {
        if let Some(off) = env.get(OFF_ENV) {
            let off: Vec<&str> = off.split(',').map(str::trim).collect();
            self.servers.retain(|s| !off.contains(&s.name.as_str()));
        }
        self
    }

    /// The servers as one Claude Code MCP config, or `None` without servers.
    pub fn mcp_config(&self) -> Option<Value> {
        if self.servers.is_empty() && self.project_servers.is_empty() {
            return None;
        }
        let mut servers = Map::new();
        for s in &self.servers {
            if let Some(at) = self.http.get(&s.name) {
                let headers = json!({"Authorization": at.authorization});
                servers.insert(
                    s.name.clone(),
                    json!({"type": "http", "url": at.url, "headers": headers}),
                );
                continue;
            }
            let env: Map<String, Value> =
                s.env.iter().map(|(k, v)| (k.clone(), json!(v))).collect();
            servers.insert(
                s.name.clone(),
                json!({"type": "stdio", "command": s.command, "args": s.args, "env": env}),
            );
        }
        for (name, server) in &self.project_servers {
            servers.entry(name.clone()).or_insert_with(|| server.clone());
        }
        Some(json!({"mcpServers": servers}))
    }

    /// Claude Code flags: the servers as `--mcp-config <config_file>` (the
    /// file is written here), the skills as a session-only plugin. Without
    /// servers an earlier launch's file goes: the plugin's background-shell
    /// hook reads it (`bg_hook.rs`) and must not send the agent to a server
    /// this launch does not have.
    pub fn claude_args(&self, config_file: &Path) -> Vec<String> {
        let mut args = Vec::new();
        // Each launch starts the hook's turned-away calls afresh: one from a launch with other
        // servers is not a retry in this one.
        let _ = crate::home_fs::remove_file(crate::bg_hook::denied_path(config_file));
        if self.servers.is_empty() && self.project_servers.is_empty() {
            let _ = crate::home_fs::remove_file(config_file);
        }
        if let Some(config) = self.mcp_config() {
            match write_private(config_file, config.to_string().as_bytes()) {
                Ok(()) => {
                    args.push("--mcp-config".into());
                    args.push(config_file.to_string_lossy().into_owned());
                }
                // Never fall back to inline JSON: that puts the token in argv. An earlier
                // launch's file goes too, so the hook never reads servers this one lacks.
                Err(e) => {
                    let _ = crate::home_fs::remove_file(config_file);
                    tracing::warn!(
                        "agent tools: MCP config {} not written, session gets no MCP servers: {e:#}",
                        config_file.display()
                    )
                }
            }
        }
        for dir in self.plugin_dir.iter().chain(&self.user_plugin_dir) {
            args.push("--plugin-dir".into());
            args.push(dir.to_string_lossy().into_owned());
        }
        args
    }
}

/// Write `bytes` to `path` as a 0600 file in a 0700 folder (to a temporary
/// file first, then renamed, so claude never reads half a config).
#[cfg(unix)]
pub(crate) fn write_private(path: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    // A request during a lost home's shutdown never makes it again (`config::mark_home_lost`),
    // and the file goes through the folder this daemon holds (`home_fs`): a home replaced after
    // the check never gets it.
    crate::config::refuse_lost_home(path)?;
    let dir = path.parent().ok_or_else(|| anyhow::anyhow!("no parent folder"))?;
    crate::home_fs::create_dir_all(dir, 0o700)?;
    crate::home_fs::set_mode(dir, 0o700)?;
    // The copy of a writer stopped before its rename is removed by the next write.
    crate::config::write_atomic_checked(path, bytes)
}
/// Windows: the folder and the file owner-only (`owner_only.rs`).
#[cfg(windows)]
pub(crate) fn write_private(path: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    crate::config::refuse_lost_home(path)?;
    let dir = path.parent().ok_or_else(|| anyhow::anyhow!("no parent folder"))?;
    crate::owner_only::create_dir_all(dir)?;
    crate::owner_only::restrict(dir)?;
    crate::config::write_atomic(path, bytes)
}

#[cfg(unix)]
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}
/// Windows has no execute bit: any file counts.
#[cfg(not(unix))]
fn is_executable(path: &Path) -> bool {
    std::fs::metadata(path).is_ok_and(|m| m.is_file())
}

/// Same rule as `cmux mcp serve` for an agent session (cmux-tui
/// `cli/mcp/config.rs`): off only when the settings file says `mcp.enabled`
/// is not `true` (`false`, or a value `serve` refuses); a missing file or
/// key is on. An unreadable file is on too: `serve` reports the error to
/// the agent instead of the server vanishing.
fn mcp_disabled(text: &str) -> bool {
    crate::user_settings::document(text)
        .and_then(|doc| doc.pointer("/mcp/enabled").cloned())
        .is_some_and(|v| !v.is_null() && v != Value::Bool(true))
}

/// Agent memory is on only when the settings file says
/// `agents.memory.enabled` is `true`: it reads the user's memory files, so
/// a missing key, another value or an unreadable file leaves it off.
fn saved_servers_off(text: &str) -> bool {
    crate::user_settings::document(text)
        .and_then(|doc| crate::user_settings::value(&doc, SAVED_SERVERS_SETTING))
        == Some(Value::Bool(false))
}

fn memory_enabled(text: &str) -> bool {
    crate::user_settings::document(text)
        .and_then(|doc| crate::user_settings::value(&doc, "agents.memory.enabled"))
        == Some(Value::Bool(true))
}

/// The person's skills as the `cmux-user` plugin, read now; `None` when the switch is off,
/// there are none, or the copy failed (logged: the session starts without them).
fn user_plugin(state_dir: &Path) -> Option<PathBuf> {
    use crate::agent_guidance as guidance;
    if !guidance::Switches::current().user_skills {
        return None;
    }
    let skills = guidance::user_skills(&guidance::user_skills_dir()?);
    guidance::materialize_user_plugin(state_dir, &skills)
        .inspect_err(|e| {
            tracing::warn!("agent tools: the user skills plugin was not written: {e:#}")
        })
        .ok()
        .flatten()
}

/// The plugin folder for the compiled-in skills, written once per content
/// hash (to a temporary folder, then renamed, so a reader never sees half).
/// `keep` picks the skills by name: the `agents.guidance.claude` switch leaves out `cmux-chat`,
/// [`AgentTools::fit_skills`] the skills of servers a session lacks.
fn materialize(state_dir: &Path, keep: impl Fn(&str) -> bool) -> anyhow::Result<PathBuf> {
    let skill_files: Vec<&(&str, &str)> =
        SKILL_FILES.iter().filter(|(p, _)| keep(skill_of(p))).collect();
    let mut all = Vec::new();
    for (path, text) in &skill_files {
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
    // Written through the folder this daemon holds (`home_fs`): a home replaced after the check
    // never gets the plugin.
    crate::config::refuse_lost_home(state_dir)?;
    crate::home_fs::create_dir_all(state_dir, 0o777)?;
    let tmp = state_dir.join(format!(".tmp-{}", uuid::Uuid::now_v7()));
    let manifest = json!({
        "name": PLUGIN_NAME,
        "description": "cmux browser and computer use skills for agents cmux starts",
        "version": env!("CARGO_PKG_VERSION"),
    });
    let mut files = vec![(".claude-plugin/plugin.json".to_owned(), manifest.to_string())];
    files.extend(skill_files.iter().map(|(p, t)| (format!("skills/{p}"), (*t).to_owned())));
    for (path, text) in files {
        let file = tmp.join(path);
        if let Some(parent) = file.parent() {
            crate::home_fs::create_dir_all(parent, 0o777)?;
        }
        crate::home_fs::write_synced(&file, text.as_bytes())?;
    }
    match crate::home_fs::rename(&tmp, &dir) {
        Ok(()) => Ok(dir),
        // Another spawn wrote the same content first.
        Err(_) if dir.join(".claude-plugin/plugin.json").is_file() => {
            let _ = crate::home_fs::remove_dir_all(&tmp);
            Ok(dir)
        }
        Err(e) => {
            let _ = crate::home_fs::remove_dir_all(&tmp);
            Err(e.into())
        }
    }
}

/// `words` as single-quoted shell words.
pub(crate) fn quoted(words: &[String]) -> String {
    let quoted: Vec<String> =
        words.iter().map(|w| format!("'{}'", w.replace('\'', "'\\''"))).collect();
    quoted.join(" ")
}

fn home_env() -> String {
    crate::config::home().to_string_lossy().into_owned()
}

#[cfg(all(test, unix))]
#[path = "agent_tools_tests.rs"]
mod tests;

/// The fake Codex resolver other unit tests use (`agent_tools_tests.rs`).
#[cfg(all(test, unix))]
pub(crate) mod tests_support {
    pub(crate) use super::tests::{codex_answers, fake_codex};
}

/// The cmux-tui daemon socket of the cmux app that started this acpmux
/// (`CMUX_BUNDLE_ID`, `CMUX_TAG` in its environment), for an agent chat's
/// Computer Use bridge when the app named none (`CMUX_TUI_SOCKET`): the app's
/// daemon runs session [`BuildIdentity::app_session`]
/// (`cmux-app`, `cmux-app-<tag>`, ...), or the old shared `cmux-app` once the
/// build adopted it (its legacy marker), in cmux-tui's default runtime folder.
/// Without it the bridge asked the `main` session, which no app runs, so an
/// agent chat's Computer Use never reached the worker. `None` outside an app.
fn app_daemon_socket() -> Option<std::path::PathBuf> {
    let var = |key: &str| std::env::var(key).ok().filter(|v| !v.trim().is_empty());
    let build = cmux_agent_pane_policy::build_identity::BuildIdentity::new(
        var("CMUX_BUNDLE_ID").as_deref(),
        var("CMUX_TAG").as_deref(),
    );
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    app_daemon_socket_for(&build, home.as_deref())
}

fn app_daemon_socket_for(
    build: &cmux_agent_pane_policy::build_identity::BuildIdentity,
    home: Option<&std::path::Path>,
) -> Option<std::path::PathBuf> {
    let session = crate::computer_use::daemon_socket::app_session(build, home)?;
    Some(cmux::raw::default_socket_path(&session))
}

#[cfg(test)]
mod app_daemon_socket_tests {
    use cmux_agent_pane_policy::build_identity::BuildIdentity;

    use super::app_daemon_socket_for;

    /// An agent chat's Computer Use bridge reaches its own app's daemon, never `main`.
    #[test]
    fn a_chat_bridge_names_its_apps_daemon() {
        let tagged =
            BuildIdentity::new(Some("com.cmuxterm.app.debug.cu.preview2"), Some("cu-preview2"));
        let path = app_daemon_socket_for(&tagged, None).expect("a tagged build has a daemon");
        assert!(path.ends_with("cmux-app-cu-preview2.sock"), "{}", path.display());
        let release = BuildIdentity::new(Some("com.cmuxterm.app"), None);
        let path = app_daemon_socket_for(&release, None).expect("release has a daemon");
        assert!(path.ends_with("cmux-app.sock"), "{}", path.display());
        assert!(app_daemon_socket_for(&BuildIdentity::new(None, None), None).is_none());
    }
}
