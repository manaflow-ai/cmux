//! Screen-detection manifest engine.
//!
//! Ported from herdrdev/herdr `src/detect/manifest.rs` at commit
//! `7b675f42af35508eab66ac42fe1598628597a893` (Apache-2.0, see
//! `manifests/LICENSE`), modified by manaflow: agents are identified by
//! manifest id/alias strings instead of a closed enum, and the engine adds
//! bounded source loading and explain output for a userland plugin.

use std::cmp::Ordering;
use std::collections::{HashMap, hash_map::Entry};
use std::fmt;
use std::fs::File;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use regex::Regex;
use serde::Deserialize;
use sha2::{Digest, Sha256};

/// Highest herdr manifest engine version whose semantics this port covers.
pub const SCREEN_DETECT_ENGINE_VERSION: u32 = 3;

pub const MAX_MANIFEST_BYTES: usize = 256 * 1024;

pub(crate) fn read_bounded_utf8_file(path: &Path, max_bytes: usize) -> io::Result<String> {
    read_bounded_utf8(File::open(path)?, max_bytes)
}

fn read_bounded_utf8(reader: impl Read, max_bytes: usize) -> io::Result<String> {
    let mut bytes = Vec::with_capacity(max_bytes.min(8 * 1024));
    reader
        .take(u64::try_from(max_bytes).unwrap_or(u64::MAX).saturating_add(1))
        .read_to_end(&mut bytes)?;
    if bytes.len() > max_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("file exceeds {max_bytes} bytes"),
        ));
    }
    String::from_utf8(bytes).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

/// Dotted numeric manifest version. Numeric comparison avoids lexical
/// surprises such as `2026.10` sorting before `2026.9`.
#[derive(Debug, Clone)]
pub struct ManifestVersion(String);

impl ManifestVersion {
    pub fn parse(value: &str) -> Result<Self, String> {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            return Err("manifest version must not be empty".into());
        }
        for segment in trimmed.split('.') {
            if segment.is_empty() || !segment.bytes().all(|byte| byte.is_ascii_digit()) {
                return Err(format!("manifest version {trimmed:?} must be dotted numeric"));
            }
            segment.parse::<u64>().map_err(|_| {
                format!("manifest version {trimmed:?} contains an oversized segment")
            })?;
        }
        Ok(Self(trimmed.to_string()))
    }
}

impl fmt::Display for ManifestVersion {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl Ord for ManifestVersion {
    fn cmp(&self, other: &Self) -> Ordering {
        let mut left = self.0.split('.');
        let mut right = other.0.split('.');
        loop {
            match (left.next(), right.next()) {
                (Some(left), Some(right)) => {
                    match left.parse::<u64>().unwrap_or(0).cmp(&right.parse::<u64>().unwrap_or(0)) {
                        Ordering::Equal => {}
                        ordering => return ordering,
                    }
                }
                (Some(left), None) => {
                    let value = left.parse::<u64>().unwrap_or(0);
                    if value != 0 {
                        return Ordering::Greater;
                    }
                }
                (None, Some(right)) => {
                    let value = right.parse::<u64>().unwrap_or(0);
                    if value != 0 {
                        return Ordering::Less;
                    }
                }
                (None, None) => return Ordering::Equal,
            }
        }
    }
}

impl PartialOrd for ManifestVersion {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl PartialEq for ManifestVersion {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}

impl Eq for ManifestVersion {}

impl<'de> Deserialize<'de> for ManifestVersion {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::parse(&value).map_err(serde::de::Error::custom)
    }
}

/// Where a manifest came from. Local overrides always take precedence over
/// a cached remote file, which takes precedence over the bundled copy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ManifestSource {
    Bundled,
    Remote { path: PathBuf, version: ManifestVersion },
    Override(PathBuf),
}

impl ManifestSource {
    pub fn label(&self) -> String {
        match self {
            Self::Bundled => "bundled".into(),
            Self::Remote { path, version } => format!("remote:{}@{version}", path.display()),
            Self::Override(path) => format!("override:{}", path.display()),
        }
    }

    /// Stable source class for machine-readable diagnostics. Keep this
    /// separate from `label`, which contains a local path and is not stable
    /// across hosts.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Bundled => "bundled",
            Self::Remote { .. } => "remote",
            Self::Override(_) => "local_override",
        }
    }
}

/// Load and update diagnostics kept with one compiled manifest. These fields
/// mirror the useful herdr explanation surface without making the daemon
/// aware of cache files or network state.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize)]
pub struct ManifestDiagnostics {
    pub warning: Option<String>,
    pub cached_remote_version: Option<String>,
    pub local_override_shadowing_remote: bool,
    pub remote_update_status: Option<String>,
    pub remote_update_error: Option<String>,
}

const MAX_RULES_PER_MANIFEST: usize = 128;
const MAX_GATE_DEPTH: usize = 8;
const MAX_TOTAL_GATES: usize = 512;
const MAX_MATCHERS_PER_GATE: usize = 32;
const MAX_TOTAL_MATCHERS: usize = 1024;
const MAX_MATCHER_CHARS: usize = 512;
// Keep user-provided catalogs and directories bounded before TOML parsing or
// regex compilation can allocate for every entry.
const MAX_MANIFESTS: usize = 256;
const MAX_MANIFEST_DIRECTORY_ENTRIES: usize = 512;
const TOP_NON_EMPTY_LINES_ENGINE_VERSION: u32 = 3;

/// Detection states a manifest rule can assign to a screen snapshot.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ScreenState {
    Idle,
    Working,
    Blocked,
    Unknown,
}

/// Screen snapshot plus OSC-derived strings. Empty `osc_title` /
/// `osc_progress` behave exactly like the pre-OSC herdr engine.
#[derive(Debug, Clone, Copy)]
pub struct DetectionInput<'a> {
    pub screen: &'a str,
    pub osc_title: &'a str,
    pub osc_progress: &'a str,
}

/// What one manifest evaluation concluded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Detection {
    pub state: ScreenState,
    /// The screen shows an agent-owned viewer (transcript scroll etc.);
    /// the previous state must be kept.
    pub skip_state_update: bool,
    /// Matched rule id, absent when the known-agent idle fallback applied.
    pub matched_rule: Option<String>,
    /// Herdr's visibility hints are retained as evidence for plugin
    /// diagnostics. A hint is true only when the matched rule declares the
    /// same state, matching herdr's publication semantics.
    pub visible_idle: bool,
    pub visible_blocker: bool,
    pub visible_working: bool,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub(crate) struct AgentManifest {
    id: String,
    version: Option<ManifestVersion>,
    min_engine_version: Option<u32>,
    #[serde(rename = "updated_at")]
    _updated_at: Option<String>,
    #[serde(default)]
    aliases: Vec<String>,
    #[serde(default)]
    rules: Vec<ManifestRule>,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
struct ManifestRule {
    id: String,
    state: Option<ManifestState>,
    #[serde(default)]
    priority: i32,
    #[serde(default = "default_region")]
    region: String,
    #[serde(default)]
    visible_idle: bool,
    #[serde(default)]
    visible_blocker: bool,
    #[serde(default)]
    visible_working: bool,
    #[serde(default)]
    skip_state_update: bool,
    #[serde(default)]
    all: Vec<ManifestGate>,
    #[serde(default)]
    any: Vec<ManifestGate>,
    #[serde(default, rename = "not")]
    not_gate: Vec<ManifestGate>,
    #[serde(default)]
    contains: Vec<String>,
    #[serde(default)]
    regex: Vec<String>,
    #[serde(default)]
    line_regex: Vec<String>,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
struct ManifestGate {
    #[serde(default)]
    all: Vec<ManifestGate>,
    #[serde(default)]
    any: Vec<ManifestGate>,
    #[serde(default, rename = "not")]
    not_gate: Vec<ManifestGate>,
    #[serde(default)]
    contains: Vec<String>,
    #[serde(default)]
    regex: Vec<String>,
    #[serde(default)]
    line_regex: Vec<String>,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum ManifestState {
    Idle,
    Working,
    Blocked,
    Unknown,
}

impl From<ManifestState> for ScreenState {
    fn from(value: ManifestState) -> Self {
        match value {
            ManifestState::Idle => ScreenState::Idle,
            ManifestState::Working => ScreenState::Working,
            ManifestState::Blocked => ScreenState::Blocked,
            ManifestState::Unknown => ScreenState::Unknown,
        }
    }
}

fn default_region() -> String {
    "whole_recent".to_string()
}

#[derive(Debug, Clone)]
struct CompiledGate {
    all: Vec<CompiledGate>,
    any: Vec<CompiledGate>,
    not_gate: Vec<CompiledGate>,
    contains: Vec<String>,
    regex: Vec<Regex>,
    line_regex: Vec<Regex>,
}

/// One agent manifest with its rule gates compiled to regex matchers.
#[derive(Debug, Clone)]
pub struct CompiledManifest {
    manifest: AgentManifest,
    compiled_rules: Vec<CompiledGate>,
    source: ManifestSource,
    diagnostics: ManifestDiagnostics,
}

impl CompiledManifest {
    pub fn id(&self) -> &str {
        &self.manifest.id
    }

    pub fn version(&self) -> Option<&ManifestVersion> {
        self.manifest.version.as_ref()
    }

    pub fn source(&self) -> &ManifestSource {
        &self.source
    }

    pub fn diagnostics(&self) -> &ManifestDiagnostics {
        &self.diagnostics
    }

    /// True when a process name equals the manifest id or one of its
    /// aliases after path/basename and extension normalization.
    pub fn matches_process_name(&self, process_name: &str) -> bool {
        let name = normalized_agent_lookup_name(path_basename(process_name));
        name == self.manifest.id
            || (self.manifest.id == "muse" && is_versioned_muse_binary(&name))
            || self.manifest.aliases.iter().any(|alias| normalized_agent_lookup_name(alias) == name)
    }

    /// Evaluate every rule against the snapshot; the highest-priority match
    /// wins (first rule wins a priority tie). No match falls back to `Idle`:
    /// a known agent showing none of its working/blocked chrome is at rest
    /// (herdr's `default_known_agent_idle_fallback`).
    pub fn detect(&self, input: DetectionInput<'_>) -> Detection {
        let mut matched: Option<&ManifestRule> = None;
        let mut regions = HashMap::new();
        for (rule, compiled) in self.manifest.rules.iter().zip(&self.compiled_rules) {
            let (region_text, lower_region_text) = cached_region(&mut regions, input, &rule.region);
            if !compiled_gate_matches(compiled, region_text, lower_region_text) {
                continue;
            }
            match matched {
                Some(previous) if previous.priority >= rule.priority => {}
                _ => matched = Some(rule),
            }
        }
        let Some(rule) = matched else {
            return Detection {
                state: ScreenState::Idle,
                skip_state_update: false,
                matched_rule: None,
                visible_idle: false,
                visible_blocker: false,
                visible_working: false,
            };
        };
        let state = rule.state.map(ScreenState::from).unwrap_or(ScreenState::Unknown);
        Detection {
            state,
            skip_state_update: rule.skip_state_update,
            matched_rule: Some(rule.id.clone()),
            visible_idle: rule.visible_idle && state == ScreenState::Idle,
            visible_blocker: rule.visible_blocker && state == ScreenState::Blocked,
            visible_working: rule.visible_working && state == ScreenState::Working,
        }
    }

    /// Explain every rule evaluation. This keeps diagnosis next to the
    /// userland rule engine and avoids adding a privileged daemon endpoint.
    pub fn explain(&self, input: DetectionInput<'_>) -> DetectionExplain {
        let mut selected: Option<&ManifestRule> = None;
        let mut evaluated_rules = Vec::with_capacity(self.manifest.rules.len());
        let mut regions = HashMap::new();
        for (rule, compiled) in self.manifest.rules.iter().zip(&self.compiled_rules) {
            let (text, lower_text) = cached_region(&mut regions, input, &rule.region);
            let matched = compiled_gate_matches(compiled, text, lower_text);
            let evidence =
                gate_evidence(&manifest_gate_from_rule(rule), compiled, text, lower_text);
            evaluated_rules.push(RuleExplanation {
                id: rule.id.clone(),
                priority: rule.priority,
                region: rule.region.clone(),
                state: rule.state.map(ScreenState::from).unwrap_or(ScreenState::Unknown),
                matched,
                region_bytes: text.len(),
                region_preview: preview(text),
                visible_idle: rule.visible_idle,
                visible_blocker: rule.visible_blocker,
                visible_working: rule.visible_working,
                contains: rule.contains.clone(),
                regex: rule.regex.clone(),
                line_regex: rule.line_regex.clone(),
                contains_count: rule.contains.len(),
                regex_count: rule.regex.len(),
                line_regex_count: rule.line_regex.len(),
                all_count: rule.all.len(),
                any_count: rule.any.len(),
                not_count: rule.not_gate.len(),
                evidence,
            });
            if matched && selected.is_none_or(|previous| previous.priority < rule.priority) {
                selected = Some(rule);
            }
        }
        let (state, matched_rule, skip_state_update, fallback_reason) = match selected {
            Some(rule) => (
                rule.state.map(ScreenState::from).unwrap_or(ScreenState::Unknown),
                Some(rule.id.clone()),
                rule.skip_state_update,
                None,
            ),
            None => (ScreenState::Idle, None, false, Some("known_agent_idle_fallback".into())),
        };
        DetectionExplain {
            process_name: self.manifest.id.clone(),
            agent: Some(self.manifest.id.clone()),
            state,
            source: self.source.label(),
            source_kind: self.source.kind(),
            version: self.manifest.version.as_ref().map(ToString::to_string),
            matched_rule,
            skip_state_update,
            fallback_reason,
            visible_idle: selected.is_some_and(|rule| {
                rule.visible_idle && rule.state.map(ScreenState::from) == Some(ScreenState::Idle)
            }),
            visible_blocker: selected.is_some_and(|rule| {
                rule.visible_blocker
                    && rule.state.map(ScreenState::from) == Some(ScreenState::Blocked)
            }),
            visible_working: selected.is_some_and(|rule| {
                rule.visible_working
                    && rule.state.map(ScreenState::from) == Some(ScreenState::Working)
            }),
            screen_detection_skipped: false,
            skipped_update_reason: selected
                .filter(|rule| rule.skip_state_update)
                .map(|rule| format!("matched_rule:{}", rule.id)),
            warning: self.diagnostics.warning.clone(),
            cached_remote_version: self.diagnostics.cached_remote_version.clone(),
            local_override_shadowing_remote: self.diagnostics.local_override_shadowing_remote,
            remote_update_status: self.diagnostics.remote_update_status.clone(),
            remote_update_error: self.diagnostics.remote_update_error.clone(),
            evaluated_rules,
        }
    }
}

/// One rule's diagnostic result.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct RuleExplanation {
    pub id: String,
    pub priority: i32,
    pub region: String,
    pub state: ScreenState,
    pub matched: bool,
    pub region_bytes: usize,
    pub region_preview: String,
    pub visible_idle: bool,
    pub visible_blocker: bool,
    pub visible_working: bool,
    /// The literal matcher expressions from the manifest. Herdr exposes
    /// these in its explain output; retaining them makes a userland rule
    /// diagnosis actionable without exposing compiled regex internals.
    pub contains: Vec<String>,
    pub regex: Vec<String>,
    pub line_regex: Vec<String>,
    pub contains_count: usize,
    pub regex_count: usize,
    pub line_regex_count: usize,
    pub all_count: usize,
    pub any_count: usize,
    pub not_count: usize,
    /// Matcher evidence contains only expressions that matched. Nested gate
    /// results retain their own `matched` flag, so `explain` can show why an
    /// `all`, `any`, or `not` gate passed or failed without exposing compiled
    /// regex internals.
    pub evidence: GateEvidence,
}

/// Match evidence for one manifest gate. This is package-owned diagnostic
/// data, not a daemon policy type. The full expressions remain on
/// `RuleExplanation`; these lists contain only the expressions that matched
/// the supplied region.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct GateEvidence {
    pub matched: bool,
    pub contains: Vec<String>,
    pub regex: Vec<String>,
    pub line_regex: Vec<String>,
    pub all: Vec<GateEvidence>,
    pub any: Vec<GateEvidence>,
    pub not_gate: Vec<GateEvidence>,
}

/// Userland diagnostic result for one process and terminal snapshot.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct DetectionExplain {
    pub process_name: String,
    pub agent: Option<String>,
    pub state: ScreenState,
    pub source: String,
    pub source_kind: &'static str,
    pub version: Option<String>,
    pub matched_rule: Option<String>,
    pub skip_state_update: bool,
    pub screen_detection_skipped: bool,
    pub skipped_update_reason: Option<String>,
    pub fallback_reason: Option<String>,
    pub visible_idle: bool,
    pub visible_blocker: bool,
    pub visible_working: bool,
    pub warning: Option<String>,
    pub cached_remote_version: Option<String>,
    pub local_override_shadowing_remote: bool,
    pub remote_update_status: Option<String>,
    pub remote_update_error: Option<String>,
    pub evaluated_rules: Vec<RuleExplanation>,
}

impl DetectionExplain {
    fn unknown(process_name: &str) -> Self {
        Self {
            process_name: process_name.to_string(),
            agent: None,
            state: ScreenState::Unknown,
            source: "none".into(),
            source_kind: "none",
            version: None,
            matched_rule: None,
            skip_state_update: false,
            screen_detection_skipped: false,
            skipped_update_reason: None,
            fallback_reason: Some("unknown_agent".into()),
            visible_idle: false,
            visible_blocker: false,
            visible_working: false,
            warning: None,
            cached_remote_version: None,
            local_override_shadowing_remote: false,
            remote_update_status: None,
            remote_update_error: None,
            evaluated_rules: Vec::new(),
        }
    }
}

fn preview(text: &str) -> String {
    let mut preview: String = text.chars().take(160).collect();
    if text.chars().count() > 160 {
        preview.push('…');
    }
    preview
}

/// Resolve and lowercase each distinct region once per screen evaluation.
/// Herdr evaluated the same region independently for every rule. A manifest
/// can contain many rules over `whole_recent` or a shared bottom slice, so
/// reusing both the slice and its case-folded text keeps the hot path linear in
/// the number of distinct regions rather than the number of rules.
fn cached_region<'cache, 'input, 'spec>(
    cache: &'cache mut HashMap<&'spec str, (&'input str, String)>,
    input: DetectionInput<'input>,
    spec: &'spec str,
) -> (&'input str, &'cache str) {
    if let Entry::Vacant(entry) = cache.entry(spec) {
        let text = region(input, spec);
        entry.insert((text, text.to_lowercase()));
    }
    let (text, lower_text) = cache.get(spec).expect("region was inserted above");
    (*text, lower_text.as_str())
}

fn compiled_gate_matches(gate: &CompiledGate, text: &str, lower_text: &str) -> bool {
    if !gate.contains.iter().all(|needle| lower_text.contains(needle)) {
        return false;
    }
    if !gate.regex.iter().all(|regex| regex.is_match(text)) {
        return false;
    }
    if !gate.line_regex.iter().all(|regex| text.lines().any(|line| regex.is_match(line))) {
        return false;
    }
    if !gate.all.iter().all(|nested| compiled_gate_matches(nested, text, lower_text)) {
        return false;
    }
    if !gate.any.is_empty()
        && !gate.any.iter().any(|nested| compiled_gate_matches(nested, text, lower_text))
    {
        return false;
    }
    if gate.not_gate.iter().any(|nested| compiled_gate_matches(nested, text, lower_text)) {
        return false;
    }
    true
}

fn gate_evidence(
    source: &ManifestGate,
    compiled: &CompiledGate,
    text: &str,
    lower_text: &str,
) -> GateEvidence {
    let contains = source
        .contains
        .iter()
        .zip(&compiled.contains)
        .filter(|(_, needle)| lower_text.contains(needle.as_str()))
        .map(|(pattern, _)| pattern.clone())
        .collect();
    let regex = source
        .regex
        .iter()
        .zip(&compiled.regex)
        .filter(|(_, pattern)| pattern.is_match(text))
        .map(|(pattern, _)| pattern.clone())
        .collect();
    let line_regex = source
        .line_regex
        .iter()
        .zip(&compiled.line_regex)
        .filter(|(_, pattern)| text.lines().any(|line| pattern.is_match(line)))
        .map(|(pattern, _)| pattern.clone())
        .collect();
    let all = source
        .all
        .iter()
        .zip(&compiled.all)
        .map(|(nested, compiled)| gate_evidence(nested, compiled, text, lower_text))
        .collect();
    let any = source
        .any
        .iter()
        .zip(&compiled.any)
        .map(|(nested, compiled)| gate_evidence(nested, compiled, text, lower_text))
        .collect();
    let not_gate = source
        .not_gate
        .iter()
        .zip(&compiled.not_gate)
        .map(|(nested, compiled)| gate_evidence(nested, compiled, text, lower_text))
        .collect();
    GateEvidence {
        matched: compiled_gate_matches(compiled, text, lower_text),
        contains,
        regex,
        line_regex,
        all,
        any,
        not_gate,
    }
}

fn normalized_agent_lookup_name(name: &str) -> String {
    let mut name = name.trim().to_lowercase();
    for suffix in [".exe", ".cmd", ".bat", ".ps1", ".js"] {
        if name.ends_with(suffix) {
            name.truncate(name.len() - suffix.len());
            break;
        }
    }
    name
}

fn path_basename(path: &str) -> &str {
    path.rsplit(['/', '\\']).find(|component| !component.is_empty()).unwrap_or(path)
}

fn is_versioned_muse_binary(name: &str) -> bool {
    name.strip_prefix("muse-bin-")
        .is_some_and(|version| version.starts_with(|character: char| character.is_ascii_digit()))
}

/// Every bundled manifest, keyed for foreground-process identification.
#[derive(Debug, Clone)]
pub struct ManifestSet {
    manifests: Vec<CompiledManifest>,
}

/// The vendored herdr manifests (see `manifests/README.md`
/// for the upstream pin). Compile-time embedded; never fetched.
const BUNDLED_MANIFESTS: &[(&str, &str)] = &[
    ("amp", include_str!("../manifests/amp.toml")),
    ("agy", include_str!("../manifests/antigravity.toml")),
    ("claude", include_str!("../manifests/claude.toml")),
    ("cline", include_str!("../manifests/cline.toml")),
    ("codex", include_str!("../manifests/codex.toml")),
    ("cursor", include_str!("../manifests/cursor.toml")),
    ("devin", include_str!("../manifests/devin.toml")),
    ("droid", include_str!("../manifests/droid.toml")),
    ("gemini", include_str!("../manifests/gemini.toml")),
    ("grok", include_str!("../manifests/grok.toml")),
    ("hermes", include_str!("../manifests/hermes.toml")),
    ("kilo", include_str!("../manifests/kilo.toml")),
    ("kimi", include_str!("../manifests/kimi.toml")),
    ("kiro", include_str!("../manifests/kiro.toml")),
    ("maki", include_str!("../manifests/maki.toml")),
    ("muse", include_str!("../manifests/muse.toml")),
    ("opencode", include_str!("../manifests/opencode.toml")),
    ("pi", include_str!("../manifests/pi.toml")),
    ("qodercli", include_str!("../manifests/qodercli.toml")),
    ("qwen", include_str!("../manifests/qwen.toml")),
    ("copilot", include_str!("../manifests/github-copilot.toml")),
];

/// The source filename for each embedded manifest. Labels above are canonical
/// adapter ids; two upstream filenames use compatibility names.
const BUNDLED_MANIFEST_FILES: &[(&str, &str)] = &[
    ("amp", "amp.toml"),
    ("agy", "antigravity.toml"),
    ("claude", "claude.toml"),
    ("cline", "cline.toml"),
    ("codex", "codex.toml"),
    ("cursor", "cursor.toml"),
    ("devin", "devin.toml"),
    ("droid", "droid.toml"),
    ("gemini", "gemini.toml"),
    ("grok", "grok.toml"),
    ("hermes", "hermes.toml"),
    ("kilo", "kilo.toml"),
    ("kimi", "kimi.toml"),
    ("kiro", "kiro.toml"),
    ("maki", "maki.toml"),
    ("muse", "muse.toml"),
    ("opencode", "opencode.toml"),
    ("pi", "pi.toml"),
    ("qodercli", "qodercli.toml"),
    ("qwen", "qwen.toml"),
    ("copilot", "github-copilot.toml"),
];

const BUNDLED_MANIFEST_CHECKSUMS: &str = include_str!("../manifests/SHA256SUMS");

static BUNDLED_SET: OnceLock<ManifestSet> = OnceLock::new();

impl ManifestSet {
    /// The embedded manifest set. Bundled files are pinned by unit tests,
    /// so a compile failure here is a vendoring bug, not a runtime input.
    pub fn bundled() -> &'static ManifestSet {
        BUNDLED_SET.get_or_init(|| {
            verify_bundled_manifest_checksums()
                .expect("bundled screen-detection manifest provenance is invalid");
            Self::from_sources(BUNDLED_MANIFESTS)
                .expect("bundled screen-detection manifests are pinned valid by tests")
        })
    }

    pub fn from_sources(sources: &[(&str, &str)]) -> Result<Self, String> {
        if sources.len() > MAX_MANIFESTS {
            return Err(format!(
                "manifest set contains {} sources, max is {MAX_MANIFESTS}",
                sources.len()
            ));
        }
        let mut set = Self { manifests: Vec::with_capacity(sources.len()) };
        for (label, content) in sources {
            let compiled = compile_manifest_source_with_source(content, ManifestSource::Bundled)
                .map_err(|err| format!("bundled manifest {label} is invalid: {err}"))?;
            set.insert_compiled(compiled)?;
        }
        Ok(set)
    }

    /// Load bundled manifests and apply optional userland sources. The daemon
    /// never reads these directories. This keeps updates and experiments out
    /// of core while preserving deterministic source precedence.
    pub fn from_environment() -> Result<Self, String> {
        let mut set = Self::from_sources(BUNDLED_MANIFESTS)?;
        let cache_dir =
            environment_path("CMUX_AGENT_MANIFEST_CACHE_DIR").or_else(default_cache_directory);
        if let Some(cache_dir) = cache_dir.as_ref() {
            set.apply_directory(cache_dir, |path, manifest| {
                let version = manifest
                    .version
                    .clone()
                    .ok_or_else(|| "remote manifest must include version".to_string())?;
                Ok(ManifestSource::Remote { path, version })
            })?;
        }
        if let Some(override_dir) =
            environment_path("CMUX_AGENT_MANIFEST_DIR").or_else(default_override_directory)
        {
            set.apply_directory(&override_dir, |path, _| Ok(ManifestSource::Override(path)))?;
        }
        // Status is read only after source precedence is resolved. This keeps
        // update diagnostics visible even when a local override is the active
        // manifest, without allowing the status file to select a manifest.
        if let Some(cache_dir) = cache_dir {
            let status = crate::manifest_update::load_status(&cache_dir);
            set.apply_update_status(&status);
        }
        Ok(set)
    }

    fn apply_update_status(&mut self, status: &crate::manifest_update::ManifestUpdateStatus) {
        for manifest in &mut self.manifests {
            let Some(agent) = status.agents.get(manifest.id()) else { continue };
            manifest.diagnostics.remote_update_status = Some(agent.last_result.clone());
            manifest.diagnostics.remote_update_error = agent.last_error.clone();
        }
    }

    fn apply_directory(
        &mut self,
        directory: &Path,
        source: impl Fn(PathBuf, &AgentManifest) -> Result<ManifestSource, String>,
    ) -> Result<(), String> {
        let entries = match std::fs::read_dir(directory) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => {
                return Err(format!("read manifest directory {}: {error}", directory.display()));
            }
        };
        let mut paths = Vec::new();
        for entry in entries {
            if paths.len() >= MAX_MANIFEST_DIRECTORY_ENTRIES {
                return Err(format!(
                    "manifest directory contains more than {MAX_MANIFEST_DIRECTORY_ENTRIES} entries"
                ));
            }
            paths.push(entry.map(|entry| entry.path()).map_err(|error| error.to_string())?);
        }
        paths.sort();
        for path in paths {
            if path.extension().and_then(|extension| extension.to_str()) != Some("toml") {
                continue;
            }
            if path.file_name().and_then(|name| name.to_str()) == Some("status.toml") {
                continue;
            }
            let result = (|| -> Result<CompiledManifest, String> {
                let content = read_bounded_utf8_file(&path, MAX_MANIFEST_BYTES)
                    .map_err(|error| format!("read manifest {}: {error}", path.display()))?;
                let parsed = parse_manifest(&content)
                    .map_err(|error| format!("manifest {} is invalid: {error}", path.display()))?;
                let manifest_source = source(path.clone(), &parsed)?;
                compile_manifest(parsed, manifest_source)
            })();
            let compiled = match result {
                Ok(compiled) => compiled,
                Err(error) => {
                    // Optional userland sources are independent. One broken
                    // override must not hide valid manifests for other agents.
                    eprintln!("cmux-agent-screen-detection: ignoring {error}");
                    continue;
                }
            };
            if let Err(error) = self.insert_compiled(compiled) {
                // Optional userland sources are independent. A conflicting
                // adapter must not prevent valid cached or override files
                // from loading for the other agents.
                eprintln!(
                    "cmux-agent-screen-detection: ignoring manifest {}: {error}",
                    path.display()
                );
            }
        }
        Ok(())
    }

    fn insert_compiled(&mut self, mut compiled: CompiledManifest) -> Result<(), String> {
        let existing_index = self.manifests.iter().position(|item| item.id() == compiled.id());
        if let Some(index) = existing_index {
            let existing = &self.manifests[index];
            if matches!(compiled.source, ManifestSource::Remote { .. })
                && let (Some(incoming), Some(current)) =
                    (compiled.version().cloned(), existing.version().cloned())
                && incoming < current
            {
                compiled.diagnostics.cached_remote_version = Some(incoming.to_string());
                compiled.diagnostics.warning = Some(format!(
                    "ignored remote manifest {} because incoming version {} is older than active version {}",
                    compiled.id(),
                    incoming,
                    current
                ));
                self.manifests[index].diagnostics = compiled.diagnostics;
                return Ok(());
            }
            if matches!(compiled.source, ManifestSource::Override(_)) {
                compiled.diagnostics.cached_remote_version =
                    existing.diagnostics.cached_remote_version.clone().or_else(|| match &existing
                        .source
                    {
                        ManifestSource::Remote { version, .. } => Some(version.to_string()),
                        _ => None,
                    });
                compiled.diagnostics.local_override_shadowing_remote =
                    compiled.diagnostics.cached_remote_version.is_some();
            }

            // Replacing an existing id can change its aliases. Check the new
            // identity set against every other manifest before mutating the
            // collection. Otherwise an override could silently make an alias
            // resolve to two adapters and leave the result dependent on file
            // ordering.
            for (candidate_index, candidate) in self.manifests.iter().enumerate() {
                if candidate_index != index
                    && let Some(identity) = conflicting_identity(candidate, &compiled)
                {
                    return Err(format!(
                        "manifest {} conflicts with {} on process identity {identity:?}",
                        compiled.id(),
                        candidate.id()
                    ));
                }
            }
            self.manifests[index] = compiled;
            return Ok(());
        }

        // A userland source may add a new adapter. Reject ambiguous process
        // identities instead of silently choosing whichever directory entry
        // happened to sort first.
        for candidate in self.manifests.iter() {
            if let Some(identity) = conflicting_identity(candidate, &compiled) {
                return Err(format!(
                    "manifest {} conflicts with {} on process identity {identity:?}",
                    compiled.id(),
                    candidate.id()
                ));
            }
        }
        if self.manifests.len() >= MAX_MANIFESTS {
            return Err(format!(
                "manifest set contains {} manifests, max is {MAX_MANIFESTS}",
                self.manifests.len() + 1
            ));
        }
        self.manifests.push(compiled);
        Ok(())
    }

    pub fn manifests(&self) -> impl Iterator<Item = &CompiledManifest> {
        self.manifests.iter()
    }

    /// The manifest whose id or aliases match the foreground process name,
    /// or `None` when the process is not a supported agent.
    pub fn identify(&self, process_name: &str) -> Option<&CompiledManifest> {
        self.manifests.iter().find(|manifest| manifest.matches_process_name(process_name))
    }

    /// Return a diagnostic explanation for a process name and terminal input.
    /// This is intentionally an SDK/plugin concern, not a daemon endpoint.
    pub fn explain(&self, process_name: &str, input: DetectionInput<'_>) -> DetectionExplain {
        let Some(manifest) = self.identify(process_name) else {
            return DetectionExplain::unknown(process_name);
        };
        let mut explanation = manifest.explain(input);
        explanation.process_name = process_name.to_string();
        explanation
    }
}

/// Verify embedded bytes against the checked-in provenance record. This catches
/// accidental edits to vendored files. It is source integrity, not a release
/// signature, because the checksum file is in the same artifact.
pub fn verify_bundled_manifest_checksums() -> Result<(), String> {
    if BUNDLED_MANIFESTS.len() != BUNDLED_MANIFEST_FILES.len() {
        return Err(format!(
            "bundled manifest mapping has {} ids for {} sources",
            BUNDLED_MANIFEST_FILES.len(),
            BUNDLED_MANIFESTS.len()
        ));
    }

    let mut expected = HashMap::new();
    for (line_number, line) in BUNDLED_MANIFEST_CHECKSUMS.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((digest, filename)) = line.split_once("  ") else {
            return Err(format!(
                "manifest checksum line {} must use '<sha256>  <filename>'",
                line_number + 1
            ));
        };
        if digest.len() != 64 || !digest.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(format!(
                "manifest checksum for {filename:?} is not a 64-character hexadecimal digest"
            ));
        }
        if filename.is_empty()
            || !filename.ends_with(".toml")
            || expected.insert(filename, digest).is_some()
        {
            return Err(format!(
                "manifest checksum filename {filename:?} is duplicated or invalid"
            ));
        }
    }

    if expected.len() != BUNDLED_MANIFEST_FILES.len() {
        return Err(format!(
            "manifest checksum record has {} files for {} bundled manifests",
            expected.len(),
            BUNDLED_MANIFEST_FILES.len()
        ));
    }

    for ((id, content), (mapped_id, filename)) in
        BUNDLED_MANIFESTS.iter().zip(BUNDLED_MANIFEST_FILES.iter())
    {
        if id != mapped_id {
            return Err(format!("manifest checksum mapping disagrees for adapter {id:?}"));
        }
        let Some(expected_digest) = expected.get(filename) else {
            return Err(format!("manifest checksum record has no entry for {filename}"));
        };
        let actual_digest = format!("{:x}", Sha256::digest(content.as_bytes()));
        if !actual_digest.eq_ignore_ascii_case(expected_digest) {
            return Err(format!(
                "bundled manifest {filename} checksum {actual_digest} does not match {expected_digest}"
            ));
        }
    }

    Ok(())
}

pub fn compile_manifest_source(content: &str) -> Result<CompiledManifest, String> {
    compile_manifest_source_with_source(content, ManifestSource::Bundled)
}

fn compile_manifest_source_with_source(
    content: &str,
    source: ManifestSource,
) -> Result<CompiledManifest, String> {
    if content.len() > MAX_MANIFEST_BYTES {
        return Err(format!("manifest exceeds {MAX_MANIFEST_BYTES} bytes"));
    }
    let manifest = parse_manifest(content)?;
    compile_manifest(manifest, source)
}

fn parse_manifest(content: &str) -> Result<AgentManifest, String> {
    let manifest = toml::from_str::<AgentManifest>(content).map_err(|err| err.to_string())?;
    validate_manifest(&manifest)?;
    Ok(manifest)
}

fn environment_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name).map(PathBuf::from).filter(|path| !path.as_os_str().is_empty())
}

fn default_cache_directory() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("XDG_CACHE_HOME").map(PathBuf::from) {
        return Some(path.join("cmux").join("agent-detection"));
    }
    std::env::var_os("HOME").map(PathBuf::from).map(|home| {
        let cache_root = if cfg!(target_os = "macos") {
            home.join("Library").join("Caches")
        } else if cfg!(windows) {
            std::env::var_os("LOCALAPPDATA")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join("AppData").join("Local"))
        } else {
            home.join(".cache")
        };
        cache_root.join("cmux").join("agent-detection")
    })
}

fn default_override_directory() -> Option<PathBuf> {
    let path = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))?
        .join("cmux")
        .join("agent-detection");
    path.exists().then_some(path)
}

fn validate_manifest(manifest: &AgentManifest) -> Result<(), String> {
    validate_manifest_id(&manifest.id, "manifest id")?;
    let mut identities = std::collections::HashSet::new();
    identities.insert(normalized_agent_lookup_name(&manifest.id));
    for alias in &manifest.aliases {
        validate_manifest_alias(alias)?;
        let normalized = normalized_agent_lookup_name(alias);
        if !identities.insert(normalized) {
            return Err(format!("manifest {} contains a duplicate id or alias", manifest.id));
        }
    }
    if let Some(version) = manifest.min_engine_version
        && version > SCREEN_DETECT_ENGINE_VERSION
    {
        return Err(format!(
            "manifest requires engine {version}, this engine is {SCREEN_DETECT_ENGINE_VERSION}"
        ));
    }
    if manifest.rules.is_empty() {
        return Err("manifest must contain at least one rule".to_string());
    }
    if manifest.rules.len() > MAX_RULES_PER_MANIFEST {
        return Err(format!(
            "manifest contains {} rules, max is {MAX_RULES_PER_MANIFEST}",
            manifest.rules.len()
        ));
    }

    let mut complexity = ManifestComplexity::default();
    let mut rule_ids = std::collections::HashSet::new();
    for rule in &manifest.rules {
        if !rule_ids.insert(rule.id.as_str()) {
            return Err(format!(
                "manifest {} contains duplicate rule id {:?}",
                manifest.id, rule.id
            ));
        }
        validate_rule_id(&rule.id)?;
        if rule.skip_state_update {
            if rule.state != Some(ManifestState::Unknown) {
                return Err(format!(
                    "rule {} uses skip_state_update without state = \"unknown\"",
                    rule.id
                ));
            }
            if rule.visible_idle || rule.visible_blocker || rule.visible_working {
                return Err(format!(
                    "rule {} uses skip_state_update with visible state evidence",
                    rule.id
                ));
            }
        }
        validate_region_name(&rule.region)
            .map_err(|err| format!("rule {} uses invalid region: {err}", rule.id))?;
        if rule.region.trim().starts_with("top_non_empty_lines(")
            && manifest
                .min_engine_version
                .is_some_and(|version| version < TOP_NON_EMPTY_LINES_ENGINE_VERSION)
        {
            return Err(format!(
                "rule {} uses top_non_empty_lines but min_engine_version is below {}",
                rule.id, TOP_NON_EMPTY_LINES_ENGINE_VERSION
            ));
        }
        validate_gate(&manifest_gate_from_rule(rule), "rule", 0, &mut complexity)
            .map_err(|err| format!("rule {} has invalid matcher gates: {err}", rule.id))?;
    }
    Ok(())
}

fn validate_manifest_id(value: &str, label: &str) -> Result<(), String> {
    if value.is_empty()
        || value.len() > 64
        || !value.as_bytes().first().is_some_and(|byte| byte.is_ascii_alphanumeric())
        || !value.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_' || byte == b'-'
        })
    {
        return Err(format!("{label} must match [a-z0-9][a-z0-9_-]* and be at most 64 bytes"));
    }
    Ok(())
}

fn validate_rule_id(value: &str) -> Result<(), String> {
    if value.is_empty()
        || value.len() > 128
        || !value.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_' || byte == b'-'
        })
    {
        return Err(format!("manifest rule id {value:?} must match [a-z0-9_-]+"));
    }
    Ok(())
}

fn validate_manifest_alias(value: &str) -> Result<(), String> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.len() > 128
        || trimmed
            .bytes()
            .any(|byte| byte == 0 || byte.is_ascii_control() || byte == b'/' || byte == b'\\')
    {
        return Err(format!(
            "manifest alias {value:?} is empty, too long, or contains a path/control character"
        ));
    }
    Ok(())
}

#[derive(Default)]
struct ManifestComplexity {
    total_gates: usize,
    total_matchers: usize,
}

fn validate_gate(
    gate: &ManifestGate,
    context: &str,
    depth: usize,
    complexity: &mut ManifestComplexity,
) -> Result<(), String> {
    if depth > MAX_GATE_DEPTH {
        return Err(format!("{context} exceeds max gate depth {MAX_GATE_DEPTH}"));
    }
    complexity.total_gates += 1;
    if complexity.total_gates > MAX_TOTAL_GATES {
        return Err(format!("manifest exceeds max gate count {MAX_TOTAL_GATES}"));
    }
    validate_matcher_limits(gate, context, complexity)?;
    if !gate_has_positive_matcher(gate) {
        return Err(format!("{context} must contain a positive matcher"));
    }
    validate_regex_patterns(&gate.regex, context, "regex")?;
    validate_regex_patterns(&gate.line_regex, context, "line_regex")?;
    for nested in &gate.all {
        validate_gate(nested, "all gate", depth + 1, complexity)?;
    }
    for nested in &gate.any {
        validate_gate(nested, "any gate", depth + 1, complexity)?;
    }
    for nested in &gate.not_gate {
        if !gate_has_any_matcher(nested) {
            return Err(format!("{context} contains an empty not gate"));
        }
        validate_not_gate(nested, depth + 1, complexity)?;
    }
    Ok(())
}

fn validate_not_gate(
    gate: &ManifestGate,
    depth: usize,
    complexity: &mut ManifestComplexity,
) -> Result<(), String> {
    if depth > MAX_GATE_DEPTH {
        return Err(format!("not gate exceeds max gate depth {MAX_GATE_DEPTH}"));
    }
    complexity.total_gates += 1;
    if complexity.total_gates > MAX_TOTAL_GATES {
        return Err(format!("manifest exceeds max gate count {MAX_TOTAL_GATES}"));
    }
    validate_matcher_limits(gate, "not gate", complexity)?;
    if !gate_has_any_matcher(gate) {
        return Err("not gate must contain a matcher".to_string());
    }
    validate_regex_patterns(&gate.regex, "not gate", "regex")?;
    validate_regex_patterns(&gate.line_regex, "not gate", "line_regex")?;
    for nested in &gate.all {
        validate_gate(nested, "not all gate", depth + 1, complexity)?;
    }
    for nested in &gate.any {
        validate_gate(nested, "not any gate", depth + 1, complexity)?;
    }
    for nested in &gate.not_gate {
        validate_not_gate(nested, depth + 1, complexity)?;
    }
    Ok(())
}

fn validate_matcher_limits(
    gate: &ManifestGate,
    context: &str,
    complexity: &mut ManifestComplexity,
) -> Result<(), String> {
    let matcher_count = gate.contains.len() + gate.regex.len() + gate.line_regex.len();
    if matcher_count > MAX_MATCHERS_PER_GATE {
        return Err(format!(
            "{context} has {matcher_count} direct matchers, max is {MAX_MATCHERS_PER_GATE}"
        ));
    }
    complexity.total_matchers += matcher_count;
    if complexity.total_matchers > MAX_TOTAL_MATCHERS {
        return Err(format!("manifest exceeds max matcher count {MAX_TOTAL_MATCHERS}"));
    }
    for value in gate.contains.iter().chain(gate.regex.iter()).chain(gate.line_regex.iter()) {
        if value.chars().count() > MAX_MATCHER_CHARS {
            return Err(format!("{context} matcher exceeds max length {MAX_MATCHER_CHARS}"));
        }
    }
    Ok(())
}

fn validate_regex_patterns(patterns: &[String], context: &str, field: &str) -> Result<(), String> {
    for pattern in patterns {
        Regex::new(pattern).map_err(|err| {
            format!("{context} contains invalid {field} pattern {pattern:?}: {err}")
        })?;
    }
    Ok(())
}

fn gate_has_positive_matcher(gate: &ManifestGate) -> bool {
    !gate.contains.is_empty()
        || !gate.regex.is_empty()
        || !gate.line_regex.is_empty()
        || !gate.all.is_empty()
        || !gate.any.is_empty()
}

fn gate_has_any_matcher(gate: &ManifestGate) -> bool {
    gate_has_positive_matcher(gate) || !gate.not_gate.is_empty()
}

fn manifest_gate_from_rule(rule: &ManifestRule) -> ManifestGate {
    ManifestGate {
        all: rule.all.clone(),
        any: rule.any.clone(),
        not_gate: rule.not_gate.clone(),
        contains: rule.contains.clone(),
        regex: rule.regex.clone(),
        line_regex: rule.line_regex.clone(),
    }
}

fn compile_manifest(
    manifest: AgentManifest,
    source: ManifestSource,
) -> Result<CompiledManifest, String> {
    let compiled_rules = compile_rules(&manifest)?;
    Ok(CompiledManifest {
        manifest,
        compiled_rules,
        source,
        diagnostics: ManifestDiagnostics::default(),
    })
}

fn conflicting_identity(left: &CompiledManifest, right: &CompiledManifest) -> Option<String> {
    let mut left_names = Vec::with_capacity(left.manifest.aliases.len() + 1);
    left_names.push(normalized_agent_lookup_name(left.id()));
    left_names
        .extend(left.manifest.aliases.iter().map(|alias| normalized_agent_lookup_name(alias)));
    std::iter::once(right.id())
        .chain(right.manifest.aliases.iter().map(String::as_str))
        .map(normalized_agent_lookup_name)
        .find(|name| left_names.iter().any(|left_name| left_name == name))
}

fn compile_rules(manifest: &AgentManifest) -> Result<Vec<CompiledGate>, String> {
    manifest
        .rules
        .iter()
        .map(|rule| {
            compile_gate(&manifest_gate_from_rule(rule))
                .map_err(|err| format!("rule {} could not be compiled: {err}", rule.id))
        })
        .collect()
}

fn validate_region_name(spec: &str) -> Result<(), String> {
    let trimmed = spec.trim();
    match trimmed {
        "whole_recent"
        | "after_last_prompt_marker"
        | "before_current_prompt_marker"
        | "whole_recent_without_current_prompt_marker"
        | "current_prompt_block_marker"
        | "after_current_prompt_block_marker"
        | "prompt_box_body"
        | "above_prompt_box"
        | "last_non_empty_above_prompt_box"
        | "after_last_horizontal_rule"
        | "osc_title"
        | "osc_progress" => Ok(()),
        _ if region_count(trimmed, "bottom_lines").is_some()
            || region_count(trimmed, "bottom_non_empty_lines").is_some()
            || top_region_count(trimmed).is_some() =>
        {
            Ok(())
        }
        _ => Err(trimmed.to_string()),
    }
}

fn region<'a>(input: DetectionInput<'a>, spec: &str) -> &'a str {
    let trimmed = spec.trim();
    // OSC regions source from their dedicated fields, not the screen.
    match trimmed {
        "osc_title" => return input.osc_title,
        "osc_progress" => return input.osc_progress,
        _ => {}
    }
    let content = input.screen;
    match trimmed {
        "whole_recent" => content,
        "after_last_prompt_marker" => after_last_prompt_marker(content),
        "before_current_prompt_marker" => before_current_prompt_marker(content),
        "whole_recent_without_current_prompt_marker" => {
            whole_recent_without_current_prompt_marker(content)
        }
        "current_prompt_block_marker" => current_prompt_block_marker(content).unwrap_or(""),
        "after_current_prompt_block_marker" => {
            after_current_prompt_block_marker(content).unwrap_or("")
        }
        "prompt_box_body" => prompt_box_body(content).unwrap_or(""),
        "above_prompt_box" => above_prompt_box(content),
        "last_non_empty_above_prompt_box" => last_non_empty_line(above_prompt_box(content)),
        "after_last_horizontal_rule" => after_last_horizontal_rule(content),
        _ => {
            if let Some(count) = region_count(trimmed, "bottom_lines") {
                return bottom_lines(content, count);
            }
            if let Some(count) = region_count(trimmed, "bottom_non_empty_lines") {
                return bottom_non_empty_lines(content, count);
            }
            if let Some(count) = top_region_count(trimmed) {
                return top_non_empty_lines(content, count);
            }
            ""
        }
    }
}

fn region_count(spec: &str, name: &str) -> Option<usize> {
    spec.strip_prefix(name)
        .and_then(|rest| rest.strip_prefix('('))
        .and_then(|rest| rest.strip_suffix(')'))
        .and_then(|count| count.parse::<usize>().ok())
}

const MAX_TOP_REGION_LINE_COUNT: usize = u16::MAX as usize;

fn top_region_count(spec: &str) -> Option<usize> {
    let count = spec.strip_prefix("top_non_empty_lines")?.strip_prefix('(')?.strip_suffix(')')?;
    if count.starts_with('0') || !count.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    count.parse::<usize>().ok().filter(|count| *count <= MAX_TOP_REGION_LINE_COUNT)
}

fn bottom_lines(content: &str, count: usize) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    let start = lines.len().saturating_sub(count);
    slice_from_line_index(content, &lines, start)
}

fn bottom_non_empty_lines(content: &str, count: usize) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    let Some(start_index) = lines
        .iter()
        .enumerate()
        .rev()
        .filter(|(_, line)| !line.trim().is_empty())
        .take(count)
        .last()
        .map(|(index, _)| index)
    else {
        return "";
    };
    slice_from_line_index(content, &lines, start_index)
}

fn top_non_empty_lines(content: &str, count: usize) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    let Some(end_index) = lines
        .iter()
        .enumerate()
        .filter(|(_, line)| !line.trim().is_empty())
        .take(count)
        .last()
        .map(|(index, _)| index)
    else {
        return "";
    };
    let byte_offset = line_start_offset(content, &lines, end_index + 1);
    &content[..byte_offset]
}

fn after_last_prompt_marker(content: &str) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    let Some(index) = lines.iter().rposition(|line| codex_prompt_line(line)) else {
        return content;
    };
    slice_from_line_index(content, &lines, index + 1)
}

fn before_current_prompt_marker(content: &str) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    let Some(index) = current_codex_prompt_index(&lines) else {
        return content;
    };
    let byte_offset = line_start_offset(content, &lines, index);
    &content[..byte_offset.min(content.len())]
}

fn whole_recent_without_current_prompt_marker(content: &str) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    if current_codex_prompt_index(&lines).is_some() { "" } else { content }
}

fn current_prompt_block_marker(content: &str) -> Option<&str> {
    let lines: Vec<&str> = content.lines().collect();
    let prompt_index = current_codex_prompt_index(&lines)?;
    lines[..prompt_index].iter().rev().find(|line| codex_block_marker_line(line)).copied()
}

fn after_current_prompt_block_marker(content: &str) -> Option<&str> {
    let lines: Vec<&str> = content.lines().collect();
    let prompt_index = current_codex_prompt_index(&lines)?;
    let block_index =
        lines[..prompt_index].iter().rposition(|line| codex_block_marker_line(line))?;
    Some(slice_from_line_index(content, &lines, block_index))
}

fn current_codex_prompt_index(lines: &[&str]) -> Option<usize> {
    let prompt_index = lines.iter().rposition(|line| codex_prompt_line(line))?;
    if lines[prompt_index + 1..].iter().any(|line| codex_block_marker_line(line)) {
        return None;
    }
    Some(prompt_index)
}

fn codex_prompt_line(line: &str) -> bool {
    line == "›" || line.starts_with("› ")
}

fn codex_block_marker_line(line: &str) -> bool {
    line.starts_with('•') || line.starts_with('■') || line.starts_with('✗') || line.starts_with('✓')
}

fn prompt_box_body(content: &str) -> Option<&str> {
    let lines: Vec<&str> = content.lines().collect();
    let top = prompt_box_top_border_index(&lines)?;
    let start = line_start_offset(content, &lines, top + 1);
    let end_index = lines[top + 1..]
        .iter()
        .position(|line| is_horizontal_rule(line))
        .map(|relative| top + 1 + relative)
        .unwrap_or(lines.len());
    let end = line_start_offset(content, &lines, end_index);
    Some(&content[start.min(content.len())..end.min(content.len())])
}

fn above_prompt_box(content: &str) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    let Some(top) = prompt_box_top_border_index(&lines) else {
        return content;
    };
    let end = line_start_offset(content, &lines, top);
    &content[..end.min(content.len())]
}

fn after_last_horizontal_rule(content: &str) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    let mut last_rule_end = 0usize;
    for (index, line) in lines.iter().enumerate() {
        if is_horizontal_rule(line) {
            last_rule_end = line_start_offset(content, &lines, index + 1);
        }
    }
    &content[last_rule_end..]
}

fn last_non_empty_line(content: &str) -> &str {
    content.lines().rev().find(|line| !line.trim().is_empty()).unwrap_or("")
}

fn prompt_box_top_border_index(lines: &[&str]) -> Option<usize> {
    let mut border_count = 0;
    for index in (0..lines.len()).rev() {
        if is_horizontal_rule(lines[index]) {
            border_count += 1;
            if border_count == 2 {
                return Some(index);
            }
        }
    }
    None
}

fn is_horizontal_rule(line: &str) -> bool {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return false;
    }
    let rule_chars = trimmed.chars().take_while(|&ch| ch == '─').count();
    if rule_chars == 0 {
        return false;
    }
    let rule_bytes =
        trimmed.char_indices().nth(rule_chars).map(|(index, _)| index).unwrap_or(trimmed.len());
    let suffix = trimmed[rule_bytes..].trim_start();
    suffix.is_empty() || rule_chars >= 3
}

fn slice_from_line_index<'a>(content: &'a str, lines: &[&str], index: usize) -> &'a str {
    let byte_offset = line_start_offset(content, lines, index);
    &content[byte_offset.min(content.len())..]
}

fn line_start_offset(content: &str, lines: &[&str], index: usize) -> usize {
    let target = index.min(lines.len());
    if target == 0 {
        return 0;
    }
    // `str::lines` hides the carriage return in CRLF input. Counting the
    // original newline-delimited chunks preserves byte offsets for both LF
    // and CRLF terminals.
    content.split_inclusive('\n').take(target).map(str::len).sum::<usize>().min(content.len())
}

fn compile_gate(gate: &ManifestGate) -> Result<CompiledGate, String> {
    Ok(CompiledGate {
        all: gate.all.iter().map(compile_gate).collect::<Result<_, _>>()?,
        any: gate.any.iter().map(compile_gate).collect::<Result<_, _>>()?,
        not_gate: gate.not_gate.iter().map(compile_gate).collect::<Result<_, _>>()?,
        contains: gate.contains.iter().map(|needle| needle.to_lowercase()).collect(),
        regex: gate
            .regex
            .iter()
            .map(|pattern| Regex::new(pattern).map_err(|err| err.to_string()))
            .collect::<Result<_, _>>()?,
        line_regex: gate
            .line_regex
            .iter()
            .map(|pattern| Regex::new(pattern).map_err(|err| err.to_string()))
            .collect::<Result<_, _>>()?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(screen: &str) -> DetectionInput<'_> {
        DetectionInput { screen, osc_title: "", osc_progress: "" }
    }

    #[test]
    fn bounded_utf8_reader_rejects_oversized_and_invalid_input() {
        assert_eq!(read_bounded_utf8(&b"hello"[..], 5).unwrap(), "hello");
        assert!(read_bounded_utf8(&b"hello!"[..], 5).is_err());
        assert!(read_bounded_utf8(&[0xff][..], 5).is_err());
    }

    #[test]
    fn screen_detect_manifest_set_rejects_too_many_sources() {
        let contents: Vec<String> = (0..=MAX_MANIFESTS)
            .map(|index| {
                format!(
                    "id = \"agent-{index}\"\n[[rules]]\nid = \"idle\"\nstate = \"idle\"\ncontains = [\"ready\"]\n"
                )
            })
            .collect();
        let sources: Vec<(&str, &str)> =
            contents.iter().map(|content| ("generated", content.as_str())).collect();

        let error = ManifestSet::from_sources(&sources).unwrap_err();
        assert!(error.contains("manifest set contains"), "{error}");
    }

    #[test]
    fn screen_detect_manifest_directory_rejects_too_many_entries() {
        let suffix = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock is after the Unix epoch")
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "cmux-agent-screen-detection-manifest-limit-{}-{suffix}",
            std::process::id()
        ));
        std::fs::create_dir(&directory).expect("create temporary manifest directory");
        for index in 0..=MAX_MANIFEST_DIRECTORY_ENTRIES {
            std::fs::write(directory.join(format!("entry-{index}.txt")), b"")
                .expect("write temporary directory entry");
        }

        let mut set = ManifestSet::from_sources(&[]).expect("empty manifest set");
        let result = set.apply_directory(&directory, |path, _| Ok(ManifestSource::Override(path)));
        let _ = std::fs::remove_dir_all(&directory);

        let error = result.unwrap_err();
        assert!(error.contains("manifest directory contains"), "{error}");
    }

    #[test]
    fn screen_detect_bundled_manifests_all_parse_and_identify() {
        let set = ManifestSet::bundled();
        let ids: Vec<&str> = set.manifests().map(CompiledManifest::id).collect();
        assert_eq!(ids.len(), 21, "all vendored manifests load: {ids:?}");
        for expected in [
            "amp", "agy", "claude", "cline", "codex", "cursor", "devin", "droid", "gemini", "grok",
            "hermes", "kilo", "kimi", "kiro", "maki", "muse", "opencode", "pi", "qodercli", "qwen",
            "copilot",
        ] {
            assert_eq!(
                set.identify(expected).map(CompiledManifest::id),
                Some(expected),
                "{expected} identifies itself"
            );
        }
    }

    #[test]
    fn screen_detect_bundled_manifest_provenance_matches_checked_hashes() {
        verify_bundled_manifest_checksums().expect("bundled manifest hashes should match");
    }

    #[test]
    fn screen_detect_identify_normalizes_paths_aliases_and_case() {
        let set = ManifestSet::bundled();
        for (name, id) in [
            ("/opt/homebrew/bin/codex", "codex"),
            ("claude-code", "claude"),
            ("CLAUDE", "claude"),
            ("cursor-agent", "cursor"),
            ("opencode.exe", "opencode"),
            ("github-copilot", "copilot"),
            (r"C:\Users\dev\kiro-cli.exe", "kiro"),
        ] {
            assert_eq!(set.identify(name).map(CompiledManifest::id), Some(id), "{name}");
        }
        for shell in ["bash", "zsh", "vim", "node", "muse-helper", "codex-helper", ""] {
            assert!(set.identify(shell).is_none(), "{shell} is not an agent");
        }
    }

    #[test]
    fn screen_detect_rule_priority_and_gates_pick_the_strongest_match() {
        let manifest = compile_manifest_source(
            r#"
id = "codex"

[[rules]]
id = "low"
state = "idle"
priority = 1
contains = ["match"]

[[rules]]
id = "high"
state = "working"
priority = 10
contains = ["match"]
all = [{ any = [{ regex = ["w[io]n"] }, { contains = ["fallback"] }] }]
not = [{ contains = ["suppressed"] }]

[[rules]]
id = "line"
state = "blocked"
priority = 5
line_regex = ["^prompt: .*\\?$"]
"#,
        )
        .unwrap();

        let matched = manifest.detect(input("a match that won"));
        assert_eq!(matched.state, ScreenState::Working);
        assert_eq!(matched.matched_rule.as_deref(), Some("high"));

        // The not gate suppresses the strong rule; the weak one remains.
        let suppressed = manifest.detect(input("a match that won but suppressed"));
        assert_eq!(suppressed.state, ScreenState::Idle);
        assert_eq!(suppressed.matched_rule.as_deref(), Some("low"));

        // line_regex must match one whole line, not the flattened text.
        let lined = manifest.detect(input("noise\nprompt: continue?\ntail"));
        assert_eq!(lined.state, ScreenState::Blocked);
        let unlined = manifest.detect(input("prompt: continue? trailing"));
        assert_eq!(unlined.state, ScreenState::Idle);
        assert_eq!(unlined.matched_rule, None, "known-agent idle fallback");
    }

    #[test]
    fn screen_detect_regions_scope_matching_to_screen_slices() {
        let manifest = compile_manifest_source(
            r#"
id = "codex"

[[rules]]
id = "tail"
state = "working"
priority = 10
region = "bottom_non_empty_lines(2)"
contains = ["spinner"]

[[rules]]
id = "title"
state = "blocked"
priority = 20
region = "osc_title"
contains = ["action required"]
"#,
        )
        .unwrap();

        let tail = manifest.detect(input("spinner far above\nline\nlast\nend"));
        assert_eq!(tail.state, ScreenState::Idle, "match above the bottom slice is out of scope");
        let hit = manifest.detect(input("above\nline\nspinner here\nend"));
        assert_eq!(hit.state, ScreenState::Working);

        let titled = manifest.detect(DetectionInput {
            screen: "plain",
            osc_title: "⚠ Action Required",
            osc_progress: "",
        });
        assert_eq!(titled.state, ScreenState::Blocked);
    }

    #[test]
    fn screen_detect_regions_preserve_crlf_boundaries() {
        let manifest = compile_manifest_source(
            r#"
id = "codex"

[[rules]]
id = "before-prompt"
state = "working"
region = "before_current_prompt_marker"
contains = ["work"]

[[rules]]
id = "after-rule"
state = "blocked"
priority = 10
region = "after_last_horizontal_rule"
contains = ["blocked"]
"#,
        )
        .unwrap();

        let before_prompt = manifest.detect(input("work\r\nnoise\r\n› \r\n"));
        assert_eq!(before_prompt.state, ScreenState::Working);

        let after_rule = manifest.detect(input("old\r\n────\r\nblocked\r\n"));
        assert_eq!(after_rule.state, ScreenState::Blocked);
    }

    #[test]
    fn screen_detect_explain_preserves_matcher_evidence() {
        let manifest = compile_manifest_source(
            r#"
id = "codex"

[[rules]]
id = "working"
state = "working"
contains = ["working", "missing literal"]
regex = ["work\\s+now", "missing regex"]
line_regex = ["^working$", "^missing line$"]
"#,
        )
        .unwrap();
        let explanation = manifest.explain(DetectionInput {
            screen: "working\nwork now",
            osc_title: "",
            osc_progress: "",
        });
        let rule = &explanation.evaluated_rules[0];
        assert_eq!(rule.contains, vec!["working", "missing literal"]);
        assert_eq!(rule.regex, vec![r"work\s+now", "missing regex"]);
        assert_eq!(rule.line_regex, vec!["^working$", "^missing line$"]);
        assert!(!rule.matched);
        assert_eq!(rule.evidence.contains, vec!["working"]);
        assert_eq!(rule.evidence.regex, vec![r"work\s+now"]);
        assert_eq!(rule.evidence.line_regex, vec!["^working$"]);
        assert!(!rule.evidence.matched);
    }

    #[test]
    fn screen_detect_explain_includes_explicit_update_status() {
        let mut set = ManifestSet::bundled().clone();
        let mut status = crate::manifest_update::ManifestUpdateStatus::default();
        status.agents.insert(
            "codex".into(),
            crate::manifest_update::ManifestAgentStatus {
                cached_version: Some("2026.08.1".into()),
                attempted_version: Some("2026.08.2".into()),
                last_checked_unix: Some(42),
                last_result: "failed".into(),
                last_error: Some("network unavailable".into()),
            },
        );
        set.apply_update_status(&status);

        let explanation = set.explain("codex", input("idle"));
        assert_eq!(explanation.remote_update_status.as_deref(), Some("failed"));
        assert_eq!(explanation.remote_update_error.as_deref(), Some("network unavailable"));
    }

    #[test]
    fn screen_detect_codex_manifest_classifies_live_screens() {
        let set = ManifestSet::bundled();
        let codex = set.identify("codex").unwrap();

        let working = codex.detect(input("context\n\n• Working (esc to interrupt)\n› \n"));
        assert_eq!(working.state, ScreenState::Working);

        let blocked = codex.detect(input("$ rm -rf build\nAllow command?\n"));
        assert_eq!(blocked.state, ScreenState::Blocked);

        let idle = codex.detect(input("ordinary prompt text"));
        assert_eq!(idle.state, ScreenState::Idle);
        assert!(idle.matched_rule.is_none());

        let viewer = codex.detect(input(
            "› old prompt\ntranscript\n↑/↓ to scroll  pgup/pgdn to page\nhome/end to jump  q to quit  esc to edit prev\n",
        ));
        assert!(viewer.skip_state_update, "transcript viewer keeps the prior state");
    }

    #[test]
    fn screen_detect_imported_claude_mcp_elicitation_is_blocked() {
        let claude = ManifestSet::bundled().identify("claude").unwrap();
        assert_eq!(claude.version().map(ToString::to_string).as_deref(), Some("2026.08.29.1"));

        let blocked = claude.detect(input(
            "MCP server \u{201C}calendar\u{201D} requests your input\n\
             \u{276F} Accept\n\
               Decline\n\
             Esc to cancel\n",
        ));
        assert_eq!(blocked.state, ScreenState::Blocked);
        assert_eq!(blocked.matched_rule.as_deref(), Some("mcp_elicitation_prompt"));
        assert!(blocked.visible_blocker);

        let incomplete = claude.detect(input(
            "MCP server \u{201C}calendar\u{201D} requests your input\n\
             Esc to cancel\n",
        ));
        assert_ne!(incomplete.matched_rule.as_deref(), Some("mcp_elicitation_prompt"));
    }

    #[test]
    fn screen_detect_claude_idle_prompt_ignores_background_shells() {
        let claude = ManifestSet::bundled().identify("claude").unwrap();
        let idle = claude.detect(input(concat!(
            "✻ Sautéed for 10s · 1 shell still running\n\n",
            "──────────────────────────────────────────────────────── WINDOWS ─\n",
            "❯\n",
            "────────────────────────────────────────────────────────────────\n",
            "  ⏵⏵ auto mode on · 1 shell · ← for agents                     /rc\n",
        )));

        assert_eq!(idle.state, ScreenState::Idle);
        assert_eq!(idle.matched_rule.as_deref(), Some("live_prompt_box"));
        assert!(idle.visible_idle);
        assert!(!idle.visible_working);
    }

    #[test]
    fn screen_detect_claude_background_shell_alone_is_idle_fallback() {
        let idle = ManifestSet::bundled()
            .explain("claude", input("  ⏵⏵ auto mode on · 1 shell · ← for agents\n"));

        assert_eq!(idle.state, ScreenState::Idle);
        assert!(idle.matched_rule.is_none());
        assert_eq!(idle.fallback_reason.as_deref(), Some("known_agent_idle_fallback"));
        assert!(!idle.visible_working);
    }

    #[test]
    fn screen_detect_claude_live_turn_with_background_shell_stays_working() {
        let claude = ManifestSet::bundled().identify("claude").unwrap();
        let working = claude.detect(input(concat!(
            "────────────────────────────────────────────────────────────────\n",
            "❯\n",
            "────────────────────────────────────────────────────────────────\n",
            "  ⏵⏵ auto mode on · 1 shell · esc to interrupt\n",
        )));

        assert_eq!(working.state, ScreenState::Working);
        assert_eq!(working.matched_rule.as_deref(), Some("live_turn_working"));
        assert!(working.visible_working);
    }

    #[test]
    fn screen_detect_claude_blocker_with_background_shell_stays_blocked() {
        let claude = ManifestSet::bundled().identify("claude").unwrap();
        let blocked = claude.detect(input(concat!(
            "do you want to proceed?\n",
            "bash command: rm -rf /tmp/test\n",
            "❯ 1. Yes\n",
            "  2. No\n\n",
            "Esc to cancel · Tab to amend · ctrl+e to explain\n",
            "  ⏵⏵ auto mode on · 1 shell · ← for agents\n",
        )));

        assert_eq!(blocked.state, ScreenState::Blocked);
        assert_eq!(blocked.matched_rule.as_deref(), Some("bash_permission_prompt"));
        assert!(blocked.visible_blocker);
        assert!(!blocked.visible_working);
    }

    #[test]
    fn screen_detect_imported_codex_weak_blocker_ignores_previous_prompt() {
        let codex = ManifestSet::bundled().identify("codex").unwrap();
        assert_eq!(codex.version().map(ToString::to_string).as_deref(), Some("2026.08.28.1"));

        let screen = "previous question [y/n]\n\
                      \u{203A} ";
        let result = codex.detect(input(screen));
        assert_eq!(result.state, ScreenState::Idle);
        assert_ne!(result.matched_rule.as_deref(), Some("weak_blocker"));
    }

    #[test]
    fn screen_detect_imported_copilot_background_agents_are_working() {
        let copilot = ManifestSet::bundled().identify("copilot").unwrap();
        assert_eq!(copilot.version().map(ToString::to_string).as_deref(), Some("2026.08.29.1"));

        let working =
            copilot.detect(input("task output\n◎ Waiting for background agents · 2 running\n"));
        assert_eq!(working.state, ScreenState::Working);
        assert_eq!(working.matched_rule.as_deref(), Some("background_agents_working"));
        assert!(working.visible_working);

        let no_icon = copilot.detect(input("Waiting for background agents · 2 running\n"));
        assert_ne!(no_icon.matched_rule.as_deref(), Some("background_agents_working"));
    }

    #[test]
    fn screen_detect_bundled_osc_rules_remain_active() {
        let set = ManifestSet::bundled();

        let claude = set.identify("claude").unwrap();
        let claude_working =
            claude
                .detect(DetectionInput { screen: "", osc_title: "⠋ project", osc_progress: "" });
        assert_eq!(claude_working.state, ScreenState::Working);

        let claude_idle = claude.detect(DetectionInput {
            screen: "",
            osc_title: "✳ project",
            osc_progress: "4;0;0",
        });
        assert_eq!(claude_idle.state, ScreenState::Idle);

        let codex = set.identify("codex").unwrap();
        let codex_blocked = codex.detect(DetectionInput {
            screen: "",
            osc_title: "⚠ Action Required",
            osc_progress: "",
        });
        assert_eq!(codex_blocked.state, ScreenState::Blocked);

        let grok = set.identify("grok").unwrap();
        let grok_working =
            grok.detect(DetectionInput { screen: "", osc_title: "", osc_progress: "4;1;-1" });
        assert_eq!(grok_working.state, ScreenState::Working);

        let grok_idle =
            grok.detect(DetectionInput { screen: "", osc_title: "grok", osc_progress: "4;0;0" });
        assert_eq!(grok_idle.state, ScreenState::Idle);
    }

    #[test]
    fn screen_detect_grok_idle_progress_overrides_custom_title() {
        let grok = ManifestSet::bundled().identify("grok").unwrap();

        let idle = grok.detect(DetectionInput {
            screen: "",
            osc_title: "custom session title",
            osc_progress: "4;0;0",
        });

        assert_eq!(idle.state, ScreenState::Idle);
        assert_eq!(idle.matched_rule.as_deref(), Some("osc_progress_idle"));
    }

    #[test]
    fn screen_detect_grok_spinner_title_overrides_idle_progress() {
        let grok = ManifestSet::bundled().identify("grok").unwrap();

        let working = grok.detect(DetectionInput {
            screen: "",
            osc_title: "⠋ custom session title",
            osc_progress: "4;0;0",
        });

        assert_eq!(working.state, ScreenState::Working);
        assert_eq!(working.matched_rule.as_deref(), Some("osc_title_spinner_working"));
    }

    #[test]
    fn screen_detect_grok_local_patch_rejects_older_remote_manifest() {
        let bundled = include_str!("../manifests/grok.toml");
        let upstream =
            bundled.replacen("version = \"2026.07.16.2.1\"", "version = \"2026.07.16.2\"", 1);
        let mut set = ManifestSet::from_sources(&[("grok", bundled)]).unwrap();
        let remote = compile_manifest_source_with_source(
            &upstream,
            ManifestSource::Remote {
                path: PathBuf::from("/tmp/grok.toml"),
                version: ManifestVersion::parse("2026.07.16.2").unwrap(),
            },
        )
        .unwrap();

        set.insert_compiled(remote).unwrap();

        let active = set.identify("grok").unwrap();
        assert_eq!(active.version().map(ToString::to_string).as_deref(), Some("2026.07.16.2.1"));
        assert!(
            active
                .diagnostics()
                .warning
                .as_deref()
                .is_some_and(|warning| { warning.contains("older than active version") })
        );
    }

    #[test]
    fn screen_detect_manifest_validation_rejects_malformed_sources() {
        for (source, why) in [
            ("id = \"x\"\n", "no rules"),
            (
                "id = \"x\"\n[[rules]]\nid = \"r\"\nstate = \"idle\"\nregion = \"nope\"\ncontains = [\"a\"]\n",
                "unknown region",
            ),
            (
                "id = \"x\"\n[[rules]]\nid = \"r\"\nstate = \"working\"\nskip_state_update = true\ncontains = [\"a\"]\n",
                "skip_state_update requires unknown state",
            ),
            (
                "id = \"x\"\n[[rules]]\nid = \"r\"\nstate = \"idle\"\nregex = [\"(\"]\n",
                "invalid regex",
            ),
            (
                "id = \"x\"\n[[rules]]\nid = \"r\"\nstate = \"idle\"\nsurprise = true\ncontains = [\"a\"]\n",
                "unknown field",
            ),
            (
                "id = \"x\"\nmin_engine_version = 99\n[[rules]]\nid = \"r\"\nstate = \"idle\"\ncontains = [\"a\"]\n",
                "future engine version",
            ),
            (
                "id = \"x\"\n[[rules]]\nid = \"r\"\nstate = \"idle\"\nnot = [{ contains = [\"a\"] }]\n",
                "not-only rule has no positive matcher",
            ),
            (
                "id = \"Codex\"\n[[rules]]\nid = \"r\"\nstate = \"idle\"\ncontains = [\"a\"]\n",
                "manifest ids are stable lowercase names",
            ),
            (
                "id = \"x\"\naliases = [\"x\"]\n[[rules]]\nid = \"r\"\nstate = \"idle\"\ncontains = [\"a\"]\n",
                "duplicate id alias",
            ),
            (
                "id = \"x\"\naliases = [\"../x\"]\n[[rules]]\nid = \"r\"\nstate = \"idle\"\ncontains = [\"a\"]\n",
                "path aliases are unsafe",
            ),
            (
                "id = \"x\"\n[[rules]]\nid = \"same\"\nstate = \"idle\"\ncontains = [\"a\"]\n[[rules]]\nid = \"same\"\nstate = \"working\"\ncontains = [\"b\"]\n",
                "duplicate rule ids",
            ),
        ] {
            assert!(compile_manifest_source(source).is_err(), "{why}");
        }
    }

    #[test]
    fn screen_detect_rejects_alias_conflicts_when_replacing_a_manifest() {
        let first = r#"
id = "first"
aliases = ["shared"]

[[rules]]
id = "idle"
state = "idle"
contains = ["ready"]
"#;
        let second = r#"
id = "second"

[[rules]]
id = "idle"
state = "idle"
contains = ["ready"]
"#;
        let replacement = r#"
id = "first"
aliases = ["second"]

[[rules]]
id = "idle"
state = "idle"
contains = ["ready"]
"#;

        let mut set = ManifestSet::from_sources(&[("first", first), ("second", second)]).unwrap();
        let compiled = compile_manifest_source_with_source(
            replacement,
            ManifestSource::Override(PathBuf::from("/tmp/first.toml")),
        )
        .unwrap();
        let error = set.insert_compiled(compiled).unwrap_err();
        assert!(error.contains("conflicts with second"));
        assert_eq!(set.identify("shared").map(CompiledManifest::id), Some("first"));
        assert_eq!(set.identify("second").map(CompiledManifest::id), Some("second"));
    }
}
