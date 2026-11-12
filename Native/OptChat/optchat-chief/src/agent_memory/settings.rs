//! The `agents.memory.*` keys of the cmux settings file, read at each use so
//! a change applies to the next call. The file and its JSONC dialect are
//! cmux-config's (`location`, `jsonc`): `CMUX_NEXT_CONFIG_FILE`, else
//! `~/.config/cmux/cmux-next.json`, else `~/.config/cmux/cmux.json`. The
//! CLI and every agent session read the same keys here, so they build the
//! same index (a different source list would rebuild it on every switch).

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use cmux_config::{jsonc, location};

use serde_json::Value;

/// What this machine's memory does.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MemorySettings {
    /// `agents.memory.enabled`: cmux registers the server for the agent
    /// sessions it starts (acpmux `agent_tools.rs` reads this key itself).
    pub enabled: bool,
    /// `agents.memory.owner`: the cmux route of the machine that holds the
    /// index (`ssh://HOST`, `unix:///PATH`, any `cmux remote` route). None:
    /// this machine holds it.
    pub owner: Option<String>,
    /// `agents.memory.ownerArgs`: extra `cmux remote rpc` options for the
    /// owner route (`--daemon FINGERPRINT`, `--ssh-arg ARG`, ...).
    pub owner_args: Vec<String>,
    /// `agents.memory.ownerCommand`: argv that runs this server on the
    /// owner, when `optchat-chief` is not where the owner's cmux keeps it.
    pub owner_command: Vec<String>,
    /// `agents.memory.remember` (default true): agents may save notes.
    pub remember: bool,
    /// `agents.memory.sources`: more folders whose `*.md` files are indexed
    /// (decision records, team notes), `~` expanded.
    pub sources: Vec<PathBuf>,
}

impl MemorySettings {
    /// The settings now; a missing or unreadable file gives the defaults
    /// (memory off, nothing extra), which never widen what runs.
    pub fn read(home: &Path) -> MemorySettings {
        Self::from_document(settings_file(home).as_ref(), home)
    }

    pub fn from_document(doc: Option<&Value>, home: &Path) -> MemorySettings {
        let get = |key: &str| doc.and_then(|d| value(d, &format!("agents.memory.{key}")));
        let strings = |key: &str| -> Vec<String> {
            match get(key) {
                Some(Value::Array(items)) => items
                    .iter()
                    .filter_map(|v| v.as_str().map(str::to_owned))
                    .filter(|s| !s.is_empty())
                    .collect(),
                _ => Vec::new(),
            }
        };
        MemorySettings {
            enabled: get("enabled") == Some(Value::Bool(true)),
            owner: get("owner")
                .and_then(|v| v.as_str().map(str::trim).map(str::to_owned))
                .filter(|s| !s.is_empty()),
            owner_args: strings("ownerArgs"),
            owner_command: strings("ownerCommand"),
            remember: get("remember") != Some(Value::Bool(false)),
            sources: strings("sources")
                .iter()
                .map(|s| expand_tilde(s, home))
                .collect(),
        }
    }
}

/// `~` and `~/...` against `home`.
pub fn expand_tilde(path: &str, home: &Path) -> PathBuf {
    match path.strip_prefix('~') {
        Some("") => home.to_owned(),
        Some(rest) if rest.starts_with('/') => home.join(&rest[1..]),
        _ => PathBuf::from(path),
    }
}

/// The user's whole settings document (cmux.json, as `settings_file`
/// finds it), for other keys read at each use (`chief.reactionsCanWake`,
/// brain/reaction_wake.rs).
pub fn document(home: &Path) -> Option<Value> {
    settings_file(home)
}

/// The user's settings document as `document` finds it, telling a missing
/// file (`Ok(None)`) from one that is there but does not read or parse
/// (`Err`), for a read that must fail closed (`chief.permissionMode`,
/// cmux#37392), as acpmux's own read of the file does.
pub fn document_checked(home: &Path) -> Result<Option<Value>, String> {
    let read = |path: &Path| match std::fs::read_to_string(path) {
        Ok(text) => Ok(Some(text)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(format!("{}: {e}", path.display())),
    };
    // The environment, with `home` as HOME, so tests name their own home.
    let env = |name: &str| match name {
        "HOME" => Some(OsString::from(home)),
        _ => crate::cli::env(name).map(OsString::from),
    };
    let text = match read(&location::config_path_from(env))? {
        Some(text) => Some(text),
        // No override and no cmux-next.json yet: classic cmux.json.
        None => match location::seed_path_from(env) {
            Some(classic) => read(&classic)?,
            None => None,
        },
    };
    let Some(text) = text else {
        return Ok(None);
    };
    parse(&text).map(Some)
}

/// Settings text as JSON: cmux-config's JSONC reader (comments, trailing
/// commas, a BOM), the dialect the app and the daemon read.
pub fn parse(text: &str) -> Result<Value, String> {
    let strict =
        jsonc::strip(text).map_err(|e| format!("the settings file does not parse: {e}"))?;
    serde_json::from_str(&strict).map_err(|e| format!("the settings file does not parse: {e}"))
}

/// The parsed settings file, or None when there is none or it does not parse.
fn settings_file(home: &Path) -> Option<Value> {
    document_checked(home).ok().flatten()
}

/// The value at a dotted key, nested or as one flat key (both forms the
/// settings owner writes).
pub fn value(doc: &Value, key: &str) -> Option<Value> {
    if let Some(v) = doc.get(key) {
        return Some(v.clone());
    }
    doc.pointer(&format!("/{}", key.replace('.', "/"))).cloned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn defaults_are_off_and_local() {
        let s = MemorySettings::from_document(None, Path::new("/h"));
        assert!(!s.enabled);
        assert!(s.remember);
        assert_eq!(s.owner, None);
        assert!(s.sources.is_empty());
    }

    #[test]
    fn reads_nested_and_flat_keys() {
        let doc = json!({
            "agents": {"memory": {"enabled": true, "owner": " ssh://box ", "sources": ["~/notes", "/abs", ""]}},
            "agents.memory.remember": false,
            "agents.memory.ownerArgs": ["--ssh-arg", "-v"],
        });
        let s = MemorySettings::from_document(Some(&doc), Path::new("/h"));
        assert!(s.enabled);
        assert!(!s.remember);
        assert_eq!(s.owner.as_deref(), Some("ssh://box"));
        assert_eq!(s.owner_args, ["--ssh-arg", "-v"]);
        assert_eq!(
            s.sources,
            [PathBuf::from("/h/notes"), PathBuf::from("/abs")]
        );
    }

    #[test]
    fn jsonc_comments_and_trailing_commas() {
        let text = "{\n // a\n \"a\": \"x // not a comment\", /* b */\n \"b\": [1, 2,],\n}";
        let v = parse(text).unwrap();
        assert_eq!(v, json!({"a": "x // not a comment", "b": [1, 2]}));
    }
}
