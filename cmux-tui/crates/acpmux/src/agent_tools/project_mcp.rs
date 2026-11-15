//! A project's own MCP servers for a Claude Code start at a repository's head (`repo_sync.rs`).
//! Claude starts each stdio server of a `.mcp.json` in the chat's folder or a parent outside the
//! tool gate, and holds its first turn until each answers `initialize`: on a checkout still
//! filling, they would run on a partial tree. Each such server goes into the chat's
//! `--mcp-config` under its own name, which replaces the project's entry, as the same command
//! under `cmux repo mcp-lazy DIR --`: that answers at once and starts the server once the whole
//! checkout is in (cmux-tui `repo_mcp_lazy.rs`, cmuxterm-hq goals/cloud-no-network-wait.md).
//!
//! Only a server Claude would start itself is wrapped, so nothing runs that would not have run.
//! Claude Code 2.1.305 under `-p` starts every project server that no settings file and no
//! `projects.<dir>` of `.claude.json` lists in `disabledMcpjsonServers`, approved or not
//! (measured 2026-11-15: a server in no list, and one left out of `enabledMcpjsonServers`, both
//! ran; a disabled one did not). A disabled server, one the managed policy denies or does not
//! allow, and every server when a `managed-mcp.json` takes over, are left alone. So are servers
//! of another type (`http`, `sse`): they read no checkout.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

/// Where Claude Code reads what decides whether it starts a project server.
#[derive(Debug, Clone, Default)]
pub struct Claude {
    /// `.claude.json` files whose `projects.<dir>.disabledMcpjsonServers` count.
    pub configs: Vec<PathBuf>,
    /// Settings files: the managed ones, the Claude home's and the chat folder's.
    pub settings: Vec<PathBuf>,
    /// The managed settings, whose `allowedMcpServers` and `deniedMcpServers` count.
    pub managed: Vec<PathBuf>,
    /// `managed-mcp.json`: while it exists, Claude starts no project server.
    pub managed_mcp: PathBuf,
}

impl Claude {
    /// Claude Code's files for a start with env `env` in `cwd`.
    pub fn of(env: &BTreeMap<String, String>, cwd: &Path) -> Self {
        let home = crate::harness_config::config_dir("CLAUDE_CONFIG_DIR", ".claude", &[env]);
        let managed_dir = if cfg!(target_os = "macos") {
            Path::new("/Library/Application Support/ClaudeCode")
        } else {
            Path::new("/etc/claude-code")
        };
        let managed = vec![managed_dir.join("managed-settings.json")];
        let mut configs = Vec::new();
        let mut settings = managed.clone();
        if let Some(home) = home {
            // `~/.claude.json` beside the default home, else `$CLAUDE_CONFIG_DIR/.claude.json`.
            configs.push(home.join(".claude.json"));
            if home.file_name().is_some_and(|name| name == ".claude")
                && let Some(parent) = home.parent()
            {
                configs.push(parent.join(".claude.json"));
            }
            settings.push(home.join("settings.json"));
        }
        settings.push(cwd.join(".claude").join("settings.json"));
        settings.push(cwd.join(".claude").join("settings.local.json"));
        Self { configs, settings, managed, managed_mcp: managed_dir.join("managed-mcp.json") }
    }
}

/// The `--mcp-config` entries for the project servers Claude would start in `cwd` from a folder
/// still `filling`, from `cwd` up: each `{command, args, env}` as `cmux repo mcp-lazy DIR --
/// command args...` run by `cmux`, DIR the chat's folder, where Claude would start it (2.1.305
/// ignores an entry's `cwd`). A closer folder's server wins a name, as in Claude. `cwd` counts
/// with its links resolved, as Claude resolves it: a linked chat folder's parents are the real
/// folder's.
pub fn wrapped(
    cwd: &Path,
    claude: &Claude,
    cmux: &Path,
    filling: impl Fn(&Path) -> bool,
) -> Map<String, Value> {
    let real = cwd.canonicalize();
    let cwd = real.as_deref().unwrap_or(cwd);
    let mut out = Map::new();
    let folders: Vec<&Path> = cwd.ancestors().take_while(|folder| filling(folder)).collect();
    if folders.is_empty() || claude.managed_mcp.exists() {
        return out;
    }
    let settings: Vec<Value> = claude.settings.iter().filter_map(|file| read(file)).collect();
    let managed: Vec<Value> = claude.managed.iter().filter_map(|file| read(file)).collect();
    let mut disabled: BTreeSet<String> = settings.iter().flat_map(disabled_in).collect();
    // A parent's project settings too, whether Claude reads them in a chat below or not: a
    // server any of them disables is never wrapped.
    for folder in &folders {
        for file in ["settings.json", "settings.local.json"] {
            disabled.extend(read(&folder.join(".claude").join(file)).iter().flat_map(disabled_in));
        }
    }
    for config in claude.configs.iter().filter_map(|file| read(file)) {
        for folder in cwd.ancestors() {
            let Some(project) = folder.to_str().and_then(|key| config["projects"].get(key)) else {
                continue;
            };
            disabled.extend(disabled_in(project));
        }
    }
    for folder in folders {
        let Some(project) = read(&folder.join(".mcp.json")) else { continue };
        let Some(servers) = project.get("mcpServers").and_then(Value::as_object) else { continue };
        for (name, server) in servers {
            if out.contains_key(name) || disabled.contains(name) {
                continue;
            }
            let Some(command) = server.get("command").and_then(Value::as_str) else { continue };
            if server.get("type").and_then(Value::as_str).is_some_and(|kind| kind != "stdio") {
                continue;
            }
            let args: Vec<&str> = server
                .get("args")
                .and_then(Value::as_array)
                .map(|args| args.iter().filter_map(Value::as_str).collect())
                .unwrap_or_default();
            let line: Vec<&str> = std::iter::once(command).chain(args.iter().copied()).collect();
            if !managed.iter().all(|policy| permits(policy, name, &line)) {
                continue;
            }
            let mut wrapper = vec!["repo".to_owned(), "mcp-lazy".to_owned()];
            wrapper.push(cwd.to_string_lossy().into_owned());
            wrapper.push("--".to_owned());
            wrapper.extend(line.iter().map(|word| (*word).to_owned()));
            let mut entry = json!({"type": "stdio", "command": cmux, "args": wrapper});
            entry["env"] = server.get("env").cloned().unwrap_or_else(|| json!({}));
            out.insert(name.clone(), entry);
        }
    }
    out
}

/// The program that runs `cmux-tui repo mcp-lazy`: this binary when it is the multicall
/// `cmux-tui` (acpmux runs as `cmux-tui acp`), else a `cmux-tui` or `cmux` beside it.
pub fn cmux_program() -> Option<PathBuf> {
    let own = crate::self_command::SelfCommand::current().ok()?;
    if !own.prefix.is_empty() {
        return Some(own.exe);
    }
    let parent = own.exe.parent()?;
    ["cmux-tui", "cmux"].iter().map(|name| parent.join(name)).find(|path| path.is_file())
}

/// Whether the checkout at `folder` still fills (its sync barrier is not open).
#[cfg(unix)]
pub fn filling(folder: &Path) -> bool {
    use cmux_git::sync_barrier::{Probe, probe};
    !matches!(probe(folder), Ok(Probe::Ready(_)))
}

#[cfg(not(unix))]
pub fn filling(_folder: &Path) -> bool {
    false
}

fn read(file: &Path) -> Option<Value> {
    serde_json::from_slice(&std::fs::read(file).ok()?).ok()
}

fn disabled_in(value: &Value) -> Vec<String> {
    value["disabledMcpjsonServers"]
        .as_array()
        .map(|names| names.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default()
}

/// The managed policy lets server `name` with command line `line` run: no `deniedMcpServers`
/// entry names it, and an `allowedMcpServers` list, if any, does.
fn permits(policy: &Value, name: &str, line: &[&str]) -> bool {
    let listed = |key: &str| {
        policy[key].as_array().map(|entries| {
            entries.iter().any(|entry| {
                entry["serverName"].as_str() == Some(name)
                    || entry["serverCommand"].as_array().is_some_and(|words| {
                        words.iter().map(Value::as_str).eq(line.iter().map(|w| Some(*w)))
                    })
            })
        })
    };
    listed("deniedMcpServers") != Some(true) && listed("allowedMcpServers") != Some(false)
}

#[cfg(test)]
#[path = "project_mcp_tests.rs"]
mod tests;
