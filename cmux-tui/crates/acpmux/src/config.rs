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
pub enum HarnessKind {
    /// Agent Client Protocol over stdio (default).
    #[default]
    Acp,
    /// Claude Code's own `-p --input-format stream-json` protocol.
    ClaudeStdio,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct HarnessProfile {
    #[serde(default, skip_serializing_if = "is_default_kind")]
    pub kind: HarnessKind,
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
    /// Model family this profile belongs to (`claude`, `codex`, `opencode`,
    /// `pi`, `gemini`). Derived from the kind and argv when absent. Family
    /// names are what `defaults` and `-u FAMILY` resolve against.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub family: Option<String>,
}

/// Session defaults for a family or a single profile (`defaults` in
/// config.json). Precedence at `session/new`: explicit request, then the
/// profile's own entry, then its family's entry, then the daemon defaults.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct SessionDefaults {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Model per profile, for an alias that spans harnesses whose ids
    /// differ: `{"opencode": "opencode-go/deepseek-v4-pro", "pi":
    /// "openrouter/deepseek/deepseek-v4"}`. Wins over `model` for that profile.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub models: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy: Option<PermissionPolicy>,
    /// Profiles to use, in order, when a session asks for this family:
    /// `["claude-sr", "claude"]` sends `-u claude` to the account pool
    /// first. Absent: a profile named like the family, else the first
    /// profile in the family.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub prefer: Vec<String>,
    /// Extra environment for every process in the family (an API base URL,
    /// a router key variable). The profile's own `env` wins on conflicts.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub env: BTreeMap<String, String>,
}

impl SessionDefaults {
    fn overlay(&mut self, top: &SessionDefaults) {
        if top.model.is_some() {
            self.model = top.model.clone();
        }
        for (k, v) in &top.models {
            self.models.insert(k.clone(), v.clone());
        }
        if top.effort.is_some() {
            self.effort = top.effort.clone();
        }
        if top.policy.is_some() {
            self.policy = top.policy;
        }
        if !top.prefer.is_empty() {
            self.prefer = top.prefer.clone();
        }
        for (k, v) in &top.env {
            self.env.insert(k.clone(), v.clone());
        }
    }
    pub fn is_empty(&self) -> bool {
        *self == SessionDefaults::default()
    }
    /// The model for one profile: the per-profile entry, else `model`.
    pub fn model_for(&self, profile: &str) -> Option<String> {
        self.models.get(profile).cloned().or_else(|| self.model.clone())
    }
}

/// The family a profile belongs to: its explicit `family`, else derived
/// from the harness kind and the argv basenames, else the first word of
/// the profile name (`claude-sr` → `claude`, `fake-pool` → `fake`).
pub fn derive_family(name: &str, profile: &HarnessProfile) -> String {
    if let Some(f) = &profile.family {
        return f.clone();
    }
    if profile.kind == HarnessKind::ClaudeStdio {
        return "claude".into();
    }
    let words: Vec<String> = profile
        .argv
        .iter()
        .map(|a| Path::new(a).file_name().map(|f| f.to_string_lossy().to_lowercase()).unwrap_or_default())
        .collect();
    for (needle, family) in [("codex", "codex"), ("opencode", "opencode"), ("gemini", "gemini"), ("pi-acp", "pi"), ("claude", "claude")] {
        if words.iter().any(|w| w.contains(needle)) {
            return family.into();
        }
    }
    name.split(['-', '_', '.']).next().unwrap_or(name).to_lowercase()
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
    #[serde(alias = "agents")]
    pub harnesses: BTreeMap<String, HarnessProfile>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub peers: BTreeMap<String, PeerConfig>,
    #[serde(default, alias = "defaultAgent")]
    pub default_harness: Option<String>,
    /// Per-family (or per-profile) session defaults, keyed by family or
    /// profile name: `{"claude": {"model": "claude-opus-5", "effort": "high",
    /// "policy": "approve-edits", "prefer": ["claude-sr", "claude"]}}`.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub defaults: BTreeMap<String, SessionDefaults>,
    #[serde(default)]
    pub store: StoreConfig,
    #[serde(default)]
    pub permission_policy: PermissionPolicy,
    /// `composerMaxRows`: most rows the TUI composer grows to before it
    /// scrolls. Env `ACPMUX_COMPOSER_ROWS` overrides. Default 12.
    #[serde(default, skip_serializing_if = "Option::is_none")]
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
    /// Profiles that came from PATH discovery, not the file. `save` leaves
    /// them out so the file keeps only what the user wrote and discovery
    /// stays live.
    #[serde(skip)]
    pub discovered: std::collections::BTreeSet<String>,
    /// `(profile, fallback)` set by discovery, stripped on save.
    #[serde(skip)]
    pub auto_fallback: Option<(String, String)>,
    /// `defaultHarness` was filled in at load, not written by the user.
    #[serde(skip)]
    pub auto_default: bool,
}

impl Config {
    /// Family of a configured profile.
    pub fn family(&self, profile: &str) -> Option<String> {
        self.harnesses.get(profile).map(|p| derive_family(profile, p))
    }

    /// Families with their profiles, in name order.
    pub fn families(&self) -> BTreeMap<String, Vec<String>> {
        let mut out: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for (name, p) in &self.harnesses {
            out.entry(derive_family(name, p)).or_default().push(name.clone());
        }
        out
    }

    /// The profile a session request names. `requested` may be a profile
    /// name or a family name: the family's `prefer` list wins, then a
    /// profile with that exact name, then the first profile in the family.
    pub fn resolve_harness(&self, requested: &str) -> Option<String> {
        self.resolve_harness_where(requested, |_, _| true)
    }

    /// `resolve_harness` with a filter on the `prefer` candidates: `ok(profile,
    /// model)` says whether that profile can run the model the request
    /// would get (the hub checks the model list it learned). When no
    /// candidate passes, the first installed one is used and the model
    /// setting fails loudly later.
    pub fn resolve_harness_where(&self, requested: &str, ok: impl Fn(&str, Option<&str>) -> bool) -> Option<String> {
        if let Some(d) = self.defaults.get(requested) {
            let installed: Vec<&String> = d.prefer.iter().filter(|p| self.harnesses.contains_key(*p)).collect();
            if let Some(p) = installed.iter().find(|p| {
                let model = self.defaults_for_request(requested, p).model_for(p);
                ok(p, model.as_deref())
            }) {
                return Some((*p).clone());
            }
            if let Some(p) = installed.first() {
                return Some((*p).clone());
            }
        }
        if self.harnesses.contains_key(requested) {
            return Some(requested.to_owned());
        }
        self.harnesses.iter().find(|(n, p)| derive_family(n, p) == requested).map(|(n, _)| n.clone())
    }

    /// Defaults for a request that named `requested` (a family, a profile,
    /// or an alias such as `deepseek`) and resolved to `profile`: the
    /// profile's own defaults, then the alias entry on top. An alias is a
    /// `defaults` key that is neither the profile nor its family.
    pub fn defaults_for_request(&self, requested: &str, profile: &str) -> SessionDefaults {
        let mut d = self.defaults_for(profile);
        let family = self.family(profile);
        if requested != profile && family.as_deref() != Some(requested) {
            if let Some(alias) = self.defaults.get(requested) {
                d.overlay(alias);
            }
        }
        d
    }

    /// Alias names: `defaults` keys that are neither a family nor a profile.
    pub fn aliases(&self) -> Vec<String> {
        let fams = self.families();
        self.defaults.keys().filter(|k| !fams.contains_key(*k) && !self.harnesses.contains_key(*k)).cloned().collect()
    }

    /// Defaults that apply to a profile: its family's entry under its own.
    pub fn defaults_for(&self, profile: &str) -> SessionDefaults {
        let mut d = SessionDefaults::default();
        if let Some(f) = self.family(profile) {
            if let Some(fd) = self.defaults.get(&f) {
                d.overlay(fd);
            }
            if f != profile {
                if let Some(pd) = self.defaults.get(profile) {
                    d.overlay(pd);
                }
            }
        }
        d
    }

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
        for (name, profile) in discover_harnesses() {
            if !cfg.harnesses.contains_key(&name) {
                cfg.discovered.insert(name.clone());
                cfg.harnesses.insert(name, profile);
            }
        }
        if cfg.harnesses.contains_key("claude-sr") {
            if let Some(c) = cfg.harnesses.get_mut("claude") {
                if c.fallback.is_none() && c.kind == HarnessKind::ClaudeStdio {
                    c.fallback = Some("claude-sr".into());
                    cfg.auto_fallback = Some(("claude".into(), "claude-sr".into()));
                }
            }
        }
        if cfg.default_harness.is_none() {
            cfg.auto_default = true;
            cfg.default_harness = cfg.harnesses.keys().next().cloned();
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
        let mut on_disk = self.clone();
        on_disk.harnesses.retain(|n, _| !self.discovered.contains(n));
        if let Some((p, f)) = &self.auto_fallback {
            if let Some(prof) = on_disk.harnesses.get_mut(p) {
                if prof.fallback.as_deref() == Some(f.as_str()) {
                    prof.fallback = None;
                }
            }
        }
        if self.auto_default {
            on_disk.default_harness = None;
        }
        write_atomic(path, serde_json::to_string_pretty(&on_disk)?.as_bytes())
    }

    pub fn profile(&self, name: &str) -> Option<&HarnessProfile> {
        self.harnesses.get(name)
    }
}

/// Look for agent adapters in the acpx config and on PATH.
pub fn discover_harnesses() -> BTreeMap<String, HarnessProfile> {
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
                                    HarnessProfile {
                                        kind: HarnessKind::Acp,
                                        argv,
                                        env: BTreeMap::new(),
                                        description: Some("imported from ~/.acpx".into()), fallback: None, family: None,
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
                "claude" => (HarnessKind::ClaudeStdio, vec![path]),
                "sr" => (HarnessKind::ClaudeStdio, vec![path, "claude".into(), "proxy".into()]),
                "gemini" => (HarnessKind::Acp, vec![path, "--experimental-acp".into()]),
                "opencode" => (HarnessKind::Acp, vec![path, "acp".into()]),
                _ => (HarnessKind::Acp, vec![path]),
            };
            agents.insert(
                name.to_owned(),
                HarnessProfile {
                    kind,
                    argv,
                    env: BTreeMap::new(),
                    description: Some(if bin == "sr" { "Claude through the subrouter account pool".into() } else { "found on PATH".into() }),
                    fallback: None, family: None,
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
        .harnesses
        .iter()
        .filter(|(_, p)| p.argv.get(1).map(String::as_str) == Some("claude") && p.argv.get(2).map(String::as_str) == Some("proxy"))
        .map(|(n, p)| (n.clone(), p.argv.clone()))
        .collect();
    for (name, argv) in candidates {
        if let Err(reason) = launcher_ok(&argv) {
            tracing::warn!(agent = %name, "launcher disabled: {reason}");
            cfg.harnesses.remove(&name);
            for p in cfg.harnesses.values_mut() {
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

fn is_default_kind(k: &HarnessKind) -> bool {
    *k == HarnessKind::Acp
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

    fn prof(kind: HarnessKind, argv: &[&str]) -> HarnessProfile {
        HarnessProfile { kind, argv: argv.iter().map(|s| s.to_string()).collect(), env: BTreeMap::new(), description: None, fallback: None, family: None }
    }

    #[test]
    fn families_are_derived_and_resolved() {
        let mut cfg = Config::default();
        cfg.harnesses.insert("claude".into(), prof(HarnessKind::ClaudeStdio, &["/usr/local/bin/claude"]));
        cfg.harnesses.insert("claude-sr".into(), prof(HarnessKind::ClaudeStdio, &["/Users/x/bin/sr", "claude", "proxy"]));
        cfg.harnesses.insert("codex".into(), prof(HarnessKind::Acp, &["/opt/homebrew/bin/codex-acp"]));
        cfg.harnesses.insert("oc".into(), prof(HarnessKind::Acp, &["opencode", "acp"]));
        cfg.harnesses.insert("pi".into(), prof(HarnessKind::Acp, &["/x/pi-acp"]));
        let mut tagged = prof(HarnessKind::Acp, &["python3", "agent.py"]);
        tagged.family = Some("codex".into());
        cfg.harnesses.insert("router-codex".into(), tagged);
        assert_eq!(cfg.family("claude-sr").as_deref(), Some("claude"));
        assert_eq!(cfg.family("oc").as_deref(), Some("opencode"));
        assert_eq!(cfg.family("pi").as_deref(), Some("pi"));
        assert_eq!(cfg.families()["codex"], vec!["codex".to_owned(), "router-codex".to_owned()]);
        // Exact profile wins, then the family's first profile.
        assert_eq!(cfg.resolve_harness("claude").as_deref(), Some("claude"));
        assert_eq!(cfg.resolve_harness("opencode").as_deref(), Some("oc"));
        assert_eq!(cfg.resolve_harness("nope"), None);
        // prefer sends the family to the pool first, and skips missing profiles.
        cfg.defaults.insert("claude".into(), SessionDefaults { model: Some("claude-opus-5".into()), models: BTreeMap::new(), effort: Some("high".into()), policy: Some(PermissionPolicy::ApproveEdits), prefer: vec!["missing".into(), "claude-sr".into()], env: BTreeMap::from([("A".to_owned(), "1".to_owned())]) });
        cfg.defaults.insert("claude-sr".into(), SessionDefaults { effort: Some("max".into()), ..Default::default() });
        assert_eq!(cfg.resolve_harness("claude").as_deref(), Some("claude-sr"));
        let d = cfg.defaults_for("claude-sr");
        assert_eq!(d.model.as_deref(), Some("claude-opus-5"));
        assert_eq!(d.effort.as_deref(), Some("max"));
        assert_eq!(d.policy, Some(PermissionPolicy::ApproveEdits));
        assert_eq!(d.env["A"], "1");
        assert!(cfg.defaults_for("codex").is_empty());
        // An alias: a defaults key that is neither family nor profile. Its
        // entry lands on top of the resolved profile's defaults, and its
        // per-profile model ids pick the right id for each harness.
        cfg.defaults.insert("deepseek".into(), SessionDefaults { prefer: vec!["oc".into(), "pi".into()], models: BTreeMap::from([("oc".to_owned(), "opencode-go/deepseek-v4-pro".to_owned()), ("pi".to_owned(), "openrouter/deepseek/deepseek-v4".to_owned())]), effort: Some("low".into()), ..Default::default() });
        assert_eq!(cfg.aliases(), vec!["deepseek".to_owned()]);
        assert_eq!(cfg.resolve_harness("deepseek").as_deref(), Some("oc"));
        let d = cfg.defaults_for_request("deepseek", "oc");
        assert_eq!(d.model_for("oc").as_deref(), Some("opencode-go/deepseek-v4-pro"));
        assert_eq!(d.effort.as_deref(), Some("low"));
        // The availability filter skips a preferred profile that cannot run the model.
        let r = cfg.resolve_harness_where("deepseek", |p, m| !(p == "oc" && m == Some("opencode-go/deepseek-v4-pro")));
        assert_eq!(r.as_deref(), Some("pi"));
        // No candidate passes: the first installed one is used.
        let r = cfg.resolve_harness_where("deepseek", |_, _| false);
        assert_eq!(r.as_deref(), Some("oc"));
        // A family or profile request never picks up an alias entry.
        assert!(cfg.defaults_for_request("opencode", "oc").models.is_empty());
        // Round-trips through JSON as camelCase under "defaults".
        let text = serde_json::to_string(&cfg).unwrap();
        assert!(text.contains("\"defaults\":{\"claude\""), "{text}");
        let back: Config = serde_json::from_str(&text).unwrap();
        assert_eq!(back.defaults, cfg.defaults);
    }

    #[test]
    fn save_leaves_discovered_profiles_out() {
        let dir = std::env::temp_dir().join(format!("acpmux-save-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut cfg = Config::default();
        cfg.path = Some(dir.join("config.json"));
        let mut claude = prof(HarnessKind::ClaudeStdio, &["claude"]);
        claude.fallback = Some("claude-sr".into());
        cfg.harnesses.insert("claude".into(), claude);
        cfg.harnesses.insert("claude-sr".into(), prof(HarnessKind::ClaudeStdio, &["sr", "claude", "proxy"]));
        cfg.harnesses.insert("pi".into(), prof(HarnessKind::Acp, &["pi-acp"]));
        cfg.discovered = ["claude-sr".to_owned(), "pi".to_owned()].into_iter().collect();
        cfg.auto_fallback = Some(("claude".into(), "claude-sr".into()));
        cfg.default_harness = Some("pi".into());
        cfg.auto_default = true;
        cfg.defaults.insert("claude".into(), SessionDefaults { model: Some("m".into()), ..Default::default() });
        cfg.save().unwrap();
        let text = std::fs::read_to_string(dir.join("config.json")).unwrap();
        let v: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["harnesses"].as_object().unwrap().keys().cloned().collect::<Vec<_>>(), vec!["claude".to_owned()]);
        assert!(v["harnesses"]["claude"].get("fallback").is_none(), "{text}");
        assert!(v.get("defaultHarness").map(|d| d.is_null()).unwrap_or(true), "{text}");
        assert_eq!(v["defaults"]["claude"]["model"], "m");
        assert!(!text.contains("composerMaxRows"), "{text}");
        let _ = std::fs::remove_dir_all(&dir);
    }

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
        cfg.harnesses.insert("claude-sr".into(), HarnessProfile { kind: HarnessKind::ClaudeStdio, argv: argv(&old), env: BTreeMap::new(), description: None, fallback: None, family: None });
        cfg.harnesses.insert("claude".into(), HarnessProfile { kind: HarnessKind::ClaudeStdio, argv: vec!["claude".into()], env: BTreeMap::new(), description: None, fallback: Some("claude-sr".into()), family: None });
        verify_launchers(&mut cfg);
        assert!(!cfg.harnesses.contains_key("claude-sr"));
        assert_eq!(cfg.harnesses["claude"].fallback, None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
