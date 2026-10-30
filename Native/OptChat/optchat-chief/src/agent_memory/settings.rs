//! The `agents.memory.*` keys of the cmux settings file, read at each use so
//! a change applies to the next call. The file and its JSONC dialect are
//! acpmux's `user_settings.rs`: `CMUX_NEXT_CONFIG_FILE`, else
//! `~/.config/cmux/cmux-next.json`, else `~/.config/cmux/cmux.json`. The
//! CLI and every agent session read the same keys here, so they build the
//! same index (a different source list would rebuild it on every switch).

use std::path::{Path, PathBuf};

use serde_json::Value;

/// The settings file override the app and tests set.
pub const CONFIG_OVERRIDE: &str = "CMUX_NEXT_CONFIG_FILE";

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

/// The parsed settings file, or None when there is none or it does not parse.
fn settings_file(home: &Path) -> Option<Value> {
    let read = |path: &Path| std::fs::read_to_string(path).ok();
    let text = match crate::cli::env(CONFIG_OVERRIDE) {
        Some(path) => read(&expand_tilde(&path, home)),
        None => read(&home.join(".config/cmux/cmux-next.json"))
            .or_else(|| read(&home.join(".config/cmux/cmux.json"))),
    }?;
    serde_json::from_str(&strip_jsonc(&text)).ok()
}

/// The value at a dotted key, nested or as one flat key (both forms the
/// settings owner writes).
pub fn value(doc: &Value, key: &str) -> Option<Value> {
    if let Some(v) = doc.get(key) {
        return Some(v.clone());
    }
    doc.pointer(&format!("/{}", key.replace('.', "/"))).cloned()
}

/// JSONC to JSON: `//` and `/* */` comments, then trailing commas, outside
/// strings. A copy of acpmux's `strip_jsonc`, so this crate takes no new
/// dependency for one settings read.
pub fn strip_jsonc(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let (mut i, mut in_string) = (0, false);
    while i < chars.len() {
        let c = chars[i];
        if in_string {
            out.push(c);
            if c == '\\' && i + 1 < chars.len() {
                out.push(chars[i + 1]);
                i += 1;
            } else if c == '"' {
                in_string = false;
            }
        } else if c == '"' {
            in_string = true;
            out.push(c);
        } else if c == '/' && chars.get(i + 1) == Some(&'/') {
            while i < chars.len() && chars[i] != '\n' {
                i += 1;
            }
            continue;
        } else if c == '/' && chars.get(i + 1) == Some(&'*') {
            i += 2;
            while i < chars.len() && !(chars[i] == '*' && chars.get(i + 1) == Some(&'/')) {
                i += 1;
            }
            i += 2;
            continue;
        } else {
            out.push(c);
        }
        i += 1;
    }
    drop_trailing_commas(&out)
}

fn drop_trailing_commas(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut in_string = false;
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if in_string {
            out.push(c);
            if c == '\\' && i + 1 < chars.len() {
                out.push(chars[i + 1]);
                i += 1;
            } else if c == '"' {
                in_string = false;
            }
        } else if c == '"' {
            in_string = true;
            out.push(c);
        } else if c == ',' {
            let next = chars[i + 1..].iter().find(|c| !c.is_whitespace());
            if !matches!(next, Some('}' | ']')) {
                out.push(c);
            }
        } else {
            out.push(c);
        }
        i += 1;
    }
    out
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
        let v: Value = serde_json::from_str(&strip_jsonc(text)).unwrap();
        assert_eq!(v, json!({"a": "x // not a comment", "b": [1, 2]}));
    }
}
