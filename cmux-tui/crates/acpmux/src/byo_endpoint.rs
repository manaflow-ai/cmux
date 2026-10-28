//! Your own model endpoint as a harness (u2586, docs/chiefs-create-byo-backend.md):
//! what `harness add` writes for `example: "anthropic-endpoint"` and
//! `example: "openai-endpoint"`, and the checks around it.
//!
//! - **anthropic-endpoint**: acpmux's own Claude Code adapter (`claude-stdio`,
//!   `claude`) with `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` (a Keychain
//!   reference), `ANTHROPIC_MODEL` and the small/fast model set to the model.
//!   The spawn removes every other inherited `ANTHROPIC_*` and Claude
//!   provider switch ([`clear_inherited`]), so the person's own login env
//!   never redirects it.
//! - **openai-endpoint**: OpenCode (`opencode acp`) with
//!   `OPENCODE_CONFIG_CONTENT` (inline config, which wins over the global and
//!   project config) defining provider `byo` on `@ai-sdk/openai-compatible`
//!   and `"model": "byo/<model>"`; the key comes from `CMUX_BYO_API_KEY`
//!   (a Keychain reference) through OpenCode's `{env:…}` substitution.
//!
//! Both profiles carry [`OWN_ENDPOINT_KEY`], an internal marker the spawn
//! removes: a family or global route never rewrites such a harness (a chat
//! or workspace route still does), and the doctor names endpoint fixes.
//! The key is never in the profile, an error, a log or argv: a literal key
//! (in a parameter, the URL or the item name) is refused.

use std::collections::BTreeMap;

/// The profile-env marker of an endpoint harness: `anthropic` or `openai`.
/// Internal: the spawn removes it (agent/command.rs).
pub const OWN_ENDPOINT_KEY: &str = "ACPMUX_OWN_ENDPOINT";
/// The env key OpenCode's `byo` provider reads its key from.
pub const OPENAI_KEY_ENV: &str = "CMUX_BYO_API_KEY";
/// The env key Claude Code sends as `Authorization: Bearer`.
pub const ANTHROPIC_KEY_ENV: &str = "ANTHROPIC_AUTH_TOKEN";
/// The OpenCode provider id the endpoint gets.
pub const OPENCODE_PROVIDER: &str = "byo";

/// Claude provider switches outside `ANTHROPIC_*` that an endpoint harness
/// must not inherit: each would send Claude Code elsewhere or sign it in
/// another way.
const CLAUDE_PROVIDER_KEYS: &[&str] = &[
    "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
    "CLAUDE_CODE_SKIP_BEDROCK_AUTH",
    "CLAUDE_CODE_SKIP_VERTEX_AUTH",
    "CLAUDE_CODE_SKIP_FOUNDRY_AUTH",
    "AWS_BEARER_TOKEN_BEDROCK",
];

/// `ANTHROPIC_*` keys removed even when nothing inherited them (so a test
/// and a reader see the rule); any other inherited `ANTHROPIC_*` goes too.
const ANTHROPIC_KEYS: &[&str] = &[
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_CUSTOM_HEADERS",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_BEDROCK_BASE_URL",
    "ANTHROPIC_VERTEX_BASE_URL",
];

/// Which endpoint kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// An Anthropic Messages API endpoint, through Claude Code.
    Anthropic,
    /// An OpenAI Chat Completions endpoint, through OpenCode.
    OpenAi,
}

impl Kind {
    /// The kind an `example` name asks for.
    pub fn from_example(name: &str) -> Option<Self> {
        match name {
            "anthropic-endpoint" => Some(Self::Anthropic),
            "openai-endpoint" => Some(Self::OpenAi),
            _ => None,
        }
    }

    /// The example name.
    pub fn example(self) -> &'static str {
        match self {
            Self::Anthropic => "anthropic-endpoint",
            Self::OpenAi => "openai-endpoint",
        }
    }

    fn marker(self) -> &'static str {
        match self {
            Self::Anthropic => "anthropic",
            Self::OpenAi => "openai",
        }
    }

    /// The endpoint kind a profile env marks, if any.
    pub fn of_env(env: &BTreeMap<String, String>) -> Option<Self> {
        match env.get(OWN_ENDPOINT_KEY).map(String::as_str) {
            Some("anthropic") => Some(Self::Anthropic),
            Some("openai") => Some(Self::OpenAi),
            _ => None,
        }
    }

    /// The env key that holds the key (what `secret set` takes).
    pub fn secret_key(self) -> &'static str {
        match self {
            Self::Anthropic => ANTHROPIC_KEY_ENV,
            Self::OpenAi => OPENAI_KEY_ENV,
        }
    }
}

/// Whether `text` holds something that must not be in a profile value: a
/// shape the secret scanner knows, or a well-known key prefix.
pub fn looks_like_secret(text: &str) -> bool {
    const PREFIXES: &[&str] =
        &["sk-", "sk_", "pk-", "rk-", "ghp_", "gho_", "github_pat_", "xox", "AKIA", "AIza"];
    PREFIXES.iter().any(|p| text.starts_with(p)) || !crate::secret_scan::find(text).is_empty()
}

/// Why a URL was refused: a plain problem, or a key in it.
#[derive(Debug, PartialEq, Eq)]
pub enum UrlError {
    Invalid(String),
    Secret(String),
}

/// The base URL as the profile keeps it (trailing `/` dropped): https, or
/// http only to localhost, 127.0.0.1 or ::1; no user or password, no
/// fragment, no `${`/`{`/`}` (acpmux and OpenCode substitutions), no key.
/// An error never repeats the URL (it may hold a key).
pub fn check_base_url(url: &str) -> Result<String, UrlError> {
    let url = url.trim();
    let bad = |m: &str| Err(UrlError::Invalid(m.to_owned()));
    if url.is_empty() {
        return bad("baseUrl is required");
    }
    if url.len() > 2048 || url.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return bad("baseUrl must be one URL without spaces");
    }
    if url.contains(['{', '}', '$', '"', '\\']) {
        return bad("baseUrl may not contain {, }, $, quotes or backslashes");
    }
    let parsed = match reqwest::Url::parse(url) {
        Ok(u) => u,
        Err(_) => return bad("baseUrl must be a full URL such as https://llm.example.com/v1"),
    };
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return Err(UrlError::Secret(
            "baseUrl may not hold a user or password; store the key in the Keychain".into(),
        ));
    }
    if parsed.query_pairs().any(|(k, _)| crate::config::profiles::secret_looking(&k))
        || looks_like_secret(url)
    {
        return Err(UrlError::Secret(
            "baseUrl holds what looks like a key; store the key in the Keychain".into(),
        ));
    }
    let host = parsed.host_str().unwrap_or("");
    if host.is_empty() {
        return bad("baseUrl has no host");
    }
    let local = matches!(host, "localhost" | "127.0.0.1" | "[::1]" | "::1");
    match parsed.scheme() {
        "https" => {}
        "http" if local => {}
        "http" => return bad("baseUrl must use https (plain http only to localhost or 127.0.0.1)"),
        _ => return bad("baseUrl must be an https URL"),
    }
    if parsed.fragment().is_some() {
        return bad("baseUrl may not have a #fragment");
    }
    Ok(url.trim_end_matches('/').to_owned())
}

/// The model id: one word of printable characters, no quotes, braces or `$`.
pub fn check_model(model: &str) -> Result<String, String> {
    let model = model.trim();
    if model.is_empty() {
        return Err("model is required".into());
    }
    if model.len() > 200
        || model.chars().any(|c| c.is_whitespace() || c.is_control())
        || model.contains(['{', '}', '$', '"', '\\', '\''])
    {
        return Err("model must be one model id (no spaces, quotes, braces or $)".into());
    }
    Ok(model.to_owned())
}

/// The Keychain item, as `service` or `service/account` (a leading
/// `keychain:` is dropped). Err((is_secret, message)); the message never
/// repeats the value.
pub fn check_keychain_item(item: &str) -> Result<String, (bool, String)> {
    let item = item.trim();
    let item = item.strip_prefix("keychain:").unwrap_or(item).trim();
    if item.is_empty() {
        return Err((false, "keychainItem is empty".into()));
    }
    if looks_like_secret(item) {
        return Err((
            true,
            "keychainItem looks like the key itself: give the name of the Keychain item that holds it"
                .into(),
        ));
    }
    if item.len() > 200
        || item.starts_with('/')
        || item.chars().any(|c| c.is_whitespace() || c.is_control())
        || item.contains(['{', '}', '$', '"', '\\'])
    {
        return Err((
            false,
            "keychainItem must be a Keychain item name: service or service/account".into(),
        ));
    }
    Ok(item.to_owned())
}

/// The item `cmux harness secret set ID KEY` writes for this kind.
pub fn default_item(kind: Kind, id: &str) -> String {
    crate::cli::harness_secret::reference(id, kind.secret_key())
}

/// What the profile is made of; every value already checked.
pub struct Endpoint<'a> {
    pub kind: Kind,
    pub id: &'a str,
    pub name: &'a str,
    pub base_url: &'a str,
    pub model: &'a str,
    pub keychain_item: &'a str,
}

fn toml_string(s: &str) -> String {
    // A JSON string is a valid TOML basic string.
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".into())
}

/// The profile file text.
pub fn profile_text(e: &Endpoint<'_>) -> String {
    let key = e.kind.secret_key();
    let head = format!(
        "# cmux harness profile: your own {} endpoint. Guide: docs/add-your-harness.md\n\
         # The key is in the Keychain item below, never in this file. Store it with:\n\
         #   cmux harness secret set {id} {key}\n\
         # Check it (one real hello turn) with: cmux harness doctor {id}\n\
         schema = 1\nid = {}\nname = {}\n",
        match e.kind {
            Kind::Anthropic => "Anthropic-compatible",
            Kind::OpenAi => "OpenAI-compatible",
        },
        toml_string(e.id),
        toml_string(e.name),
        id = e.id,
    );
    let item_line = format!("{key} = {{ keychain = {} }}\n", toml_string(e.keychain_item));
    let marker = format!("{OWN_ENDPOINT_KEY} = {}\n", toml_string(e.kind.marker()));
    match e.kind {
        Kind::Anthropic => {
            let m = toml_string(e.model);
            format!(
                "{head}icon = \"claude\"\nprotocol = \"claude-stdio\"\ncommand = \"claude\"\n\n\
                 [capabilities]\npermission_modes = true\nresume = true\n\n\
                 [defaults]\nmodel = {m}\n\n[models]\nlist = [{m}]\n\n\
                 [env]\nANTHROPIC_BASE_URL = {}\n{item_line}ANTHROPIC_MODEL = {m}\n\
                 ANTHROPIC_SMALL_FAST_MODEL = {m}\nANTHROPIC_DEFAULT_HAIKU_MODEL = {m}\n{marker}",
                toml_string(e.base_url),
            )
        }
        Kind::OpenAi => {
            let full = format!("{OPENCODE_PROVIDER}/{}", e.model);
            let mut models = serde_json::Map::new();
            models.insert(e.model.to_owned(), serde_json::json!({"name": e.model}));
            let config = serde_json::json!({
                "$schema": "https://opencode.ai/config.json",
                "provider": {OPENCODE_PROVIDER: {
                    "npm": "@ai-sdk/openai-compatible",
                    "name": e.name,
                    "options": {"baseURL": e.base_url, "apiKey": format!("{{env:{OPENAI_KEY_ENV}}}")},
                    "models": models,
                }},
                "model": full,
                "small_model": full,
            });
            let f = toml_string(&full);
            format!(
                "{head}icon = \"opencode\"\nprotocol = \"acp\"\ncommand = \"opencode\"\nargs = [\"acp\"]\n\n\
                 [capabilities]\npermission_modes = true\nresume = true\n\n\
                 [defaults]\nmodel = {f}\n\n[models]\nlist = [{f}]\n\n\
                 [auth]\ndocs = \"https://opencode.ai/docs/providers/\"\n\n\
                 [env]\nOPENCODE_CONFIG_CONTENT = {}\n{item_line}{marker}",
                toml_string(&config.to_string()),
            )
        }
    }
}

/// What a failed hello turn says is wrong.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Problem {
    /// The endpoint refused the key.
    Key,
    /// The endpoint was not reached, or the path is wrong.
    BaseUrl,
    /// The endpoint has no such model.
    Model,
    /// Nothing recognizable.
    Other,
}

/// Whether `text` has `code` as a whole number (not inside 4011).
fn has_code(text: &str, code: &str) -> bool {
    text.match_indices(code).any(|(at, found)| {
        // `at` comes from match_indices, so it is a character boundary.
        let Some((head, tail)) = text.split_at_checked(at) else { return false };
        let before = head.chars().next_back();
        let after = tail.strip_prefix(found).and_then(|t| t.chars().next());
        !before.is_some_and(|c| c.is_ascii_digit()) && !after.is_some_and(|c| c.is_ascii_digit())
    })
}

/// The problem an error from Claude Code, OpenCode or the endpoint names.
pub fn classify(text: &str) -> Problem {
    let t = text.to_ascii_lowercase();
    let any = |words: &[&str]| words.iter().any(|w| t.contains(w));
    if has_code(&t, "401")
        || has_code(&t, "403")
        || any(&[
            "unauthorized",
            "authentication_error",
            "authentication failed",
            "invalid api key",
            "invalid x-api-key",
            "incorrect api key",
            "invalid_api_key",
            "invalid bearer",
            "api key not valid",
            "permission_denied",
            "forbidden",
        ])
    {
        return Problem::Key;
    }
    if t.contains("model")
        && (has_code(&t, "404")
            || any(&[
                "not found",
                "not_found",
                "does not exist",
                "unknown model",
                "invalid model",
                "no such model",
                "model_not_found",
                "unsupported model",
            ]))
    {
        return Problem::Model;
    }
    if has_code(&t, "404")
        || has_code(&t, "405")
        || any(&[
            "connection error",
            "connection refused",
            "econnrefused",
            "enotfound",
            "getaddrinfo",
            "unable to connect",
            "failed to connect",
            "fetch failed",
            "could not resolve",
            "name or service not known",
            "nodename nor servname",
            "econnreset",
            "etimedout",
            "timed out",
            "certificate",
            "ssl",
            "not found",
            "<html",
        ])
    {
        return Problem::BaseUrl;
    }
    Problem::Other
}

/// The fix line for `problem` (no value: the report masks env values).
pub fn fix(problem: Problem, kind: Kind, id: &str) -> String {
    let key = kind.secret_key();
    let base = match kind {
        Kind::Anthropic => "the URL before /v1/messages, for example https://llm.example.com",
        Kind::OpenAi => "the URL before /chat/completions, usually ending in /v1",
    };
    match problem {
        Problem::Key => format!(
            "check the key: the endpoint refused it. Store it again with `cmux harness secret set {id} {key}`"
        ),
        Problem::BaseUrl => format!(
            "check the base URL: the endpoint was not reached or has no such path. It is {base}; add the harness again with the right baseUrl (--base-url)"
        ),
        Problem::Model => "model not found: the endpoint has no such model. Add the harness again with a model id from its model list (--model)".to_owned(),
        Problem::Other => format!(
            "check the base URL, the key (`cmux harness secret set {id} {key}`) and the model"
        ),
    }
}

/// Remove from `cmd` the inherited Claude provider env an Anthropic endpoint
/// harness must not get: every `ANTHROPIC_*` and Claude provider switch that
/// `env` (what the profile sets) does not set itself.
pub(crate) fn clear_inherited(cmd: &mut tokio::process::Command, env: &BTreeMap<String, String>) {
    let mut drop: Vec<String> = crate::agent::command_env(cmd)
        .into_iter()
        .map(|(k, _)| k)
        .filter(|k| k.starts_with("ANTHROPIC_") || CLAUDE_PROVIDER_KEYS.contains(&k.as_str()))
        .collect();
    drop.extend(ANTHROPIC_KEYS.iter().chain(CLAUDE_PROVIDER_KEYS).map(|k| (*k).to_owned()));
    drop.retain(|k| !env.contains_key(k));
    for k in drop {
        cmd.env_remove(k);
    }
}

#[cfg(all(test, unix))]
#[path = "byo_endpoint_tests.rs"]
mod tests;
