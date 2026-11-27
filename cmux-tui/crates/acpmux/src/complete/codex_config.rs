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
        let Ok(config) = text.parse::<toml::Table>() else { return Self::default() };
        let model = config.get("model").and_then(toml::Value::as_str).map(str::to_owned);
        let provider = config
            .get("model_provider")
            .and_then(toml::Value::as_str)
            .filter(|p| bare_key(p))
            .map(str::to_owned);
        let mut overrides = Vec::new();
        if let Some(id) = provider.as_deref().filter(|p| *p != OPENAI) {
            overrides.push(format!("model_provider={}", quoted(id)));
            let settings = config
                .get("model_providers")
                .and_then(toml::Value::as_table)
                .and_then(|all| all.get(id))
                .and_then(toml::Value::as_table);
            let mut leaves = Vec::new();
            if let Some(settings) = settings {
                flatten(settings, &mut Vec::new(), &mut leaves);
            }
            leaves.sort();
            overrides.extend(
                leaves
                    .into_iter()
                    .map(|(path, value)| format!("model_providers.{id}.{path}={value}")),
            );
        }
        Self { provider, model, overrides }
    }

    /// Whether the user runs Codex on a provider other than OpenAI.
    pub fn custom_provider(&self) -> bool {
        self.provider.as_deref().is_some_and(|p| p != OPENAI)
    }

    /// The model for a run without one: from the user's own provider's list
    /// when it is not OpenAI (Codex's live list, made under the user's
    /// config; the curated catalog names OpenAI's), else from `offered`;
    /// else the user's configured model.
    pub fn model_for(&self, offered: &[String], live: Option<&[String]>) -> Option<String> {
        let list = if self.custom_provider() { live.unwrap_or_default() } else { offered };
        super::model_pick::pick(super::recipes::Recipe::Codex, list).or_else(|| self.model.clone())
    }
}

const OPENAI: &str = "openai";

/// A TOML bare key: the only keys passed on, so no quoting is needed.
fn bare_key(key: &str) -> bool {
    !key.is_empty() && key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

fn quoted(s: &str) -> String {
    // A JSON string is a TOML basic string.
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_owned())
}

/// Every non-table value under `table` as `(dotted path, TOML value)`,
/// without credential-bearing ones or keys that need quoting.
fn flatten(table: &toml::Table, path: &mut Vec<String>, out: &mut Vec<(String, String)>) {
    for (key, value) in table {
        if !bare_key(key) {
            continue;
        }
        path.push(key.clone());
        if let Some(inner) = value.as_table() {
            if !headers(path) {
                flatten(inner, path, out);
            }
        } else if !credential(path)
            && let Some(rendered) = render(value)
        {
            out.push((path.join("."), rendered));
        }
        path.pop();
    }
}

fn normalized(component: &str) -> String {
    component.to_ascii_lowercase().replace('-', "_")
}

/// A header table (its values are often keys).
fn headers(path: &[String]) -> bool {
    path.iter()
        .map(|c| normalized(c))
        .any(|c| matches!(c.as_str(), "headers" | "http_headers" | "env_http_headers"))
}

/// A value that may hold a secret (classic's `isCredentialBearingKey`):
/// headers, tokens, secrets, passwords, credentials, auth and keys. Kept:
/// `env_key` and `requires_openai_auth`, which name where the key is.
fn credential(path: &[String]) -> bool {
    if headers(path) {
        return true;
    }
    let joined = path.iter().map(|c| normalized(c)).collect::<Vec<_>>().join(".");
    if matches!(joined.as_str(), "env_key" | "env_key_instructions" | "requires_openai_auth") {
        return false;
    }
    ["token", "secret", "password", "credential", "auth", "api_key", "apikey"]
        .iter()
        .any(|word| joined.contains(word))
        || joined.ends_with("_key")
        || joined == "key"
}

/// `value` as a TOML value for `-c`; None for one that cannot be written.
fn render(value: &toml::Value) -> Option<String> {
    Some(match value {
        toml::Value::String(s) => quoted(s),
        toml::Value::Integer(n) => n.to_string(),
        toml::Value::Float(f) if f.is_finite() => format!("{f:?}"),
        toml::Value::Float(_) => return None,
        toml::Value::Boolean(b) => b.to_string(),
        toml::Value::Datetime(d) => d.to_string(),
        toml::Value::Array(items) => {
            let items: Option<Vec<String>> = items.iter().map(render).collect();
            format!("[{}]", items?.join(", "))
        }
        toml::Value::Table(table) => {
            let mut fields = Vec::new();
            for (key, inner) in table {
                if !bare_key(key) {
                    return None;
                }
                fields.push(format!("{key} = {}", render(inner)?));
            }
            fields.sort();
            format!("{{ {} }}", fields.join(", "))
        }
    })
}

/// `$CODEX_HOME/config.toml`, else `~/.codex/config.toml`.
pub fn config_path(codex_home: Option<&str>, home: Option<&Path>) -> Option<PathBuf> {
    match codex_home.filter(|h| !h.is_empty()) {
        Some(dir) => Some(PathBuf::from(dir).join("config.toml")),
        None => home.map(|h| h.join(".codex").join("config.toml")),
    }
}
