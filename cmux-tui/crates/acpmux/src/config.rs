//! Configuration: `$ACPMUX_HOME/config.json`, agent registry, store mode.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

static HOME_OVERRIDE: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();

/// Set the state directory for this process, below `ACPMUX_HOME` in
/// precedence. A host binary uses it to keep a tagged build's daemon apart
/// from the user's (`cmux acp` under `CMUX_TAG`). Set once, before `home()`.
pub fn set_home_override(path: PathBuf) {
    let _ = HOME_OVERRIDE.set(path);
}

pub fn home() -> PathBuf {
    if let Ok(v) = std::env::var("ACPMUX_HOME") {
        return PathBuf::from(v);
    }
    if let Some(path) = HOME_OVERRIDE.get() {
        return path.clone();
    }
    dirs::home_dir().unwrap_or_else(|| PathBuf::from(".")).join(".acpmux")
}

/// Unix socket path. macOS limits socket paths to about 100 bytes, so a
/// long home directory falls back to a short path in a private per-user
/// directory under /tmp, derived from the home path so daemon and clients
/// agree.
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
    let dir = PathBuf::from(format!("/tmp/acpmux-{uid}"));
    if private_dir(&dir, uid) {
        return dir.join(format!("{hash:016x}.sock"));
    }
    // Another user owns or can write the shared directory: never trust a
    // socket there. The long path fails to bind with a clear error instead.
    preferred
}

/// Create `dir` mode 0700 if missing; true only when it is a real directory
/// owned by `uid` that nobody else can enter.
fn private_dir(dir: &Path, uid: u32) -> bool {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt};
    let _ = std::fs::DirBuilder::new().mode(0o700).create(dir);
    match std::fs::symlink_metadata(dir) {
        Ok(m) => m.is_dir() && m.uid() == uid && m.mode() & 0o077 == 0,
        Err(_) => false,
    }
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
    /// Models this harness can run, declared here when the harness reports
    /// none over ACP (or reports too many): shown in pickers and `daemon
    /// models` ahead of the reported catalog. A string or `{id, name}`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub models: Vec<DeclaredModel>,
    /// Defaults for this profile, the same as a `defaults` entry named
    /// after it; kept inline so one block describes a harness completely.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy: Option<PermissionPolicy>,
}

/// A model in a profile's `models` list: `"id"` or `{"id": …, "name": …}`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(untagged)]
pub enum DeclaredModel {
    Id(String),
    Full {
        id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
    },
}

impl DeclaredModel {
    pub fn id(&self) -> &str {
        match self {
            DeclaredModel::Id(s) => s,
            DeclaredModel::Full { id, .. } => id,
        }
    }
    pub fn name(&self) -> &str {
        match self {
            DeclaredModel::Id(s) => s,
            DeclaredModel::Full { id, name } => name.as_deref().unwrap_or(id),
        }
    }
}

/// Session defaults for a family or a single profile (`defaults` in
/// config.json). Precedence at `session/new`: explicit request, then the
/// profile's own entry, then its family's entry, then the daemon defaults.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct SessionDefaults {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy: Option<PermissionPolicy>,
    /// Profiles to use, in order, when a session asks for this family:
    /// `["claude-sr", "claude"]` sends `-m claude` to the account pool
    /// first. Absent: the family's only profile, else the profile named
    /// like the family, else the request is refused.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub prefer: Vec<String>,
    /// Extra environment for every process in the family (an API base URL,
    /// a router key variable). The profile's own `env` wins on conflicts.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub env: BTreeMap<String, String>,
}

impl SessionDefaults {
    pub fn overlay(&mut self, top: &SessionDefaults) {
        if top.model.is_some() {
            self.model = top.model.clone();
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
        .map(|a| {
            Path::new(a).file_name().map(|f| f.to_string_lossy().to_lowercase()).unwrap_or_default()
        })
        .collect();
    // A fork is its own family (omp, prime): `-m pi` never lands on one.
    for (needle, family) in [
        ("codex", "codex"),
        ("opencode", "opencode"),
        ("gemini", "gemini"),
        ("pi-acp", "pi"),
        ("omp", "omp"),
        ("prime-agent", "prime"),
        ("claude", "claude"),
    ] {
        if words.iter().any(|w| w.contains(needle)) {
            return family.into();
        }
    }
    name.split(['-', '_', '.']).next().unwrap_or(name).to_lowercase()
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
#[derive(Default)]
pub enum StoreMode {
    Memory,
    #[default]
    Local,
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
        Self { mode: StoreMode::Local, segment_bytes: default_segment_bytes() }
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
    /// Browser origins allowed besides the listener's own and the agent
    /// pane's (for example a page dev server). `null` is never allowed.
    #[serde(default, alias = "allowed_origins", skip_serializing_if = "Vec::is_empty")]
    pub allowed_origins: Vec<String>,
    /// `Host` names allowed besides loopback (a proxy that keeps a public
    /// name). Both lists are read when the listener starts.
    #[serde(default, alias = "allowed_hosts", skip_serializing_if = "Vec::is_empty")]
    pub allowed_hosts: Vec<String>,
}

fn default_palette_prefix() -> String {
    "/".into()
}
fn default_skill_prefix() -> String {
    "$".into()
}
fn default_leader() -> String {
    "ctrl+x".into()
}
fn default_leader_timeout_ms() -> u64 {
    2000
}

/// TUI interaction settings. These deliberately live in acpmux's config so
/// the same preferences apply to the native TUI and future clients.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TuiConfig {
    /// Prefix that opens the command palette/command line (`/` by default).
    #[serde(default = "default_palette_prefix")]
    pub palette_prefix: String,
    /// Additional accepted command prefixes, for example `[":"]`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub palette_aliases: Vec<String>,
    /// Prefix for inline skills (`$` by default).
    #[serde(default = "default_skill_prefix")]
    pub skill_prefix: String,
    /// Sequential leader key, such as `ctrl+x`, `ctrl+space`, or `none`.
    #[serde(default = "default_leader")]
    pub leader: String,
    #[serde(default = "default_leader_timeout_ms")]
    pub leader_timeout_ms: u64,
    /// App action -> key or key sequence; arrays and comma-separated alternatives are accepted.
    #[serde(default)]
    pub keybinds: BTreeMap<String, serde_json::Value>,
    /// Extra skill roots, relative to the selected project or absolute.
    #[serde(default)]
    pub skill_paths: Vec<String>,
}

impl Default for TuiConfig {
    fn default() -> Self {
        Self {
            palette_prefix: default_palette_prefix(),
            palette_aliases: vec![],
            skill_prefix: default_skill_prefix(),
            leader: default_leader(),
            leader_timeout_ms: default_leader_timeout_ms(),
            keybinds: BTreeMap::new(),
            skill_paths: vec![],
        }
    }
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
    /// Named bundles for `-p NAME`: `{"deepseek": {"harness": "opencode",
    /// "model": "opencode-go/deepseek-v4-pro", "effort": "low"}}`.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub presets: BTreeMap<String, Preset>,
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
    #[serde(default)]
    pub tui: TuiConfig,
    /// `pool`: hidden pre-created sessions that make a harness switch
    /// instant (`hub/pool/`).
    #[serde(default, skip_serializing_if = "PoolConfig::is_default")]
    pub pool: PoolConfig,
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
    /// The `defaults.claude.prefer` list discovery filled in, not the user.
    /// `save` drops it only while it is still unchanged.
    #[serde(skip)]
    pub auto_prefer: Option<Vec<String>>,
    /// The dashboard listener could not bind this run, so `websocket` is
    /// not being served. Kept apart so a save does not drop the address.
    #[serde(skip)]
    pub web_unbound: bool,
    /// Loopback page dev server origins from `--allow-dev-origin` (this run
    /// only, never saved).
    #[serde(skip)]
    pub dev_origins: Vec<String>,
    /// Profiles whose launcher failed its start-up check, with the reason.
    /// They stay configured (sessions on them keep their history) but no
    /// family preference or fallback routes new work to them.
    #[serde(skip)]
    pub unavailable: BTreeMap<String, String>,
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

    /// The profile for a `-m` head: a family (its `prefer` list, else its
    /// only profile, else the profile named like it), else a profile name.
    /// Anything else, or a family with several profiles and no `prefer`,
    /// is an error that names what exists.
    pub fn resolve_harness(&self, head: &str) -> std::result::Result<String, String> {
        let fams = self.families();
        if let Some(members) = fams.get(head) {
            if let Some(d) = self.defaults.get(head) {
                // An unavailable profile is skipped; the next preference serves.
                // Only the family's own profiles count; a stray name never
                // routes the family to another family's profile.
                if let Some(p) = d.prefer.iter().find(|p| {
                    members.contains(*p)
                        && self.harnesses.contains_key(*p)
                        && !self.unavailable.contains_key(*p)
                }) {
                    return Ok(p.clone());
                }
            }
            if members.len() == 1 {
                return Ok(members[0].clone());
            }
            if members.iter().any(|m| m == head) {
                return Ok(head.to_owned());
            }
            return Err(format!(
                "family {head:?} has several profiles ({}) and no preference; write one of them, or `acpmux defaults {head} prefer=…`",
                members.join(", ")
            ));
        }
        if self.harnesses.contains_key(head) {
            return Ok(head.to_owned());
        }
        Err(format!(
            "unknown harness {head:?}; families: {}; profiles: {}; presets: {}",
            fams.keys().cloned().collect::<Vec<_>>().join(", "),
            self.harnesses.keys().cloned().collect::<Vec<_>>().join(", "),
            if self.presets.is_empty() {
                "none".to_owned()
            } else {
                self.presets.keys().cloned().collect::<Vec<_>>().join(", ")
            }
        ))
    }

    /// Defaults that apply to a profile: the family's entry, then the
    /// `defaults` entry named after the profile, then the profile's own
    /// inline `model`/`effort`/`policy`.
    pub fn defaults_for(&self, profile: &str) -> SessionDefaults {
        let mut d = SessionDefaults::default();
        if let Some(f) = self.family(profile) {
            if let Some(fd) = self.defaults.get(&f) {
                d.overlay(fd);
            }
            if f != profile
                && let Some(pd) = self.defaults.get(profile)
            {
                d.overlay(pd);
            }
        }
        if let Some(p) = self.harnesses.get(profile) {
            d.overlay(&SessionDefaults {
                model: p.model.clone(),
                effort: p.effort.clone(),
                policy: p.policy,
                prefer: vec![],
                env: BTreeMap::new(),
            });
        }
        d
    }

    pub fn path() -> PathBuf {
        home().join("config.json")
    }

    /// Load config. When no file exists, build defaults and try to import
    /// agent profiles from `~/.acpx/config.json` so existing setups keep working.
    pub fn load() -> Result<Self> {
        Self::load_from(&Self::path())
    }

    pub fn load_from(path: &Path) -> Result<Self> {
        let path = path.to_owned();
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
            if let Some(c) = cfg.harnesses.get_mut("claude")
                && c.fallback.is_none()
                && c.kind == HarnessKind::ClaudeStdio
            {
                c.fallback = Some("claude-sr".into());
                cfg.auto_fallback = Some(("claude".into(), "claude-sr".into()));
            }
            // `-m claude` goes to the pool first, then the direct login, and
            // the pool falls back to the direct login. Only when the user
            // wrote no preference of their own.
            if cfg.discovered.contains("claude-sr") {
                let has_direct = cfg.harnesses.contains_key("claude");
                if let Some(p) = cfg.harnesses.get_mut("claude-sr")
                    && p.fallback.is_none()
                    && has_direct
                {
                    p.fallback = Some("claude".into());
                }
                let entry = cfg.defaults.entry("claude".into()).or_default();
                if entry.prefer.is_empty() {
                    entry.prefer = ["claude-sr", "claude"]
                        .iter()
                        .filter(|n| has_direct || **n != "claude")
                        .map(|n| n.to_string())
                        .collect();
                    cfg.auto_prefer = Some(entry.prefer.clone());
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

    /// Where preset directories live (`presets/` next to config.json); None
    /// for an in-code config, which then takes no `systemPrompt`.
    pub fn presets_dir(&self) -> Option<PathBuf> {
        self.path.as_ref().and_then(|p| p.parent()).map(|d| d.join("presets"))
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
        if let Some((p, f)) = &self.auto_fallback
            && let Some(prof) = on_disk.harnesses.get_mut(p)
            && prof.fallback.as_deref() == Some(f.as_str())
        {
            prof.fallback = None;
        }
        if self.auto_default {
            on_disk.default_harness = None;
        }
        if let Some(generated) = &self.auto_prefer
            && let Some(d) = on_disk.defaults.get_mut("claude")
            && d.prefer == *generated
        {
            d.prefer.clear();
            if d.is_empty() {
                on_disk.defaults.remove("claude");
            }
        }
        write_atomic(path, serde_json::to_string_pretty(&on_disk)?.as_bytes())
    }

    pub fn profile(&self, name: &str) -> Option<&HarnessProfile> {
        self.harnesses.get(name)
    }

    /// The web listener this daemon actually serves, if any.
    pub fn web_listener(&self) -> Option<&WebSocketConfig> {
        self.websocket.as_ref().filter(|_| !self.web_unbound)
    }
}

/// Look for agent adapters in the acpx config and on PATH.
pub fn discover_harnesses() -> BTreeMap<String, HarnessProfile> {
    let mut agents = BTreeMap::new();
    if let Some(home) = dirs::home_dir() {
        let acpx = home.join(".acpx").join("config.json");
        if let Ok(text) = std::fs::read_to_string(&acpx)
            && let Ok(v) = serde_json::from_str::<serde_json::Value>(&text)
            && let Some(map) = v.get("agents").and_then(|a| a.as_object())
        {
            for (name, profile) in map {
                if let Some(argv) = profile.get("argv").and_then(|a| a.as_array()) {
                    let argv: Vec<String> =
                        argv.iter().filter_map(|s| s.as_str().map(str::to_owned)).collect();
                    if !argv.is_empty() {
                        agents.insert(
                            name.clone(),
                            HarnessProfile {
                                kind: HarnessKind::Acp,
                                argv,
                                env: BTreeMap::new(),
                                description: Some("imported from ~/.acpx".into()),
                                fallback: None,
                                family: None,
                                models: vec![],
                                model: None,
                                effort: None,
                                policy: None,
                            },
                        );
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
        ("opencode-v2", "opencode2"),
        ("deepseek", "dsh"),
        // pi (earendil-works/pi) speaks ACP through the pi-acp adapter,
        // which spawns `pi --mode rpc`: `bun add -g pi-acp`.
        ("pi", "pi-acp"),
        // Claude through the subrouter account pool: `sr claude proxy`
        // picks the account with the most quota and fails over on limits.
        ("claude-sr", "sr"),
        // oh-my-pi (can1357/oh-my-pi), a pi fork with a native ACP server.
        ("omp", "omp"),
        // Prime Agent (PrimeIntellect-ai/prime-agent), a pi fork: `--mode acp`.
        ("prime", "prime-agent"),
    ] {
        if agents.contains_key(name) {
            continue;
        }
        if let Some(path) = which(bin) {
            let (kind, argv) = match bin {
                "claude" => (HarnessKind::ClaudeStdio, vec![path]),
                "sr" => (HarnessKind::ClaudeStdio, vec![path, "claude".into(), "proxy".into()]),
                "omp" => (HarnessKind::Acp, vec![path, "acp".into()]),
                "prime-agent" => (HarnessKind::Acp, vec![path, "--mode".into(), "acp".into()]),
                "gemini" => (HarnessKind::Acp, vec![path, "--experimental-acp".into()]),
                "opencode" | "opencode2" => (HarnessKind::Acp, vec![path, "acp".into()]),
                "dsh" => (HarnessKind::Acp, vec![path, "--profile".into(), "acp".into()]),
                _ => (HarnessKind::Acp, vec![path]),
            };
            agents.insert(
                name.to_owned(),
                HarnessProfile {
                    kind,
                    argv,
                    env: BTreeMap::new(),
                    description: Some(if bin == "sr" {
                        "Claude through the subrouter account pool".into()
                    } else {
                        "found on PATH".into()
                    }),
                    fallback: None,
                    family: if matches!(bin, "dsh" | "opencode2") {
                        Some(name.into())
                    } else {
                        None
                    },
                    models: vec![],
                    model: None,
                    effort: None,
                    policy: None,
                },
            );
        }
    }
    // Codex speaks ACP only through its adapter. Without a codex-acp on PATH (or an ~/.acpx
    // entry), an installed codex still gets a harness through the pinned adapter package.
    if !agents.contains_key("codex")
        && let Some(profile) =
            codex_through_adapter_package(which("codex").as_deref(), which("npx").as_deref())
    {
        agents.insert("codex".to_owned(), profile);
    }
    // A direct Claude falls over to the pool when its account is exhausted.
    if agents.contains_key("claude-sr")
        && let Some(c) = agents.get_mut("claude")
        && c.fallback.is_none()
    {
        c.fallback = Some("claude-sr".into());
    }
    agents
}

/// Drop discovered launcher profiles whose binary cannot actually run the
/// harness: an older subrouter without `claude proxy`, or one whose proxy
/// setup fails before Claude starts. Runs once at daemon start, so a
/// `claude` session never fails over into a launcher that dies at once.
pub fn verify_launchers(cfg: &mut Config) {
    let servers =
        dirs::home_dir().map(|home| home.join(".subrouter/codex/servers.json")).unwrap_or_default();
    let env_route =
        std::env::var("SUBROUTER_URL").ok().or_else(|| crate::login_env::var("SUBROUTER_URL"));
    let route = subrouter_route(env_route.as_deref(), &servers);
    verify_launchers_with(cfg, route);
}

/// The subrouter server Claude traffic goes to when `sr` has no `claude proxy`:
/// `SUBROUTER_URL`, else the default server in `sr`'s own list
/// (`~/.subrouter/codex/servers.json`, read only). Only an http(s) URL counts.
pub fn subrouter_route(env_url: Option<&str>, servers_json: &std::path::Path) -> Option<String> {
    let http = |url: &str| {
        let url = url.trim().trim_end_matches('/');
        (url.starts_with("http://") || url.starts_with("https://")).then(|| url.to_owned())
    };
    if let Some(url) = env_url.and_then(http) {
        return Some(url);
    }
    let value: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(servers_json).ok()?).ok()?;
    let default = value.get("default")?.as_str()?;
    value
        .get("servers")?
        .as_array()?
        .iter()
        .find(|server| server.get("name").and_then(|n| n.as_str()) == Some(default))?
        .get("url")?
        .as_str()
        .and_then(http)
}

/// `verify_launchers` with the subrouter route given: a proxy launcher that
/// fails becomes the `claude` profile routed through that server when there
/// is one, else it is marked unavailable.
pub fn verify_launchers_with(cfg: &mut Config, route: Option<String>) {
    let candidates: Vec<(String, Vec<String>)> = cfg
        .harnesses
        .iter()
        .filter(|(_, p)| {
            p.argv.get(1).map(String::as_str) == Some("claude")
                && p.argv.get(2).map(String::as_str) == Some("proxy")
        })
        .map(|(n, p)| (n.clone(), p.argv.clone()))
        .collect();
    for (name, argv) in candidates {
        if let Err(reason) = launcher_ok(&argv) {
            if let Some(url) = &route
                && let Some(claude) = cfg.harnesses.get("claude").cloned()
            {
                tracing::info!(agent = %name, %url, "{reason}; routing Claude through the subrouter server");
                let mut env = claude.env.clone();
                env.insert("ANTHROPIC_BASE_URL".into(), url.clone());
                // The server picks the pooled account and ignores the client token.
                env.insert("ANTHROPIC_AUTH_TOKEN".into(), "subrouter".into());
                env.insert("ANTHROPIC_CUSTOM_HEADERS".into(), "X-Subrouter-Agent: claude".into());
                let previous = cfg.harnesses.get(&name).cloned();
                cfg.harnesses.insert(
                    name.clone(),
                    HarnessProfile {
                        kind: claude.kind,
                        argv: claude.argv.clone(),
                        env,
                        description: Some(format!("Claude through the subrouter server {url}")),
                        fallback: None,
                        family: previous
                            .as_ref()
                            .and_then(|p| p.family.clone())
                            .or(Some("claude".into())),
                        models: previous.as_ref().map(|p| p.models.clone()).unwrap_or_default(),
                        model: previous.as_ref().and_then(|p| p.model.clone()),
                        effort: previous.as_ref().and_then(|p| p.effort.clone()),
                        policy: previous.as_ref().and_then(|p| p.policy),
                    },
                );
                continue;
            }
            tracing::warn!(agent = %name, "launcher unavailable: {reason}");
            cfg.unavailable.insert(name.clone(), reason);
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
    crate::login_env::apply_std(&mut cmd);
    cmd.args(&argv[1..])
        .arg("--version")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    scrub_nested_claude_env(&mut cmd);
    let mut child = cmd.spawn().map_err(|e| format!("{}: {e}", argv[0]))?;
    // Woken by the child's exit (SIGCHLD), not a polling tick.
    use wait_timeout::ChildExt;
    match child.wait_timeout(std::time::Duration::from_secs(20)) {
        Ok(Some(_)) => {}
        Ok(None) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("{} claude proxy --version did not finish in 20s", argv[0]));
        }
        Err(e) => return Err(e.to_string()),
    }
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    let text =
        format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    // Warnings (a peer that could not be reached) are not failures.
    let first = text
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty() && !l.starts_with("warning:"))
        .unwrap_or("")
        .to_owned();
    if !out.status.success()
        || first.starts_with("subrouter:")
        || text.to_lowercase().contains("unknown command")
    {
        return Err(format!(
            "`{} claude proxy --version` failed: {}",
            argv[0],
            if first.is_empty() { out.status.to_string() } else { first }
        ));
    }
    Ok(())
}

fn which(bin: &str) -> Option<String> {
    let path = crate::login_env::path()?;
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
    // Owner-only from creation: these files hold tokens and session data.
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)
            .with_context(|| format!("write {}", tmp.display()))?;
        f.write_all(bytes).with_context(|| format!("write {}", tmp.display()))?;
    }
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
    for k in nested_claude_keys() {
        cmd.env_remove(k);
    }
}

/// The keys `scrub_nested_claude_env` removes, from the daemon's environment
/// and the imported login environment.
fn nested_claude_keys() -> Vec<std::ffi::OsString> {
    if std::env::var_os("CLAUDECODE").is_none() {
        return Vec::new();
    }
    std::env::vars_os()
        .map(|(k, _)| k)
        .chain(crate::login_env::imported_keys().into_iter().map(Into::into))
        .filter(|k| {
            let key = k.to_string_lossy();
            key.starts_with("CLAUDE")
                || key.starts_with("ANTHROPIC_")
                || key.starts_with("CMUX_CLAUDE_")
                || key.starts_with("SUBROUTER_CLAUDE_")
                || key == "NODE_OPTIONS"
        })
        .collect()
}

/// Same, for tokio's process builder.
pub fn scrub_nested_claude_env_tokio(cmd: &mut tokio::process::Command) {
    for k in nested_claude_keys() {
        cmd.env_remove(k);
    }
}

mod codex_adapter;
pub use codex_adapter::{
    CODEX_ACP_PACKAGE, adapter_package_launch, codex_through_adapter_package,
    resolve_adapter_package_bin,
};
mod pool;
pub use pool::PoolConfig;
mod preset_args;
pub use preset_args::{
    Preset, SYSTEM_PROMPT_FILE, check_preset_args, check_preset_dir_name, checked_system_prompt,
    parse_preset_args, remove_preset_dir, write_system_prompt,
};

#[cfg(test)]
mod tests;
