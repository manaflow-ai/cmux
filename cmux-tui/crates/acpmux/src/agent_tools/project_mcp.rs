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
//! allow by name, and every server when a `managed-mcp.json` takes over or a managed policy holds
//! an MCP rule this does not model (or cannot be read as JSON and names MCP), are left alone, as
//! are servers of another type (`http`, `sse`): they read no checkout. The managed policy is read
//! from every source Claude reads (cmux-tui `claude_plugin::policy_files`).

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
        // Claude's home: `CLAUDE_CONFIG_DIR`, else `.claude` under the launch's `HOME`. Both the
        // profile's `HOME` and acpmux's own count: a server either one disables is never wrapped.
        let mut homes: Vec<PathBuf> =
            crate::harness_config::config_dir("CLAUDE_CONFIG_DIR", ".claude", &[env])
                .into_iter()
                .collect();
        let configured = env.get("CLAUDE_CONFIG_DIR").is_some_and(|dir| !dir.is_empty());
        if let Some(profile_home) = env.get("HOME").filter(|home| !configured && !home.is_empty()) {
            let profile = Path::new(profile_home).join(".claude");
            if !homes.contains(&profile) {
                homes.push(profile);
            }
        }
        let managed_dir = if cfg!(target_os = "macos") {
            Path::new("/Library/Application Support/ClaudeCode")
        } else {
            Path::new("/etc/claude-code")
        };
        // Every place Claude reads policy from (as cmux-tui `claude_plugin::policy_files`):
        // managed settings and their drop-ins, macOS managed preferences, and each home's cached
        // remote settings.
        let mut managed = vec![managed_dir.join("managed-settings.json")];
        if let Ok(entries) = std::fs::read_dir(managed_dir.join("managed-settings.d")) {
            let mut dropins: Vec<PathBuf> = entries.flatten().map(|entry| entry.path()).collect();
            dropins.sort();
            managed.extend(dropins);
        }
        if cfg!(target_os = "macos") {
            let preferences = Path::new("/Library/Managed Preferences");
            managed.push(preferences.join("com.anthropic.claudecode.plist"));
            let user = env.get("USER").cloned().or_else(|| std::env::var("USER").ok());
            if let Some(user) = user.filter(|user| !user.is_empty()) {
                managed.push(preferences.join(user).join("com.anthropic.claudecode.plist"));
            }
        }
        managed.extend(homes.iter().map(|home| home.join("remote-settings.json")));
        let mut configs = Vec::new();
        let mut settings = managed.clone();
        for home in homes {
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
    let mut managed = Vec::new();
    for file in &claude.managed {
        let Ok(data) = std::fs::read(file) else { continue };
        match serde_json::from_slice::<Value>(&data) {
            // A policy this does not model (only managed servers, say) may stop what Claude starts:
            // nothing is wrapped.
            Ok(policy) if unmodeled_mcp_policy(&policy) => return out,
            Ok(policy) => managed.push(policy),
            // A policy that is not JSON (a property list) and names MCP at all: nothing is wrapped.
            Err(_) if data.windows(3).any(|window| window.eq_ignore_ascii_case(b"mcp")) => {
                return out;
            }
            Err(_) => {}
        }
    }
    let mut disabled: BTreeSet<String> = settings.iter().flat_map(disabled_in).collect();
    // Every parent's project settings too, also above the checkout, whether Claude reads them in
    // a chat below or not: a server any of them disables is never wrapped.
    for folder in cwd.ancestors() {
        for file in ["settings.json", "settings.local.json"] {
            disabled.extend(read(&folder.join(".claude").join(file)).iter().flat_map(disabled_in));
        }
    }
    for config in claude.configs.iter().filter_map(|file| read(file)) {
        for folder in cwd.ancestors() {
            let Some(project) = folder.to_str().and_then(|key| config.get("projects")?.get(key))
            else {
                continue;
            };
            disabled.extend(disabled_in(project));
            // A local-scope server (`projects.<dir>.mcpServers`) of a project server's name is
            // the one Claude starts: the project's entry is left alone, never wrapped over it.
            let local = project.get("mcpServers").and_then(Value::as_object);
            disabled.extend(local.into_iter().flat_map(|servers| servers.keys().cloned()));
        }
    }
    // A name a closer folder declares is its own, whatever its type: a parent's server of the
    // same name never takes its place.
    let mut declared = BTreeSet::new();
    for folder in folders {
        let Some(project) = read(&folder.join(".mcp.json")) else { continue };
        let Some(servers) = project.get("mcpServers").and_then(Value::as_object) else { continue };
        for (name, server) in servers {
            if !declared.insert(name.clone()) || disabled.contains(name) {
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
            let env = server.get("env").cloned().unwrap_or_else(|| json!({}));
            out.insert(
                name.clone(),
                json!({"type": "stdio", "command": cmux, "args": wrapper, "env": env}),
            );
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
    value
        .get("disabledMcpjsonServers")
        .and_then(Value::as_array)
        .map(|names| names.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default()
}

/// The managed policy lets server `name` with command line `line` run wrapped: no
/// `deniedMcpServers` entry names it or its command, and an `allowedMcpServers` list, if any,
/// names it. An allowance by command alone does not do: Claude would judge the wrapper's command
/// (`cmux-tui repo mcp-lazy ...`) against it and refuse the server, so it is left to Claude.
fn permits(policy: &Value, name: &str, line: &[&str]) -> bool {
    let listed = |key: &str, by_command: bool| {
        policy.get(key).and_then(Value::as_array).map(|entries| {
            entries.iter().any(|entry| {
                entry.get("serverName").and_then(Value::as_str) == Some(name)
                    || (by_command
                        && entry.get("serverCommand").and_then(Value::as_array).is_some_and(
                            |words| {
                                words.iter().map(Value::as_str).eq(line.iter().map(|w| Some(*w)))
                            },
                        ))
            })
        })
    };
    listed("deniedMcpServers", true) != Some(true)
        && listed("allowedMcpServers", false) != Some(false)
}

/// Whether `policy` holds an MCP rule beyond the allow and deny lists [`permits`] reads.
fn unmodeled_mcp_policy(policy: &Value) -> bool {
    policy.as_object().is_some_and(|keys| {
        keys.keys().any(|key| {
            key.to_ascii_lowercase().contains("mcp")
                && key != "allowedMcpServers"
                && key != "deniedMcpServers"
                && key != "disabledMcpjsonServers"
                && key != "enabledMcpjsonServers"
                && key != "enableAllProjectMcpServers"
        })
    })
}

#[cfg(test)]
#[path = "project_mcp_tests.rs"]
mod tests;
