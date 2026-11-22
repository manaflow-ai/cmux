//! The `sessions` block of a harness profile (ALL-CHATS-ON-DEVICE C2/C3).
//! Part of `config/profiles.rs`.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Built-in chat store adapters (Rust code in the device chat index).
pub const SESSION_BUILTIN_ADAPTERS: &[&str] =
    &["claude-code", "codex", "opencode", "pi", "gemini", "cursor-agent", "amp", "aider"];
/// Data-only adapters a profile describes completely.
pub const SESSION_DATA_ADAPTERS: &[&str] = &["jsonl", "json", "sqlite"];
/// Index fields a `sessions.fields` table may map.
pub const SESSION_FIELDS: &[&str] = &["id", "title", "cwd", "created", "updated", "count"];

/// One `sessions.fields` selector, or a list where the first non-empty wins.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(untagged)]
pub enum FieldSelector {
    One(String),
    FirstOf(Vec<String>),
}

impl FieldSelector {
    pub fn selectors(&self) -> Vec<&str> {
        match self {
            Self::One(s) => vec![s.as_str()],
            Self::FirstOf(list) => list.iter().map(String::as_str).collect(),
        }
    }
}

/// How the index reopens one chat.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionsResume {
    /// `{id}`, `{cwd}` and `{path}` are replaced.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub argv: Vec<String>,
    /// Run folder: `{cwd}` or `any`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    /// Resume through acpmux adopt (ACP) instead of a command.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub adopt: Option<bool>,
}

/// Where a harness keeps its chats (ALL-CHATS-ON-DEVICE C2/C3; schema from
/// the all-chats lane, `.cmux-scratch/nx-all-chats/DESIGN.md` section 5).
/// Validated here, read by the device chat index.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionsSpec {
    /// A built-in adapter, or `jsonl` | `json` | `sqlite` for a data-only one.
    pub adapter: String,
    /// Store roots: `${VAR}` / `${VAR:-default}` read the login env, `~` = home.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub roots: Vec<String>,
    /// Wrapper layouts: each match is one more root; `*` is the account label.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub layouts: Vec<String>,
    /// File glob under each root (data-only adapters).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub files: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub exclude: Vec<String>,
    /// Index field -> selector (`file.stem`, `file.mtime`, `first:<ptr>`,
    /// `last:<ptr>`, `count:<ptr>=<value>`), jsonl/json only.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub fields: BTreeMap<String, FieldSelector>,
    /// One read-only query (sqlite only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub query: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume: Option<SessionsResume>,
}

/// The problems in a sessions block, as messages.
pub fn check_sessions(s: &SessionsSpec) -> Vec<String> {
    let mut out = Vec::new();
    let builtin = SESSION_BUILTIN_ADAPTERS.contains(&s.adapter.as_str());
    let data = SESSION_DATA_ADAPTERS.contains(&s.adapter.as_str());
    if !builtin && !data {
        out.push(format!(
            "sessions.adapter {:?} is unknown; use one of {}, {}",
            s.adapter,
            SESSION_BUILTIN_ADAPTERS.join(", "),
            SESSION_DATA_ADAPTERS.join(", ")
        ));
        return out;
    }
    if builtin {
        if s.files.is_some() || !s.exclude.is_empty() || !s.fields.is_empty() || s.query.is_some() {
            out.push(format!(
                "sessions: the built-in adapter {:?} takes only roots, layouts and resume",
                s.adapter
            ));
        }
    } else {
        if s.roots.is_empty() && s.layouts.is_empty() {
            out.push("sessions: a data-only adapter needs roots or layouts".into());
        }
        if s.files.as_deref().is_none_or(|f| f.trim().is_empty()) {
            out.push("sessions.files: a data-only adapter needs a file glob".into());
        }
    }
    if s.adapter == "sqlite" {
        if !s.fields.is_empty() {
            out.push("sessions.fields: the sqlite adapter names columns in query instead".into());
        }
        match &s.query {
            None => out.push("sessions.query: the sqlite adapter needs a query".into()),
            Some(q) => {
                let upper = q.trim_start().to_ascii_uppercase();
                let read_only = (upper.starts_with("SELECT") || upper.starts_with("WITH"))
                    && ![
                        "ATTACH", "PRAGMA", "INSERT", "UPDATE", "DELETE", "DROP", "CREATE",
                        "ALTER", "REPLACE", "VACUUM",
                    ]
                    .iter()
                    .any(|w| {
                        upper
                            .split(|c: char| !c.is_ascii_alphanumeric() && c != '_')
                            .any(|t| t == *w)
                    })
                    && !q.trim_end().trim_end_matches(';').contains(';');
                if !read_only {
                    out.push("sessions.query must be one read-only SELECT".into());
                }
            }
        }
    } else if !builtin {
        if s.query.is_some() {
            out.push("sessions.query is only for the sqlite adapter".into());
        }
        if !s.fields.contains_key("id") {
            out.push("sessions.fields needs id".into());
        }
    }
    for (k, sel) in &s.fields {
        if !SESSION_FIELDS.contains(&k.as_str()) {
            out.push(format!(
                "sessions.fields: unknown field {k:?}; use {}",
                SESSION_FIELDS.join(", ")
            ));
        }
        for one in sel.selectors() {
            let ok = one == "file.stem"
                || one == "file.mtime"
                || one.strip_prefix("first:").is_some_and(|p| p.starts_with('/'))
                || one.strip_prefix("last:").is_some_and(|p| p.starts_with('/'))
                || one
                    .strip_prefix("count:")
                    .is_some_and(|p| p.starts_with('/') && p.contains('='));
            if !ok {
                out.push(format!(
                    "sessions.fields.{k}: selector {one:?} is not file.stem, file.mtime, first:/ptr, last:/ptr or count:/ptr=value"
                ));
            }
        }
    }
    if let Some(r) = &s.resume {
        let adopt = r.adopt == Some(true);
        if adopt != r.argv.is_empty() {
            out.push("sessions.resume needs exactly one of argv or adopt = true".into());
        }
        if let Some(cwd) = &r.cwd
            && cwd != "{cwd}"
            && cwd != "any"
        {
            out.push(format!("sessions.resume.cwd {cwd:?} must be \"{{cwd}}\" or \"any\""));
        }
    }
    out
}
