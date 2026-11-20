//! OpenClaw's home for a Chief turn (brain_home.rs). Every key below is one OpenClaw documents
//! (openclaw/openclaw, `docs/gateway/*`, read at bd9166435, 2026-11-19); its schema is strict, so
//! an unknown key stops its Gateway (exit 78) and the turn falls back.
//!
//! - `OPENCLAW_HOME=<home>`: the state folder is `<home>/.openclaw`, the config
//!   `<home>/.openclaw/openclaw.json`.
//! - Sandbox mode `all` (coordinator decision 2026-11-19, its CVE record): every tool runs in a
//!   container. OpenClaw has no host fallback, so a Mac without `docker` or `podman` cannot run
//!   it: the brain is `unavailable` and the Chief's default harness answers ([`blocker`]).
//! - No skills: no bundled skill and none for the agent; ClawHub installs have no off switch in
//!   the config, so the Chief never runs `openclaw skills install`.
//! - Its scheduler off (`cron.enabled`, `cron.triggers.enabled`; the heartbeat runs as a cron
//!   job), no chat channel (none configured, and `OPENCLAW_SKIP_CHANNELS`), no update check or
//!   telemetry.
//! - `openclaw acp` refuses per-session MCP servers (acpmux sends it none,
//!   `agent_tools::NO_SESSION_MCP_FAMILIES`): cmux's servers are in `mcp.servers` here. They run
//!   on the host beside the Gateway, and the sandbox lets their tools through
//!   (`tools.sandbox.tools.alsoAllow`).
//! - The agent workspace is the Chief's turn folder, so the turn's `cwd` is inside it (a
//!   sandboxed `session/new` refuses any other) and the Chief's AGENTS.md is its instructions;
//!   `skipBootstrap` keeps OpenClaw from writing its own files there.
//! - `openclaw acp` starts no Gateway: the host runs one per Chief ([`Gateway`]) on a loopback
//!   port, with a token in a 0600 file.

use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt as _;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

use crate::brain_home::{BrainSetup, GATEWAY_KEY};
use crate::session_dir::write_if_changed;

/// The provider id the config names the team gateway by.
pub const PROVIDER: &str = "cmux-gateway";

/// `<home>/.openclaw`.
pub fn state_dir(home: &Path) -> PathBuf {
    home.join(".openclaw")
}

/// The Gateway's token file (0600, one value).
pub fn token_path(home: &Path) -> PathBuf {
    state_dir(home).join("gateway.token")
}

/// The port the config names, recorded beside it.
fn port_path(home: &Path) -> PathBuf {
    state_dir(home).join("gateway.port")
}

/// Why OpenClaw cannot run a Chief turn on this machine, if it cannot: sandbox mode `all`
/// needs a container engine on PATH.
pub fn blocker(path_var: Option<&std::ffi::OsStr>) -> Option<String> {
    let found = path_var.is_some_and(|p| {
        std::env::split_paths(p).any(|dir| {
            ["docker", "podman"]
                .iter()
                .any(|bin| dir.join(bin).is_file())
        })
    });
    (!found).then(|| {
        "OpenClaw runs only in sandbox mode \"all\", which needs Docker or Podman on this machine; neither is on PATH".to_owned()
    })
}

/// The container engine the sandbox uses: podman when only podman is on PATH.
fn backend(path_var: Option<&std::ffi::OsStr>) -> &'static str {
    let has = |bin: &str| {
        path_var.is_some_and(|p| std::env::split_paths(p).any(|dir| dir.join(bin).is_file()))
    };
    if !has("docker") && has("podman") {
        "podman"
    } else {
        "docker"
    }
}

/// The config for `setup`, the Gateway on `port`.
pub fn config(home: &Path, setup: &BrainSetup, port: u16, sandbox: &str) -> Value {
    let mut servers = Map::new();
    let mut allowed = Vec::new();
    for server in &setup.mcp_servers {
        let Some(name) = server.get("name").and_then(Value::as_str) else {
            continue;
        };
        servers.insert(
            name.to_owned(),
            json!({
                "command": server.get("command").cloned().unwrap_or(Value::Null),
                "args": server.get("args").cloned().unwrap_or(json!([])),
                "env": server.get("env").cloned().unwrap_or(json!({})),
            }),
        );
        allowed.push(Value::String(format!("{name}__*")));
    }
    json!({
        "gateway": {
            "mode": "local",
            "port": port,
            "bind": "loopback",
            "auth": {"mode": "token", "token": {"source": "file", "provider": "cmuxgw", "id": "value"}},
        },
        "secrets": {"providers": {"cmuxgw": {
            "source": "file",
            "path": token_path(home).display().to_string(),
            "mode": "singleValue",
        }}},
        "cron": {"enabled": false, "triggers": {"enabled": false}},
        "update": {"checkOnStart": false},
        "telemetry": {"enabled": false},
        "skills": {"allowBundled": [], "load": {"watch": false}},
        // The Chief keeps the memory of record: no OpenClaw memory plugin, no memory flush.
        "plugins": {"slots": {"memory": "none"}},
        "tools": {"sandbox": {"tools": {"alsoAllow": allowed}}},
        "mcp": {"servers": servers},
        "models": {"mode": "replace", "providers": {PROVIDER: {
            "baseUrl": format!("{}/v1", setup.base_url),
            "api": "openai-responses",
            "apiKey": GATEWAY_KEY,
            "models": [{"id": setup.model, "name": setup.model, "input": ["text"], "contextWindow": 200000, "maxTokens": 32000}],
        }}},
        "agents": {"defaults": {
            "workspace": setup.session_dir.display().to_string(),
            "skipBootstrap": true,
            "compaction": {"memoryFlush": {"enabled": false}},
            "model": {"primary": format!("{PROVIDER}/{}", setup.model)},
            "skills": [],
            "sandbox": {"mode": "all", "backend": sandbox},
        }},
    })
}

/// A free loopback port now (the Gateway binds it at its start).
fn free_port() -> io::Result<u16> {
    let listener = std::net::TcpListener::bind(("127.0.0.1", 0))?;
    Ok(listener.local_addr()?.port())
}

/// Writes the token (once, 0600) and the config. The port is kept across starts.
pub fn write(home: &Path, setup: &BrainSetup) -> io::Result<()> {
    let dir = state_dir(home);
    std::fs::create_dir_all(&dir)?;
    let token = token_path(home);
    if std::fs::metadata(&token).map_or(true, |m| !m.is_file() || m.len() == 0) {
        let mut bytes = [0u8; 32];
        ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut bytes)
            .map_err(|_| io::Error::other("no random bytes for the Gateway token"))?;
        let text: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        // Whole or not at all: a temporary file (0600 from its creation), then a rename.
        let tmp = token.with_extension(format!("token.{}.tmp", std::process::id()));
        let _ = std::fs::remove_file(&tmp);
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp)?;
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        std::fs::rename(&tmp, &token)?;
    }
    let port = match std::fs::read_to_string(port_path(home))
        .ok()
        .and_then(|p| p.trim().parse::<u16>().ok())
    {
        Some(port) => port,
        None => {
            let port = free_port()?;
            write_if_changed(&port_path(home), port.to_string().as_bytes())?;
            port
        }
    };
    let path = std::env::var_os("PATH");
    let doc = config(home, setup, port, backend(path.as_deref()));
    let mut bytes = serde_json::to_vec_pretty(&doc).map_err(io::Error::other)?;
    bytes.push(b'\n');
    write_if_changed(&dir.join("openclaw.json"), &bytes)
}

/// The host env keys the Gateway keeps: the program's own search path and locale, the user,
/// temp, the cmux sockets its `cmux` MCP server talks to, and the container engine's socket.
const GATEWAY_ENV: [&str; 13] = [
    "PATH",
    "HOME",
    "USER",
    "LOGNAME",
    "LANG",
    "TMPDIR",
    "DOCKER_HOST",
    "CMUX_TUI_SOCKET",
    "CMUX_MUX_SOCKET",
    "CMUX_SOCKET_PATH",
    "CMUX_APP_DAEMON_SOCKET",
    "CMUX_BUNDLED_CLI_PATH",
    "CMUX_NEXT_CONFIG_FILE",
];

/// Whether `pid` is still a Gateway this host's code started: a process group leader whose
/// command is `openclaw ... gateway run`. A pid the system gave to another program since is
/// never signalled.
fn is_our_gateway(pid: i32) -> bool {
    let Ok(out) = std::process::Command::new("/bin/ps")
        .args(["-o", "pgid=,command=", "-p", &pid.to_string()])
        .stdin(std::process::Stdio::null())
        .output()
    else {
        return false;
    };
    let text = String::from_utf8_lossy(&out.stdout);
    let mut words = text.split_whitespace();
    let leader = words.next().and_then(|g| g.parse::<i32>().ok()) == Some(pid);
    let command: Vec<&str> = words.collect();
    leader
        && command.iter().any(|w| w.contains("openclaw"))
        && command.windows(2).any(|w| w == ["gateway", "run"])
}

/// The Chief's OpenClaw Gateway: a child of the host, ended (its process group) when the host
/// lets go of it. A Gateway an earlier host left (its pid file) is ended first.
pub struct Gateway {
    child: std::process::Child,
    pid_file: PathBuf,
}

fn pid_path(home: &Path) -> PathBuf {
    state_dir(home).join("gateway.pid")
}

impl Gateway {
    /// Starts `openclaw gateway run` for the Chief's OpenClaw home.
    pub fn start(openclaw: &Path, home: &Path, log: &dyn Fn(String)) -> io::Result<Gateway> {
        if let Some(old) = std::fs::read_to_string(pid_path(home))
            .ok()
            .and_then(|p| p.trim().parse::<i32>().ok())
            .filter(|pid| *pid > 1)
            .filter(|pid| is_our_gateway(*pid))
        {
            // Only our own Gateway's group: the pid file is in the Chief's own OpenClaw home.
            // SAFETY: kill(2) with a negative pid signals that process group; no memory access.
            let ended = unsafe { libc::kill(-old, libc::SIGTERM) } == 0;
            if ended {
                log(format!(
                    "openclaw: ended the Gateway an earlier host left (pid {old})"
                ));
            }
        }
        let port = std::fs::read_to_string(port_path(home)).unwrap_or_default();
        let logfile = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(state_dir(home).join("gateway.log"))?;
        // The Gateway runs the model and the tools: only what it needs from the host's env,
        // never a provider key of the person's.
        let keep: Vec<(String, std::ffi::OsString)> = GATEWAY_ENV
            .iter()
            .filter_map(|k| std::env::var_os(k).map(|v| ((*k).to_owned(), v)))
            .collect();
        let child = std::process::Command::new(openclaw)
            .args([
                "gateway",
                "run",
                "--bind",
                "loopback",
                "--port",
                port.trim(),
            ])
            .env_clear()
            .envs(keep)
            .env("OPENCLAW_HOME", home)
            .env("OPENCLAW_SKIP_CHANNELS", "1")
            .env("OPENCLAW_SKIP_CRON", "1")
            .env("OPENCLAW_NO_AUTO_UPDATE", "1")
            .env("DO_NOT_TRACK", "1")
            .stdin(std::process::Stdio::null())
            .stdout(logfile.try_clone()?)
            .stderr(logfile)
            .process_group(0)
            .spawn()?;
        write_if_changed(&pid_path(home), child.id().to_string().as_bytes())?;
        let pid_file = pid_path(home);
        log(format!(
            "openclaw: Gateway pid {} on 127.0.0.1:{}",
            child.id(),
            port.trim()
        ));
        Ok(Gateway { child, pid_file })
    }
}

impl Drop for Gateway {
    fn drop(&mut self) {
        let pid = self.child.id() as i32;
        // SAFETY: kill(2) on the process group this host started; no memory access.
        unsafe {
            libc::kill(-pid, libc::SIGTERM);
        }
        let _ = self.child.wait();
        let _ = std::fs::remove_file(&self.pid_file);
    }
}
