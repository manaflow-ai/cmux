//! Your own model endpoint as a harness (u2586, docs/chiefs-create-byo-backend.md):
//! what `harness add` writes for `example: "anthropic-endpoint"` and
//! `example: "openai-endpoint"`, and the checks around it.
//!
//! - **anthropic-endpoint**: acpmux's own Claude Code adapter (`claude-stdio`,
//!   `claude`) with `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` (a Keychain
//!   reference), `ANTHROPIC_MODEL` (the first model) and Claude Code's Opus,
//!   Sonnet and Haiku slots ([`claude_slots`]).
//!   The spawn removes every other inherited `ANTHROPIC_*` and Claude
//!   provider switch ([`clear_inherited`]), so the person's own login env
//!   never redirects it.
//! - **openai-endpoint**: OpenCode (`opencode acp`) with
//!   `OPENCODE_CONFIG_CONTENT` (inline config, which wins over the global and
//!   project config) defining provider `byo` on `@ai-sdk/openai-compatible`
//!   with every model, and `"model": "byo/<first model>"`; the key comes from
//!   `CMUX_BYO_API_KEY` (a Keychain reference) through OpenCode's `{env:…}`
//!   substitution. A keyless endpoint's config names no key, and the spawn
//!   removes an inherited `CMUX_BYO_API_KEY` from every endpoint harness.
//!
//! An endpoint harness holds one or more models (the picker lists each; the
//! first is the default). [`ALL_MODELS`] in the list asks for every model the
//! endpoint's `/models` lists ([`fetch_models`], bounded by
//! [`FETCH_TIMEOUT`]); the add fills it in before the profile is written.
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
/// A model-list entry that stands for every model the endpoint lists.
pub const ALL_MODELS: &str = "*";
/// The most models one endpoint harness lists.
pub const MAX_MODELS: usize = 100;
/// How long a model-list fetch may take, connect included.
// timeout: one model-list fetch from the person's endpoint while a harness is checked; a slow one fails that check with a message and can be retried
pub const FETCH_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);
/// The most bytes of a model-list answer read.
pub(crate) const MAX_LIST_BYTES: usize = 4 << 20;

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

    pub(crate) fn marker(self) -> &'static str {
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

/// The model list: each entry one model id or several separated by commas
/// (the app's add sends one string), in order, without repeats; the first is
/// the default. [`ALL_MODELS`] may appear once, for the fetched list.
pub fn check_models(entries: &[String]) -> Result<Vec<String>, String> {
    let mut out: Vec<String> = Vec::new();
    for word in entries.iter().flat_map(|e| e.split(',')).map(str::trim).filter(|w| !w.is_empty()) {
        let model = if word == ALL_MODELS { word.to_owned() } else { check_model(word)? };
        if !out.contains(&model) {
            out.push(model);
        }
    }
    if out.is_empty() {
        return Err("model is required".into());
    }
    if out.len() > MAX_MODELS {
        return Err(format!("at most {MAX_MODELS} models"));
    }
    Ok(out)
}

/// Claude Code's model slots for `models` (largest first): Opus is the first,
/// Sonnet the second, Haiku (also the small, fast model) the third; a slot
/// with no model of its own takes the one before it. So a subagent or a
/// `/model opus` never asks the endpoint for a model it does not serve.
pub fn claude_slots(models: &[String]) -> [(&'static str, &str); 4] {
    let opus = models.first().map(String::as_str).unwrap_or_default();
    let sonnet = models.get(1).map(String::as_str).unwrap_or(opus);
    let haiku = models.get(2).map(String::as_str).unwrap_or(sonnet);
    [
        ("ANTHROPIC_DEFAULT_OPUS_MODEL", opus),
        ("ANTHROPIC_DEFAULT_SONNET_MODEL", sonnet),
        ("ANTHROPIC_DEFAULT_HAIKU_MODEL", haiku),
        ("ANTHROPIC_SMALL_FAST_MODEL", haiku),
    ]
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

/// The item a keyless endpoint's reply names for this kind (where a key would go).
pub fn default_item(kind: Kind, id: &str) -> String {
    crate::cli::harness_secret::reference(id, kind.secret_key())
}

/// What the profile is made of; every value already checked.
pub struct Endpoint<'a> {
    pub kind: Kind,
    pub id: &'a str,
    pub name: &'a str,
    pub base_url: &'a str,
    /// One or more, the default first; never [`ALL_MODELS`].
    pub models: &'a [String],
    /// None: the endpoint takes no key, and the profile names no Keychain item.
    pub keychain_item: Option<&'a str>,
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
         # A key is only ever in the Keychain item named below, never in this file. A new key:\n\
         #   add it again with --key --force (or from Settings > Agents), id {id}, key {key}\n\
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
    let item_line = e
        .keychain_item
        .map(|item| format!("{key} = {{ keychain = {} }}\n", toml_string(item)))
        .unwrap_or_default();
    let marker = format!("{OWN_ENDPOINT_KEY} = {}\n", toml_string(e.kind.marker()));
    match e.kind {
        Kind::Anthropic => {
            let m = toml_string(e.models.first().map(String::as_str).unwrap_or_default());
            let list = e.models.iter().map(|m| toml_string(m)).collect::<Vec<_>>().join(", ");
            let slots: String = claude_slots(e.models)
                .iter()
                .map(|(k, v)| format!("{k} = {}\n", toml_string(v)))
                .collect();
            format!(
                "{head}icon = \"claude\"\nprotocol = \"claude-stdio\"\ncommand = \"claude\"\n\n\
                 [capabilities]\npermission_modes = true\nresume = true\n\n\
                 [defaults]\nmodel = {m}\n\n[models]\nlist = [{list}]\n\n\
                 [env]\nANTHROPIC_BASE_URL = {}\n{item_line}ANTHROPIC_MODEL = {m}\n{slots}{marker}",
                toml_string(e.base_url),
            )
        }
        Kind::OpenAi => {
            let full = |m: &str| format!("{OPENCODE_PROVIDER}/{m}");
            let first = full(e.models.first().map(String::as_str).unwrap_or_default());
            // Every model in the provider: OpenCode reports these, and a chat starts on any.
            let mut models = serde_json::Map::new();
            for m in e.models {
                models.insert(m.clone(), serde_json::json!({"name": m}));
            }
            // apiKey is the env reference (never a value), and only when the profile names a
            // Keychain item: a keyless endpoint's config reads no variable, so a stray
            // CMUX_BYO_API_KEY in some env never reaches it (the spawn removes it too:
            // [`clear_inherited`]). A key comes only with an add (`--key`, Settings).
            let mut options = serde_json::json!({"baseURL": e.base_url});
            if let (Some(_), Some(map)) = (e.keychain_item, options.as_object_mut()) {
                let key = serde_json::Value::String(format!("{{env:{OPENAI_KEY_ENV}}}"));
                map.insert("apiKey".to_owned(), key);
            }
            let config = serde_json::json!({
                "$schema": "https://opencode.ai/config.json",
                "provider": {OPENCODE_PROVIDER: {
                    "npm": "@ai-sdk/openai-compatible",
                    "name": e.name,
                    "options": options,
                    "models": models,
                }},
                "model": first,
                "small_model": first,
            });
            let list =
                e.models.iter().map(|m| toml_string(&full(m))).collect::<Vec<_>>().join(", ");
            let f = toml_string(&first);
            format!(
                "{head}icon = \"opencode\"\nprotocol = \"acp\"\ncommand = \"opencode\"\nargs = [\"acp\"]\n\n\
                 [capabilities]\npermission_modes = true\nresume = true\n\n\
                 [defaults]\nmodel = {f}\n\n[models]\nlist = [{list}]\n\n\
                 [auth]\ndocs = \"https://opencode.ai/docs/providers/\"\n\n\
                 [env]\nOPENCODE_CONFIG_CONTENT = {}\n{item_line}{marker}",
                toml_string(&config.to_string()),
            )
        }
    }
}

/// Where the endpoint lists its models: `<base>/models` for an OpenAI base
/// (it ends in `/v1`), `<base>/v1/models` for an Anthropic base (it ends
/// before `/v1`), as each API names it.
/// A query on the base (`?api-version=...`) stays, after the path.
pub fn models_url(kind: Kind, base_url: &str) -> String {
    let (path, query) = match base_url.split_once('?') {
        Some((path, query)) => (path, Some(query)),
        None => (base_url, None),
    };
    let base = path.trim_end_matches('/');
    let url = if kind == Kind::OpenAi || base.ends_with("/v1") {
        format!("{base}/models")
    } else {
        format!("{base}/v1/models")
    };
    match query {
        Some(query) => format!("{url}?{query}"),
        None => url,
    }
}

/// The model ids a `/models` answer lists, in its order: OpenAI's and
/// Anthropic's `{"data": [{"id"}]}`, or a local server's `{"models":
/// [{"id"|"model"|"name"}]}`. An id [`check_model`] refuses is left out.
pub fn parse_models(body: &str) -> Result<Vec<String>, String> {
    let v: serde_json::Value = serde_json::from_str(body)
        .map_err(|_| "the endpoint's model list is not JSON".to_owned())?;
    let rows = v
        .get("data")
        .and_then(serde_json::Value::as_array)
        .or_else(|| v.get("models").and_then(serde_json::Value::as_array))
        .ok_or_else(|| "the endpoint's answer has no model list (data or models)".to_owned())?;
    let mut out: Vec<String> = Vec::new();
    for row in rows {
        let id = match row {
            serde_json::Value::String(id) => Some(id.as_str()),
            row => ["id", "model", "name"]
                .iter()
                .find_map(|k| row.get(k).and_then(serde_json::Value::as_str)),
        };
        if let Some(id) = id.and_then(|id| check_model(id).ok())
            && !out.contains(&id)
        {
            out.push(id);
        }
        if out.len() == MAX_MODELS {
            break;
        }
    }
    Ok(out)
}

/// Asks the endpoint for its models ([`models_url`]): the URL checked again
/// (https, or http only to this machine), no redirects, [`FETCH_TIMEOUT`].
/// The key goes as a bearer token (and `x-api-key` to an Anthropic one);
/// an error never holds it.
pub async fn fetch_models(
    kind: Kind,
    base_url: &str,
    key: Option<&str>,
    timeout: std::time::Duration,
) -> Result<Vec<String>, String> {
    let base = check_base_url(base_url).map_err(|e| match e {
        UrlError::Invalid(m) | UrlError::Secret(m) => m,
    })?;
    let url = models_url(kind, &base);
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = reqwest::Client::builder()
        .timeout(timeout)
        // timeout: connecting to the endpoint's model list (a check of a harness being added); the whole fetch keeps FETCH_TIMEOUT
        .connect_timeout(timeout.min(std::time::Duration::from_secs(5)))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| format!("cannot make the request: {e}"))?;
    let mut request = client.get(&url);
    if kind == Kind::Anthropic {
        request = request.header("anthropic-version", "2023-06-01");
    }
    if let Some(key) = key.filter(|k| !k.is_empty()) {
        request = request.bearer_auth(key);
        if kind == Kind::Anthropic {
            request = request.header("x-api-key", key);
        }
    }
    let response = request.send().await.map_err(|e| {
        if e.is_timeout() {
            format!("the endpoint did not answer in {} s", timeout.as_secs())
        } else {
            "the endpoint was not reached: check the base URL".to_owned()
        }
    })?;
    let status = response.status().as_u16();
    match status {
        200..=299 => {}
        401 | 403 => return Err(format!("the endpoint refused the key (HTTP {status})")),
        404 | 405 => {
            return Err(format!(
                "the endpoint has no model list at {} (HTTP {status}): check the base URL, or type the model ids",
                url.rsplit_once("//").map_or(url.as_str(), |(_, rest)| rest)
            ));
        }
        _ => return Err(format!("the endpoint answered HTTP {status} for its model list")),
    }
    let bytes = read_capped(response, MAX_LIST_BYTES).await?;
    let models = parse_models(&String::from_utf8_lossy(&bytes))?;
    if models.is_empty() {
        return Err("the endpoint lists no models: type the model ids".into());
    }
    Ok(models)
}

/// The body of `response`, read a chunk at a time and refused as soon as it
/// passes `cap` bytes (a declared length past it is refused before any read).
async fn read_capped(mut response: reqwest::Response, cap: usize) -> Result<Vec<u8>, String> {
    let too_large = || "the endpoint's model list is too large".to_owned();
    if response.content_length().is_some_and(|n| n > cap as u64) {
        return Err(too_large());
    }
    let mut body = Vec::new();
    while let Some(chunk) =
        response.chunk().await.map_err(|_| "the model list did not arrive".to_owned())?
    {
        if body.len() + chunk.len() > cap {
            return Err(too_large());
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

/// What a failed hello turn says is wrong.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Problem {
    /// The endpoint refused the key.
    Key,
    /// The key works, but its account has no credit left.
    Credit,
    /// The endpoint was not reached, or the path is wrong.
    BaseUrl,
    /// The endpoint has no such model.
    Model,
    /// Nothing recognizable.
    Other,
}

/// Whether `text` has `code` as a whole number (not inside 4011).
fn has_code(text: &str, code: &str) -> bool {
    text.match_indices(code).any(|(at, _)| {
        let before = text[..at].chars().next_back();
        let after = text[at + code.len()..].chars().next();
        !before.is_some_and(|c| c.is_ascii_digit()) && !after.is_some_and(|c| c.is_ascii_digit())
    })
}

/// The problem an error from Claude Code, OpenCode or the endpoint names.
pub fn classify(text: &str) -> Problem {
    let t = text.to_ascii_lowercase();
    let any = |words: &[&str]| words.iter().any(|w| t.contains(w));
    // The words the agent pane reads as `no-credit` (webviews failureCopy.ts NO_CREDIT). First: an
    // OpenAI-compatible endpoint sends it as a 429 or 402, and its body can name the key too.
    if any(&[
        "credit balance is too low",
        "credit balance too low",
        "insufficient_quota",
        "insufficient quota",
        "billing_hard_limit",
        "billing hard limit",
        "exceeded your current quota",
        "insufficient credits",
        "insufficient credit",
        "payment required",
    ]) {
        return Problem::Credit;
    }
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
            "check the key ({key}): the endpoint refused it. Add {id} again with its key (`cmux harness add {id} ... --key --force`, or Settings > Agents)"
        ),
        Problem::BaseUrl => format!(
            "check the base URL: the endpoint was not reached or has no such path. It is {base}; add the harness again with the right baseUrl (--base-url)"
        ),
        Problem::Credit => format!(
            "add credit: the endpoint took the key, but the account it belongs to is out of credit. Add credit to that account, then run `cmux harness doctor {id}` again"
        ),
        Problem::Model => "model not found: the endpoint has no such model. Add the harness again with a model id from its model list (--model)".to_owned(),
        Problem::Other => format!(
            "check the base URL, the key ({key}; add {id} again with `--key --force`) and the model"
        ),
    }
}

/// Whether a Keychain service is cmux's own (`cmux-harness`), in any spelling: endpoint keys
/// cmux stored, one item per endpoint profile.
pub fn is_own_service(service: &str) -> bool {
    let service = service.trim();
    let service = service.strip_prefix("keychain:").unwrap_or(service).trim();
    service.eq_ignore_ascii_case(crate::cli::harness_secret::SERVICE)
}

/// Whether `account` is endpoint `id`'s own (`<id>/<KEY>.<generation>`, or `<id>/<KEY>` as an
/// older build wrote it). `id` None: any one endpoint's own account, exactly (the profile env
/// resolver, which has no id).
pub fn is_own_account(account: &str, id: Option<&str>) -> bool {
    let Some((owner, rest)) = account.split_once('/') else { return false };
    let (key, generation) = match rest.split_once('.') {
        Some((key, g)) => (key, Some(g)),
        None => (rest, None),
    };
    crate::config::profiles::valid_id(owner)
        && id.is_none_or(|id| id == owner)
        && crate::config::profiles::valid_env_key(key)
        && generation.is_none_or(|g| !g.is_empty() && g.chars().all(|c| c.is_ascii_hexdigit()))
}

/// Every Keychain read for an endpoint harness's key goes through here: the `*` models read of
/// an add (`id` Some) and the profile env resolver (spawn, doctor, run, sign-in; `id` None).
/// An item in cmux's own `cmux-harness` service is read only by its exact account, endpoint
/// `id`'s own: never the bare service, which would match any endpoint's key. Any other item is
/// one the person named for this endpoint (`keychainItem`), read as named.
pub fn endpoint_keychain_lookup(
    id: Option<&str>,
    service: &str,
    account: Option<&str>,
    lookup: &dyn Fn(&str, Option<&str>) -> Result<String, String>,
) -> Result<String, String> {
    if !is_own_service(service) {
        return lookup(service, account);
    }
    match account.filter(|a| is_own_account(a, id)) {
        Some(account) => lookup(crate::cli::harness_secret::SERVICE, Some(account)),
        None => Err(format!(
            "an endpoint reads only its own item in {} (by its exact account)",
            crate::cli::harness_secret::SERVICE
        )),
    }
}

/// Remove from `cmd` the inherited env an endpoint harness of `kind` must not
/// get, unless `env` (what the profile sets) sets it itself: `CMUX_BYO_API_KEY`
/// for both kinds (a key only ever comes from the profile's own Keychain item,
/// never the daemon's or a login shell's env), and for an Anthropic endpoint
/// every `ANTHROPIC_*` and Claude provider switch.
pub(crate) fn clear_inherited(
    cmd: &mut tokio::process::Command,
    kind: Kind,
    env: &BTreeMap<String, String>,
) {
    let mut drop: Vec<String> = vec![OPENAI_KEY_ENV.to_owned()];
    if kind == Kind::Anthropic {
        drop.extend(
            crate::agent::command_env(cmd).into_iter().map(|(k, _)| k).filter(|k| cleared(k)),
        );
        drop.extend(ANTHROPIC_KEYS.iter().chain(CLAUDE_PROVIDER_KEYS).map(|k| (*k).to_owned()));
    }
    drop.retain(|k| !env.contains_key(k));
    for k in drop {
        cmd.env_remove(k);
    }
}

/// A name `clear_inherited` removes unless the harness sets it itself.
fn cleared(name: &str) -> bool {
    name.starts_with("ANTHROPIC_") || CLAUDE_PROVIDER_KEYS.contains(&name)
}

/// The harness of `profile_env` (its unresolved env, the endpoint marker
/// still in it) never takes `name` from the login env: an Anthropic endpoint
/// harness's `clear_inherited` removes it (`login_env::ChildEnv`), as every
/// endpoint harness removes an inherited `CMUX_BYO_API_KEY`.
pub(crate) fn clears(name: &str, profile_env: &BTreeMap<String, String>) -> bool {
    let Some(kind) = Kind::of_env(profile_env) else { return false };
    !profile_env.contains_key(name)
        && (name == OPENAI_KEY_ENV || (kind == Kind::Anthropic && cleared(name)))
}

#[cfg(all(test, unix))]
#[path = "byo_endpoint_tests.rs"]
mod tests;
