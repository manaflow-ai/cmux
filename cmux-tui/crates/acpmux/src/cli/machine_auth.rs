//! `acpmux machine-auth` (`cmux-tui acp --json machine-auth` on a Cloud machine; the Mac's
//! `cmux cloud machine-auth --machine vm_…` runs it there): how the agents acpmux starts on this
//! machine reach models, and whether the machine holds any provider login.
//!
//! It reads the env the running daemon recorded about itself at startup (`ENV_FILE`, written by
//! the `daemon.lock` holder: keys as their state only, never a value), adds the machine's model route the way a spawn does (`cloud_model_plane.rs`), and
//! looks for the login files Claude Code and Codex read. It prints names, verdicts and
//! credential-free base URLs only, never a value of a key or a token.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::cloud_model_plane::{self, PLACEHOLDER, PLANE_FILE};

/// Provider credential variables that mean the agent would not use the edge's placeholder route.
const CREDENTIAL_VARS: [&str; 5] = [
    "CLAUDE_CODE_OAUTH_TOKEN",
    "ANTHROPIC_AUTH_TOKEN",
    "CODEX_API_KEY",
    "CODEX_ACCESS_TOKEN",
    "CHATGPT_ACCESS_TOKEN",
];

/// The names the report reads from the daemon's env.
fn watched() -> impl Iterator<Item = &'static str> {
    cloud_model_plane::KEYS.into_iter().chain(CREDENTIAL_VARS)
}

/// Login files in the daemon user's HOME, as `(relative path, what reads it)`.
const LOGIN_FILES: [(&str, &str); 2] =
    [(".claude/.credentials.json", "claude"), (".codex/auth.json", "codex")];

/// Image-managed route files (bake.ts `agentModelRouteFiles`); reported, not required.
const MANAGED: [(&str, &str); 2] = [
    ("/etc/claude-code/managed-settings.json", "claude"),
    ("/etc/codex/managed_config.toml", "codex"),
];

/// `scheme://host[:port]/path` of a URL, without userinfo, query or fragment.
pub fn safe_url(url: &str) -> String {
    let (scheme, rest) = url.split_once("://").unwrap_or(("", url));
    let rest = rest.split(['?', '#']).next().unwrap_or_default();
    let (authority, path) =
        rest.find('/').and_then(|i| rest.split_at_checked(i)).unwrap_or((rest, ""));
    let host = authority.rsplit('@').next().unwrap_or_default();
    if scheme.is_empty() { format!("{host}{path}") } else { format!("{scheme}://{host}{path}") }
}

fn host_of(url: &str) -> String {
    let safe = safe_url(url);
    let rest = safe.split_once("://").map_or(safe.as_str(), |(_, r)| r);
    rest.split('/').next().unwrap_or_default().split(':').next().unwrap_or_default().to_owned()
}

/// A key's verdict: `placeholder`, `missing`, or `other` (a real value: never printed).
fn key_state(value: Option<&String>) -> &'static str {
    match value.map(String::as_str) {
        None | Some("") => "missing",
        Some(PLACEHOLDER) => "placeholder",
        Some(_) => "other",
    }
}

/// The env a spawn gives an agent: the daemon's watched names, then the machine's route where absent.
/// `(value, source)` per name; source is `daemon` or `model_plane`.
pub fn agent_env(
    daemon: &BTreeMap<String, String>,
    plane: &BTreeMap<String, String>,
) -> BTreeMap<String, (String, &'static str)> {
    let mut env: BTreeMap<String, (String, &'static str)> = daemon
        .iter()
        .filter(|(_, v)| !v.is_empty())
        .map(|(k, v)| (k.clone(), (v.clone(), "daemon")))
        .collect();
    for (k, v) in cloud_model_plane::missing(plane, |key| env.contains_key(key)) {
        env.insert(k, (v, "model_plane"));
    }
    env
}

fn agent(
    env: &BTreeMap<String, (String, &'static str)>,
    edge_host: &str,
    base_var: &str,
    key_var: &str,
) -> Value {
    let base = env.get(base_var);
    let key = env.get(key_var).map(|(v, _)| v.clone());
    let routed = base.is_some_and(|(url, _)| host_of(url) == edge_host);
    json!({
        "base_url": base.map(|(url, _)| safe_url(url)),
        "base_url_source": base.map_or("missing", |(_, s)| *s),
        "key_var": key_var,
        "key": key_state(key.as_ref()),
        "key_source": env.get(key_var).map_or("missing", |(_, s)| *s),
        "edge_routed": routed,
    })
}

/// Login file and settings findings under `home`: `(path, agent, kind)`; kind `file` or the
/// credential variable names a settings file sets.
pub fn login_findings(home: &Path) -> Vec<Value> {
    let mut found = Vec::new();
    for (rel, agent) in LOGIN_FILES {
        let path = home.join(rel);
        if std::fs::symlink_metadata(&path).is_ok() {
            found.push(json!({"path": format!("~/{rel}"), "agent": agent, "kind": "file"}));
        }
    }
    // A Claude login an older transfer wrote into settings' env (CloudCredentialInstaller).
    let settings = home.join(".claude/settings.json");
    if let Some(env) = std::fs::read_to_string(&settings)
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .and_then(|v| v.get("env").cloned())
        .and_then(|e| e.as_object().cloned())
    {
        let names: Vec<&str> =
            ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"]
                .into_iter()
                .filter(|n| {
                    env.get(*n)
                        .and_then(Value::as_str)
                        .is_some_and(|v| !v.is_empty() && v != PLACEHOLDER)
                })
                .collect();
        if !names.is_empty() {
            found.push(json!({"path": "~/.claude/settings.json", "agent": "claude", "kind": "settings_env", "names": names}));
        }
    }
    // A key saved by Claude Code's own API key prompt.
    if std::fs::read_to_string(home.join(".claude.json"))
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .is_some_and(|v| {
            v.get("primaryApiKey").and_then(Value::as_str).is_some_and(|k| !k.is_empty())
        })
    {
        found.push(json!({"path": "~/.claude.json", "agent": "claude", "kind": "api_key"}));
    }
    found
}

/// The report, from its inputs (tests pass their own).
pub fn report(
    cloud_vm: bool,
    plane: Result<BTreeMap<String, String>, cloud_model_plane::Problem>,
    daemon: Option<(u32, BTreeMap<String, String>)>,
    home: &Path,
    managed: Vec<Value>,
) -> Value {
    let plane_state = match &plane {
        Ok(_) => "ok",
        Err(problem) => problem.word(),
    };
    let plane = plane.unwrap_or_default();
    let edge_host = plane
        .get("CMUX_CODEROUTER_URL")
        .or_else(|| plane.get("ANTHROPIC_BASE_URL"))
        .map(|u| host_of(u))
        .unwrap_or_else(|| "coderouter.cmux.internal".to_owned());
    let (pid, daemon_env) = match daemon {
        Some((pid, env)) => (Some(pid), env),
        None => (None, BTreeMap::new()),
    };
    // Off a Cloud machine a spawn adds no route.
    let none = BTreeMap::new();
    let env = agent_env(&daemon_env, if cloud_vm { &plane } else { &none });
    let claude = agent(&env, &edge_host, "ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY");
    let codex = agent(&env, &edge_host, "OPENAI_BASE_URL", "OPENAI_API_KEY");
    let credential_env: Vec<&str> =
        CREDENTIAL_VARS.into_iter().filter(|n| env.contains_key(*n)).collect();
    let logins = login_findings(home);
    let routed = |a: &Value| a["edge_routed"] == true && a["key"] == "placeholder";
    let holds = !logins.is_empty() || !credential_env.is_empty();
    let ok = cloud_vm
        && plane_state == "ok"
        && pid.is_some()
        && routed(&claude)
        && routed(&codex)
        && !holds;
    json!({
        "cloud_vm": cloud_vm,
        "edge_host": edge_host,
        "model_plane": {"path": PLANE_FILE, "state": plane_state},
        "daemon": {"running": pid.is_some(), "pid": pid},
        "agents": {"claude": claude, "codex": codex},
        "credential_env": credential_env,
        "login_files": logins,
        "holds_credential": holds,
        "managed_route_files": managed,
        "ok": ok,
    })
}

/// The daemon's own record of the env its agents start with, in its home (0600). The holder
/// registers itself (plans/cmux-next/pty-holder.md): no reader scans another process.
pub const ENV_FILE: &str = "daemon-agent-env.json";

/// A recorded value that is set but is not the edge placeholder (a key's value is never written).
const SET: &str = "<set>";

/// What the record keeps of `name`'s value: a base URL without userinfo, query or fragment; a key
/// as `PLACEHOLDER` or `SET`; a credential variable as `SET`. Empty or absent: nothing.
fn recorded_value(name: &str, value: &str) -> Option<String> {
    if value.is_empty() {
        return None;
    }
    Some(if name.ends_with("_URL") {
        safe_url(value)
    } else if value == PLACEHOLDER {
        PLACEHOLDER.to_owned()
    } else {
        SET.to_owned()
    })
}

/// The record's JSON for `pid` from `env` (the watched names only).
fn record_json(pid: u32, env: &dyn Fn(&str) -> Option<String>) -> Value {
    let recorded: serde_json::Map<String, Value> = watched()
        .filter_map(|name| Some((name.to_owned(), Value::from(recorded_value(name, &env(name)?)?))))
        .collect();
    json!({"pid": pid, "env": recorded})
}

/// Writes this process's record into `home` (temporary file, 0600, then rename). Called by the
/// daemon once it holds `daemon.lock`; a failure only leaves `machine-auth` reporting no daemon.
pub fn record_daemon_env(home: &Path) -> std::io::Result<()> {
    let body = record_json(std::process::id(), &|k| std::env::var(k).ok()).to_string();
    let tmp = home.join(format!("{ENV_FILE}.{}.tmp", std::process::id()));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let _ = std::fs::remove_file(&tmp);
    std::io::Write::write_all(&mut options.open(&tmp)?, body.as_bytes())?;
    std::fs::rename(&tmp, home.join(ENV_FILE))
}

/// The lock holder's pid and its recorded env; `None` when no daemon holds the lock or its record
/// is missing or belongs to another pid (a record left by an earlier daemon is never used).
fn read_daemon_env(home: &Path) -> Option<(u32, BTreeMap<String, String>)> {
    let text = std::fs::read_to_string(home.join("daemon.lock")).ok()?;
    let pid: u32 = text.lines().next()?.trim().parse().ok()?;
    let record: Value =
        serde_json::from_str(&std::fs::read_to_string(home.join(ENV_FILE)).ok()?).ok()?;
    if record["pid"].as_u64() != Some(u64::from(pid)) {
        return None;
    }
    let env = record["env"]
        .as_object()?
        .iter()
        .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_owned())))
        .collect();
    Some((pid, env))
}

fn home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| PathBuf::from("/home/cmux"))
}

/// Prints the report (`--json`: one object; else a short summary). Exit 0 when `ok`, 1 otherwise.
pub fn run(json_out: bool) -> i32 {
    let managed = MANAGED
        .into_iter()
        .map(|(path, agent)| json!({"path": path, "agent": agent, "present": Path::new(path).is_file()}))
        .collect();
    let value = report(
        crate::cloud_host::is_cloud_vm(),
        cloud_model_plane::read_at(Path::new(PLANE_FILE), true),
        read_daemon_env(&crate::config::home()),
        &home_dir(),
        managed,
    );
    let ok = value["ok"] == true;
    if json_out {
        println!("{value}");
    } else {
        for name in ["claude", "codex"] {
            let a = &value["agents"][name];
            println!(
                "{name}: {} (key {}, {})",
                a["base_url"].as_str().unwrap_or("no base URL"),
                a["key"].as_str().unwrap_or("?"),
                if a["edge_routed"] == true { "through the edge" } else { "not through the edge" }
            );
        }
        println!("login files: {}", value["login_files"].as_array().map_or(0, Vec::len));
        println!("{}", if ok { "ok" } else { "not ok" });
    }
    if ok { 0 } else { 1 }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plane() -> BTreeMap<String, String> {
        BTreeMap::from([
            ("OPENAI_BASE_URL".into(), "https://coderouter.cmux.internal/v1".into()),
            ("OPENAI_API_KEY".into(), PLACEHOLDER.into()),
            ("CMUX_CODEROUTER_URL".into(), "https://coderouter.cmux.internal".into()),
            ("ANTHROPIC_BASE_URL".into(), "https://coderouter.cmux.internal".into()),
            ("ANTHROPIC_API_KEY".into(), PLACEHOLDER.into()),
        ])
    }

    fn temp_home() -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("acpmux-machine-auth-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn the_daemon_record_keeps_no_key_value_and_belongs_to_its_pid() {
        let env = BTreeMap::from([
            ("ANTHROPIC_BASE_URL", "https://user:pw@coderouter.cmux.internal/v1?x=1"),
            ("ANTHROPIC_API_KEY", PLACEHOLDER),
            ("OPENAI_API_KEY", "sk-real-secret"),
            ("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat-secret"),
            ("CODEX_API_KEY", ""),
        ]);
        let v = record_json(42, &|k| env.get(k).map(|v| (*v).to_owned()));
        let text = v.to_string();
        assert!(!text.contains("secret") && !text.contains("pw@"), "{text}");
        assert_eq!(v["env"]["ANTHROPIC_BASE_URL"], "https://coderouter.cmux.internal/v1");
        assert_eq!(v["env"]["ANTHROPIC_API_KEY"], PLACEHOLDER);
        assert_eq!(v["env"]["OPENAI_API_KEY"], SET);
        assert_eq!(v["env"]["CLAUDE_CODE_OAUTH_TOKEN"], SET);
        assert!(v["env"].get("CODEX_API_KEY").is_none());

        let home = temp_home();
        std::fs::write(home.join(ENV_FILE), v.to_string()).unwrap();
        std::fs::write(home.join("daemon.lock"), "42\n").unwrap();
        let (pid, read) = read_daemon_env(&home).unwrap();
        assert_eq!(pid, 42);
        let r = report(true, Ok(plane()), Some((pid, read)), &home, Vec::new());
        assert_eq!(r["agents"]["codex"]["key"], "other");
        assert_eq!(r["holds_credential"], true);
        // An earlier daemon's record is not this daemon's.
        std::fs::write(home.join("daemon.lock"), "43\n").unwrap();
        assert!(read_daemon_env(&home).is_none());
        let _ = std::fs::remove_dir_all(&home);
    }

    /// Lane F's finding: a daemon with no route in its env still gives its agents the edge.
    #[test]
    fn a_bare_daemon_env_reports_the_machine_route() {
        let home = temp_home();
        let v = report(true, Ok(plane()), Some((7, BTreeMap::new())), &home, Vec::new());
        assert_eq!(v["agents"]["claude"]["base_url"], "https://coderouter.cmux.internal");
        assert_eq!(v["agents"]["claude"]["base_url_source"], "model_plane");
        assert_eq!(v["agents"]["claude"]["key"], "placeholder");
        assert_eq!(v["agents"]["codex"]["edge_routed"], true);
        assert_eq!(v["holds_credential"], false);
        assert_eq!(v["ok"], true);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn a_login_file_or_a_real_key_is_reported_by_name_only() {
        let home = temp_home();
        std::fs::create_dir_all(home.join(".codex")).unwrap();
        std::fs::write(
            home.join(".codex/auth.json"),
            "{\"tokens\":{\"refresh_token\":\"rt-secret\"}}",
        )
        .unwrap();
        std::fs::create_dir_all(home.join(".claude")).unwrap();
        std::fs::write(
            home.join(".claude/settings.json"),
            "{\"env\":{\"CLAUDE_CODE_OAUTH_TOKEN\":\"sk-ant-oat-secret\"}}",
        )
        .unwrap();
        let daemon =
            BTreeMap::from([("ANTHROPIC_API_KEY".to_owned(), "sk-ant-api-secret".to_owned())]);
        let v = report(true, Ok(plane()), Some((7, daemon)), &home, Vec::new());
        let text = v.to_string();
        for secret in ["rt-secret", "sk-ant-oat-secret", "sk-ant-api-secret"] {
            assert!(!text.contains(secret), "{text}");
        }
        assert_eq!(v["agents"]["claude"]["key"], "other");
        assert_eq!(v["holds_credential"], true);
        assert_eq!(v["login_files"].as_array().unwrap().len(), 2);
        assert_eq!(v["ok"], false);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn no_daemon_no_file_or_another_endpoint_is_not_ok() {
        let home = temp_home();
        assert_eq!(report(true, Ok(plane()), None, &home, Vec::new())["ok"], false);
        let missing = report(
            true,
            Err(cloud_model_plane::Problem::Missing),
            Some((7, BTreeMap::new())),
            &home,
            Vec::new(),
        );
        assert_eq!(missing["model_plane"]["state"], "missing");
        assert_eq!(missing["agents"]["claude"]["base_url_source"], "missing");
        let own = BTreeMap::from([(
            "ANTHROPIC_BASE_URL".to_owned(),
            "https://user:pw@api.example.com/x?k=1".to_owned(),
        )]);
        let v = report(true, Ok(plane()), Some((7, own)), &home, Vec::new());
        assert_eq!(v["agents"]["claude"]["base_url"], "https://api.example.com/x");
        assert_eq!(v["agents"]["claude"]["edge_routed"], false);
        assert_eq!(v["ok"], false);
        let _ = std::fs::remove_dir_all(&home);
    }
}
