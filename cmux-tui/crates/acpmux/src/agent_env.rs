//! The environment every agent chat gets from the cmux settings file, read at each start
//! (`hub/spawn.rs`), as Claude Code's `env` setting and Codex's `shell_environment_policy`
//! (`set`, `exclude`) do for their own processes:
//!
//! - `agents.env` (name to value): variables every chat's agent and its tools get. A value the
//!   profile, preset, route, session or the login shell already sets keeps its value, as
//!   `prompt_cache_env.rs` fills only what is unset. A remote-origin chat gets none: it gets no
//!   login env either.
//! - `agents.envExclude` (names, or `PREFIX_*`): variables never passed to the agent, whoever set
//!   them (the daemon's env, the login shell, a profile, `agents.env`), removed last when the
//!   command is built (`agent/command.rs`). acpmux's own session wiring (`ACPMUX_*`, the caller
//!   token and socket, `CMUX_AGENT_SESSION`) is never removed: without it the agent cannot reach
//!   its chat.
//!
//! A name is a shell variable name (`[A-Za-z_][A-Za-z0-9_]*`); an entry that is not one, or an
//! `agents.env` value that is not a string, is skipped with a warning. No file, a key that is
//! absent or a file that does not parse sets and removes nothing.

use std::collections::BTreeMap;

/// The variables every chat gets.
pub const SET_SETTING: &str = "agents.env";
/// The variables no chat gets.
pub const EXCLUDE_SETTING: &str = "agents.envExclude";
/// The profile-env marker that carries the exclude list from the spawn to the command build
/// (`agent/command.rs` removes it and applies it), comma separated: acpmux's own, never a
/// profile's.
pub const EXCLUDE_MARKER: &str = "ACPMUX_ENV_EXCLUDE";

/// `agents.env` and `agents.envExclude` as the settings file holds them now.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AgentEnv {
    pub set: BTreeMap<String, String>,
    pub exclude: Vec<String>,
}

/// Whether `name` is a shell variable name.
fn is_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars.next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Whether `entry` is an exclude entry: a name, or a name prefix ending in `*`.
fn is_pattern(entry: &str) -> bool {
    match entry.strip_suffix('*') {
        Some("") => false,
        Some(prefix) => is_name(prefix),
        None => is_name(entry),
    }
}

impl AgentEnv {
    /// The two settings from a parsed settings document.
    pub fn from_doc(doc: &serde_json::Value) -> Self {
        let mut out = Self::default();
        if let Some(map) =
            crate::user_settings::value(doc, SET_SETTING).as_ref().and_then(|v| v.as_object())
        {
            for (name, value) in map {
                match value.as_str() {
                    Some(value) if is_name(name) && !value.contains('\0') => {
                        out.set.insert(name.clone(), value.to_owned());
                    }
                    _ => tracing::warn!(
                        name,
                        "{SET_SETTING}: skipped an entry that is not NAME: \"value\""
                    ),
                }
            }
        }
        if let Some(list) =
            crate::user_settings::value(doc, EXCLUDE_SETTING).as_ref().and_then(|v| v.as_array())
        {
            for entry in list {
                match entry.as_str().map(str::trim) {
                    Some(entry) if is_pattern(entry) => {
                        if !out.exclude.iter().any(|e| e == entry) {
                            out.exclude.push(entry.to_owned());
                        }
                    }
                    _ => {
                        tracing::warn!(%entry, "{EXCLUDE_SETTING}: skipped an entry that is not NAME or PREFIX_*")
                    }
                }
            }
        }
        out
    }

    /// The settings as the file holds them now (read at each start, so a change applies to the
    /// next chat).
    pub fn current() -> Self {
        match crate::user_settings::read() {
            crate::user_settings::Settings::Parsed(doc) => Self::from_doc(&doc),
            crate::user_settings::Settings::Missing
            | crate::user_settings::Settings::Unreadable(_) => Self::default(),
        }
    }

    /// Fills `env` (the spawn's profile env) for a chat: `set`'s names that neither `env` nor
    /// `login` (the login shell's value the agent gets) has, unless `remote` (a remote-origin
    /// chat), and the exclude marker, which replaces any marker already there.
    pub fn apply(
        &self,
        env: &mut BTreeMap<String, String>,
        remote: bool,
        login: &dyn Fn(&str) -> Option<String>,
    ) {
        if !remote {
            for (name, value) in &self.set {
                if !env.contains_key(name) && login(name).is_none() {
                    env.insert(name.clone(), value.clone());
                }
            }
        }
        env.remove(EXCLUDE_MARKER);
        if !self.exclude.is_empty() {
            env.insert(EXCLUDE_MARKER.to_owned(), self.exclude.join(","));
        }
    }
}

/// acpmux's own session wiring, never excluded.
fn protected(name: &str) -> bool {
    name.starts_with("ACPMUX_")
        || crate::person_tokens::CALLER_ENV_KEYS.contains(&name)
        || name == crate::agent_tools::AGENT_SESSION_ENV
}

/// The exclude entries a marker value holds.
pub fn patterns(marker: &str) -> Vec<String> {
    marker.split(',').map(str::trim).filter(|e| is_pattern(e)).map(str::to_owned).collect()
}

/// Whether `name` is excluded by `patterns` (and not acpmux's own).
pub fn excluded(name: &str, patterns: &[String]) -> bool {
    !protected(name)
        && patterns.iter().any(|p| match p.strip_suffix('*') {
            Some(prefix) => name.starts_with(prefix),
            None => name == p,
        })
}

#[cfg(test)]
#[path = "agent_env_tests.rs"]
mod tests;
