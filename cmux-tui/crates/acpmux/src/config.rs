//! Configuration: `$ACPMUX_HOME/config.json`, agent registry, store mode.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub fn home() -> PathBuf {
    if let Ok(v) = std::env::var("ACPMUX_HOME") {
        return PathBuf::from(v);
    }
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".acpmux")
}

/// Unix socket path. macOS limits socket paths to about 100 bytes, so a
/// long home directory falls back to a short per-user path under /tmp that
/// is derived from the home path, so daemon and clients agree.
pub fn socket_path() -> PathBuf {
    if let Ok(v) = std::env::var("ACPMUX_SOCKET") {
        return PathBuf::from(v);
    }
    let preferred = home().join("acpmux.sock");
    if preferred.as_os_str().len() < 96 {
        return preferred;
    }
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in home().to_string_lossy().bytes() {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    let uid = unsafe { libc::getuid() };
    PathBuf::from(format!("/tmp/acpmux-{uid}-{hash:016x}.sock"))
}

/// How acpmux talks to the agent process.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "kebab-case")]
pub enum AgentKind {
    /// Agent Client Protocol over stdio (default).
    #[default]
    Acp,
    /// Claude Code's own `-p --input-format stream-json` protocol.
    ClaudeStdio,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AgentProfile {
    #[serde(default, skip_serializing_if = "is_default_kind")]
    pub kind: AgentKind,
    pub argv: Vec<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub env: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Profile to move a session onto when this one's account reports a
    /// usage or rate limit mid-turn. Discovery sets `claude-sr` (the
    /// subrouter account pool) for `claude` when `sr` is installed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fallback: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum StoreMode {
    Memory,
    Local,
}

impl Default for StoreMode {
    fn default() -> Self {
        StoreMode::Local
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct StoreConfig {
    #[serde(default)]
    pub mode: StoreMode,
    /// Segment roll size in bytes for the event log.
    #[serde(default = "default_segment_bytes")]
    pub segment_bytes: u64,
}

fn default_segment_bytes() -> u64 {
    8 * 1024 * 1024
}

impl Default for StoreConfig {
    fn default() -> Self {
        Self {
            mode: StoreMode::Local,
            segment_bytes: default_segment_bytes(),
        }
    }
}

/// Permission policy applied when no attached client answers.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "kebab-case")]
pub enum PermissionPolicy {
    /// Ask attached clients; wait without limit when none is attached.
    #[default]
    Ask,
    ApproveAll,
    ApproveReads,
    /// Reads plus edits auto-approved; shell, delete and move still ask.
    /// Claude Code's "accept edits" without needing Claude's own mode.
    ApproveEdits,
    DenyAll,
}

impl std::str::FromStr for PermissionPolicy {
    type Err = String;
    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        match s {
            "ask" => Ok(Self::Ask),
            "approve-all" | "yolo" => Ok(Self::ApproveAll),
            "approve-reads" => Ok(Self::ApproveReads),
            "approve-edits" | "accept-edits" => Ok(Self::ApproveEdits),
            "deny-all" => Ok(Self::DenyAll),
            other => Err(format!("unknown permission policy: {other}")),
        }
    }
}

impl std::fmt::Display for PermissionPolicy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            Self::Ask => "ask",
            Self::ApproveAll => "approve-all",
            Self::ApproveReads => "approve-reads",
            Self::ApproveEdits => "approve-edits",
            Self::DenyAll => "deny-all",
        };
        f.write_str(s)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WebSocketConfig {
    pub listen: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
}

/// A remote acpmux daemon this daemon mirrors. Sessions there appear here as
/// `<peer>/<name>` and every request is forwarded.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PeerConfig {
    pub url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    #[serde(default)]
    pub agents: BTreeMap<String, AgentProfile>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub peers: BTreeMap<String, PeerConfig>,
    #[serde(default)]
    pub default_agent: Option<String>,
    #[serde(default)]
    pub store: StoreConfig,
    #[serde(default)]
    pub permission_policy: PermissionPolicy,
    /// `composerMaxRows`: most rows the TUI composer grows to before it
    /// scrolls. Env `ACPMUX_COMPOSER_ROWS` overrides. Default 12.
    #[serde(default)]
    pub composer_max_rows: Option<u16>,
    /// `notifyCommand`: shell command the daemon runs when a session needs a
    /// permission or ends a turn while nobody is attached. Gets ACPMUX_EVENT,
    /// ACPMUX_SESSION_ID, ACPMUX_SESSION_NAME and ACPMUX_TEXT in its env.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notify_command: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub websocket: Option<WebSocketConfig>,
    /// Where this config was loaded from. A config built in code (tests,
    /// `--memory` runs) has no path and is never written to disk.
    #[serde(skip)]
    pub path: Option<PathBuf>,
}

impl Config {
    pub fn path() -> PathBuf {
        home().join("config.json")
    }

    /// Load config. When no file exists, build defaults and try to import
    /// agent profiles from `~/.acpx/config.json` so existing setups keep working.
    pub fn load() -> Result<Self> {
        let path = Self::path();
        let mut cfg = if path.exists() {
            let text = std::fs::read_to_string(&path)
                .with_context(|| format!("read {}", path.display()))?;
            serde_json::from_str::<Config>(&text)
                .with_context(|| format!("parse {}", path.display()))?
        } else {
            Config::default()
        };
        // Harnesses found on PATH join the configured ones, so installing an
        // adapter such as pi-acp is enough; configured entries always win.
        for (name, profile) in discover_agents() {
            cfg.agents.entry(name).or_insert(profile);
        }
        if cfg.agents.contains_key("claude-sr") {
            if let Some(c) = cfg.agents.get_mut("claude") {
                if c.fallback.is_none() && c.kind == AgentKind::ClaudeStdio {
                    c.fallback = Some("claude-sr".into());
                }
            }
        }
        if cfg.default_agent.is_none() {
            cfg.default_agent = cfg.agents.keys().next().cloned();
        }
        cfg.path = Some(path);
        Ok(cfg)
    }

    /// Write back to the file this config came from. No-op for in-code configs.
    pub fn save(&self) -> Result<()> {
        let Some(path) = &self.path else {
            tracing::debug!("config has no file; not saved");
            return Ok(());
        };
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        write_atomic(path, serde_json::to_string_pretty(self)?.as_bytes())
    }

    pub fn agent(&self, name: &str) -> Option<&AgentProfile> {
        self.agents.get(name)
    }
}

/// Look for agent adapters in the acpx config and on PATH.
pub fn discover_agents() -> BTreeMap<String, AgentProfile> {
    let mut agents = BTreeMap::new();
    if let Some(home) = dirs::home_dir() {
        let acpx = home.join(".acpx").join("config.json");
        if let Ok(text) = std::fs::read_to_string(&acpx) {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) {
                if let Some(map) = v.get("agents").and_then(|a| a.as_object()) {
                    for (name, profile) in map {
                        if let Some(argv) = profile.get("argv").and_then(|a| a.as_array()) {
                            let argv: Vec<String> = argv
                                .iter()
                                .filter_map(|s| s.as_str().map(str::to_owned))
                                .collect();
                            if !argv.is_empty() {
                                agents.insert(
                                    name.clone(),
                                    AgentProfile {
                                        kind: AgentKind::Acp,
                                        argv,
                                        env: BTreeMap::new(),
                                        description: Some("imported from ~/.acpx".into()), fallback: None,
                                    },
                                );
                            }
                        }
                    }
                }
            }
        }
    }
    for (name, bin) in [
        ("codex", "codex-acp"),
        ("claude", "claude"),
        ("gemini", "gemini"),
        ("opencode", "opencode"),
        // pi (earendil-works/pi) speaks ACP through the pi-acp adapter,
        // which spawns `pi --mode rpc`: `bun add -g pi-acp`.
        ("pi", "pi-acp"),
        // Claude through the subrouter account pool: `sr claude proxy`
        // picks the account with the most quota and fails over on limits.
        ("claude-sr", "sr"),
    ] {
        if agents.contains_key(name) {
            continue;
        }
        if let Some(path) = which(bin) {
            let (kind, argv) = match bin {
                "claude" => (AgentKind::ClaudeStdio, vec![path]),
                "sr" => (AgentKind::ClaudeStdio, vec![path, "claude".into(), "proxy".into()]),
                "gemini" => (AgentKind::Acp, vec![path, "--experimental-acp".into()]),
                "opencode" => (AgentKind::Acp, vec![path, "acp".into()]),
                _ => (AgentKind::Acp, vec![path]),
            };
            agents.insert(
                name.to_owned(),
                AgentProfile {
                    kind,
                    argv,
                    env: BTreeMap::new(),
                    description: Some(if bin == "sr" { "Claude through the subrouter account pool".into() } else { "found on PATH".into() }),
                    fallback: None,
                },
            );
        }
    }
    // A direct Claude falls over to the pool when its account is exhausted.
    if agents.contains_key("claude-sr") {
        if let Some(c) = agents.get_mut("claude") {
            if c.fallback.is_none() {
                c.fallback = Some("claude-sr".into());
            }
        }
    }
    agents
}

/// Drop discovered launcher profiles whose binary cannot actually run the
/// harness: an older subrouter without `claude proxy`, or one whose proxy
/// setup fails before Claude starts. Runs once at daemon start, so a
/// `claude` session never fails over into a launcher that dies at once.
pub fn verify_launchers(cfg: &mut Config) {
    let candidates: Vec<(String, Vec<String>)> = cfg
        .agents
        .iter()
        .filter(|(_, p)| p.argv.get(1).map(String::as_str) == Some("claude") && p.argv.get(2).map(String::as_str) == Some("proxy"))
        .map(|(n, p)| (n.clone(), p.argv.clone()))
        .collect();
    for (name, argv) in candidates {
        if let Err(reason) = launcher_ok(&argv) {
            tracing::warn!(agent = %name, "launcher disabled: {reason}");
            cfg.agents.remove(&name);
            for p in cfg.agents.values_mut() {
                if p.fallback.as_deref() == Some(name.as_str()) {
                    p.fallback = None;
                }
            }
        }
    }
}

fn launcher_ok(argv: &[String]) -> std::result::Result<(), String> {
    let mut cmd = std::process::Command::new(&argv[0]);
    cmd.args(&argv[1..]).arg("--version").stdin(std::process::Stdio::null()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped());
    scrub_nested_claude_env(&mut cmd);
    let mut child = cmd.spawn().map_err(|e| format!("{}: {e}", argv[0]))?;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if std::time::Instant::now() < deadline => std::thread::sleep(std::time::Duration::from_millis(100)),
            Ok(None) => {
                let _ = child.kill();
                return Err(format!("{} claude proxy --version did not finish in 20s", argv[0]));
            }
            Err(e) => return Err(e.to_string()),
        }
    }
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    let text = format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    let first = text.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("").to_owned();
    if !out.status.success() || first.starts_with("subrouter:") || text.to_lowercase().contains("unknown command") {
        return Err(format!("`{} claude proxy --version` failed: {}", argv[0], if first.is_empty() { out.status.to_string() } else { first }));
    }
    Ok(())
}

fn which(bin: &str) -> Option<String> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(bin);
        if candidate.is_file() {
            return Some(candidate.to_string_lossy().into_owned());
        }
    }
    None
}

fn is_default_kind(k: &AgentKind) -> bool {
    *k == AgentKind::Acp
}

pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = path.with_extension(format!("tmp-{}-{n}", std::process::id()));
    std::fs::write(&tmp, bytes).with_context(|| format!("write {}", tmp.display()))?;
    std::fs::rename(&tmp, path).with_context(|| format!("rename to {}", path.display()))?;
    Ok(())
}

/// Variables a Claude Code session plants for its own children: a
/// per-session API proxy and auth, hooks, and wrapper shims. A daemon or
/// agent launched from inside such a session must not inherit them, or its
/// Claude processes dial a proxy that dies with that session ("API Error:
/// Connection refused"). Applied only when `CLAUDECODE` is set, so a user's
/// own `ANTHROPIC_*` settings in a plain shell still pass through.
pub fn scrub_nested_claude_env(cmd: &mut std::process::Command) {
    if std::env::var_os("CLAUDECODE").is_none() {
        return;
    }
    for (k, _) in std::env::vars_os() {
        let key = k.to_string_lossy();
        if key.starts_with("CLAUDE") || key.starts_with("ANTHROPIC_") || key.starts_with("CMUX_CLAUDE_") || key.starts_with("SUBROUTER_CLAUDE_") || key == "NODE_OPTIONS" {
            cmd.env_remove(&k);
        }
    }
}

/// Same, for tokio's process builder.
pub fn scrub_nested_claude_env_tokio(cmd: &mut tokio::process::Command) {
    if std::env::var_os("CLAUDECODE").is_none() {
        return;
    }
    for (k, _) in std::env::vars_os() {
        let key = k.to_string_lossy();
        if key.starts_with("CLAUDE") || key.starts_with("ANTHROPIC_") || key.starts_with("CMUX_CLAUDE_") || key.starts_with("SUBROUTER_CLAUDE_") || key == "NODE_OPTIONS" {
            cmd.env_remove(&k);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launcher_check_rejects_old_subrouter() {
        let dir = std::env::temp_dir().join(format!("acpmux-launcher-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let old = dir.join("sr-old");
        std::fs::write(&old, "#!/bin/sh\necho 'subrouter: unknown command: sr claude proxy' >&2\nexit 1\n").unwrap();
        let broken = dir.join("sr-broken");
        std::fs::write(&broken, "#!/bin/sh\necho 'subrouter: prepare shared Claude proxy history: file exists' >&2\nexit 0\n").unwrap();
        let good = dir.join("sr-good");
        std::fs::write(&good, "#!/bin/sh\necho '2.1.275 (Claude Code)'\n").unwrap();
        for p in [&old, &broken, &good] {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let argv = |p: &std::path::Path| vec![p.to_string_lossy().into_owned(), "claude".into(), "proxy".into()];
        assert!(launcher_ok(&argv(&old)).unwrap_err().contains("unknown command"));
        assert!(launcher_ok(&argv(&broken)).unwrap_err().contains("prepare shared"));
        assert!(launcher_ok(&argv(&good)).is_ok());
        let mut cfg = Config::default();
        cfg.agents.insert("claude-sr".into(), AgentProfile { kind: AgentKind::ClaudeStdio, argv: argv(&old), env: BTreeMap::new(), description: None, fallback: None });
        cfg.agents.insert("claude".into(), AgentProfile { kind: AgentKind::ClaudeStdio, argv: vec!["claude".into()], env: BTreeMap::new(), description: None, fallback: Some("claude-sr".into()) });
        verify_launchers(&mut cfg);
        assert!(!cfg.agents.contains_key("claude-sr"));
        assert_eq!(cfg.agents["claude"].fallback, None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
