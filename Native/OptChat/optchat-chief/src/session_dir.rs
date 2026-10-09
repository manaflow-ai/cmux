//! The turn sessions' working directory, written once per host start: every
//! turn runs in it, so the harness sees the same CLAUDE.md, settings and MCP
//! servers each time (section 7.2: byte-identical prompt and tools).
//!
//! A turn should see only what this directory holds (section 7: a fresh call,
//! nothing carried over; section 7.2: MASTER, then VIEW_DOC, then the
//! instructions at the end). The turn sessions' acpmux preset points
//! `CLAUDE_CONFIG_DIR` at `optchat/claude`, whose settings turn auto-memory
//! off and hold no hooks, so the user's own ~/.claude/CLAUDE.md, settings,
//! hooks and project memory never reach a turn. What stays outside our
//! control: Claude Code's own system prompt (with its date and environment
//! lines) and any machine-wide managed settings.
//!
//! Deviation: acpmux drops `mcpServers` from `session/new` (it always starts
//! the agent with `[]`), so mux/host's way of passing MCP servers reaches no
//! harness. The servers go in the directory's `.mcp.json` instead, enabled
//! by the project settings, which Claude Code harnesses read.

use std::collections::BTreeMap;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use serde_json::{Value, json};

use crate::paths::Paths;
use crate::prompt::{Tools, system_text};

/// What the session directory is made of.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionSetup {
    /// This executable (absolute), which serves `mcp` and the `chief` launcher.
    pub exe: String,
    /// `CMUX_MCP_COMMAND`: the cmux binary whose `mcp serve` is the cmux MCP server.
    pub cmux_mcp: Option<String>,
    /// Env the turn's tools see (MUX_HOME, CMUX_SOCKET_PATH, ACPMUX_*, PATH).
    pub env: BTreeMap<String, String>,
    /// The user's instructions file, read at host start (section 7.2).
    pub instructions: Option<String>,
    /// How the turn reaches its memory tools (the harness family).
    pub tools: crate::prompt::Tools,
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
    servers.insert(
        "optchat".into(),
        json!({"type": "stdio", "command": setup.exe, "args": args, "env": {}}),
    );
    if let Some(cmux) = &setup.cmux_mcp {
        servers.insert(
            "cmux".into(),
            json!({"type": "stdio", "command": cmux, "args": ["mcp", "serve"], "env": {}}),
        );
    }
    json!({"mcpServers": servers})
}

/// The project settings: the MCP servers above enabled, the tools' env with
/// the launcher directory first on PATH, and `deny` (Claude Code's
/// subagents always) denied, which takes those tools out of the list.
pub fn settings_json(setup: &SessionSetup, paths: &Paths, deny: &[&str]) -> Value {
    let mut names = vec!["optchat"];
    if setup.cmux_mcp.is_some() {
        names.push("cmux");
    }
    let mut env: serde_json::Map<String, Value> = setup
        .env
        .iter()
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
/// tokens bare). A turn keeps Bash, Read, Edit, Write, WebFetch, WebSearch,
/// and ToolSearch (it loads the MCP tools on demand); work beyond those goes
/// to subagents. A tool a later Claude Code adds is offered until it is
/// listed here.
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

/// The env of the turn sessions' acpmux preset.
pub fn isolation_env(paths: &Paths) -> BTreeMap<String, String> {
    let mut env = BTreeMap::new();
    env.insert(
        "CLAUDE_CONFIG_DIR".to_owned(),
        paths.claude_config.display().to_string(),
    );
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
    let agents = system_text(setup.instructions.as_deref(), &Tools::Cli(chief));
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
    write_if_changed(
        &paths.session.join(".mcp.json"),
        pretty(&mcp_json(setup, paths))?.as_bytes(),
    )?;
    let settings = pretty(&settings_json(setup, paths, &TURN_DENIED_TOOLS))?;
    write_if_changed(
        &paths.session.join(".claude").join("settings.json"),
        settings.as_bytes(),
    )?;
    // The same switches in the local project settings, which some harness
    // versions read for MCP approval instead of the shared file.
    write_if_changed(
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
    Ok(())
}

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
    let dir = session.join(".claude");
    std::fs::create_dir_all(&dir)?;
    for name in ["settings.json", "settings.local.json"] {
        let path = dir.join(name);
        let mut value: Value = std::fs::read_to_string(&path)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .filter(Value::is_object)
            .unwrap_or_else(|| json!({}));
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

#[cfg(test)]
mod tests {
    use super::*;

    fn setup() -> SessionSetup {
        let mut env = BTreeMap::new();
        env.insert("MUX_HOME".to_string(), "/h".to_string());
        env.insert("PATH".to_string(), "/usr/bin".to_string());
        SessionSetup {
            exe: "/x/optchat-chief".into(),
            cmux_mcp: Some("/x/cmux".into()),
            env,
            instructions: None,
            tools: crate::prompt::Tools::Mcp,
        }
    }

    #[test]
    fn files_are_byte_stable_across_writes() {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths::new(dir.path());
        paths.create().unwrap();
        write(&paths, &setup()).unwrap();
        let first = std::fs::read(paths.session.join("CLAUDE.md")).unwrap();
        let modified = std::fs::metadata(paths.session.join("CLAUDE.md"))
            .unwrap()
            .modified()
            .unwrap();
        write(&paths, &setup()).unwrap();
        assert_eq!(
            std::fs::read(paths.session.join("CLAUDE.md")).unwrap(),
            first
        );
        assert_eq!(
            std::fs::metadata(paths.session.join("CLAUDE.md"))
                .unwrap()
                .modified()
                .unwrap(),
            modified,
            "an unchanged file is not rewritten"
        );
        assert_eq!(first, crate::prompt::claude_md(None).as_bytes());
        let mcp: Value =
            serde_json::from_slice(&std::fs::read(paths.session.join(".mcp.json")).unwrap())
                .unwrap();
        assert_eq!(mcp["mcpServers"]["optchat"]["args"][0], "mcp");
        assert_eq!(mcp["mcpServers"]["cmux"]["args"], json!(["mcp", "serve"]));
        // Audit round 2: Claude Code's own subagents would stream their
        // steps into the turn's events (section 9: they stay out of the log);
        // the Chief starts agents with `chief agents` instead.
        let settings: Value = serde_json::from_slice(
            &std::fs::read(paths.session.join(".claude").join("settings.json")).unwrap(),
        )
        .unwrap();
        // Audit round 3, M3: acpmux keeps questions and plan approval for a
        // human under every policy, and nobody answers them in a turn.
        assert_eq!(settings["permissions"]["deny"], json!(TURN_DENIED_TOOLS));
        // Audit round 3, M6: turn transcripts are kept a short while only.
        let user: Value = serde_json::from_slice(
            &std::fs::read(paths.claude_config.join("settings.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(user["cleanupPeriodDays"], TURN_TRANSCRIPT_DAYS);
        // Live check 2026-10-04: under `sr claude proxy` only project
        // settings are read (sr resets CLAUDE_CONFIG_DIR to ~/.claude).
        assert_eq!(settings["cleanupPeriodDays"], TURN_TRANSCRIPT_DAYS);
        assert_eq!(settings["disableAllHooks"], true);
        assert_eq!(settings["autoMemoryEnabled"], false);
        let launcher = std::fs::read_to_string(paths.bin.join("chief")).unwrap();
        assert!(launcher.contains("MUX_HOME=/h; export MUX_HOME\n"));
        assert!(launcher.ends_with("exec /x/optchat-chief \"$@\"\n"));
    }

    #[test]
    fn quoting() {
        assert_eq!(shell_quote("/a/b"), "/a/b");
        assert_eq!(shell_quote("a b'c"), "'a b'\\''c'");
    }
}
