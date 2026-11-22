//! Folder harness profiles (BRING-YOUR-OWN-HARNESS H4): a profile file found
//! in a repository or workspace, `<folder>/.cmux/harnesses/<id>.toml`.
//!
//! A folder profile runs a program with the user's rights, and anybody who can
//! change the repository can change the file. So it is never loaded on its
//! own. A session may use it only when ALL of these hold at that spawn:
//! 1. the folder's Trust answer is `trusted` (`trust::get`, AGENT-TRUST-GATE;
//!    a damaged trust record counts as no answer);
//! 2. the user confirmed "Enable harness" for exactly these bytes: the enable
//!    record (`<acpmux home>/harness-enable.json`, 0600) holds (canonical
//!    folder, id, sha256 of the file and icon bytes); any byte change needs a
//!    new confirmation;
//! 3. the session's cwd is inside the folder, and the session is not from a
//!    Web or peer connection;
//! 4. the id is not a catalog profile or family (a folder profile never
//!    replaces a user, managed, cmux.json, config.json or discovered harness).
//!
//! Folder files follow the managed rules (no literal value under a
//! secret-looking env key), may not be symlinks, may not name a relative
//! program path, and keep their icon next to them.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::json;

use super::profiles::{
    Diagnostic, MAX_PROFILE_BYTES, ProfileMeta, Severity, parse_folder_profile_toml,
};
use super::{Config, HarnessProfile};
use crate::trust;

/// The enable record's file name in the acpmux home.
pub const ENABLE_RECORD: &str = "harness-enable.json";

/// Env keys whose value changes which code a program loads. The enable
/// confirmation shows their values with a warning.
pub const CODE_LOADING_ENV: &[&str] = &[
    "PATH",
    "NODE_OPTIONS",
    "NODE_PATH",
    "PYTHONPATH",
    "PYTHONSTARTUP",
    "PYTHONHOME",
    "RUBYOPT",
    "RUBYLIB",
    "PERL5OPT",
    "PERL5LIB",
    "BASH_ENV",
    "ENV",
    "ZDOTDIR",
    "GIT_SSH_COMMAND",
];

/// The folder that holds a folder's profile files.
pub fn profile_dir(folder: &Path) -> PathBuf {
    folder.join(".cmux").join("harnesses")
}

/// Where the trust and enable records are read and written.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FolderGate {
    pub enable_record: PathBuf,
    pub trust: trust::Paths,
}

impl FolderGate {
    /// The records of the acpmux home `home` (the folder of config.json).
    pub fn for_home(home: &Path) -> Option<Self> {
        let user = dirs::home_dir()?;
        Some(Self {
            enable_record: home.join(ENABLE_RECORD),
            trust: trust::Paths {
                claude_json: user.join(".claude.json"),
                codex_config: user.join(".codex").join("config.toml"),
                record: home.join("trust.json"),
                agent_home: trust::agent_home_root(),
            },
        })
    }
}

/// What a folder profile needs before a session may use it.
#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum FolderState {
    /// The folder has no `trusted` answer.
    NeedsTrust,
    /// Trusted, but these bytes were never confirmed.
    NeedsEnable,
    /// Trusted and confirmed: sessions inside the folder may use it.
    Enabled,
    /// The file is invalid or would replace a catalog harness.
    Error,
}

/// One folder profile and its state. Never carries env values.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FolderProfile {
    pub id: String,
    /// The canonical folder (the one that holds `.cmux/harnesses`).
    pub folder: String,
    pub path: String,
    pub state: FolderState,
    /// The folder's trust level: trusted, untrusted or unknown.
    pub trust: String,
    /// sha256 of the file bytes and icon bytes; None when unreadable.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
    /// Files inside the folder that the command line runs or names; their
    /// bytes are part of `sha256`.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub checked_files: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub diagnostics: Vec<Diagnostic>,
    #[serde(skip)]
    pub profile: Option<HarnessProfile>,
    /// The file's display data (name, icon); set once the file parsed.
    #[serde(skip)]
    pub meta: Option<ProfileMeta>,
}

/// Every profile file in `folder`'s `.cmux/harnesses`, by file name.
pub fn scan(cfg: &Config, gate: &FolderGate, folder: &Path) -> Result<Vec<FolderProfile>, String> {
    let folder = canonical(folder)?;
    let dir = profile_dir(&folder);
    let entries = match std::fs::read_dir(&dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
        Err(e) => return Err(format!("cannot read {}: {e}", dir.display())),
    };
    let mut ids: Vec<String> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "toml"))
        .filter_map(|p| p.file_stem().map(|s| s.to_string_lossy().into_owned()))
        .collect();
    ids.sort();
    Ok(ids.iter().filter_map(|id| load_one(cfg, gate, &folder, id)).collect())
}

/// The folder profile `id` of `folder`; None when it has no such file.
pub fn load_one(cfg: &Config, gate: &FolderGate, folder: &Path, id: &str) -> Option<FolderProfile> {
    let folder = canonical(folder).ok()?;
    let dir = profile_dir(&folder);
    let path = dir.join(format!("{id}.toml"));
    std::fs::symlink_metadata(&path).ok()?;
    let shown = path.to_string_lossy().into_owned();
    let level = trust_level(gate, &folder);
    let mut fp = FolderProfile {
        id: id.to_owned(),
        folder: folder.to_string_lossy().into_owned(),
        path: shown.clone(),
        state: FolderState::Error,
        trust: level.as_str().to_owned(),
        sha256: None,
        checked_files: vec![],
        diagnostics: vec![],
        profile: None,
        meta: None,
    };
    let bytes = match read_folder_file(&path) {
        Ok(bytes) => bytes,
        Err(d) => {
            fp.diagnostics.push(d);
            return Some(fp);
        }
    };
    let Ok(text) = std::str::from_utf8(&bytes) else {
        fp.diagnostics.push(Diagnostic::error(&shown, Some(id), "not UTF-8 text".into(), None));
        return Some(fp);
    };
    let (profile, icon, warnings) = match parse_folder_profile_toml(text, &path, Some(id)) {
        Ok((_, profile, meta, warnings)) => {
            let icon = meta.icon.clone();
            fp.meta = Some(meta);
            (profile, icon, warnings)
        }
        Err(errors) => {
            fp.diagnostics = errors;
            return Some(fp);
        }
    };
    fp.diagnostics = warnings;
    let mut hashed = bytes.clone();
    if let Some(icon) = icon.as_deref().filter(|i| i.starts_with('/')) {
        match icon_bytes(&dir, Path::new(icon)) {
            Ok(icon_bytes) => {
                hashed.extend_from_slice(b"\0icon\0");
                hashed.extend_from_slice(&icon_bytes);
            }
            Err(message) => {
                fp.diagnostics.push(Diagnostic::error(&shown, Some(id), message, None));
                return Some(fp);
            }
        }
    }
    let program = &profile.argv[0];
    if program.contains('/') && !Path::new(program).is_absolute() {
        fp.diagnostics.push(Diagnostic::error(
            &shown,
            Some(id),
            format!("command {program:?} is a relative path"),
            Some("use a program name on PATH or an absolute path".into()),
        ));
        return Some(fp);
    }
    if catalog_names(cfg).contains(id) {
        fp.diagnostics.push(Diagnostic::error(
            &shown,
            Some(id),
            format!("{id:?} is already a harness or family; a folder profile cannot replace it"),
            Some("pick another id (rename the file and its id)".into()),
        ));
        return Some(fp);
    }
    match checked_files(&folder, &profile) {
        Ok(files) => {
            for (path, digest) in files {
                hashed.extend_from_slice(b"\0file\0");
                hashed.extend_from_slice(path.as_bytes());
                hashed.extend_from_slice(b"\0");
                hashed.extend_from_slice(digest.as_bytes());
                fp.checked_files.push(path);
            }
        }
        Err(message) => {
            fp.diagnostics.push(Diagnostic::error(&shown, Some(id), message, None));
            return Some(fp);
        }
    }
    let sha = crate::sha256::sha256_hex(&hashed);
    fp.state = if level != trust::Level::Trusted {
        FolderState::NeedsTrust
    } else if enabled_in(gate, &fp.folder, id, &sha) {
        FolderState::Enabled
    } else {
        FolderState::NeedsEnable
    };
    fp.sha256 = Some(sha);
    fp.profile = Some(profile);
    Some(fp)
}

/// Records the user's "Enable harness" confirmation for the bytes whose
/// sha256 the user saw (`shown_sha256`). Refused unless the folder is trusted
/// now and the file still has exactly those bytes.
pub fn enable(
    cfg: &Config,
    gate: &FolderGate,
    folder: &Path,
    id: &str,
    shown_sha256: &str,
) -> Result<FolderProfile, String> {
    let fp = load_one(cfg, gate, folder, id)
        .ok_or_else(|| format!("{} has no {id}.toml", profile_dir(folder).display()))?;
    if let Some(reason) = refusal(&fp) {
        return Err(reason);
    }
    if fp.sha256.as_deref() != Some(shown_sha256) {
        return Err(format!("{} changed after it was shown; run enable again", fp.path));
    }
    let mut record = read_record(&gate.enable_record)?;
    record.enabled.retain(|e| !(e.folder == fp.folder && e.id == id));
    record.enabled.push(EnableEntry {
        folder: fp.folder.clone(),
        id: id.to_owned(),
        sha256: shown_sha256.to_owned(),
        argv: fp.profile.as_ref().map(|p| p.argv.clone()).unwrap_or_default(),
        enabled_at: crate::store::now_ms(),
    });
    write_record(&gate.enable_record, &record)?;
    load_one(cfg, gate, folder, id).ok_or_else(|| format!("{} disappeared", fp.path))
}

/// Forgets every confirmation of `id` in `folder`. Ok(false): none existed.
pub fn disable(gate: &FolderGate, folder: &Path, id: &str) -> Result<bool, String> {
    let folder = canonical(folder)?.to_string_lossy().into_owned();
    let mut record = read_record(&gate.enable_record)?;
    let before = record.enabled.len();
    record.enabled.retain(|e| !(e.folder == folder && e.id == id));
    if record.enabled.len() == before {
        return Ok(false);
    }
    write_record(&gate.enable_record, &record)?;
    Ok(true)
}

/// Every folder profile a chat in `cwd` sees: those of `cwd` and of each
/// parent, nearest folder first. An id in a nearer folder hides the same id
/// further up, as `resolve_for_session` picks the nearest. An id the catalog
/// has stays in the list as an error (`load_one`).
pub fn scan_for_cwd(cfg: &Config, gate: &FolderGate, cwd: &Path) -> Vec<FolderProfile> {
    let Ok(cwd) = canonical(cwd) else { return vec![] };
    let mut seen = BTreeSet::new();
    let mut out = Vec::new();
    for folder in cwd.ancestors().filter(|f| profile_dir(f).is_dir()) {
        for fp in scan(cfg, gate, folder).unwrap_or_default() {
            if seen.insert(fp.id.clone()) {
                out.push(fp);
            }
        }
    }
    out
}

/// Folder profile `id` of `start` or of its nearest parent that has
/// `.cmux/harnesses/<id>.toml`. None: no folder has the file, or `id` is not
/// a valid id or is a catalog name (a folder profile never replaces one).
pub fn find_nearest(
    cfg: &Config,
    gate: &FolderGate,
    id: &str,
    start: &Path,
) -> Option<FolderProfile> {
    let folder = nearest_folder(cfg, id, start)?;
    load_one(cfg, gate, &folder, id)
}

/// The nearest folder (`start` or a parent) with `.cmux/harnesses/<id>.toml`.
fn nearest_folder(cfg: &Config, id: &str, start: &Path) -> Option<PathBuf> {
    if !super::profiles::valid_id(id) || catalog_names(cfg).contains(id) || !start.is_absolute() {
        return None;
    }
    let start = canonical(start).ok()?;
    let found = start.ancestors().find(|f| profile_dir(f).join(format!("{id}.toml")).exists());
    found.map(Path::to_path_buf)
}

/// What `enable` shows before it records anything, gathered once for the
/// CLI (`cmux harness enable`) and the app's sheet (`_acpmux/harness_enable`)
/// so both show the same facts: the profile and its prompt (`prompt`).
#[derive(Debug, Clone)]
pub struct EnablePrompt {
    pub profile: FolderProfile,
    pub prompt: serde_json::Value,
}

/// Why `prepare_enable` has no prompt to show.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EnableRefusal {
    /// The folder has no such profile file.
    NotFound(String),
    /// No trusted answer, or the file is invalid (`refusal`).
    Refused(String),
}

impl EnableRefusal {
    pub fn message(&self) -> &str {
        match self {
            Self::NotFound(m) | Self::Refused(m) => m,
        }
    }
}

/// Loads folder profile `id` of `folder`, refuses it like `enable` does, and
/// builds the prompt with the program a spawn would run (`resolve_program`).
pub fn prepare_enable(
    cfg: &Config,
    gate: &FolderGate,
    folder: &Path,
    id: &str,
) -> Result<EnablePrompt, EnableRefusal> {
    let fp = load_one(cfg, gate, folder, id).ok_or_else(|| {
        EnableRefusal::NotFound(format!("{} has no {id}.toml", profile_dir(folder).display()))
    })?;
    if let Some(reason) = refusal(&fp) {
        return Err(EnableRefusal::Refused(reason));
    }
    let base = PathBuf::from(&fp.folder);
    let program = fp.profile.as_ref().and_then(|p| resolve_program(p, Some(&base)));
    let prompt = prompt(&fp, program.as_deref());
    Ok(EnablePrompt { profile: fp, prompt })
}

/// The program a spawn of `profile` runs, found the way the spawn finds it:
/// an absolute path as is, a relative one from `base` (else the current
/// folder), a bare name on the profile's own plain PATH (relative entries
/// from `base`) else the login PATH. Only an executable regular file counts.
/// The one resolver of `enable`, the app's Enable sheet and `harness doctor`.
pub fn resolve_program(profile: &HarnessProfile, base: Option<&Path>) -> Option<PathBuf> {
    let program = profile.argv.first().filter(|p| !p.is_empty())?;
    if program.contains('/') {
        let path = match base {
            Some(base) if !Path::new(program).is_absolute() => base.join(program),
            _ => PathBuf::from(program),
        };
        return executable(&path).then_some(path);
    }
    let path = match profile.env.get("PATH").filter(|v| !v.contains("${")) {
        Some(own) => std::ffi::OsString::from(own),
        None => crate::login_env::path()?,
    };
    std::env::split_paths(&path)
        .map(|dir| match base {
            Some(base) if !dir.is_absolute() => base.join(dir),
            _ => dir,
        })
        .map(|dir| dir.join(program))
        .find(|candidate| executable(candidate))
}

/// An executable regular file (a link counts by its target).
fn executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// Why a session may not start a folder profile now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FolderRefusal {
    pub message: String,
    /// `harness.needs_trust` or `harness.needs_enable`, so the app can offer
    /// the folder's Trust question or its Enable harness sheet. None for a
    /// Web or peer connection and for an invalid file.
    pub reason: Option<&'static str>,
    pub id: String,
    /// The folder that holds `.cmux/harnesses`.
    pub folder: String,
}

/// The profile a session named `id` with folder `cwd` may run: an enabled
/// folder profile of the nearest folder (cwd or a parent) that has
/// `.cmux/harnesses/<id>.toml`. None: no folder has that file (the caller
/// reports an unknown harness). Some(Err): a file exists but may not run.
pub fn resolve_for_session(
    cfg: &Config,
    id: &str,
    cwd: &Path,
    remote: bool,
) -> Option<Result<(HarnessProfile, PathBuf), FolderRefusal>> {
    let gate = cfg.folder_gate.as_ref()?;
    let folder = nearest_folder(cfg, id, cwd)?;
    let shown = folder.to_string_lossy().into_owned();
    let refuse = |message: String, reason: Option<&'static str>| FolderRefusal {
        message,
        reason,
        id: id.to_owned(),
        folder: shown.clone(),
    };
    if remote {
        return Some(Err(refuse(
            format!(
                "harness {id} is a folder profile ({}); a Web or peer connection cannot start it",
                folder.display()
            ),
            None,
        )));
    }
    let fp = load_one(cfg, gate, &folder, id)?;
    Some(match (fp.state, fp.profile) {
        (FolderState::Enabled, Some(profile)) => Ok((profile, folder)),
        (FolderState::NeedsTrust, _) => {
            Err(refuse(needs_trust_message_parts(&fp.id, &fp.folder), Some("harness.needs_trust")))
        }
        (FolderState::NeedsEnable, _) => Err(refuse(
            format!(
                "harness {id} is a folder profile in {} that is not enabled (or changed since it was enabled); run `cmux harness enable {id} --folder {}`",
                fp.folder, fp.folder
            ),
            Some("harness.needs_enable"),
        )),
        _ => Err(refuse(first_error_parts(&fp.diagnostics, &fp.path), None)),
    })
}

/// What the "Enable harness" confirmation shows: the file, folder, trust,
/// the exact command line, each env key with its source, and the hash.
/// Plain values are shown: a folder file may not hold a literal secret, and
/// a plain value such as NODE_OPTIONS can load code. Keychain items and
/// login variables are named, never read.
pub fn confirmation_text(fp: &FolderProfile, resolved_program: Option<&Path>) -> String {
    let mut out = format!("Enable harness {:?} from {}\n", fp.id, visible(&fp.path));
    out.push_str(&format!("  folder:  {} (trust: {})\n", visible(&fp.folder), fp.trust));
    let Some(profile) = &fp.profile else { return out };
    let line: Vec<String> = profile.argv.iter().map(|a| shell_quote(a)).collect();
    out.push_str(&format!("  command: {}\n", line.join(" ")));
    match resolved_program {
        Some(p) => out.push_str(&format!("  program: {}\n", visible(&p.to_string_lossy()))),
        None => out.push_str("  program: no executable file found now\n"),
    }
    for file in &fp.checked_files {
        out.push_str(&format!("  checked: {} (a change asks again)\n", visible(file)));
    }
    for warning in program_warnings(fp, resolved_program) {
        out.push_str(&format!("  warning: {warning}\n"));
    }
    if profile.env.is_empty() {
        out.push_str("  env:     none\n");
    }
    for (key, value) in &profile.env {
        let shown = env_source(value);
        out.push_str(&format!("  env:     {key} = {shown}\n"));
        if let Some(warning) = env_warning(key) {
            out.push_str(&format!("  warning: {warning}\n"));
        }
    }
    if let Some(sha) = &fp.sha256 {
        out.push_str(&format!("  sha256:  {sha}\n"));
    }
    out.push_str(&format!(
        "It runs with your rights in chats whose folder is inside {}.\nAny change to the file asks again.\n",
        visible(&fp.folder)
    ));
    out
}

/// The confirmation as data, for the app's "Enable harness" sheet
/// (`_acpmux/harness_enable`): the same facts and warnings as the CLI text,
/// plus that text. Plain values are shown as in the CLI; Keychain items and
/// login variables are named, never read.
pub fn prompt(fp: &FolderProfile, resolved_program: Option<&Path>) -> serde_json::Value {
    let profile = fp.profile.as_ref();
    let env: Vec<serde_json::Value> = profile
        .map(|p| p.env.iter().map(|(key, value)| env_entry(key, value)).collect())
        .unwrap_or_default();
    let mut warnings = program_warnings(fp, resolved_program);
    if let Some(p) = profile {
        warnings.extend(p.env.keys().filter_map(|k| env_warning(k)));
    }
    json!({
        "id": fp.id,
        "folder": fp.folder,
        "path": fp.path,
        "state": fp.state,
        "trust": fp.trust,
        "argv": profile.map(|p| p.argv.clone()).unwrap_or_default(),
        "program": resolved_program,
        "env": env,
        "checkedFiles": fp.checked_files,
        "warnings": warnings,
        "sha256": fp.sha256,
        "diagnostics": fp.diagnostics,
        "text": confirmation_text(fp, resolved_program),
    })
}

/// Warnings about the program: a file inside the folder that is not
/// checked, or a launcher that downloads a package on each launch.
fn program_warnings(fp: &FolderProfile, resolved_program: Option<&Path>) -> Vec<String> {
    let mut out = Vec::new();
    if let Some(p) = resolved_program
        && p.starts_with(&fp.folder)
        && !fp.checked_files.iter().any(|f| Path::new(f) == p)
    {
        out.push(
            "the program is a file inside this folder; a change to it is not checked again".into(),
        );
    }
    if let Some(launcher) = fp.profile.as_ref().and_then(|p| download_launcher(&p.argv)) {
        out.push(format!(
            "{launcher} downloads and runs a package at launch; a new package version is not checked"
        ));
    }
    out
}

/// The warning for an env key that changes which code a program loads.
fn env_warning(key: &str) -> Option<String> {
    (CODE_LOADING_ENV.contains(&key) || key.starts_with("DYLD_") || key.starts_with("LD_"))
        .then(|| format!("{key} changes which code a program loads"))
}

/// One env entry of the prompt: key, source kind and, for a plain value,
/// the value (control characters written out).
fn env_entry(key: &str, value: &str) -> serde_json::Value {
    if let Some(item) = value.strip_prefix("${keychain:").and_then(|v| v.strip_suffix('}')) {
        return json!({"key": key, "source": "keychain", "item": item});
    }
    if let Some(var) = value.strip_prefix("${env:").and_then(|v| v.strip_suffix('}')) {
        return json!({"key": key, "source": "env", "variable": var});
    }
    json!({"key": key, "source": "plain", "value": visible(value)})
}

/// One env value as the confirmation shows it.
fn env_source(value: &str) -> String {
    if let Some(item) = value.strip_prefix("${keychain:").and_then(|v| v.strip_suffix('}')) {
        return format!("Keychain item {item:?}");
    }
    if let Some(var) = value.strip_prefix("${env:").and_then(|v| v.strip_suffix('}')) {
        return format!("your login variable {var}");
    }
    format!("{} (plain)", shell_quote(value))
}

fn shell_quote(text: &str) -> String {
    let plain = !text.is_empty()
        && text.chars().all(|c| c.is_ascii_alphanumeric() || "-_./:=@%+,${}".contains(c));
    if plain { text.to_owned() } else { format!("'{}'", visible(&text.replace('\'', "'\\''"))) }
}

/// `text` with every control character written out (`\n`, `\r`, `\t`,
/// `\xNN`, `\u{NNNN}`), so a file cannot move the cursor or hide text in the
/// confirmation.
fn visible(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() && (c as u32) < 0x100 => {
                out.push_str(&format!("\\x{:02x}", c as u32));
            }
            c if c.is_control() || is_bidi_control(c) => {
                out.push_str(&format!("\\u{{{:04x}}}", c as u32));
            }
            c => out.push(c),
        }
    }
    out
}

/// Unicode marks that reorder how the text around them is shown.
fn is_bidi_control(c: char) -> bool {
    matches!(
        c,
        '\u{061c}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}'
    )
}

// ------------------------------------------------------------- internals

/// Largest file inside the folder whose bytes join the enable hash.
const MAX_CHECKED_BYTES: u64 = 64 * 1024 * 1024;

/// Every regular file inside `folder` that the command line runs or names:
/// the program (absolute, or found on the profile's PATH, else the login
/// PATH, `resolve_program`) and each argument (or the value after `=`) taken as a path, relative
/// ones from the folder. Each comes with the sha256 of its bytes, sorted by
/// path. A link inside the folder counts by its target, whose path joins the
/// hash, so retargeting it asks again.
fn checked_files(folder: &Path, profile: &HarnessProfile) -> Result<Vec<(String, String)>, String> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(program) = profile.argv.first() {
        if Path::new(program).is_absolute() {
            candidates.push(PathBuf::from(program));
        } else if !program.contains('/') {
            candidates.extend(resolve_program(profile, Some(folder)));
        }
    }
    for arg in profile.argv.iter().skip(1) {
        for part in [Some(arg.as_str()), arg.split_once('=').map(|(_, v)| v)].into_iter().flatten()
        {
            if part.is_empty() || part.contains("${") {
                continue;
            }
            candidates.push(if Path::new(part).is_absolute() {
                PathBuf::from(part)
            } else {
                folder.join(part)
            });
        }
    }
    let mut files: Vec<(String, String)> = Vec::new();
    for candidate in candidates {
        let Ok(real) = std::fs::canonicalize(&candidate) else { continue };
        if !(candidate.starts_with(folder) || real.starts_with(folder)) {
            continue;
        }
        let Ok(meta) = std::fs::metadata(&real) else { continue };
        if !meta.is_file() {
            continue;
        }
        let shown = if candidate.starts_with(folder) { &candidate } else { &real };
        let mut key = shown.to_string_lossy().into_owned();
        if real != *shown {
            key = format!("{key} -> {}", real.display());
        }
        if files.iter().any(|(k, _)| *k == key) {
            continue;
        }
        if meta.len() > MAX_CHECKED_BYTES {
            return Err(format!(
                "{} is larger than {MAX_CHECKED_BYTES} bytes, too large to check on every launch",
                shown.display()
            ));
        }
        let bytes = std::fs::read(&real).map_err(|e| format!("{}: {e}", shown.display()))?;
        files.push((key, crate::sha256::sha256_hex(&bytes)));
    }
    files.sort();
    Ok(files)
}

/// The launcher that downloads and runs a package on each launch, when the
/// command line is one (`npx pkg@latest`, `bunx`, `uvx`, `pnpm dlx`, ...).
fn download_launcher(argv: &[String]) -> Option<String> {
    let name = Path::new(argv.first()?).file_name()?.to_string_lossy().into_owned();
    let sub = argv.get(1).map(String::as_str);
    let hit = match name.as_str() {
        "npx" | "bunx" | "pnpx" | "uvx" => true,
        "pnpm" | "yarn" => sub == Some("dlx"),
        "bun" => sub == Some("x"),
        "pipx" => sub == Some("run"),
        "uv" => sub == Some("tool") && argv.get(2).map(String::as_str) == Some("run"),
        _ => false,
    };
    hit.then(|| match sub.filter(|_| !matches!(name.as_str(), "npx" | "bunx" | "pnpx" | "uvx")) {
        Some(sub) => format!("{name} {sub}"),
        None => name,
    })
}

fn canonical(folder: &Path) -> Result<PathBuf, String> {
    let text = folder.to_string_lossy();
    trust::normalize_cwd(&text).map(PathBuf::from)
}

/// The trust gate's rule (`trust::session_level`) for a family that is
/// neither Claude Code nor Codex: acpmux's decision, else the stricter of the
/// agents' levels. A folder profile names its own family, so it never picks
/// the more lenient single-agent rule.
fn trust_level(gate: &FolderGate, folder: &Path) -> trust::Level {
    match trust::session_level(&gate.trust, &folder.to_string_lossy(), "") {
        Ok((_, level)) => level,
        // A damaged record is no answer (fail closed).
        Err(_) => trust::Level::Unknown,
    }
}

/// Catalog ids and family names a folder profile may not take.
fn catalog_names(cfg: &Config) -> BTreeSet<String> {
    let mut names: BTreeSet<String> = cfg.harnesses.keys().cloned().collect();
    names.extend(cfg.families().into_keys());
    names
}

/// The file's bytes after the type, size and owner checks.
fn read_folder_file(path: &Path) -> Result<Vec<u8>, Diagnostic> {
    use std::os::unix::fs::MetadataExt;
    let shown = path.to_string_lossy().into_owned();
    let error = |m: String, fix: Option<String>| Diagnostic::error(&shown, None, m, fix);
    let meta =
        std::fs::symlink_metadata(path).map_err(|e| error(format!("cannot read: {e}"), None))?;
    if !meta.file_type().is_file() {
        return Err(error("a folder profile must be a regular file, not a symlink".into(), None));
    }
    if meta.len() > MAX_PROFILE_BYTES {
        return Err(error(format!("the file is larger than {MAX_PROFILE_BYTES} bytes"), None));
    }
    let uid = unsafe { libc::getuid() };
    if meta.uid() != uid || meta.mode() & 0o022 != 0 {
        return Err(error(
            "another user can change this file, and a profile runs a program with your rights"
                .into(),
            Some(format!("chmod go-w {shown}")),
        ));
    }
    let bytes = std::fs::read(path).map_err(|e| error(format!("cannot read: {e}"), None))?;
    if bytes.len() as u64 > MAX_PROFILE_BYTES {
        return Err(error(format!("the file is larger than {MAX_PROFILE_BYTES} bytes"), None));
    }
    Ok(bytes)
}

/// The icon's bytes: a regular file directly in the profile folder.
fn icon_bytes(dir: &Path, icon: &Path) -> Result<Vec<u8>, String> {
    if icon.parent() != Some(dir) {
        return Err(
            "a folder profile's icon must be a file next to it (icon = \"<id>.svg\")".into()
        );
    }
    let meta = std::fs::symlink_metadata(icon).map_err(|e| format!("icon: {e}"))?;
    if !meta.file_type().is_file() {
        return Err("a folder profile's icon must be a regular file, not a symlink".into());
    }
    std::fs::read(icon).map_err(|e| format!("icon: {e}"))
}

/// Why `enable` refuses this profile now: no trust answer, or an invalid file.
pub fn refusal(fp: &FolderProfile) -> Option<String> {
    match fp.state {
        FolderState::Error => Some(first_error_parts(&fp.diagnostics, &fp.path)),
        FolderState::NeedsTrust => Some(needs_trust_message_parts(&fp.id, &fp.folder)),
        FolderState::Enabled | FolderState::NeedsEnable => None,
    }
}

fn needs_trust_message_parts(id: &str, folder: &str) -> String {
    format!(
        "harness {id} is a folder profile in {folder}, which is not trusted; answer the folder's Trust question first (open a cmux chat in it), then run `cmux harness enable {id} --folder {folder}`"
    )
}

fn first_error_parts(diagnostics: &[Diagnostic], path: &str) -> String {
    diagnostics
        .iter()
        .find(|d| d.severity == Severity::Error)
        .map(|d| match &d.fix {
            Some(fix) => format!("{}: {} (fix: {fix})", d.path, d.message),
            None => format!("{}: {}", d.path, d.message),
        })
        .unwrap_or_else(|| format!("{path}: the profile cannot be used"))
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct EnableRecord {
    #[serde(default)]
    version: u32,
    #[serde(default)]
    enabled: Vec<EnableEntry>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct EnableEntry {
    folder: String,
    id: String,
    sha256: String,
    /// The command line the user confirmed (for review; the hash decides).
    #[serde(default)]
    argv: Vec<String>,
    #[serde(default)]
    enabled_at: u64,
}

/// A missing record is empty; a damaged one is an error and never overwritten.
fn read_record(path: &Path) -> Result<EnableRecord, String> {
    match std::fs::read_to_string(path) {
        Ok(text) => serde_json::from_str(&text)
            .map_err(|e| format!("enable record {} is damaged: {e}", path.display())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(EnableRecord::default()),
        Err(e) => Err(format!("enable record {}: {e}", path.display())),
    }
}

fn write_record(path: &Path, record: &EnableRecord) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("enable record: {e}"))?;
    }
    let value = json!({"version": 1, "enabled": record.enabled});
    let bytes = serde_json::to_vec_pretty(&value).map_err(|e| e.to_string())?;
    super::write_atomic(path, &bytes).map_err(|e| format!("enable record: {e}"))
}

fn enabled_in(gate: &FolderGate, folder: &str, id: &str, sha: &str) -> bool {
    // A damaged record enables nothing (fail closed).
    read_record(&gate.enable_record).is_ok_and(|r| {
        r.enabled.iter().any(|e| e.folder == folder && e.id == id && e.sha256 == sha)
    })
}

#[cfg(test)]
#[path = "folder_profiles_tests.rs"]
mod tests;
