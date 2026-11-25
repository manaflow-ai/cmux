//! Which of the person's own stdio MCP servers a chat reaches through the daemon's pool
//! (`mcp_pool.rs`) instead of starting its own copy.
//!
//! Only servers the person names share: the setting `agents.mcpServers.share` (`true` or `"*"`
//! for every one, or a list of names) or the profile's or daemon's `ACPMUX_MCP_SHARE` (`*`, or
//! names with commas; `0` for none). Default: none, every server runs as before. A server that
//! keeps state per client (a working folder it is told, a login per chat) is better left out.
//!
//! The entry each harness would start is read from its own config, with its own precedence:
//! Claude Code's local scope (`projects.<dir>.mcpServers` of `.claude.json`), then the project's
//! `.mcp.json` from the chat's folder up (only the servers Claude would start,
//! `project_mcp::started`), then the user scope (`mcpServers` of `.claude.json`); Codex's
//! `[mcp_servers.<name>]` of `$CODEX_HOME/config.toml`, enabled. The chat gets an entry of the
//! same name that runs `acpmux mcp-shim`: Claude Code's `--mcp-config` entry replaces the one of
//! its own config, and Codex merges the ACP entry's `command` and `args` into the person's.
//! Nothing is removed or turned off: a server this cannot share exactly as the harness would
//! start it (another type than stdio, a `${VAR}` the harness expands, a name a managed policy
//! decides, a disabled one) is left to the harness, and so is every server of a chat whose
//! daemon has no pool.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use serde_json::{Map, Value, json};

use super::project_mcp;
use crate::mcp_pool::Spec;

/// The setting naming the person's servers that share.
pub const SHARE_SETTING: &str = "agents.mcpServers.share";
/// The env naming them, over the setting: `*`, names with commas, or `0`.
pub const SHARE_ENV: &str = "ACPMUX_MCP_SHARE";

/// Which servers share.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Share {
    None,
    All,
    Names(BTreeSet<String>),
}

impl Share {
    fn takes(&self, name: &str) -> bool {
        match self {
            Share::None => false,
            Share::All => true,
            Share::Names(names) => names.contains(name),
        }
    }

    fn from_list(text: &str) -> Self {
        let text = text.trim();
        match text {
            "" | "0" | "false" => Share::None,
            "*" | "1" | "true" => Share::All,
            _ => Share::Names(
                text.split(',')
                    .map(str::trim)
                    .filter(|n| !n.is_empty())
                    .map(str::to_owned)
                    .collect(),
            ),
        }
    }

    /// The profile's env, else the daemon's, else the settings `text`.
    pub fn of(env: &BTreeMap<String, String>, settings: Option<&str>) -> Self {
        if let Some(v) = env.get(SHARE_ENV).cloned().or_else(|| std::env::var(SHARE_ENV).ok()) {
            return Share::from_list(&v);
        }
        let value = settings
            .and_then(crate::user_settings::document)
            .and_then(|doc| crate::user_settings::value(&doc, SHARE_SETTING));
        match value {
            Some(Value::Bool(true)) => Share::All,
            Some(Value::String(s)) => Share::from_list(&s),
            Some(Value::Array(names)) => {
                Share::Names(names.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            }
            _ => Share::None,
        }
    }
}

fn expands(text: &str) -> bool {
    text.contains("${")
}

/// The pool spec of a stdio entry `server` (`{command, args, env}` as JSON) the harness would
/// start in `cwd`, or `None` when it is not one this can start the same way.
fn spec_of(
    command: &str,
    args: &[String],
    env: Option<&Map<String, Value>>,
    cwd: &Path,
    profile_env: &BTreeMap<String, String>,
) -> Option<Spec> {
    if expands(command) || args.iter().any(|a| expands(a)) {
        return None;
    }
    let mut spec_env = BTreeMap::new();
    for (k, v) in env.into_iter().flatten() {
        let v = v.as_str()?;
        if expands(v) {
            return None;
        }
        spec_env.insert(k.clone(), v.to_owned());
    }
    // The harness finds a bare command on its own `PATH`: the server does too.
    if let Some(path) = profile_env.get("PATH").filter(|_| !spec_env.contains_key("PATH")) {
        spec_env.insert("PATH".to_owned(), path.clone());
    }
    Some(Spec {
        command: command.to_owned(),
        args: args.to_vec(),
        env: spec_env,
        cwd: Some(cwd.to_path_buf()),
    })
}

/// The `--mcp-config` entries for a Claude Code chat in `cwd` with profile env `env`: each shared
/// server of the person's, under its own name, as an `acpmux mcp-shim` entry. `taken`: names the
/// chat's config already holds (cmux's own servers), never replaced.
pub fn claude(
    env: &BTreeMap<String, String>,
    cwd: &Path,
    taken: &BTreeSet<String>,
    home: &Path,
) -> Map<String, Value> {
    let share = Share::of(env, crate::user_settings::text().as_deref());
    if share == Share::None || !crate::mcp_pool::listening() {
        return Map::new();
    }
    let claude = project_mcp::Claude::of(env, cwd);
    claude_with(&claude, &share, env, cwd, taken, |spec| {
        crate::mcp_pool::register(home, spec).map(
            |(program, args)| json!({"type": "stdio", "command": program, "args": args, "env": {}}),
        )
    })
}

/// [`claude`] over `claude`'s files, each entry made by `entry` from its spec.
pub fn claude_with(
    claude: &project_mcp::Claude,
    share: &Share,
    env: &BTreeMap<String, String>,
    cwd: &Path,
    taken: &BTreeSet<String>,
    entry: impl Fn(&Spec) -> Option<Value>,
) -> Map<String, Value> {
    let mut out = Map::new();
    if claude.managed_mcp.exists() {
        return out;
    }
    let Some(managed) = project_mcp::managed_policies(claude) else { return out };
    let real = cwd.canonicalize().unwrap_or_else(|_| cwd.to_path_buf());
    let configs: Vec<Value> =
        claude.configs.iter().filter_map(|f| project_mcp::read_json(f)).collect();
    // The project entry of the chat's folder (or the closest parent Claude keeps one for).
    let project = |config: &Value| -> Option<Value> {
        real.ancestors().find_map(|folder| {
            folder.to_str().and_then(|k| config.get("projects")?.get(k)).cloned()
        })
    };
    let projects: Vec<Value> = configs.iter().filter_map(project).collect();
    // `/mcp disable` lists a user or local server here.
    let disabled: BTreeSet<String> = projects
        .iter()
        .flat_map(|p| {
            p.get("disabledMcpServers").and_then(Value::as_array).cloned().unwrap_or_default()
        })
        .filter_map(|v| v.as_str().map(str::to_owned))
        .collect();
    // Claude's precedence: local, then project, then user. The first a name has is the one.
    let mut candidates: Vec<(String, Value)> = Vec::new();
    for p in &projects {
        for (name, server) in p.get("mcpServers").and_then(Value::as_object).into_iter().flatten() {
            candidates.push((name.clone(), server.clone()));
        }
    }
    let folders: Vec<&Path> = real.ancestors().collect();
    for (name, server, _) in project_mcp::started(&real, claude, &folders) {
        candidates.push((name, server));
    }
    for config in &configs {
        for (name, server) in
            config.get("mcpServers").and_then(Value::as_object).into_iter().flatten()
        {
            candidates.push((name.clone(), server.clone()));
        }
    }
    let mut seen = BTreeSet::new();
    for (name, server) in candidates {
        if !seen.insert(name.clone()) || taken.contains(&name) || !share.takes(&name) {
            continue;
        }
        if disabled.contains(&name) {
            continue;
        }
        let Some(line) = project_mcp::stdio_line(&server) else { continue };
        if !project_mcp::permitted(&managed, &name, &line) {
            continue;
        }
        let Some(spec) =
            spec_of(&line[0], &line[1..], server.get("env").and_then(Value::as_object), &real, env)
        else {
            continue;
        };
        if let Some(e) = entry(&spec) {
            out.insert(name, e);
        }
    }
    out
}

/// The ACP `mcpServers` entries for a Codex chat in `cwd`: each shared enabled stdio server of
/// the person's `config.toml`, under its own name, as an `acpmux mcp-shim` entry. `taken`: the
/// names the chat's servers already hold.
pub fn codex(
    env: &BTreeMap<String, String>,
    cwd: &Path,
    taken: &BTreeSet<String>,
    home: &Path,
) -> Vec<Value> {
    let share = Share::of(env, crate::user_settings::text().as_deref());
    if share == Share::None || !crate::mcp_pool::listening() {
        return Vec::new();
    }
    let Some(dir) = crate::harness_config::config_dir("CODEX_HOME", ".codex", &[env]) else {
        return Vec::new();
    };
    let Ok(text) = std::fs::read_to_string(dir.join("config.toml")) else { return Vec::new() };
    codex_with(&text, &share, env, cwd, taken, |spec| {
        crate::mcp_pool::register(home, spec)
            .map(|(program, args)| (program.to_string_lossy().into_owned(), args))
    })
}

/// [`codex`] over config `text`; `entry` gives each spec's `(command, args)`.
pub fn codex_with(
    text: &str,
    share: &Share,
    env: &BTreeMap<String, String>,
    cwd: &Path,
    taken: &BTreeSet<String>,
    entry: impl Fn(&Spec) -> Option<(String, Vec<String>)>,
) -> Vec<Value> {
    let Ok(table) = text.parse::<toml::Table>() else { return Vec::new() };
    let Some(servers) = table.get("mcp_servers").and_then(toml::Value::as_table) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for (name, server) in servers {
        if taken.contains(name) || !share.takes(name) {
            continue;
        }
        let Some(server) = server.as_table() else { continue };
        // The ACP entry turns it on: a server the person turned off stays theirs.
        if server.get("enabled").and_then(toml::Value::as_bool) == Some(false) {
            continue;
        }
        if server.contains_key("url") {
            continue;
        }
        let Some(command) = server.get("command").and_then(toml::Value::as_str) else { continue };
        let args: Vec<String> = server
            .get("args")
            .and_then(toml::Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|a| a.as_str().map(str::to_owned))
            .collect();
        let mut server_env = Map::new();
        if let Some(table) = server.get("env").and_then(toml::Value::as_table) {
            for (k, v) in table {
                let Some(v) = v.as_str() else { continue };
                server_env.insert(k.clone(), json!(v));
            }
        }
        // `env_vars`: names Codex passes on from its own env.
        for var in server.get("env_vars").and_then(toml::Value::as_array).into_iter().flatten() {
            let Some(var) = var.as_str() else { continue };
            let v = env.get(var).cloned().or_else(|| std::env::var(var).ok());
            if let Some(v) = v.filter(|_| !server_env.contains_key(var)) {
                server_env.insert(var.to_owned(), json!(v));
            }
        }
        let folder = server.get("cwd").and_then(toml::Value::as_str).map(Path::new).unwrap_or(cwd);
        let Some(spec) = spec_of(command, &args, Some(&server_env), folder, env) else { continue };
        if let Some((command, args)) = entry(&spec) {
            out.push(json!({"name": name, "command": command, "args": args, "env": []}));
        }
    }
    out
}

#[cfg(test)]
#[path = "shared_servers_tests.rs"]
mod tests;
