//! The turn sessions' working directory, written once per host start: every
//! turn runs in it, so the harness sees the same CLAUDE.md, settings and MCP
//! servers each time (section 7.2: byte-identical prompt and tools).
//!
//! A turn should see only what this directory holds (section 7: a fresh call,
//! nothing carried over; section 7.2: MASTER, then VIEW_DOC, then the
//! instructions at the end). The turn sessions sign in with the user's own
//! Claude login, so they use the user's Claude home; their acpmux preset
//! turns auto-memory and CLAUDE.md files off (its system prompt carries the
//! instructions), and this directory's project settings turn hooks off, so
//! the user's own ~/.claude/CLAUDE.md, hooks and project memory never reach
//! a turn. What stays outside our control: Claude Code's own system prompt
//! (with its date and environment lines), the user's other settings and
//! any machine-wide managed settings.
//!
//! Deviation: acpmux ignores the client's `mcpServers` in `session/new` and
//! gives every agent chat its own agent tools instead (cmux, cmux-cua,
//! secrets: acpmux agent_tools.rs, cx-wx93i; a Chief turn keeps only cmux,
//! `TURN_TOOL_SERVERS`, cx-4a5w2), so mux/host's way of passing
//! MCP servers reaches no harness. The Chief's own `optchat` server, which
//! acpmux does not know, goes in the directory's `.mcp.json`, enabled by the
//! project settings, which Claude Code harnesses read.

use std::collections::BTreeMap;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use serde_json::{Value, json};

use crate::paths::Paths;
use crate::prompt::{Tools, chief_system_text, system_text};

/// What the session directory is made of.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionSetup {
    /// This executable (absolute), which serves `mcp` and the `chief` launcher.
    pub exe: String,
    /// Env the turn's tools see (MUX_HOME, CMUX_SOCKET_PATH, ACPMUX_*, PATH).
    pub env: BTreeMap<String, String>,
    /// The user's instructions file, read at host start (section 7.2).
    pub instructions: Option<String>,
    /// How the turn reaches its memory tools (the harness family).
    pub tools: crate::prompt::Tools,
    /// The `env` of the user's Claude Code settings (`user_settings_env`):
    /// a session that loads no user setting source still gets it (the
    /// user's API route, for one), under the session's own env.
    pub user_env: BTreeMap<String, String>,
    /// The record grants the `profile` tool (chief_profile.rs): the
    /// launcher section of AGENTS.md names `chief profile`.
    pub profile_tool: bool,
    /// The record grants the `chiefs` tool: the launcher section names
    /// `chief chiefs`.
    pub chiefs_tool: bool,
}

/// Whether this host copies the user's Claude Code settings env into its
/// sessions' settings (`OPTCHAT_COPY_USER_ENV`, `0` turns it off).
/// Only on a macOS host, the user's own Mac: a Chief in a Linux VM or a
/// dev backend image never copies a settings env into its files.
pub fn copy_user_env_allowed(setting: Option<&str>) -> bool {
    cfg!(target_os = "macos") && setting.map(str::trim) != Some("0")
}

/// The user's settings env for this host's sessions (`user_settings_env`
/// of the user's Claude home) when `copy_user_env_allowed`, else empty.
/// Its values are never logged.
pub fn host_user_env() -> BTreeMap<String, String> {
    if copy_user_env_allowed(crate::cli::env("OPTCHAT_COPY_USER_ENV").as_deref()) {
        user_settings_env(&crate::compactor::user_claude_home())
    } else {
        BTreeMap::new()
    }
}

/// The `env` block of the user's Claude Code settings file
/// (`<Claude home>/settings.json`), string values only; empty when the
/// file is missing or unreadable.
pub fn user_settings_env(claude_home: &Path) -> BTreeMap<String, String> {
    use std::os::unix::fs::MetadataExt;
    let file = claude_home.join("settings.json");
    // Only a file this user owns: another user's settings are not ours to copy.
    // SAFETY: getuid has no preconditions and cannot fail.
    let uid = unsafe { libc::getuid() };
    if std::fs::metadata(&file).map_or(true, |m| m.uid() != uid) {
        return BTreeMap::new();
    }
    std::fs::read(&file)
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|v| v.get("env").and_then(Value::as_object).cloned())
        .into_iter()
        .flatten()
        .filter_map(|(k, v)| v.as_str().map(|v| (k, v.to_owned())))
        .collect()
}

pub fn shell_quote(value: &str) -> String {
    let plain = !value.is_empty()
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_./:@=-".contains(&b));
    if plain {
        value.to_owned()
    } else {
        format!("'{}'", value.replace('\'', "'\\''"))
    }
}

/// The `.mcp.json` of the session directory.
pub fn mcp_json(setup: &SessionSetup, paths: &Paths) -> Value {
    mcp_json_for(setup, paths, false)
}

/// The `.mcp.json` of the Chief's (`subagent` false) or a subagent's
/// directory: a subagent's `optchat` server offers zoom and date only.
pub fn mcp_json_for(setup: &SessionSetup, paths: &Paths, subagent: bool) -> Value {
    let mut servers = serde_json::Map::new();
    let mut args = vec![
        "mcp".to_owned(),
        "--socket".to_owned(),
        paths.tools_socket.to_string_lossy().into_owned(),
    ];
    if subagent {
        args.extend(["--role".to_owned(), "subagent".to_owned()]);
    }
    // The Chief's own tools stay in every prompt (`alwaysLoad`), never behind ToolSearch
    // (TURN_SETTINGS_ENV): a `spawn` turn calls spawn first, with no ToolSearch step.
    // The Chief's own turn hands its turn seal (chief_profile.rs
    // TURN_KEY_ENV, in the turn preset's env only) to its `optchat` server:
    // Claude Code starts a stdio server without the turn's env and expands
    // `${VAR}` from its own, so the file names the variable, never the
    // value. A subagent's server gets none.
    // A subagent's server learns which subagent it serves (escalate_auth)
    // from its acpmux session name, named here, never copied.
    let env = if subagent {
        json!({"ACPMUX_SESSION_NAME": "${ACPMUX_SESSION_NAME:-}"})
    } else {
        let key = crate::chief_profile::TURN_KEY_ENV;
        let mut env = serde_json::Map::new();
        env.insert(key.to_owned(), Value::String(format!("${{{key}:-}}")));
        Value::Object(env)
    };
    servers.insert(
        "optchat".into(),
        json!({"type": "stdio", "command": setup.exe, "args": args, "env": env, "alwaysLoad": true}),
    );
    // No `cmux` server here: acpmux gives every agent chat its own `cmux mcp
    // serve` (cx-wx93i, acpmux agent_tools.rs), the Chief's turns and
    // subagents included, so a second one only doubled the tool list
    // (hq-6d 2026-10-14: one cmux MCP server per turn).
    // The MCP servers of the tool packs that are on (toolpacks.rs).
    for (name, server) in
        crate::toolpacks::claude_servers(&crate::toolpacks::load(&paths.home), &paths.bin)
    {
        servers.entry(name).or_insert(server);
    }
    json!({"mcpServers": servers})
}

/// The project settings: the MCP servers above enabled, the tools' env with
/// the launcher directory first on PATH, and `deny` (Claude Code's
/// subagents always) denied, which takes those tools out of the list.
pub fn settings_json(setup: &SessionSetup, paths: &Paths, deny: &[&str]) -> Value {
    let mut names = vec!["optchat".to_owned()];
    names.extend(
        crate::toolpacks::claude_servers(&crate::toolpacks::load(&paths.home), &paths.bin)
            .into_iter()
            .map(|(n, _)| n),
    );
    // The user's settings env first (a session that loads no user setting
    // source keeps the user's API route), the session's own over it.
    let mut env: serde_json::Map<String, Value> = setup
        .user_env
        .iter()
        .chain(setup.env.iter())
        .map(|(k, v)| (k.clone(), Value::String(v.clone())))
        .collect();
    let path = setup
        .env
        .get("PATH")
        .map_or("/usr/bin:/bin", String::as_str);
    env.insert(
        "PATH".into(),
        Value::String(format!("{}:{path}", paths.bin.display())),
    );
    // Claude Code's own subagents (Task/Agent) stream their steps through the
    // same session as the turn, and acpmux's translator cannot tell them
    // apart, so they would land in the log as the Chief's own (section 9:
    // a subagent's tool calls stay in its own session). The Chief starts
    // agents with `chief agents`, whose reports come back as `[name]` messages.
    json!({
        "enableAllProjectMcpServers": true,
        "enabledMcpjsonServers": names,
        "env": env,
        "permissions": {"deny": deny},
        // Also here, not only in the isolated configuration: claude-sr
        // resets CLAUDE_CONFIG_DIR to ~/.claude (live check 2026-10-04), so
        // project settings are the ones a turn is sure to read.
        "autoMemoryEnabled": false,
        "disableAllHooks": true,
        "cleanupPeriodDays": TURN_TRANSCRIPT_DAYS,
    })
}

/// Tools no Chief session offers: Claude Code's own subagents (above),
/// and the tools that wait for a human (a question, plan mode), which
/// acpmux keeps for a human under every policy and nobody answers in a
/// turn, so one call would hang the turn until its limit. Subagents keep
/// every other tool: they do the work.
pub const SUBAGENT_DENIED_TOOLS: [&str; 5] = [
    "Task",
    "Agent",
    "AskUserQuestion",
    "EnterPlanMode",
    "ExitPlanMode",
];

/// A turn session's denied tools (parity item 5): the above, and every
/// other built-in tool of Claude Code 2.1.287 the Chief does not work with,
/// so the turn's prefix stays small (measured 2026-10-08: 20.7k to 12.1k
/// tokens bare). A turn keeps Bash, Read, Edit, Write, WebFetch, WebSearch
/// and ToolSearch; the Chief's own MCP tools load with it and the cmux MCP
/// tools behind ToolSearch (`TURN_SETTINGS_ENV`); work beyond those goes to
/// subagents. The turn
/// preset's `--tools` allowlist (`host::TURN_TOOLS`) is the main guard: a
/// tool a later Claude Code adds is not offered. This
/// list stays as the second guard, for an acpmux older than that preset
/// arg (the preset is then installed without it).
pub const TURN_DENIED_TOOLS: [&str; 25] = [
    "Task",
    "Agent",
    "AskUserQuestion",
    "EnterPlanMode",
    "ExitPlanMode",
    "CronCreate",
    "CronDelete",
    "CronList",
    "DesignSync",
    "EnterWorktree",
    "ExitWorktree",
    "ListAgents",
    "Monitor",
    "NotebookEdit",
    "PushNotification",
    "ReportFindings",
    "ScheduleWakeup",
    "SendMessage",
    "Skill",
    "TaskCreate",
    "TaskGet",
    "TaskList",
    "TaskStop",
    "TaskUpdate",
    "Workflow",
];

/// The daemon-owned cmux MCP tools a Chief turn keeps (cx-68uof, hq-6d
/// 2026-10-16): manage its own workspaces/terminals, answer dialogs, and
/// follow agents. Mac app actions are not authority-scoped and stay denied.
/// Chiefs, conversations, memory and subagents are the
/// Chief's own `optchat` server (chiefs, profile, spawn, tell, zoom, date),
/// which always loads; cmux MCP has no conversation or Chief tools (v2_tools
/// EXCLUDED). Every other cmux MCP tool is denied in the turn's settings
/// and stays reachable through the `cmux` CLI on its own host. Names:
/// `agents_*` and `render` (cmux mcp agent tools). `agents_chat_send`,
/// `agents_chat_read` and `agents_chat_state` reach the agent chats the user
/// started in the app (#25571): a send is the Chief's agent message, under
/// the daemon's agent message policy, and starts a turn in that chat, a
/// restored chat no tab has shown yet included.
pub const CHIEF_CMUX_TOOLS: [&str; 16] = [
    "agents_snapshot",
    "agents_workspace_create",
    "agents_workspace_select",
    "agents_terminal_split",
    "agents_terminal_focus",
    "agents_tab_select",
    "agents_dialog_list",
    "agents_dialog_answer",
    "agents_events",
    "agents_wait",
    "render",
    "agents_terminal_list",
    "agents_terminal_send",
    "agents_chat_send",
    "agents_chat_read",
    "agents_chat_state",
];

/// The turn presets' env that keeps only acpmux's `cmux` MCP server
/// (acpmux `agent_tools::SERVERS_ENV`; its built-in turn presets set the
/// same, cx-4a5w2). In the app, whose bundle has `cmux-cua`, the computer
/// use and secret servers' 43 tool names and instructions came after the
/// turn's cache mark: 1,440 of its 2,905 uncached tokens, every turn.
pub const TURN_TOOL_SERVERS: (&str, &str) = ("ACPMUX_AGENT_TOOL_SERVERS", "cmux");

/// The turn presets' env that limits acpmux's `cmux` MCP server to
/// `CHIEF_CMUX_TOOLS` (acpmux `agent_tools::MCP_TOOLS_ENV`).
pub const TURN_TOOLS_ENV: &str = "CMUX_MCP_TOOLS";

/// The code-mode tools of `cmux mcp serve`: a script reaches every cmux
/// tool, so a turn always denies them, even when the server did not get
/// `TURN_TOOLS_ENV`.
const CODE_MODE_TOOLS: [&str; 2] = ["cmux_exec", "cmux_docs"];

/// Deny rules for the other agent tool servers, the second guard for an
/// acpmux without `TURN_TOOL_SERVERS` (their tools leave the list; their
/// instructions stay).
pub const TURN_DENIED_SERVERS: [&str; 3] =
    ["mcp__cmux-cua", "mcp__cmux-secrets", "mcp__cmux-sessions"];

/// How long `cmux mcp tools` may take before a turn keeps every tool.
const TOOL_LIST_LIMIT: std::time::Duration = std::time::Duration::from_secs(15);

/// The cmux MCP tool names of the CLI the turn's env runs (`cmux --json
/// mcp tools`, the list `cmux mcp serve` gives every agent chat) and whether
/// the app's action tools were in it (`app_actions`: false while the cmux
/// app does not answer; its `app_*` tools then load later). None when it
/// fails or takes longer than `TOOL_LIST_LIMIT` (Err: why).
pub fn cmux_tool_names(env: &BTreeMap<String, String>) -> Result<CmuxToolList, String> {
    let mut child = std::process::Command::new("cmux")
        .args(["--json", "mcp", "tools"])
        .envs(env)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("cmux --json mcp tools did not start: {e}"))?;
    // Only the pipe goes to the reader; the child stays here unreaped, so a
    // kill after the limit can never reach a reused pid.
    let (Some(mut stdout), Some(mut stderr)) = (child.stdout.take(), child.stderr.take()) else {
        let _ = child.kill();
        let _ = child.wait();
        return Err("cmux --json mcp tools gave no output pipe".to_owned());
    };
    // Its stderr says why the app's tools are missing; read on its own
    // thread so a full pipe never blocks the child.
    let note = std::thread::spawn(move || {
        let mut text = String::new();
        let _ = std::io::Read::read_to_string(
            &mut std::io::Read::take(&mut stderr, 16 * 1024),
            &mut text,
        );
        let text = text.trim().to_owned();
        (!text.is_empty()).then_some(text)
    });
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = tx.send(std::io::Read::read_to_end(&mut stdout, &mut bytes).map(|_| bytes));
    });
    let Ok(Ok(bytes)) = rx.recv_timeout(TOOL_LIST_LIMIT) else {
        let _ = child.kill();
        let _ = child.wait();
        return Err(format!(
            "cmux --json mcp tools took longer than {} s",
            TOOL_LIST_LIMIT.as_secs()
        ));
    };
    let status = child
        .wait()
        .map_err(|e| format!("cmux --json mcp tools: {e}"))?;
    let note = note.join().ok().flatten();
    if !status.success() {
        return Err(match note {
            Some(note) => format!("cmux --json mcp tools failed ({status}): {note}"),
            None => format!("cmux --json mcp tools failed ({status})"),
        });
    }
    let value: Value = serde_json::from_slice(&bytes)
        .map_err(|e| format!("cmux --json mcp tools printed no JSON: {e}"))?;
    let names = value["tools"]
        .as_array()
        .map(|tools| {
            tools
                .iter()
                .filter_map(|t| t["name"].as_str().map(str::to_owned))
                .collect()
        })
        .ok_or_else(|| "cmux --json mcp tools listed no tools".to_owned())?;
    Ok(CmuxToolList {
        names,
        app_actions: value["app_actions"] == true,
        note,
    })
}

/// One `cmux --json mcp tools` answer.
#[derive(Debug, Clone)]
pub struct CmuxToolList {
    /// The tool names.
    pub names: Vec<String>,
    /// Whether the app's action tools were in it.
    pub app_actions: bool,
    /// What the CLI said on stderr (why the app's tools are missing).
    pub note: Option<String>,
}

/// Deny rules (`mcp__cmux__<name>`) for every name not in `CHIEF_CMUX_TOOLS`.
fn deny_rules(names: Vec<String>) -> Vec<String> {
    CODE_MODE_TOOLS
        .iter()
        .map(|name| (*name).to_owned())
        .chain(names.into_iter().filter(|name| {
            !CHIEF_CMUX_TOOLS.contains(&name.as_str()) && !CODE_MODE_TOOLS.contains(&name.as_str())
        }))
        .map(|name| format!("mcp__cmux__{name}"))
        .collect()
}

/// The pending marker: the env of a tool list taken before the cmux app
/// answered. Each turn start (`set_session_cache`) lists again with it until
/// the app's action tools are in, then adds their denials.
const PENDING: &str = "cmux-tools-pending.json";

/// The last list that had the app's action tools, in a session's
/// `.claude`: a list read while the app does not answer (the Mac asleep, its
/// relay down) keeps its names, so no app tool loses its denial.
const LAST_KNOWN: &str = "cmux-tools-last.json";

/// Deny rules for every cmux MCP tool of `env`'s CLI not in
/// `CHIEF_CMUX_TOOLS`. When the list cannot be read, or has no app action
/// tools, the last known list (`LAST_KNOWN`) is kept with it and host.log
/// says why; with no last known list, a failed read denies the whole cmux
/// server. An unavailable catalog never widens a Chief's tool grant.
/// When the app's action tools were not in the list, `session` gets the
/// pending marker.
pub fn cmux_tool_denials(session: &Path, env: &BTreeMap<String, String>) -> Vec<String> {
    let dir = session.join(".claude");
    let pending = dir.join(PENDING);
    let last_path = dir.join(LAST_KNOWN);
    let last: Vec<String> = std::fs::read_to_string(&last_path)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default();
    let list = match cmux_tool_names(env) {
        Ok(list) => list,
        Err(why) => {
            if last.is_empty() {
                crate::log::log(format!(
                    "reading the cmux MCP tool list failed and no list is known; Chief turns deny the cmux MCP server: {why}"
                ));
            } else {
                crate::log::log(format!(
                    "reading the cmux MCP tool list failed; Chief turns keep the last known list ({} tools): {why}",
                    last.len()
                ));
            }
            if last.is_empty() {
                return vec!["mcp__cmux".to_owned()];
            }
            return deny_rules(last);
        }
    };
    if list.app_actions {
        let _ = std::fs::remove_file(&pending);
        if let Ok(text) = serde_json::to_string(&list.names)
            && let Err(e) = write_private(&last_path, text.as_bytes())
        {
            crate::log::log(format!("writing {}: {e}", last_path.display()));
        }
        return deny_rules(list.names);
    }
    let why = list.note.as_deref().unwrap_or("no reason given");
    crate::log::log(format!(
        "the cmux app did not answer, so its action tools are missing from the cmux MCP tool list{}: {why}",
        if last.is_empty() {
            String::new()
        } else {
            format!(
                "; Chief turns keep the last known list ({} tools)",
                last.len()
            )
        }
    ));
    if let Ok(text) = serde_json::to_string(env)
        && let Err(e) = write_private(&pending, text.as_bytes())
    {
        crate::log::log(format!("writing {}: {e}", pending.display()));
    }
    let mut names = list.names;
    for name in last {
        if !names.contains(&name) {
            names.push(name);
        }
    }
    deny_rules(names)
}

/// With the pending marker in `dir` (a session's `.claude`): the denials of
/// a list that now has the app's action tools (the marker goes), else None.
fn pending_denials(dir: &Path) -> Option<Vec<String>> {
    let pending = dir.join(PENDING);
    let env: BTreeMap<String, String> =
        serde_json::from_str(&std::fs::read_to_string(&pending).ok()?).ok()?;
    let list = cmux_tool_names(&env).ok()?;
    let (names, app) = (list.names, list.app_actions);
    if !app {
        return None;
    }
    let _ = std::fs::remove_file(&pending);
    if let Ok(text) = serde_json::to_string(&names) {
        let _ = write_private(&dir.join(LAST_KNOWN), text.as_bytes());
    }
    Some(deny_rules(names))
}

/// The Claude Code env of every turn, in the turn directory's project
/// settings (over the user's settings env; acpmux's built-in Chief presets
/// take no env from the host): tool search on, so every MCP tool but the
/// Chief's own (`optchat`, `alwaysLoad` in `.mcp.json`) waits behind
/// ToolSearch. The cmux MCP server that acpmux gives every agent chat
/// (cx-wx93i; the only cmux server of a turn, `mcp_json_for`) and the app's
/// old `CMUX_MCP_COMMAND` server listed 165 tools, 100.8k
/// tokens without the app's actions (count_tokens, 2026-10-14); loaded with
/// the turn they made a one-word reply write a 274k-token cache ($2.75,
/// cx-l0vf8). `true`, not `auto`: Claude Code turns `auto` off for a base URL
/// that is not Anthropic's (the subrouter), and the subrouter forwards the
/// tool_reference blocks. `optchat` stays loaded, so a `spawn` turn still
/// calls spawn first (cx-7ssql: ToolSearch before spawn cost 2.5 s).
pub const TURN_SETTINGS_ENV: [(&str, &str); 1] = [("ENABLE_TOOL_SEARCH", "true")];

/// Days Claude Code keeps a turn session's transcript in the isolated
/// configuration (the memory is the record; these only help debugging).
pub const TURN_TRANSCRIPT_DAYS: u64 = 2;

/// `bin/chief`: runs this executable with the host's env baked in, because
/// the harness runs tools in the acpmux daemon's environment, not the host's.
pub fn launcher(setup: &SessionSetup) -> String {
    let mut text = String::from("#!/bin/sh\n");
    for (key, value) in &setup.env {
        if key != "PATH" {
            text.push_str(&format!("{key}={}; export {key}\n", shell_quote(value)));
        }
    }
    text.push_str(&format!("exec {} \"$@\"\n", shell_quote(&setup.exe)));
    text
}

/// The isolated Claude Code configuration's user settings: no auto-memory
/// (continuity is the view alone), no hooks, no extra memory files, and a
/// short transcript retention (each turn's transcript holds the whole view).
pub fn claude_settings() -> Value {
    json!({"autoMemoryEnabled": false, "hooks": {}, "cleanupPeriodDays": TURN_TRANSCRIPT_DAYS})
}

/// Env every Chief Claude session's preset carries (turn, compactor,
/// subagent; isolated or not): no background plugin auto-update. Claude Code refreshes
/// plugin marketplaces with `git` in ~/.claude/plugins/marketplaces, outside
/// the Chief home, and skips it when the auto-updater is disabled (2.1.295;
/// `DISABLE_AUTOUPDATER`, narrower than CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC,
/// which also turns off feature flags). Only these sessions: the user's
/// ~/.claude config is never changed.
pub const QUIET_ENV: [(&str, &str); 1] = [("DISABLE_AUTOUPDATER", "1")];

/// The env of the turn and subagent sessions' acpmux presets: no
/// auto-memory. No `CLAUDE_CONFIG_DIR` of their own: Claude Code finds the
/// user's login through the user's Claude home, and a plain `claude`
/// session pointed at another directory is signed out (`claude auth
/// status`: loggedIn false). The session directory's project settings keep
/// hooks off and deny the tools a session must not use, as they did for
/// claude-sr, which resets the variable anyway.
pub fn isolation_env(_paths: &Paths) -> BTreeMap<String, String> {
    let mut env = BTreeMap::new();
    env.insert("CLAUDE_CODE_DISABLE_AUTO_MEMORY".to_owned(), "1".to_owned());
    env
}

/// Writes the directory; a file is rewritten only when its bytes differ.
/// The instructions go to CLAUDE.md for a Claude Code harness (the old
/// layout; the cached layout puts them in the turn preset's system prompt
/// and removes the file, `set_claude_md`), to AGENTS.md for any other.
pub fn write(paths: &Paths, setup: &SessionSetup) -> io::Result<()> {
    std::fs::create_dir_all(paths.session.join(".claude"))?;
    std::fs::create_dir_all(&paths.bin)?;
    // AGENTS.md always (a turn may swap to codex or another harness between
    // turns, engine.rs); Claude Code reads only CLAUDE.md, which only the
    // old layout of a Claude harness keeps.
    let chief = paths.bin.join("chief").display().to_string();
    let agents = chief_system_text(
        setup.instructions.as_deref(),
        &Tools::Cli(chief),
        setup.profile_tool,
        setup.chiefs_tool,
    );
    write_if_changed(&paths.session.join("AGENTS.md"), agents.as_bytes())?;
    match setup.tools {
        Tools::Mcp => {
            let text = system_text(setup.instructions.as_deref(), &Tools::Mcp);
            write_if_changed(&paths.session.join("CLAUDE.md"), text.as_bytes())?;
        }
        Tools::Cli(_) => remove_if_present(&paths.session.join("CLAUDE.md"))?,
    }
    let pretty = |v: &Value| -> io::Result<String> {
        Ok(format!(
            "{}\n",
            serde_json::to_string_pretty(v).map_err(io::Error::other)?
        ))
    };
    // The tool packs that are on: their skills in the Chief's own skills
    // folder, their MCP servers below (toolpacks.rs).
    let packs = crate::toolpacks::load(&paths.home);
    crate::toolpacks::sync_skills(&paths.home, &packs);
    write_if_changed(
        &paths.session.join(".mcp.json"),
        pretty(&mcp_json(setup, paths))?.as_bytes(),
    )?;
    // Private: they may hold the user's settings env (an API token).
    // cx-68uof: only the Chief's cmux MCP tools load with a turn; the rest
    // are denied, so Claude Code lists none of them (the deferred-tool list
    // it appends after our cached input was 3,365 tokens for 165 tools).
    let denied = cmux_tool_denials(&paths.session, &setup.env);
    let deny: Vec<&str> = TURN_DENIED_TOOLS
        .iter()
        .copied()
        .chain(TURN_DENIED_SERVERS)
        .chain(denied.iter().map(String::as_str))
        .collect();
    let mut settings = settings_json(setup, paths, &deny);
    for (key, value) in TURN_SETTINGS_ENV {
        settings["env"][key] = json!(value);
    }
    // git asks the tool packs' credential helpers for their hosts (toolpacks.rs).
    for (key, value) in crate::toolpacks::git_env(&packs, &paths.bin) {
        settings["env"][key] = json!(value);
    }
    settings["permissions"]["allow"] = json!(crate::approval::turn_allowed_tools());
    let settings = pretty(&settings)?;
    write_private(
        &paths.session.join(".claude").join("settings.json"),
        settings.as_bytes(),
    )?;
    // The same switches in the local project settings, which some harness
    // versions read for MCP approval instead of the shared file.
    write_private(
        &paths.session.join(".claude").join("settings.local.json"),
        settings.as_bytes(),
    )?;
    std::fs::create_dir_all(&paths.claude_config)?;
    write_if_changed(
        &paths.claude_config.join("settings.json"),
        pretty(&claude_settings())?.as_bytes(),
    )?;
    let chief = paths.bin.join("chief");
    write_if_changed(&chief, launcher(setup).as_bytes())?;
    std::fs::set_permissions(&chief, std::fs::Permissions::from_mode(0o755))?;
    let claude = paths.bin.join("claude");
    write_if_changed(&claude, CLAUDE_SHIM.as_bytes())?;
    std::fs::set_permissions(&claude, std::fs::Permissions::from_mode(0o755))?;
    // Each pack's CLI and git with the Chief's own login when it has one
    // (toolpacks.rs; the GitHub pack's gh as before).
    remove_if_present(&paths.bin.join("git-credential-chief"))?;
    let mut shims = crate::toolpacks::wrappers(&packs);
    shims.extend(crate::toolpacks::script_wrappers(&paths.home, &packs));
    // A pack turned off or removed takes its wrapper with it.
    for entry in std::fs::read_dir(&paths.bin)?.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let ours = std::fs::read_to_string(entry.path())
            .is_ok_and(|t| t.lines().take(3).any(|l| l.contains("(tool pack ")));
        if ours && !shims.iter().any(|(n, _)| *n == name) {
            remove_if_present(&entry.path())?;
        }
    }
    for (name, text) in shims {
        let shim = paths.bin.join(name);
        write_if_changed(&shim, text.as_bytes())?;
        std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o755))?;
    }
    Ok(())
}

/// Variables a Claude harness plants in its own process env that must not
/// reach a `claude` started from its shell: a subrouter account's Claude
/// home (`CLAUDE_CONFIG_DIR`, whose settings name a dead local base URL,
/// `http://127.0.0.1:1`), the harness's route and credentials, and the
/// nested-session markers.
pub const CLAUDE_SHIM_DROPPED_ENV: [&str; 8] = [
    "CLAUDE_CONFIG_DIR",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_CUSTOM_HEADERS",
    "CLAUDECODE",
    "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_CODE_SSE_PORT",
];

/// `bin/claude`, first on the PATH of the Chief's turn and subagent
/// sessions: a background agent a session starts with `claude` (no
/// terminal) runs the user's own Claude CLI (the next `claude` on PATH)
/// with the user's own config: `~/.claude/settings.json`, which Claude
/// Code re-reads while it runs, and the user's login. Without it such an
/// agent inherited the session's `CLAUDE_CONFIG_DIR` (a subrouter account's
/// home) and retried a dead base URL until it timed out (a103,
/// 2026-10-19). `CHIEF_KEEP_CLAUDE_ENV=1` keeps the inherited variables.
pub const CLAUDE_SHIM: &str = r#"#!/bin/sh
# optchat-chief: run the user's own Claude CLI with the user's own config
# (session_dir.rs CLAUDE_SHIM).
self_dir=$(cd "$(dirname "$0")" && pwd -P)
PATH=$(printf '%s' "$PATH" | tr ':' '
' | while IFS= read -r d; do
  [ -n "$d" ] && [ "$(cd "$d" 2>/dev/null && pwd -P)" != "$self_dir" ] && printf '%s:' "$d"
done)
PATH=${PATH%:}
export PATH
if [ "${CHIEF_KEEP_CLAUDE_ENV:-}" != 1 ]; then
  unset CLAUDE_CONFIG_DIR ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SSE_PORT
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "claude: not found on PATH (after the Chief's own bin)" >&2
  exit 127
fi
exec claude "$@"
"#;

/// Writes every subagent's working directory (section 9): `.mcp.json`
/// (zoom and date), the turn's project settings (no Task/Agent, no hooks,
/// no auto-memory) with `OPTCHAT_SUBAGENT=1` in the tools' env (the `chief`
/// launcher then refuses spawn and tell), and `text` (the subagent system
/// prompt) as AGENTS.md on a harness without MCP. On a Claude harness the
/// subagent preset carries it, or `set_claude_md` writes it per spawn.
pub fn write_subagent(paths: &Paths, setup: &SessionSetup, text: &str) -> io::Result<()> {
    let dir = &paths.subagent;
    std::fs::create_dir_all(dir.join(".claude"))?;
    let pretty = |v: &Value| -> io::Result<String> {
        Ok(format!(
            "{}\n",
            serde_json::to_string_pretty(v).map_err(io::Error::other)?
        ))
    };
    write_if_changed(
        &dir.join(".mcp.json"),
        pretty(&mcp_json_for(setup, paths, true))?.as_bytes(),
    )?;
    let mut sub = setup.clone();
    sub.env.insert(SUBAGENT_ENV.to_owned(), "1".to_owned());
    // Subagents load the user's own settings; no copy of its env here.
    sub.user_env.clear();
    let settings = pretty(&settings_json(&sub, paths, &SUBAGENT_DENIED_TOOLS))?;
    write_if_changed(
        &dir.join(".claude").join("settings.json"),
        settings.as_bytes(),
    )?;
    write_if_changed(
        &dir.join(".claude").join("settings.local.json"),
        settings.as_bytes(),
    )?;
    match setup.tools {
        Tools::Mcp => remove_if_present(&dir.join("AGENTS.md")),
        Tools::Cli(_) => write_if_changed(&dir.join("AGENTS.md"), text.as_bytes()),
    }
}

/// The subagent directory's AGENTS.md for a codex subagent beside a Claude
/// default (a spawn follows the turn's engine): Claude Code never reads it.
pub fn write_subagent_agents_md(paths: &Paths, text: &str) -> io::Result<()> {
    std::fs::create_dir_all(&paths.subagent)?;
    write_if_changed(&paths.subagent.join("AGENTS.md"), text.as_bytes())
}

/// Set in a subagent's tools' env: the `chief` launcher refuses spawn and
/// tell there (section 9: subagents get zoom and date, not spawn).
pub const SUBAGENT_ENV: &str = "OPTCHAT_SUBAGENT";

/// Writes the session directory's CLAUDE.md (Some) or removes it (None).
pub fn set_claude_md(session: &Path, text: Option<&str>) -> io::Result<()> {
    let path = session.join("CLAUDE.md");
    match text {
        Some(text) => {
            std::fs::create_dir_all(session)?;
            write_if_changed(&path, text.as_bytes())
        }
        None => remove_if_present(&path),
    }
}

/// Sets `promptCacheTtl` in the session directory's Claude Code project
/// settings (settings.json and settings.local.json; the other keys stay):
/// Claude Code's own cache marks then take the TTL of ours, since the API
/// refuses a 1h mark after a 5m one. Claude Code reads it at session start.
pub fn set_prompt_cache_ttl(session: &Path, ttl: crate::prompt::CacheTtl) -> io::Result<()> {
    set_session_cache(session, ttl, false)
}

/// `set_prompt_cache_ttl`, and with `ours` (the session's first message
/// carries our mark) DISABLE_PROMPT_CACHING=1: Claude Code then places none
/// of its own. It marks its two system blocks and the last two messages of
/// every request after a session's first (Claude Code 2.1.287, measured),
/// and the API takes at most 4, so our mark in the history makes 5 on the
/// session's second request. Without our mark, Claude Code's own stay.
pub fn set_session_cache(
    session: &Path,
    ttl: crate::prompt::CacheTtl,
    ours: bool,
) -> io::Result<()> {
    let dir = session.join(".claude");
    std::fs::create_dir_all(&dir)?;
    // cx-68uof: the cmux app's action tools, when they were not listed at
    // host start, are denied from the first turn that finds them.
    let late = pending_denials(&dir);
    for name in ["settings.json", "settings.local.json"] {
        let path = dir.join(name);
        let mut value: Value = std::fs::read_to_string(&path)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .filter(Value::is_object)
            .unwrap_or_else(|| json!({}));
        if let Some(late) = &late {
            if !value["permissions"]["deny"].is_array() {
                value["permissions"]["deny"] = json!([]);
            }
            if let Some(deny) = value["permissions"]["deny"].as_array_mut() {
                for rule in late {
                    if !deny.iter().any(|d| d == rule) {
                        deny.push(json!(rule));
                    }
                }
            }
        }
        value["promptCacheTtl"] = json!(ttl.as_str());
        // At 5 minutes also FORCE_PROMPT_CACHING_5M, which wins over every
        // other source of Claude Code's TTL (a subscription login marks 1h).
        if !value["env"].is_object() {
            value["env"] = json!({});
        }
        match ttl {
            crate::prompt::CacheTtl::FiveMinutes => {
                value["env"]["FORCE_PROMPT_CACHING_5M"] = json!("1");
            }
            crate::prompt::CacheTtl::OneHour => {
                if let Some(env) = value["env"].as_object_mut() {
                    env.remove("FORCE_PROMPT_CACHING_5M");
                }
            }
        }
        if ours {
            value["env"]["DISABLE_PROMPT_CACHING"] = json!("1");
        } else if let Some(env) = value["env"].as_object_mut() {
            env.remove("DISABLE_PROMPT_CACHING");
        }
        let text = format!(
            "{}\n",
            serde_json::to_string_pretty(&value).map_err(io::Error::other)?
        );
        write_if_changed(&path, text.as_bytes())?;
    }
    Ok(())
}

fn remove_if_present(path: &Path) -> io::Result<()> {
    match std::fs::remove_file(path) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
        _ => Ok(()),
    }
}

/// Replaces `path` through a temporary file, so a reader never sees half a file.
/// `write_if_changed` for a file that may hold a secret: written 0600 from
/// its first byte, and kept 0600.
pub fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    if std::fs::read(path).is_ok_and(|old| old == bytes) {
        return std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    static WRITES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = WRITES.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = path.with_extension(format!("tmp.{}.{n}", std::process::id()));
    let written = (|| {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp)?;
        file.write_all(bytes)?;
        std::fs::rename(&tmp, path)
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    written
}

pub fn write_if_changed(path: &Path, bytes: &[u8]) -> io::Result<()> {
    if std::fs::read(path).is_ok_and(|old| old == bytes) {
        return Ok(());
    }
    // Unique per write: two threads of one process (codex compactor nodes
    // sharing one directory) may write the same file at once.
    static WRITES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = WRITES.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = path.with_extension(format!("tmp.{}.{n}", std::process::id()));
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, path)
}
