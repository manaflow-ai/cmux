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

use std::path::{Path, PathBuf};

use serde::Serialize;

use super::profiles::Diagnostic;
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
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub diagnostics: Vec<Diagnostic>,
    #[serde(skip)]
    pub profile: Option<HarnessProfile>,
}

/// Every profile file in `folder`'s `.cmux/harnesses`, by file name.
pub fn scan(_cfg: &Config, _gate: &FolderGate, _folder: &Path) -> Result<Vec<FolderProfile>, String> {
    Ok(vec![])
}

/// The folder profile `id` of `folder`; None when it has no such file.
pub fn load_one(_cfg: &Config, _gate: &FolderGate, _folder: &Path, _id: &str) -> Option<FolderProfile> {
    None
}

/// Records the user's "Enable harness" confirmation (red: not yet).
pub fn enable(
    _cfg: &Config,
    _gate: &FolderGate,
    _folder: &Path,
    _id: &str,
    _shown_sha256: &str,
) -> Result<FolderProfile, String> {
    Err("folder profiles are not implemented".into())
}

/// Forgets every confirmation of `id` in `folder` (red: not yet).
pub fn disable(_gate: &FolderGate, _folder: &Path, _id: &str) -> Result<bool, String> {
    Ok(false)
}

/// The profile a session may run from a folder (red: never).
pub fn resolve_for_session(
    _cfg: &Config,
    _id: &str,
    _cwd: &Path,
    _remote: bool,
) -> Option<Result<(HarnessProfile, PathBuf), String>> {
    None
}

/// What the "Enable harness" confirmation shows (red: nothing).
pub fn confirmation_text(_fp: &FolderProfile, _resolved_program: Option<&Path>) -> String {
    String::new()
}

/// Why `enable` refuses this profile now (red: never).
pub fn refusal(_fp: &FolderProfile) -> Option<String> {
    None
}

#[cfg(test)]
#[path = "folder_profiles_tests.rs"]
mod tests;
