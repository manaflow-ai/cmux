//! Screen-detection manifest engine.
//!
//! Ported from herdrdev/herdr `src/detect/manifest.rs` at commit
//! `7b675f42af35508eab66ac42fe1598628597a893` (Apache-2.0, see
//! `manifests/LICENSE`), modified by manaflow: agents are identified by
//! manifest id/alias strings instead of a closed enum, and the engine adds
//! bounded source loading and explain output for a userland plugin. Claude
//! background-shell regression fixtures are adapted from herdr's
//! `src/detect/manifest/tests.rs` at commit
//! `987b070fbfa187e85009b45cd7e208fc6175ff6a`.

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
/// Explain output used when a known agent has no matching visible rule.
pub const DEFAULT_KNOWN_AGENT_IDLE_FALLBACK: &str = "known_agent_idle_fallback";

pub const MAX_MANIFEST_BYTES: usize = 256 * 1024;

/// Read a UTF-8 file with a hard byte bound. The CLI and library share this
/// helper so diagnostic commands cannot drift from manifest loading rules.
pub fn read_bounded_utf8_file(path: &Path, max_bytes: usize) -> io::Result<String> {
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
            None => {
                (ScreenState::Idle, None, false, Some(DEFAULT_KNOWN_AGENT_IDLE_FALLBACK.into()))
            }
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
    let Some(version) = name.strip_prefix("muse-bin-") else {
        return false;
    };
    let (numeric, suffix) = version.split_once('-').unwrap_or((version, ""));
    let numeric_parts = numeric.split('.').collect::<Vec<_>>();
    if numeric_parts.len() < 2
        || numeric_parts
            .iter()
            .any(|part| part.is_empty() || !part.bytes().all(|byte| byte.is_ascii_digit()))
    {
        return false;
    }
    suffix.is_empty()
        || suffix
            .split(['.', '-'])
            .all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_alphanumeric()))
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
    ("letta", include_str!("../manifests/letta.toml")),
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
    ("letta", "letta.toml"),
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
            if crate::manifest_update::is_status_file(&path) {
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
    for (field, values) in [
        ("contains", gate.contains.as_slice()),
        ("regex", gate.regex.as_slice()),
        ("line_regex", gate.line_regex.as_slice()),
    ] {
        for value in values {
            if value.is_empty() {
                return Err(format!("{context} {field} matcher must not be empty"));
            }
            if value.chars().count() > MAX_MATCHER_CHARS {
                return Err(format!("{context} matcher exceeds max length {MAX_MATCHER_CHARS}"));
            }
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
