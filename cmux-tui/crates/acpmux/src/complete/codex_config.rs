//! The user's own Codex model provider for `_acpmux/complete`'s `codex exec`.
//!
//! The recipe runs with `--ignore-user-config` so no tools, MCP servers or
//! rules of the user's load, which also drops their `model_provider`. As
//! classic cmux did (origin/main `CodexAutoNamingArguments.build`), the
//! provider choice and its `[model_providers.<id>]` settings from
//! `$CODEX_HOME/config.toml` come back as `-c` overrides, without the
//! credential-bearing ones (tokens, secrets, keys, headers), which would show
//! in the process list. `env_key` and `requires_openai_auth` stay: they name
//! where the key is, not the key, and the provider needs them to sign in.

use std::path::{Path, PathBuf};

/// What `codex exec` keeps of the user's config.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CodexUserConfig {
    /// `model_provider`, when it names one.
    pub provider: Option<String>,
    /// The top-level `model`.
    pub model: Option<String>,
    /// `-c` values: `model_provider=...` and the provider's settings.
    pub overrides: Vec<String>,
}

impl CodexUserConfig {
    /// Reads a `config.toml` text; an unreadable one is an empty config.
    pub fn parse(text: &str) -> Self {
        // hq#1957: not implemented yet (the failing tests come first).
        let _ = text;
        Self::default()
    }

    /// The model for a run without one: from the user's own provider's list
    /// when it is not OpenAI (Codex's live list, made under the user's
    /// config; the curated catalog names OpenAI's), else from `offered`;
    /// else the user's configured model.
    pub fn model_for(&self, offered: &[String], live: Option<&[String]>) -> Option<String> {
        // hq#1957: not implemented yet (the failing tests come first).
        let _ = (offered, live);
        None
    }
}

/// `$CODEX_HOME/config.toml`, else `~/.codex/config.toml`.
pub fn config_path(codex_home: Option<&str>, home: Option<&Path>) -> Option<PathBuf> {
    match codex_home.filter(|h| !h.is_empty()) {
        Some(dir) => Some(PathBuf::from(dir).join("config.toml")),
        None => home.map(|h| h.join(".codex").join("config.toml")),
    }
}
