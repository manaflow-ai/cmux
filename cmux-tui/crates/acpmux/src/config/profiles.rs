//! Harness profile files (BRING-YOUR-OWN-HARNESS H1): one declarative TOML
//! file per harness, also accepted in cmux.json `agents.harnesses` and in a
//! managed (company) folder. Each file maps onto one [`HarnessProfile`]; the
//! extra display, capability, auth and sessions data goes to [`ProfileMeta`].
//!
//! Sources, the first one wins for an id:
//! 1. managed: `/Library/Application Support/cmux/harnesses/*.toml` (macOS),
//!    `/etc/cmux/harnesses/*.toml` (other unix);
//! 2. user files: `$XDG_CONFIG_HOME/cmux/harnesses/*.toml`, default
//!    `~/.config/cmux/harnesses/`;
//! 3. cmux.json `agents.harnesses`.
//!
//! acpmux's own config.json and PATH discovery rank below all three
//! (`Config::join_profiles`). One bad file never stops the others: it gets a
//! [`Diagnostic`] and its id is left out. Diagnostics never carry env values.
//!
//! Env values may be references, resolved only when a harness starts
//! ([`resolve_env_refs`]): `{ keychain = "service[/account]" }` (TOML) or the
//! string `${keychain:service[/account]}`, and `{ env = "VAR" }` or
//! `${env:VAR}` (the login environment). A managed file may not hold a
//! literal value under a secret-looking key; a user file gets a warning.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::{DeclaredModel, HarnessKind, HarnessProfile, PermissionPolicy};

#[path = "profile_env.rs"]
mod env_refs;
#[path = "profile_sessions.rs"]
mod sessions;
use env_refs::is_reference;
pub use env_refs::{has_env_refs, keychain_lookup, resolve_env_refs};
pub use sessions::{
    FieldSelector, SESSION_BUILTIN_ADAPTERS, SESSION_DATA_ADAPTERS, SESSION_FIELDS, SessionsResume,
    SessionsSpec, check_sessions,
};

/// Largest profile file read, in bytes.
pub const MAX_PROFILE_BYTES: u64 = 64 * 1024;
/// Largest icon file accepted, in bytes.
pub const MAX_ICON_BYTES: u64 = 256 * 1024;
/// Built-in icon names a profile may use instead of a file.
pub const BUILTIN_ICONS: &[&str] =
    &["claude", "openai", "codex", "opencode", "pi", "gemini", "terminal", "generic"];
/// Effort ids a profile may declare (the catalog's protocol ids).
pub const EFFORT_IDS: &[&str] = &["none", "minimal", "low", "medium", "high", "xhigh", "max"];

/// Where profile files come from.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ProfileSources {
    /// Managed (company) folders, highest precedence first.
    pub managed: Vec<PathBuf>,
    /// The user's harness folder.
    pub user_dir: Option<PathBuf>,
    /// cmux.json (its `agents.harnesses` object).
    pub cmux_json: Option<PathBuf>,
}

impl ProfileSources {
    /// The folders of this user and machine.
    pub fn current() -> Self {
        let config_dir = std::env::var_os("XDG_CONFIG_HOME")
            .filter(|v| !v.is_empty())
            .map(|v| PathBuf::from(v).join("cmux"))
            .or_else(|| dirs::home_dir().map(|home| home.join(".config").join("cmux")));
        let managed = if std::env::consts::OS == "macos" {
            PathBuf::from("/Library/Application Support/cmux/harnesses")
        } else {
            PathBuf::from("/etc/cmux/harnesses")
        };
        Self {
            managed: vec![managed],
            user_dir: config_dir.as_ref().map(|d| d.join("harnesses")),
            cmux_json: config_dir.map(|d| d.join("cmux.json")),
        }
    }

    /// No sources (a config built in code).
    pub fn none() -> Self {
        Self::default()
    }
}

/// Where a loaded profile came from.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "kebab-case")]
pub enum ProfileSource {
    Managed,
    #[default]
    UserFile,
    CmuxJson,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Error,
    Warning,
}

/// One problem in one profile source, with the fix when there is one.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Diagnostic {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub severity: Severity,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fix: Option<String>,
}

impl Diagnostic {
    pub fn error(path: &str, id: Option<&str>, message: String, fix: Option<String>) -> Self {
        Self {
            path: path.to_owned(),
            id: id.map(str::to_owned),
            severity: Severity::Error,
            message,
            fix,
        }
    }
    pub fn warning(path: &str, id: Option<&str>, message: String, fix: Option<String>) -> Self {
        Self { severity: Severity::Warning, ..Self::error(path, id, message, fix) }
    }
}

/// What the picker may offer for a harness. The session's live ACP config
/// options still win when the harness reports them.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Capabilities {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub effort: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fast: Option<bool>,
    #[serde(default, alias = "permission_modes", skip_serializing_if = "Option::is_none")]
    pub permission_modes: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume: Option<bool>,
}

/// How a user logs in to the harness. No secrets: shown in doctor and in
/// the picker's "unavailable" reason.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AuthNotes {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub login: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub docs: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub check: Vec<String>,
}

/// Catalog metadata for one declared model (M2 user layer input).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ModelDetail {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub short_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub family: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub efforts: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fast: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_window: Option<u64>,
}

/// What a profile file says beyond the [`HarnessProfile`] itself.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ProfileMeta {
    pub source: ProfileSource,
    /// The file (or cmux.json) the profile came from.
    pub source_path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    /// A built-in icon name, or an absolute path to the icon file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capabilities: Option<Capabilities>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auth: Option<AuthNotes>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sessions: Option<SessionsSpec>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub models_command: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub model_details: Vec<ModelDetail>,
    /// The agent whose cmux hooks report status for a terminal harness.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hooks: Option<String>,
}

/// Every profile from every source, and every problem found.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct LoadedProfiles {
    pub profiles: BTreeMap<String, (HarnessProfile, ProfileMeta)>,
    pub diagnostics: Vec<Diagnostic>,
}

// ------------------------------------------------------------- file shape

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "kebab-case")]
enum Protocol {
    #[default]
    Acp,
    Terminal,
    ClaudeStdio,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum EnvValue {
    Plain(String),
    Keychain { keychain: String },
    Env { env: String },
}

#[derive(Debug, Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct FileDefaults {
    model: Option<String>,
    effort: Option<String>,
    policy: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum FileModel {
    Id(String),
    Full(FileModelFull),
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct FileModelFull {
    id: String,
    name: Option<String>,
    #[serde(alias = "shortName")]
    short_name: Option<String>,
    family: Option<String>,
    #[serde(default)]
    efforts: Vec<String>,
    #[serde(alias = "defaultEffort")]
    default_effort: Option<String>,
    fast: Option<bool>,
    #[serde(alias = "contextWindow")]
    context_window: Option<u64>,
}

#[derive(Debug, Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct FileModels {
    #[serde(default)]
    list: Vec<FileModel>,
    #[serde(default)]
    command: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ProfileFile {
    schema: Option<u32>,
    /// Required in a file; in cmux.json the object key is the id.
    id: Option<String>,
    name: Option<String>,
    icon: Option<String>,
    family: Option<String>,
    description: Option<String>,
    #[serde(default)]
    protocol: Protocol,
    command: String,
    #[serde(default)]
    args: Vec<String>,
    fallback: Option<String>,
    #[serde(default)]
    env: BTreeMap<String, EnvValue>,
    defaults: Option<FileDefaults>,
    capabilities: Option<Capabilities>,
    models: Option<FileModels>,
    auth: Option<AuthNotes>,
    sessions: Option<SessionsSpec>,
    hooks: Option<String>,
}

// ---------------------------------------------------------------- loading

/// Load every profile from `sources`, first source wins for an id.
pub fn load(sources: &ProfileSources) -> LoadedProfiles {
    let mut out = LoadedProfiles::default();
    for dir in &sources.managed {
        load_dir(dir, ProfileSource::Managed, &mut out);
    }
    if let Some(dir) = &sources.user_dir {
        load_dir(dir, ProfileSource::UserFile, &mut out);
    }
    if let Some(path) = &sources.cmux_json {
        load_cmux_json(path, &mut out);
    }
    check_fallbacks(&mut out);
    out
}

fn load_dir(dir: &Path, source: ProfileSource, out: &mut LoadedProfiles) {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return,
        Err(e) => {
            out.diagnostics.push(Diagnostic::error(
                &dir.to_string_lossy(),
                None,
                format!("cannot read the folder: {e}"),
                None,
            ));
            return;
        }
    };
    let mut files: Vec<PathBuf> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "toml"))
        .collect();
    files.sort();
    for path in files {
        let text = match read_profile_file(&path, source) {
            Ok(text) => text,
            Err(d) => {
                out.diagnostics.push(d);
                continue;
            }
        };
        let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned());
        let parsed = parse_profile_toml(&text, &path, stem.as_deref(), source);
        insert(out, parsed);
    }
}

/// The file's text after the size, type and owner checks: a profile runs a
/// program with the user's rights, so nobody else may be able to change it.
fn read_profile_file(path: &Path, source: ProfileSource) -> Result<String, Diagnostic> {
    use std::os::unix::fs::MetadataExt;
    let shown = path.to_string_lossy().into_owned();
    let meta = std::fs::metadata(path)
        .map_err(|e| Diagnostic::error(&shown, None, format!("cannot read the file: {e}"), None))?;
    if !meta.is_file() {
        return Err(Diagnostic::error(&shown, None, "not a regular file".into(), None));
    }
    if meta.len() > MAX_PROFILE_BYTES {
        return Err(Diagnostic::error(
            &shown,
            None,
            format!("the file is larger than {MAX_PROFILE_BYTES} bytes"),
            None,
        ));
    }
    let uid = unsafe { libc::getuid() };
    let owner_ok = meta.uid() == uid || (source == ProfileSource::Managed && meta.uid() == 0);
    if !owner_ok || meta.mode() & 0o022 != 0 {
        return Err(Diagnostic::error(
            &shown,
            None,
            "another user can change this file, and a profile runs a program with your rights"
                .into(),
            Some(format!("chmod go-w {shown}")),
        ));
    }
    std::fs::read_to_string(path)
        .map_err(|e| Diagnostic::error(&shown, None, format!("cannot read the file: {e}"), None))
}

fn load_cmux_json(path: &Path, out: &mut LoadedProfiles) {
    let shown = path.to_string_lossy().into_owned();
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return,
        Err(e) => {
            out.diagnostics.push(Diagnostic::error(
                &shown,
                None,
                format!("cannot read: {e}"),
                None,
            ));
            return;
        }
    };
    // cmux.json is JSON with comments; its own reader reports syntax errors,
    // so a file this simple parser cannot read is left to it.
    let Ok(value) = serde_json::from_str::<serde_json::Value>(&strip_json_comments(&text)) else {
        return;
    };
    let Some(map) = value.pointer("/agents/harnesses") else { return };
    let Some(map) = map.as_object() else {
        out.diagnostics.push(Diagnostic::error(
            &shown,
            None,
            "agents.harnesses must be an object of id -> profile".into(),
            None,
        ));
        return;
    };
    for (id, profile) in map {
        let parsed = match serde_json::from_value::<ProfileFile>(profile.clone()) {
            Ok(file) => build(file, path, Some(id), ProfileSource::CmuxJson, Some(id), false),
            Err(e) => Err(vec![Diagnostic::error(
                &shown,
                Some(id),
                format!("agents.harnesses.{id}: {e}"),
                None,
            )]),
        };
        insert(out, parsed);
    }
}

pub type Parsed = Result<(String, HarnessProfile, ProfileMeta, Vec<Diagnostic>), Vec<Diagnostic>>;

fn insert(out: &mut LoadedProfiles, parsed: Parsed) {
    match parsed {
        Ok((id, profile, meta, warnings)) => {
            out.diagnostics.extend(warnings);
            if let Some((_, winner)) = out.profiles.get(&id) {
                out.diagnostics.push(Diagnostic::warning(
                    &meta.source_path,
                    Some(&id),
                    format!("ignored: {} defines {id:?} too and wins", winner.source_path),
                    (winner.source == ProfileSource::Managed).then(|| {
                        "a managed profile cannot be replaced; pick another id".to_owned()
                    }),
                ));
            } else {
                out.profiles.insert(id, (profile, meta));
            }
        }
        Err(errors) => out.diagnostics.extend(errors),
    }
}

fn check_fallbacks(out: &mut LoadedProfiles) {
    let ids: Vec<String> = out.profiles.keys().cloned().collect();
    let mut warnings = Vec::new();
    for (id, (profile, meta)) in &out.profiles {
        if let Some(f) = &profile.fallback
            && !ids.contains(f)
        {
            warnings.push(Diagnostic::warning(
                &meta.source_path,
                Some(id),
                format!("fallback {f:?} is not a profile file; it must be configured elsewhere"),
                None,
            ));
        }
    }
    out.diagnostics.extend(warnings);
}

/// Parse one TOML profile. `stem` is the file name without `.toml`, which
/// must equal the id.
pub fn parse_profile_toml(
    text: &str,
    path: &Path,
    stem: Option<&str>,
    source: ProfileSource,
) -> Parsed {
    let shown = path.to_string_lossy().into_owned();
    let file: ProfileFile = toml::from_str(text).map_err(|e| {
        vec![Diagnostic::error(&shown, stem, e.message().to_string(), toml_fix(&e, text))]
    })?;
    build(file, path, stem, source, None, source == ProfileSource::Managed)
}

/// Parse a folder profile (`<folder>/.cmux/harnesses/<id>.toml`, H4) with the
/// managed rules: a literal value under a secret-looking env key is an error.
/// The returned meta says `user-file`; folder profiles never join the catalog.
pub fn parse_folder_profile_toml(text: &str, path: &Path, stem: Option<&str>) -> Parsed {
    let shown = path.to_string_lossy().into_owned();
    let file: ProfileFile = toml::from_str(text).map_err(|e| {
        vec![Diagnostic::error(&shown, stem, e.message().to_string(), toml_fix(&e, text))]
    })?;
    build(file, path, stem, ProfileSource::UserFile, None, true)
}

/// The line of a TOML error, as a fix hint.
fn toml_fix(e: &toml::de::Error, text: &str) -> Option<String> {
    let span = e.span()?;
    let line = text[..span.start.min(text.len())].matches('\n').count() + 1;
    Some(format!("see line {line}"))
}

fn build(
    file: ProfileFile,
    path: &Path,
    stem: Option<&str>,
    source: ProfileSource,
    json_key: Option<&str>,
    strict: bool,
) -> Parsed {
    let shown = path.to_string_lossy().into_owned();
    let mut errors = Vec::new();
    let mut warnings = Vec::new();
    let id = match (json_key, &file.id) {
        (Some(key), Some(id)) if id != key => {
            errors.push(Diagnostic::error(
                &shown,
                Some(key),
                format!("id {id:?} differs from its key {key:?}"),
                Some(format!("remove id or set it to {key:?}")),
            ));
            key.to_owned()
        }
        (Some(key), _) => key.to_owned(),
        (None, Some(id)) => id.clone(),
        (None, None) => {
            errors.push(Diagnostic::error(
                &shown,
                stem,
                "missing id".into(),
                stem.map(|s| format!("add `id = \"{s}\"`")),
            ));
            stem.unwrap_or_default().to_owned()
        }
    };
    let idr = Some(id.as_str());
    if !valid_id(&id) {
        errors.push(Diagnostic::error(
            &shown,
            idr,
            format!("id {id:?} must be 1-40 lowercase letters, digits or '-', starting with a letter or digit"),
            None,
        ));
    }
    if json_key.is_none()
        && let Some(stem) = stem
        && stem != id
    {
        errors.push(Diagnostic::error(
            &shown,
            idr,
            format!("the file name must be the id: {id}.toml"),
            Some(format!("rename the file to {id}.toml")),
        ));
    }
    if let Some(v) = file.schema
        && v != 1
    {
        errors.push(Diagnostic::error(
            &shown,
            idr,
            format!("schema {v} is not supported (this build reads schema 1)"),
            None,
        ));
    }
    let command = file.command.trim().to_owned();
    if command.is_empty() {
        errors.push(Diagnostic::error(&shown, idr, "command is empty".into(), None));
    } else if command.chars().any(char::is_whitespace) && !Path::new(&command).is_absolute() {
        errors.push(Diagnostic::error(
            &shown,
            idr,
            format!("command {command:?} has spaces"),
            Some("put the program in command and each argument in args".into()),
        ));
    }
    if command.contains("${") {
        errors.push(Diagnostic::error(
            &shown,
            idr,
            "command may not contain ${…}; use args".into(),
            None,
        ));
    }
    let mut env = BTreeMap::new();
    for (key, value) in file.env {
        if !valid_env_key(&key) {
            errors.push(Diagnostic::error(
                &shown,
                idr,
                format!("env key {key:?} is not a valid variable name"),
                None,
            ));
            continue;
        }
        let text = match value {
            EnvValue::Plain(v) => {
                if secret_looking(&key) && !is_reference(&v) && !v.is_empty() {
                    let message = format!("env {key} holds a literal value under a secret name");
                    let fix = Some(format!(
                        "store it in the Keychain and write {key} = {{ keychain = \"cmux-harness/{id}/{key}\" }}"
                    ));
                    if strict {
                        errors.push(Diagnostic::error(&shown, idr, message, fix));
                    } else {
                        warnings.push(Diagnostic::warning(&shown, idr, message, fix));
                    }
                }
                v
            }
            EnvValue::Keychain { keychain } => {
                if keychain.trim().is_empty() || keychain.contains('}') {
                    errors.push(Diagnostic::error(
                        &shown,
                        idr,
                        format!("env {key}: keychain must be \"service\" or \"service/account\""),
                        None,
                    ));
                }
                format!("${{keychain:{keychain}}}")
            }
            EnvValue::Env { env: var } => {
                if !valid_env_key(&var) {
                    errors.push(Diagnostic::error(
                        &shown,
                        idr,
                        format!("env {key}: {var:?} is not a valid variable name"),
                        None,
                    ));
                }
                format!("${{env:{var}}}")
            }
        };
        env.insert(key, text);
    }
    let defaults = file.defaults.unwrap_or_default();
    let policy = match defaults.policy.as_deref().map(str::parse::<PermissionPolicy>) {
        None => None,
        Some(Ok(p)) => Some(p),
        Some(Err(e)) => {
            errors.push(Diagnostic::error(
                &shown,
                idr,
                format!("defaults.policy: {e}"),
                Some("use ask, approve-reads, approve-edits, approve-all or deny-all".into()),
            ));
            None
        }
    };
    let mut check_efforts = |what: &str, efforts: &[String]| {
        for e in efforts {
            if !EFFORT_IDS.contains(&e.as_str()) {
                errors.push(Diagnostic::error(
                    &shown,
                    idr,
                    format!("{what}: unknown effort {e:?}"),
                    Some(format!("use one of {}", EFFORT_IDS.join(", "))),
                ));
            }
        }
    };
    if let Some(c) = &file.capabilities {
        check_efforts("capabilities.effort", &c.effort);
    }
    let models_file = file.models.unwrap_or_default();
    let mut models = Vec::new();
    let mut details = Vec::new();
    for m in models_file.list {
        match m {
            FileModel::Id(id) => models.push(DeclaredModel::Id(id)),
            FileModel::Full(m) => {
                check_efforts(&format!("models {:?}", m.id), &m.efforts);
                if let Some(d) = &m.default_effort {
                    check_efforts(
                        &format!("models {:?} default_effort", m.id),
                        std::slice::from_ref(d),
                    );
                }
                models.push(DeclaredModel::Full { id: m.id.clone(), name: m.name.clone() });
                details.push(ModelDetail {
                    id: m.id,
                    name: m.name,
                    short_name: m.short_name,
                    family: m.family,
                    efforts: m.efforts,
                    default_effort: m.default_effort,
                    fast: m.fast,
                    context_window: m.context_window,
                });
            }
        }
    }
    if models.iter().any(|m| m.id().trim().is_empty()) {
        errors.push(Diagnostic::error(&shown, idr, "a model has an empty id".into(), None));
    }
    let icon = match file.icon {
        None => None,
        Some(icon) if BUILTIN_ICONS.contains(&icon.as_str()) => Some(icon),
        Some(icon) if icon.contains('.') || icon.contains('/') => match check_icon(path, &icon) {
            Ok(p) => Some(p),
            Err(message) => {
                errors.push(Diagnostic::error(&shown, idr, message, None));
                None
            }
        },
        Some(icon) => {
            warnings.push(Diagnostic::warning(
                &shown,
                idr,
                format!("unknown built-in icon {icon:?}; the generic icon is shown"),
                Some(format!(
                    "use a file (icon = \"{id}.svg\") or one of {}",
                    BUILTIN_ICONS.join(", ")
                )),
            ));
            None
        }
    };
    if let Some(sessions) = &file.sessions {
        for message in check_sessions(sessions) {
            errors.push(Diagnostic::error(&shown, idr, message, None));
        }
    }
    if file.protocol == Protocol::Terminal && !models.is_empty() {
        warnings.push(Diagnostic::warning(
            &shown,
            idr,
            "a terminal harness has no model picker; models are ignored".into(),
            None,
        ));
    }
    if !errors.is_empty() {
        return Err(errors);
    }
    let kind = match file.protocol {
        Protocol::Acp => HarnessKind::Acp,
        Protocol::Terminal => HarnessKind::Terminal,
        Protocol::ClaudeStdio => HarnessKind::ClaudeStdio,
    };
    let mut argv = vec![command];
    argv.extend(file.args);
    let profile = HarnessProfile {
        kind,
        argv,
        env,
        description: file.description,
        fallback: file.fallback,
        family: file.family,
        models,
        model: defaults.model,
        effort: defaults.effort,
        policy,
    };
    let meta = ProfileMeta {
        source,
        source_path: shown,
        display_name: file.name,
        icon,
        capabilities: file.capabilities,
        auth: file.auth,
        sessions: file.sessions,
        models_command: models_file.command,
        model_details: details,
        hooks: file.hooks,
    };
    Ok((id, profile, meta, warnings))
}

/// The icon file next to the profile: absolute path when it is a small
/// svg or png.
fn check_icon(profile: &Path, icon: &str) -> Result<String, String> {
    let dir = profile.parent().unwrap_or(Path::new("."));
    let path = dir.join(icon);
    let ext = path.extension().map(|x| x.to_string_lossy().to_lowercase()).unwrap_or_default();
    if ext != "svg" && ext != "png" {
        return Err(format!("icon {icon:?} must be an .svg or .png file"));
    }
    let meta = std::fs::metadata(&path).map_err(|_| format!("icon file {icon:?} is missing"))?;
    if !meta.is_file() || meta.len() > MAX_ICON_BYTES {
        return Err(format!("icon {icon:?} must be a file of at most {MAX_ICON_BYTES} bytes"));
    }
    Ok(path.to_string_lossy().into_owned())
}

pub fn valid_id(id: &str) -> bool {
    let b = id.as_bytes();
    !b.is_empty()
        && b.len() <= 40
        && (b[0].is_ascii_lowercase() || b[0].is_ascii_digit())
        && b.iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-')
}

pub fn valid_env_key(key: &str) -> bool {
    let b = key.as_bytes();
    !b.is_empty()
        && (b[0].is_ascii_alphabetic() || b[0] == b'_')
        && b.iter().all(|c| c.is_ascii_alphanumeric() || *c == b'_')
}

/// A key whose value is probably a credential.
pub fn secret_looking(key: &str) -> bool {
    let k = key.to_ascii_uppercase();
    ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL", "AUTH", "COOKIE"]
        .iter()
        .any(|w| k.contains(w))
}

/// JSON with `//` and `/* */` comments, comments removed (strings kept).
fn strip_json_comments(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    let mut in_string = false;
    while let Some(c) = chars.next() {
        if in_string {
            out.push(c);
            if c == '\\' {
                if let Some(n) = chars.next() {
                    out.push(n);
                }
            } else if c == '"' {
                in_string = false;
            }
            continue;
        }
        match (c, chars.peek()) {
            ('"', _) => {
                in_string = true;
                out.push(c);
            }
            ('/', Some('/')) => {
                for n in chars.by_ref() {
                    if n == '\n' {
                        out.push('\n');
                        break;
                    }
                }
            }
            ('/', Some('*')) => {
                chars.next();
                let mut prev = ' ';
                for n in chars.by_ref() {
                    if prev == '*' && n == '/' {
                        break;
                    }
                    prev = n;
                }
            }
            _ => out.push(c),
        }
    }
    out
}

#[cfg(test)]
#[path = "profiles_tests.rs"]
mod tests;
