//! The chat settings the app sends (`_acpmux/chat_settings`, S8):
//! cmux.json `agents.chats.enabled`, `agents.chats.discovery` and
//! `agents.chats.roots`, plus the roots managed config adds. The app owns
//! the effective values (it reads MDM, which the daemon cannot); the daemon
//! keeps the last values in `chat-settings.json` so a restart without the
//! app keeps them.
//!
//! A root is a plain folder; the harness is found from the folder's layout
//! (a Claude home has `projects/`, a Codex home `sessions/` or its state
//! database, ...). A folder that holds no known store, or that is guarded,
//! is refused with the reason; nothing reads inside a guarded spelling.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use cmux_chat_index::{AdapterKind, RootSpec};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Effective chat settings. Defaults: on, discovery on, no extra roots.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ChatSettings {
    pub enabled: bool,
    pub discovery: bool,
    /// The user's roots (cmux.json).
    pub roots: Vec<PathBuf>,
    /// Roots managed config adds; the user cannot remove them.
    pub managed_roots: Vec<PathBuf>,
}

impl Default for ChatSettings {
    fn default() -> Self {
        Self { enabled: true, discovery: true, roots: Vec::new(), managed_roots: Vec::new() }
    }
}

/// A settings root the index does not read, and why.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsRefusal {
    pub path: PathBuf,
    pub reason: String,
    pub managed: bool,
}

impl ChatSettings {
    /// The most roots one message may carry.
    pub const MAX_ROOTS: usize = 256;

    /// `{enabled?, discovery?, roots?, managedRoots?}`; a missing field keeps its default.
    pub fn from_params(params: &Value) -> Result<Self, String> {
        let flag = |key: &str| match params.get(key) {
            None | Some(Value::Null) => Ok(true),
            Some(Value::Bool(on)) => Ok(*on),
            Some(_) => Err(format!("{key} must be true or false")),
        };
        let paths = |key: &str| -> Result<Vec<PathBuf>, String> {
            let list = match params.get(key) {
                None | Some(Value::Null) => return Ok(Vec::new()),
                Some(Value::Array(list)) => list,
                Some(_) => return Err(format!("{key} must be a list of folder paths")),
            };
            if list.len() > Self::MAX_ROOTS {
                return Err(format!("{key} has more than {} folders", Self::MAX_ROOTS));
            }
            let mut out: Vec<PathBuf> = Vec::new();
            for item in list {
                let path = item.as_str().ok_or_else(|| format!("{key} must hold strings"))?;
                let path = PathBuf::from(path);
                if !out.contains(&path) {
                    out.push(path);
                }
            }
            Ok(out)
        };
        Ok(Self {
            enabled: flag("enabled")?,
            discovery: flag("discovery")?,
            roots: paths("roots")?,
            managed_roots: paths("managedRoots")?,
        })
    }

    /// The saved settings; defaults when the file is missing or unreadable.
    pub fn load(path: &Path) -> Self {
        fs::read(path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    /// Writes the file (0600, through a temp file and a rename).
    pub fn save(&self, path: &Path) -> io::Result<()> {
        let dir = path.parent().ok_or_else(|| io::Error::other("no parent folder"))?;
        fs::create_dir_all(dir)?;
        let bytes = serde_json::to_vec_pretty(self).map_err(io::Error::other)?;
        let tmp = path.with_extension("json.tmp");
        let mut options = fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let mut file = options.open(&tmp)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        fs::rename(&tmp, path)
    }

    /// The root specs of the settings roots (managed first), and the refused ones.
    pub fn root_specs(
        &self,
        refuse: &dyn Fn(&Path) -> Option<String>,
    ) -> (Vec<RootSpec>, Vec<SettingsRefusal>) {
        let mut specs: Vec<RootSpec> = Vec::new();
        let mut refused = Vec::new();
        let all = self
            .managed_roots
            .iter()
            .map(|p| (p, true))
            .chain(self.roots.iter().map(|p| (p, false)));
        let mut seen: Vec<&PathBuf> = Vec::new();
        for (path, managed) in all {
            if seen.contains(&path) {
                continue;
            }
            seen.push(path);
            // `refuse` checks the spelling before anything reads the path.
            let reason = refuse(path).or_else(|| {
                let found = probe(path);
                if found.is_empty() {
                    let reason = if path.is_dir() {
                        "holds no chat folder of a known harness (Claude Code, Codex, OpenCode, Pi, Gemini CLI, Cursor agent, Amp)"
                    } else {
                        "is not a folder"
                    };
                    return Some(format!("{} {reason}", path.display()));
                }
                for spec in found {
                    if !specs.contains(&spec) {
                        specs.push(spec);
                    }
                }
                None
            });
            if let Some(reason) = reason {
                refused.push(SettingsRefusal { path: path.clone(), reason, managed });
            }
        }
        (specs, refused)
    }
}

/// The harness stores a folder holds, found from its layout only (names
/// of entries, never file contents).
pub fn probe(path: &Path) -> Vec<RootSpec> {
    let mut out = Vec::new();
    if !path.is_absolute() || !path.is_dir() {
        return out;
    }
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
    let parent = path.parent().and_then(|p| p.file_name()).and_then(|n| n.to_str()).unwrap_or("");
    let dir = |sub: &str| path.join(sub).is_dir();
    let has_file = |dir: &Path, test: &dyn Fn(&str) -> bool| {
        fs::read_dir(dir).is_ok_and(|entries| {
            entries.flatten().any(|e| e.file_name().to_str().is_some_and(test))
        })
    };
    let mut add = |harness: AdapterKind, at: PathBuf| {
        let spec = RootSpec { harness, path: at, label: None };
        if !out.contains(&spec) {
            out.push(spec);
        }
    };
    // Claude Code: `<home>/projects`, or the projects folder itself.
    if dir("projects") {
        add(AdapterKind::ClaudeCode, path.join("projects"));
    } else if name == "projects" {
        add(AdapterKind::ClaudeCode, path.to_path_buf());
    }
    // Pi: `<agent>/sessions`, `~/.pi`, or a sessions folder outside a Codex home.
    let codex_files =
        |n: &str| (n.starts_with("state_") && n.contains(".sqlite")) || n == "session_index.jsonl";
    if name == ".pi" && path.join("agent/sessions").is_dir() {
        add(AdapterKind::Pi, path.join("agent/sessions"));
    } else if name == "agent" && dir("sessions") {
        add(AdapterKind::Pi, path.join("sessions"));
    } else if name == "sessions" && parent == "agent" {
        add(AdapterKind::Pi, path.to_path_buf());
    } else if dir("sessions") || dir("archived_sessions") || has_file(path, &codex_files) {
        // Codex: a home with `sessions/`, its state database or its index.
        add(AdapterKind::Codex, path.to_path_buf());
    }
    // OpenCode: the data folder with `opencode*.db`, or its parent.
    let opencode_db = |n: &str| n.starts_with("opencode") && n.ends_with(".db");
    if has_file(path, &opencode_db) {
        add(AdapterKind::OpenCode, path.to_path_buf());
    } else if dir("opencode") && has_file(&path.join("opencode"), &opencode_db) {
        add(AdapterKind::OpenCode, path.join("opencode"));
    }
    // Gemini CLI: `<.gemini>/tmp/<project>/chats`.
    let gemini = fs::read_dir(path.join("tmp"))
        .is_ok_and(|entries| entries.flatten().any(|e| e.path().join("chats").is_dir()));
    if gemini {
        add(AdapterKind::Gemini, path.to_path_buf());
    }
    // Cursor agent: `~/.cursor/chats`.
    if name == ".cursor" && dir("chats") {
        add(AdapterKind::CursorAgent, path.join("chats"));
    } else if name == "chats" && parent == ".cursor" {
        add(AdapterKind::CursorAgent, path.to_path_buf());
    }
    // Amp: a threads folder of `T-*.json`.
    let amp = |n: &str| n.starts_with("T-") && n.ends_with(".json");
    if name == "threads" || has_file(path, &amp) {
        add(AdapterKind::Amp, path.to_path_buf());
    } else if dir("threads") {
        add(AdapterKind::Amp, path.join("threads"));
    }
    out
}

#[cfg(test)]
#[path = "settings_tests.rs"]
mod tests;
