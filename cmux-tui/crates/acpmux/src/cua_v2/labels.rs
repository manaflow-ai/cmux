//! The display labels of one Computer Use session: who asks (agent), where
//! (workspace) and through what (client). The bridge sends them in
//! `session/hello`; the worker shows them on the approval card
//! (docs/computer-use-approvals.md, "Sessions"). They are words for the
//! person, never authority: the worker's grants follow the connection.
//!
//! acpmux sets them when it spawns a session: [`Labels::mark`] puts them into
//! the session's private spawn env (after the profile and preset, which
//! cannot set them), `agent_tools.rs` hands them to the bridge's own env, and
//! `agent/command.rs` keeps them out of the harness's env.

use std::collections::BTreeMap;

use serde_json::{Value, json};

/// The agent label (the harness: `claude`, `codex`, ...).
pub const AGENT_ENV: &str = "ACPMUX_CUA_LABEL_AGENT";
/// The workspace label (the session's folder name).
pub const WORKSPACE_ENV: &str = "ACPMUX_CUA_LABEL_WORKSPACE";
/// The client label (`cmux` for an agent chat, `cli` for `cmux computer-use`).
pub const CLIENT_ENV: &str = "ACPMUX_CUA_LABEL_CLIENT";
/// Every label key.
pub const KEYS: [&str; 3] = [AGENT_ENV, WORKSPACE_ENV, CLIENT_ENV];

/// The client label of an agent chat acpmux spawned.
pub const CHAT_CLIENT: &str = "cmux";
/// The client label of `cmux computer-use` (`cli_bridge.rs`).
pub const CLI_CLIENT: &str = "cli";

/// Longest label, in characters.
const MAX_CHARS: usize = 80;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Labels {
    pub agent: String,
    pub workspace: String,
    pub client: String,
}

impl Labels {
    pub fn new(agent: &str, workspace: &str, client: &str) -> Self {
        Labels { agent: clean(agent), workspace: clean(workspace), client: clean(client) }
    }

    /// The labels of a session folder `cwd` run by harness `agent`.
    pub fn for_session(agent: &str, cwd: &std::path::Path, client: &str) -> Self {
        let workspace =
            cwd.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        Labels::new(agent, &workspace, client)
    }

    /// The labels in an env (`get` reads one key).
    pub fn from_env(get: impl Fn(&str) -> Option<String>) -> Self {
        let read = |key: &str| get(key).unwrap_or_default();
        Labels::new(&read(AGENT_ENV), &read(WORKSPACE_ENV), &read(CLIENT_ENV))
    }

    /// The labels as env pairs.
    pub fn env(&self) -> Vec<(String, String)> {
        [(AGENT_ENV, &self.agent), (WORKSPACE_ENV, &self.workspace), (CLIENT_ENV, &self.client)]
            .into_iter()
            .map(|(k, v)| (k.to_owned(), v.clone()))
            .collect()
    }

    /// Puts these labels into a session's spawn env, replacing any value a
    /// profile or preset put there.
    pub fn mark(&self, env: &mut BTreeMap<String, String>) {
        for (key, value) in self.env() {
            env.insert(key, value);
        }
    }

    /// The labels a spawn env carries, if [`Labels::mark`] ran on it.
    pub fn in_spawn_env(env: &BTreeMap<String, String>) -> Option<Self> {
        KEYS.iter()
            .any(|key| env.contains_key(*key))
            .then(|| Labels::from_env(|key| env.get(key).cloned()))
    }

    /// `session/hello`'s params.
    pub fn params(&self) -> Value {
        json!({"agent": self.agent, "workspace": self.workspace, "client": self.client})
    }
}

/// One printable line of at most [`MAX_CHARS`] characters.
fn clean(text: &str) -> String {
    text.chars().filter(|c| !c.is_control()).take(MAX_CHARS).collect::<String>().trim().to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels_are_one_printable_bounded_line() {
        let labels = Labels::new("claude\n\u{7}", &"w".repeat(200), " cli ");
        assert_eq!(labels.agent, "claude");
        assert_eq!(labels.workspace.chars().count(), MAX_CHARS);
        assert_eq!(labels.client, "cli");
    }

    #[test]
    fn a_session_is_labelled_by_its_harness_and_folder() {
        let labels =
            Labels::for_session("codex", std::path::Path::new("/w/api-server"), CHAT_CLIENT);
        assert_eq!(
            labels.params(),
            json!({"agent": "codex", "workspace": "api-server", "client": "cmux"})
        );
    }

    #[test]
    fn marking_replaces_what_a_profile_set_and_reads_back() {
        let mut env = BTreeMap::from([(AGENT_ENV.to_owned(), "Trusted Admin".to_owned())]);
        assert_eq!(Labels::in_spawn_env(&BTreeMap::new()), None);
        let labels = Labels::new("claude", "repo", CHAT_CLIENT);
        labels.mark(&mut env);
        assert_eq!(Labels::in_spawn_env(&env), Some(labels));
    }
}
