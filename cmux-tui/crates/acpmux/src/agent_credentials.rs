//! A Cloud chat's model credential, delivered by the owner's Mac with the agent's launch
//! (cmux-tui/docs/model-connections.md, "Revision 2": no gateway, connections go straight to the
//! machine).
//!
//! The Mac app reads the chat's connection from its own acpmux (`_acpmux/connections/credential`,
//! the person's Keychain) and sends the env with the start: `session/new` with
//! `_meta.acpmux.credentials: {env: {NAME: value}}`, and later `agent/credentials.update
//! {sessionId, env}` with a refreshed ChatGPT access token. Both come from this machine's cmux-tui
//! daemon over the unix socket (its `agent-session-start` / `agent-session-credentials`, which take
//! them only from the owner's own app on the owner's own Cloud VM); acpmux takes them only from its
//! unix socket and never from an agent's own connection ([`admit`]).
//!
//! The credential lives in memory, on its [`crate::hub::Session`] only: never in the session's
//! meta, journal, transcript, events, snapshots or logs, and never in the machine's model-plane env
//! file. A daemon that restarts keeps none of it; the agent host it hands over keeps the env it
//! started with, and the new daemon reads the credential back from that agent's own process env
//! when it adopts the host ([`recovered`], Linux `/proc/PID/environ`; only an agent [`apply`] marked
//! with [`MARKER`]), so the agent's next start (a wake after the machine paused, a route switch)
//! runs on it again (cmux#45776: a Cloud Claude chat said "not signed in" after a pause). The Mac
//! re-sends only a token that expires; an agent whose host also ended before a daemon restart
//! starts without it. An idle chat is the usual case of that (its agent hibernates after two idle
//! minutes, `hub/idle.rs`), so its summary says `credentialOnlyHere` meanwhile and a machine update
//! wakes it before it restarts this daemon (`hub/credentials.rs` `credential_only_here`, cmux-host
//! `updater/credential_wake.rs`). Left open: a daemon that ends any other way while the agent
//! sleeps (a crash, a rollback's restart), a closed chat, and a session that holds a credential
//! with no agent and no hibernation (its agent crashed, or its first start failed or has not run
//! yet). Without one the agent keeps today's coderouter route.
//! with [`MARKER`]). Copilot is delivered again by the owner. Its OpenCode files are never a
//! credential source for the daemon.
//!
//! At each spawn ([`apply`]) the agent gets the credential's variables and loses the machine's
//! coderouter route (`cloud_model_plane::KEYS`: base URLs, placeholder keys) and any other provider
//! login, through the route-unset list the spawn already honours (`routes::UNSET_KEY`). Codex with a
//! ChatGPT plan token (Sign in with ChatGPT, Codex's own OAuth client) runs on a custom provider
//! (`-c` overrides, never an edit of the shared `config.toml`) to the ChatGPT Codex backend Codex
//! itself uses for a ChatGPT sign-in, with the account the token names (cmux#45774: the
//! token-sharing route on api.openai.com refused most accounts with
//! `subscription_sharing_user_not_eligible`); Codex with an OpenAI key the same shape on
//! `OPENAI_API_KEY` to api.openai.com. The overrides go after codex's `app-server` word
//! ([`codex_config_index`]). Claude needs only its env.

use crate::byo_endpoint::{self, Kind};
use crate::rpc::RpcError;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// The `_meta.acpmux` field of `session/new` that carries the launch credential.
pub const FIELD: &str = "credentials";
/// The method that replaces a session's credential (a refreshed ChatGPT token).
pub const UPDATE_METHOD: &str = "agent/credentials.update";

/// Claude Code's long-lived token (`claude setup-token`).
pub const CLAUDE_OAUTH: &str = "CLAUDE_CODE_OAUTH_TOKEN";
/// An Anthropic API key (serves Claude).
pub const ANTHROPIC_KEY: &str = "ANTHROPIC_API_KEY";
/// An OpenAI API key (serves Codex).
pub const OPENAI_KEY: &str = "OPENAI_API_KEY";
/// A ChatGPT plan access token (serves Codex through [`CHATGPT_PROVIDER`]).
pub const CHATGPT_TOKEN: &str = "CMUX_CHATGPT_ACCESS_TOKEN";
/// The ChatGPT account a [`CHATGPT_TOKEN`] acts for, set at the spawn from the token itself and
/// sent as [`ACCOUNT_HEADER`] (never a credential name of its own).
pub const CHATGPT_ACCOUNT: &str = "CMUX_CHATGPT_ACCOUNT_ID";
/// The header the ChatGPT Codex backend reads the account from.
pub const ACCOUNT_HEADER: &str = "chatgpt-account-id";

/// The only names a credential may set.
pub(crate) const GEMINI_KEY: &str = "GEMINI_API_KEY";
pub(crate) const VERTEX_EXPRESS_KEY: &str = "GOOGLE_API_KEY";
const GROK_KEY: &str = "XAI_API_KEY";
pub const GROK_PLAN_TOKEN: &str = "CMUX_GROK_PLAN_ACCESS_TOKEN";
pub const COPILOT_TOKEN: &str = "CMUX_COPILOT_GITHUB_TOKEN";

pub const NAMES: &[&str] = &[
    CLAUDE_OAUTH,
    ANTHROPIC_KEY,
    OPENAI_KEY,
    CHATGPT_TOKEN,
    byo_endpoint::OPENAI_KEY_ENV,
    byo_endpoint::ANTHROPIC_KEY_ENV,
    GEMINI_KEY,
    VERTEX_EXPRESS_KEY,
    GROK_KEY,
    GROK_PLAN_TOKEN,
    COPILOT_TOKEN,
];

/// Set by [`apply`] on a credentialed agent's env to the name of its variable (a name, never a
/// value): what lets a daemon that adopts the agent later take that variable back ([`recovered`]),
/// and never a variable the agent merely inherited.
pub const MARKER: &str = "ACPMUX_LAUNCH_CREDENTIAL";
/// The validated endpoint metadata (no key) for restart recovery.
pub const ENDPOINT_MARKER: &str = "ACPMUX_LAUNCH_ENDPOINT";

/// What a credentialed agent never inherits: the machine's coderouter route, and every other
/// provider login or endpoint switch that would outrank the credential or send it elsewhere.
pub const UNSET: &[&str] = &[
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_CUSTOM_HEADERS",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
    "OPENAI_BASE_URL",
    "OPENAI_API_KEY",
    "CODEX_API_KEY",
    "CMUX_CODEROUTER_URL",
    "CMUX_CHATGPT_ACCESS_TOKEN",
    "CMUX_CHATGPT_ACCOUNT_ID",
    "CMUX_CODEX_AUTH",
    "OPENCODE_CONFIG_CONTENT",
    "OPENCODE_AUTH_CONTENT",
    "OPENROUTER_API_KEY",
    "COPILOT_GITHUB_TOKEN",
    "GROK_AUTH_PROVIDER_COMMAND",
    "GROK_CLI_CHAT_PROXY_BASE_URL",
    "GROK_AUTH_PATH",
    GROK_PLAN_TOKEN,
    COPILOT_TOKEN,
    crate::subscriptions::grok_hook::ROUTE,
    byo_endpoint::OPENAI_KEY_ENV,
    MARKER,
    ENDPOINT_MARKER,
];

/// The Codex provider a ChatGPT plan token runs on: the ChatGPT Codex backend
/// ([`crate::chatgpt::CODEX_BACKEND`]), with the account header.
pub const CHATGPT_PROVIDER: &str = "openai_chatgpt_plan";
/// The Codex provider an OpenAI API key runs on: the same shape on `OPENAI_API_KEY`.
pub const OPENAI_KEY_PROVIDER: &str = "openai_api_key";
/// Where the OpenAI key's provider sends.
pub const OPENAI_BASE: &str = "https://api.openai.com/v1";

/// The longest value taken (a ChatGPT JWT is a few KiB).
const MAX_VALUE_BYTES: usize = 16 * 1024;

/// The family a credential serves.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Family {
    Claude,
    Codex,
    Copilot,
    Opencode,
    Gemini,
    Grok,
}

impl Family {
    /// The family of a harness family name (`claude`, `claude-…`, `codex`, `codex-…`).
    pub fn of_harness(family: &str) -> Option<Self> {
        if family.starts_with("claude") {
            Some(Self::Claude)
        } else if family.starts_with("codex") {
            Some(Self::Codex)
        } else {
            match family {
                "github-copilot" => Some(Self::Copilot),
                "opencode" | "openrouter" => Some(Self::Opencode),
                "gemini" => Some(Self::Gemini),
                "grok" => Some(Self::Grok),
                _ => None,
            }
        }
    }
}

/// The provider endpoint metadata sent with a launch credential (Revision 3).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct LaunchEndpoint {
    pub(crate) kind: Kind,
    pub(crate) base_url: String,
    pub(crate) models: Vec<String>,
}

impl LaunchEndpoint {
    pub(crate) fn checked(kind: Kind, base_url: &str, models: &[String]) -> Option<Self> {
        if models.len() > byo_endpoint::MAX_MODELS {
            return None;
        }
        let models = byo_endpoint::check_models(models).ok()?;
        if models.iter().any(|model| {
            model == byo_endpoint::ALL_MODELS
                || model.starts_with('-')
                || byo_endpoint::looks_like_secret(model)
        }) {
            return None;
        }
        Some(Self { kind, base_url: byo_endpoint::check_cloud_base_url(base_url).ok()?, models })
    }

    pub(crate) fn harness(&self) -> &'static str {
        self.kind.harness()
    }
}

/// A launch credential: the variables one agent gets. Its `Debug` never shows a value.
#[derive(Clone, PartialEq, Eq)]
pub struct AgentCredential {
    env: BTreeMap<String, String>,
    endpoint: Option<LaunchEndpoint>,
    connection: Option<String>,
}

impl std::fmt::Debug for AgentCredential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AgentCredential")
            .field("names", &self.env.keys().collect::<Vec<_>>())
            .finish()
    }
}

impl AgentCredential {
    /// `{env: {NAME: value}}`: one name of [`NAMES`] (a Claude token or key, or a Codex key or
    /// ChatGPT token), a value of token characters only. Anything else is refused, never trimmed.
    pub fn parse(value: &Value) -> Result<Self, RpcError> {
        let refused = |why: &str| {
            RpcError::invalid_params(format!("credentials: {why}"))
                .with_data(serde_json::json!({"reason": "credentials.invalid"}))
        };
        let object = value.as_object().ok_or_else(|| refused("must be an object"))?;
        if object.keys().any(|k| !matches!(k.as_str(), "env" | "endpoint" | "connection")) {
            return Err(refused("only `env`, `endpoint` and `connection` are taken"));
        }
        let env = object
            .get("env")
            .and_then(Value::as_object)
            .ok_or_else(|| refused("`env` must be an object"))?;
        if env.len() != 1 {
            return Err(refused("`env` names exactly one variable"));
        }
        let mut out = BTreeMap::new();
        for (name, value) in env {
            if !NAMES.contains(&name.as_str()) {
                return Err(refused("a variable this launch does not take"));
            }
            let value = value.as_str().ok_or_else(|| refused("a value must be a string"))?;
            if !token_shaped(value) {
                return Err(refused("a value is not a token"));
            }
            out.insert(name.clone(), value.to_owned());
        }
        let endpoint = if let Some(endpoint) = object.get("endpoint") {
            let endpoint: LaunchEndpoint = serde_json::from_value(endpoint.clone())
                .map_err(|_| refused("invalid endpoint metadata"))?;
            let endpoint =
                LaunchEndpoint::checked(endpoint.kind, &endpoint.base_url, &endpoint.models)
                    .ok_or_else(|| refused("invalid Cloud endpoint"))?;
            let key = out
                .get(endpoint.kind.secret_key())
                .ok_or_else(|| refused("credential name does not match endpoint kind"))?;
            if endpoint.base_url.contains(key)
                || endpoint.models.iter().any(|model| model.contains(key))
            {
                return Err(refused("endpoint metadata contains the credential"));
            }
            Some(endpoint)
        } else {
            if out.contains_key(byo_endpoint::OPENAI_KEY_ENV)
                || out.contains_key(byo_endpoint::ANTHROPIC_KEY_ENV)
            {
                return Err(refused("endpoint metadata is required for this name"));
            }
            None
        };
        let connection = object
            .get("connection")
            .map(|value| {
                value
                    .as_str()
                    .filter(|id| {
                        crate::routes::is_route_id(id)
                            && !out.values().any(|secret| {
                                *id == secret.as_str()
                                    || (secret.len() >= 6 && id.contains(secret.as_str()))
                            })
                    })
                    .map(str::to_owned)
                    .ok_or_else(|| refused("invalid connection id"))
            })
            .transpose()?;
        Ok(Self { env: out, endpoint, connection })
    }

    /// The owner's connection ID for restoring a chat after its agent exits.
    pub(crate) fn connection(&self) -> Option<&str> {
        self.connection.as_deref()
    }

    pub(crate) fn keep_connection(&mut self, id: Option<&str>) {
        self.connection = id.map(str::to_owned);
    }

    /// New launches and updates take API keys and supported grants. Legacy Claude tokens can
    /// only be recovered from an existing process during migration.
    pub(crate) fn parse_delivery(value: &Value) -> Result<Self, RpcError> {
        let credential = Self::parse(value)?;
        if credential.has_legacy_claude_token() {
            return Err(RpcError::invalid_params(
                "credentials: sign in with Claude Code on this machine",
            )
            .with_data(serde_json::json!({"reason": "credentials.invalid"})));
        }
        Ok(credential)
    }

    /// The family its variable serves.
    pub fn family(&self) -> Family {
        if self.env.contains_key(GEMINI_KEY) || self.env.contains_key(VERTEX_EXPRESS_KEY) {
            Family::Gemini
        } else if self.env.contains_key(GROK_KEY) || self.env.contains_key(GROK_PLAN_TOKEN) {
            Family::Grok
        } else if self.env.contains_key(COPILOT_TOKEN) {
            Family::Copilot
        } else if self.env.contains_key(byo_endpoint::OPENAI_KEY_ENV) {
            Family::Opencode
        } else if self.env.contains_key(CLAUDE_OAUTH)
            || self.env.contains_key(ANTHROPIC_KEY)
            || self.env.contains_key(byo_endpoint::ANTHROPIC_KEY_ENV)
        {
            Family::Claude
        } else {
            Family::Codex
        }
    }

    pub(crate) fn has_legacy_claude_token(&self) -> bool {
        self.env.contains_key(CLAUDE_OAUTH)
    }

    pub(crate) fn key_provider(&self) -> Option<&'static str> {
        self.names().find_map(|variable| match variable {
            ANTHROPIC_KEY => Some("Anthropic"),
            OPENAI_KEY => Some("OpenAI"),
            GEMINI_KEY => Some("Gemini"),
            VERTEX_EXPRESS_KEY => Some("Vertex AI"),
            GROK_KEY => Some("xAI"),
            byo_endpoint::ANTHROPIC_KEY_ENV => Some("Anthropic"),
            byo_endpoint::OPENAI_KEY_ENV => Some("OpenAI-compatible"),
            _ => None,
        })
    }

    pub(crate) fn uses_anthropic_key(&self) -> bool {
        self.env.contains_key(ANTHROPIC_KEY)
    }

    pub(crate) fn has_anthropic_endpoint(&self) -> bool {
        self.endpoint.as_ref().is_some_and(|endpoint| endpoint.kind == Kind::Anthropic)
    }

    /// Verify a matching endpoint resolves to public addresses on this machine.
    pub(crate) async fn check_endpoint_destination(&self, family: &str) -> Result<(), RpcError> {
        if let Some(endpoint) = &self.endpoint
            && Family::of_harness(family) == Some(self.family())
            && !byo_endpoint::resolves_publicly(&endpoint.base_url).await
        {
            return Err(RpcError::invalid_params("the endpoint does not resolve to a public host")
                .with_data(serde_json::json!({"reason": "credentials.endpoint_unavailable"})));
        }
        Ok(())
    }

    /// A ChatGPT plan token: it expires, the Mac refreshes it, and its agent restarts on the new one.
    pub fn is_chatgpt_plan(&self) -> bool {
        self.env.contains_key(CHATGPT_TOKEN)
    }

    /// The variable names (never a value).
    pub fn names(&self) -> impl Iterator<Item = &str> {
        self.env.keys().map(String::as_str)
    }
}

/// Redact a key echoed in a line before parsing, logging or presenting it.
pub(crate) fn redact_line(line: String, key: Option<&str>) -> String {
    match key {
        Some(key) if !key.is_empty() && line.contains(key) => line.replace(key, "[redacted]"),
        _ => line,
    }
}

/// Printable ASCII token characters, non-empty and bounded: no whitespace, quote, `$` or brace, so
/// no env expansion or shell reading can change it.
pub(crate) fn token_shaped(value: &str) -> bool {
    (1..=MAX_VALUE_BYTES).contains(&value.len())
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || b"-._~+/=:".contains(&b))
}

/// The credential `session/new`'s `_meta.acpmux` carries, if any.
pub fn requested(meta: Option<&Value>) -> Result<Option<AgentCredential>, RpcError> {
    match meta.and_then(|m| m.get(FIELD)) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => AgentCredential::parse_delivery(value).map(Some),
    }
}

/// Only this machine's unix socket, and never an agent's own connection (a proven caller token),
/// sets a credential: the Web, the app's pane listener and a peer daemon never do.
pub fn admit(local_socket: bool, caller: Option<&str>) -> Result<(), RpcError> {
    if local_socket && caller.is_none() {
        return Ok(());
    }
    Err(RpcError::new(-32001, "credentials are taken only from this machine's own socket")
        .with_data(serde_json::json!({"reason": "credentials.refused"})))
}

/// Applies `credential` to the spawn of a `family` harness: the provider route and logins removed
/// (also from what it would inherit), its variable set, and Codex pointed at the direct provider.
/// A credential of another family than the harness's is not applied (false): that agent keeps
/// the machine's route.
pub fn apply(
    credential: &AgentCredential,
    family: &str,
    argv: &mut Vec<String>,
    env: &mut BTreeMap<String, String>,
) -> bool {
    let Some(harness) = Family::of_harness(family) else { return false };
    if harness != credential.family() {
        return false;
    }
    let mut unset: Vec<String> = env
        .get(crate::routes::UNSET_KEY)
        .map(|l| l.split(',').filter(|k| !k.is_empty()).map(str::to_owned).collect())
        .unwrap_or_default();
    let native = crate::provider_cloud_auth::Provider::for_family(family);
    for key in
        UNSET.iter().copied().chain(native.into_iter().flat_map(|provider| provider.direct_env()))
    {
        env.remove(key);
        if !unset.iter().any(|u| u == key) {
            unset.push(key.to_owned());
        }
    }
    env.insert(crate::routes::UNSET_KEY.to_owned(), unset.join(","));
    for (k, v) in &credential.env {
        env.insert(k.clone(), v.clone());
    }
    env.insert(MARKER.to_owned(), credential.names().collect::<Vec<_>>().join(","));
    if let Some(endpoint) = &credential.endpoint {
        if endpoint.kind == Kind::Anthropic {
            env.retain(|key, _| {
                !key.starts_with("ANTHROPIC_") || key == byo_endpoint::ANTHROPIC_KEY_ENV
            });
        }
        let endpoint_env = match endpoint.kind {
            Kind::Anthropic => byo_endpoint::claude_env(&endpoint.base_url, &endpoint.models),
            Kind::OpenAi => {
                byo_endpoint::opencode_env("Endpoint", &endpoint.base_url, &endpoint.models, true)
            }
        };
        env.extend(endpoint_env.into_iter().map(|(key, value)| (key.to_owned(), value)));
        if endpoint.kind == Kind::Anthropic {
            env.insert(ANTHROPIC_KEY.to_owned(), String::new());
            crate::claude_cloud_auth::isolate_endpoint_settings(argv);
        }
        env.insert(byo_endpoint::OWN_ENDPOINT_KEY.to_owned(), endpoint.kind.marker().to_owned());
        env.insert(ENDPOINT_MARKER.to_owned(), serde_json::json!(endpoint).to_string());
    }
    if harness == Family::Claude && credential.env.contains_key(ANTHROPIC_KEY) {
        env.insert("ANTHROPIC_BASE_URL".into(), "https://api.anthropic.com".into());
        if env.get(crate::agent::REMOTE_ENV_POLICY_KEY).map(String::as_str) != Some("1") {
            crate::claude_cloud_auth::isolate_api_key_settings(argv);
        }
    }
    if harness == Family::Gemini {
        env.extend(
            crate::provider_cloud_auth::gemini_key_env(
                credential.env.contains_key(VERTEX_EXPRESS_KEY),
            )
            .into_iter()
            .map(|(key, value)| (key.to_owned(), value.to_owned())),
        );
    }
    if harness == Family::Codex {
        if credential.is_chatgpt_plan() {
            configure_chatgpt(argv, env);
        } else {
            configure_openai_key(argv);
        }
    }
    true
}

pub(crate) fn configure_local_codex_route(
    argv: &mut Vec<String>,
    env: &mut BTreeMap<String, String>,
) {
    if env.contains_key(OPENAI_KEY)
        && env.get("OPENAI_BASE_URL").is_some_and(|base| base == OPENAI_BASE)
    {
        env.remove(CHATGPT_TOKEN);
        env.remove(CHATGPT_ACCOUNT);
        configure_openai_key(argv);
    } else if env.contains_key(CHATGPT_TOKEN) {
        configure_chatgpt(argv, env);
    }
}

fn configure_openai_key(argv: &mut Vec<String>) {
    set_codex_provider(
        argv,
        &CodexProvider {
            name: OPENAI_KEY_PROVIDER,
            base_url: OPENAI_BASE,
            env_key: OPENAI_KEY,
            account: false,
        },
    );
}

/// Configures Codex to use its ChatGPT backend. The command line contains env names only.
pub(crate) fn configure_chatgpt(argv: &mut Vec<String>, env: &mut BTreeMap<String, String>) {
    env.remove(CHATGPT_ACCOUNT);
    if let Some(account) = env.get(CHATGPT_TOKEN).and_then(|token| token_account(token)) {
        env.insert(CHATGPT_ACCOUNT.to_owned(), account);
    }
    set_codex_provider(
        argv,
        &CodexProvider {
            name: CHATGPT_PROVIDER,
            base_url: crate::chatgpt::CODEX_BACKEND,
            env_key: CHATGPT_TOKEN,
            account: true,
        },
    );
}

/// The credential an agent [`apply`] launched on, read back from its process env (`environ`: the
/// NUL-separated `NAME=value` list of `/proc/PID/environ`): the one variable [`MARKER`] names,
/// checked as [`AgentCredential::parse`] checks a sent one. None when the agent was not launched on
/// a credential, or what its env says is not one.
pub fn recovered(environ: &[u8]) -> Option<AgentCredential> {
    let vars: BTreeMap<&str, &str> = environ
        .split(|b| *b == 0)
        .filter_map(|entry| std::str::from_utf8(entry).ok()?.split_once('='))
        .collect();
    recovered_in(&vars)
}

/// [`recovered`] over an agent's env already split into `NAME` to value.
fn recovered_in(vars: &BTreeMap<&str, &str>) -> Option<AgentCredential> {
    let name = *vars.get(MARKER)?;
    if name == COPILOT_TOKEN || !NAMES.contains(&name) {
        return None;
    }
    let value = *vars.get(name)?;
    let mut wire = serde_json::json!({"env": {name: value}});
    if let Some(endpoint) = vars.get(ENDPOINT_MARKER) {
        wire["endpoint"] = serde_json::from_str(endpoint).ok()?;
    }
    AgentCredential::parse(&wire).ok()
}

/// [`recovered`] for the running process `pid` (this daemon's adopted agent), read through the
/// one-pid env reader `agent_host::tree::environ` (the env its exec was given). Linux only:
/// elsewhere (and when its env cannot be read) None.
pub fn recovered_from_pid(pid: u32) -> Option<AgentCredential> {
    #[cfg(target_os = "linux")]
    {
        let pairs = crate::agent_host::tree::environ(pid)?;
        let vars: BTreeMap<_, _> = pairs.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        recovered_in(&vars)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = pid;
        None
    }
}

/// The ChatGPT account a ChatGPT access token (a JWT) names, from its unverified claims: it only
/// picks the header the token is sent with, so the backend still checks the token itself.
fn token_account(jwt: &str) -> Option<String> {
    token_claims(jwt)?
        .pointer("/https:~1~1api.openai.com~1auth/chatgpt_account_id")
        .and_then(Value::as_str)
        .filter(|id| {
            !id.is_empty()
                && id.len() <= 128
                && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
        .map(str::to_owned)
}

/// Reads an already-running access token's deadline for restart scheduling only.
#[cfg(unix)]
pub(crate) fn chatgpt_token_expiry(jwt: &str) -> Option<i64> {
    token_claims(jwt)?.get("exp")?.as_i64()
}

fn token_claims(jwt: &str) -> Option<Value> {
    use base64::Engine as _;
    let payload = jwt.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload.trim_end_matches('='))
        .ok()?;
    serde_json::from_slice(&bytes).ok()
}

/// One custom Codex provider a credential runs on: where it sends, the variable its bearer is
/// read from, and whether it also sends the ChatGPT account ([`CHATGPT_ACCOUNT`]).
pub struct CodexProvider<'a> {
    pub name: &'a str,
    pub base_url: &'a str,
    pub env_key: &'a str,
    pub account: bool,
}

/// The `-c` overrides that select `provider` (a custom one on its `env_key`), in place of any
/// `model_provider` the argv already chose (the image's `cmux` route, an own-mode `openai`).
pub fn codex_provider_args(provider: &CodexProvider<'_>) -> Vec<String> {
    let CodexProvider { name, base_url, env_key, account } = provider;
    let table = format!("model_providers.{name}");
    let mut args = vec![
        format!("model_provider=\"{name}\""),
        format!("{table}.name=\"{name}\""),
        format!("{table}.base_url=\"{base_url}\""),
        format!("{table}.env_key=\"{env_key}\""),
    ];
    if *account {
        args.push(format!("{table}.env_http_headers.{ACCOUNT_HEADER}=\"{CHATGPT_ACCOUNT}\""));
    } else if *name == OPENAI_KEY_PROVIDER {
        for (header, variable) in
            [("OpenAI-Organization", "OPENAI_ORGANIZATION"), ("OpenAI-Project", "OPENAI_PROJECT")]
        {
            args.push(format!("{table}.env_http_headers.{header}=\"{variable}\""));
        }
    }
    args.extend([
        format!("{table}.wire_api=\"responses\""),
        format!("{table}.requires_openai_auth=false"),
        format!("{table}.supports_websockets=false"),
    ]);
    args.into_iter().flat_map(|value| ["-c".to_owned(), value]).collect()
}

fn set_codex_provider(argv: &mut Vec<String>, provider: &CodexProvider<'_>) {
    if argv.is_empty() {
        return;
    }
    // Every earlier `-c model_provider=…` (or `--config`) pair goes: the last one would win anyway,
    // and the argv then says one provider.
    let mut i = 1;
    while let Some(arg) = argv.get(i) {
        let flag = arg == "-c" || arg == "--config";
        let joined =
            arg.starts_with("--config=model_provider=") || arg.starts_with("-cmodel_provider=");
        if flag && argv.get(i + 1).is_some_and(|v| v.starts_with("model_provider=")) {
            argv.drain(i..i.saturating_add(2));
        } else if joined {
            argv.remove(i);
        } else {
            i = i.saturating_add(1);
        }
    }
    let at = codex_config_index(argv);
    for (offset, arg) in codex_provider_args(provider).into_iter().enumerate() {
        argv.insert(at + offset, arg);
    }
}

/// Where a `-c` override goes in a codex command line: right after its `app-server` word, else
/// right after the program, so it follows (and wins over) the profile's own root overrides.
/// Codex 0.160 drops every override before the subcommand once the subcommand has one of its own
/// (cmux#45774), so the launch moves every override after `app-server` before it, in order
/// (`harness_limits::codex_args`, cmux#48354): none is dropped on any codex.
pub fn codex_config_index(argv: &[String]) -> usize {
    argv.iter().skip(1).position(|a| a == "app-server").map_or(1, |i| i + 2).min(argv.len())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const CHATGPT: &str = "eyJhbGciOi.eyJzdWIiOi.c2lnbmF0dXJl";

    fn env(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
    }

    #[test]
    fn copilot_is_never_recovered_from_agent_state() {
        let marked = format!("{MARKER}={COPILOT_TOKEN}\0XDG_DATA_HOME=/tmp/fixture\0");
        assert!(recovered(marked.as_bytes()).is_none());
        let with_token = format!("{marked}{COPILOT_TOKEN}=fixture-token\0");
        assert!(recovered(with_token.as_bytes()).is_none());
    }

    #[test]
    fn endpoint_credentials_apply_after_the_route_unset_and_recover() {
        for (kind, key, harness) in [
            ("openai", byo_endpoint::OPENAI_KEY_ENV, "opencode"),
            ("anthropic", byo_endpoint::ANTHROPIC_KEY_ENV, "claude"),
        ] {
            let token = "fixture-endpoint-credential";
            let wire = json!({
                "env": {key: token},
                "endpoint": {"kind": kind, "baseUrl": "https://provider.example/v1",
                             "models": ["big", "small"]}
            });
            let credential = AgentCredential::parse(&wire).unwrap();
            let mut argv = vec![harness.to_owned()];
            let mut env = env(&[
                ("ANTHROPIC_BASE_URL", "https://old.example"),
                ("OPENAI_BASE_URL", "https://old.example"),
            ]);
            assert!(!apply(&credential, "codex", &mut argv, &mut env));
            assert!(apply(&credential, harness, &mut argv, &mut env));
            if kind == "anthropic" {
                assert_eq!(env["ANTHROPIC_BASE_URL"], "https://provider.example/v1");
                assert_eq!(env["ANTHROPIC_MODEL"], "big");
                assert_eq!(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "small");
            } else {
                let config: Value = serde_json::from_str(&env["OPENCODE_CONFIG_CONTENT"]).unwrap();
                assert_eq!(config["model"], "byo/big");
                assert_eq!(
                    config["provider"]["byo"]["options"]["apiKey"],
                    "{env:CMUX_BYO_API_KEY}"
                );
                assert!(config["provider"]["byo"]["models"].get("small").is_some());
            }
            assert_eq!(env[key], token);
            assert!(!env.contains_key("OPENAI_BASE_URL"));
            if kind == "anthropic" {
                assert_eq!(argv, [harness, "--setting-sources", ""]);
            } else {
                assert_eq!(argv, [harness]);
            }
            assert!(argv.iter().all(|word| !word.contains(token)));
            assert!(!format!("{credential:?}").contains(token));
            assert!(!format!("{credential:?}").contains("provider.example"));
            assert!(!env[ENDPOINT_MARKER].contains(token));
            let environ =
                env.iter().map(|(name, value)| format!("{name}={value}\0")).collect::<String>();
            assert_eq!(recovered(environ.as_bytes()).as_ref(), Some(&credential));
        }
    }

    #[test]
    fn endpoint_credentials_do_not_read_settings_that_can_replace_the_provider() {
        let wire = json!({"env": {byo_endpoint::ANTHROPIC_KEY_ENV: "fixture-key"},
            "endpoint":{"kind":"anthropic", "baseUrl":"https://provider.example", "models":["model-a"]}});
        let credential = AgentCredential::parse(&wire).unwrap();
        let mut argv =
            ["claude", "--setting-sources", "user,project,local", "--settings=supplied.json"]
                .into_iter()
                .map(str::to_owned)
                .collect();
        assert!(apply(&credential, "claude", &mut argv, &mut BTreeMap::new()));
        assert_eq!(argv, ["claude", "--setting-sources", ""]);
    }

    #[test]
    fn endpoint_credentials_reject_local_hosts_and_unpaired_variables() {
        for url in [
            "http://localhost:11434/v1",
            "https://localhost.",
            "https://127.1",
            "https://10.0.0.1",
            "https://192.168.1.10",
            "https://169.254.1.2",
            "https://[::1]",
            "https://[::ffff:127.0.0.1]",
            "https://[fd00::1]",
            "https://model.local",
        ] {
            let wire = json!({"env": {byo_endpoint::OPENAI_KEY_ENV: "fixture-key"},
                "endpoint":{"kind":"openai", "baseUrl":url, "models":["model-a"]}});
            assert!(AgentCredential::parse(&wire).is_err(), "{url}");
        }
        assert!(
            AgentCredential::parse(&json!({"env": {byo_endpoint::OPENAI_KEY_ENV: "fixture-key"}}))
                .is_err()
        );
        assert!(
            AgentCredential::parse(&json!({"env": {OPENAI_KEY: "fixture-key"},
            "endpoint":{"kind":"openai", "baseUrl":"https://host.example", "models":["model-a"]}}))
            .is_err()
        );
        assert!(AgentCredential::parse(&json!({"env": {byo_endpoint::OPENAI_KEY_ENV: "fixture-key"},
            "endpoint":{"kind":"openai", "baseUrl":"https://host.example", "models":["fixture-key"]}})).is_err());
    }

    #[test]
    fn native_credentials_clear_alternate_keys_and_model_routes() {
        for (harness, key, alternate_key, route) in [
            ("gemini", GEMINI_KEY, "GOOGLE_API_KEY", "GOOGLE_GEMINI_BASE_URL"),
            ("grok", GROK_KEY, "GROK_CODE_XAI_API_KEY", "GROK_MODELS_BASE_URL"),
        ] {
            let credential = AgentCredential::parse(&json!({"env": {key: "fixture-key"}})).unwrap();
            let mut argv = vec![harness.into()];
            let mut env = env(&[(alternate_key, "alternate"), (route, "https://route.example")]);
            assert!(!apply(&credential, "codex", &mut argv, &mut env));
            assert!(apply(&credential, harness, &mut argv, &mut env));
            assert_eq!(env[key], "fixture-key");
            assert!(!env.contains_key(alternate_key));
            if harness == "gemini" {
                assert_eq!(env[route], "https://generativelanguage.googleapis.com");
                for flag in ["GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_GENAI_USE_GCA"] {
                    assert_eq!(env[flag], "false");
                }
            } else {
                assert!(!env.contains_key(route));
            }
            assert!(env[crate::routes::UNSET_KEY].split(',').any(|name| name == route));
        }
    }

    #[test]
    fn only_one_known_token_shaped_variable_is_taken() {
        let ok = AgentCredential::parse(&json!({"env": {CLAUDE_OAUTH: "sk-ant-oat01-abc_DEF"}}));
        assert_eq!(ok.unwrap().family(), Family::Claude);
        for bad in [
            json!({"env": {"PATH": "/evil"}}),
            json!({"env": {CLAUDE_OAUTH: "a b"}}),
            json!({"env": {CLAUDE_OAUTH: "${env:HOME}"}}),
            json!({"env": {CLAUDE_OAUTH: ""}}),
            json!({"env": {CLAUDE_OAUTH: "x", OPENAI_KEY: "y"}}),
            json!({"env": {}}),
            json!({"env": {CLAUDE_OAUTH: "x"}, "file": "/tmp/x"}),
            json!("sk-ant-oat01"),
        ] {
            assert!(AgentCredential::parse(&bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn its_debug_names_the_variable_never_the_value() {
        let c = AgentCredential::parse(&json!({"env": {CHATGPT_TOKEN: CHATGPT}})).unwrap();
        let shown = format!("{c:?}");
        assert!(shown.contains(CHATGPT_TOKEN));
        assert!(!shown.contains(CHATGPT));
    }

    #[test]
    fn only_the_unix_socket_without_a_caller_token_sets_one() {
        assert!(admit(true, None).is_ok());
        assert!(admit(true, Some("agent-session")).is_err());
        assert!(admit(false, None).is_err());
    }

    #[test]
    fn a_claude_launch_drops_the_coderouter_route_and_takes_the_token() {
        let c =
            AgentCredential::parse(&json!({"env": {CLAUDE_OAUTH: "sk-ant-oat01-abc"}})).unwrap();
        let mut argv = vec!["claude".to_owned()];
        let mut e = env(&[
            ("ANTHROPIC_BASE_URL", "https://coderouter.cmux.internal"),
            ("ANTHROPIC_API_KEY", crate::cloud_model_plane::PLACEHOLDER),
            (crate::routes::UNSET_KEY, "FOO"),
        ]);
        assert!(apply(&c, "claude", &mut argv, &mut e));
        assert_eq!(e[CLAUDE_OAUTH], "sk-ant-oat01-abc");
        assert!(!e.contains_key("ANTHROPIC_BASE_URL"));
        assert!(!e.contains_key("ANTHROPIC_API_KEY"));
        let unset: Vec<&str> = e[crate::routes::UNSET_KEY].split(',').collect();
        assert!(unset.contains(&"FOO"));
        for key in crate::cloud_model_plane::KEYS {
            assert!(unset.contains(&key), "{key} is removed from what the agent inherits");
        }
        assert_eq!(argv, ["claude"], "Claude needs only its env");
    }

    #[test]
    fn an_anthropic_key_stays_set_though_its_name_is_on_the_unset_list() {
        let c = AgentCredential::parse(&json!({"env": {ANTHROPIC_KEY: "sk-ant-api03-x"}})).unwrap();
        let (mut argv, mut e) = (vec!["claude".to_owned()], BTreeMap::new());
        assert!(apply(&c, "claude", &mut argv, &mut e));
        // The spawn removes the unset names from the inherited env before it sets the profile's.
        assert_eq!(e[ANTHROPIC_KEY], "sk-ant-api03-x");
    }

    /// A ChatGPT access token whose claims name `account`.
    fn chatgpt_token(account: Option<&str>) -> String {
        use base64::Engine as _;
        let b64 = |v: serde_json::Value| {
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(v.to_string())
        };
        let auth = account.map_or(json!({}), |a| json!({"chatgpt_account_id": a}));
        format!(
            "{}.{}.c2lnbmF0dXJl",
            b64(json!({"alg": "RS256"})),
            b64(json!({"sub": "user-1", "https://api.openai.com/auth": auth}))
        )
    }

    /// cmux#45774: Sign in with ChatGPT's token (Codex's own OAuth client) runs on the ChatGPT
    /// Codex backend with the account it names, as Codex itself runs a ChatGPT sign-in.
    #[test]
    fn codex_on_a_chatgpt_plan_runs_the_chatgpt_codex_backend_for_the_tokens_account() {
        let token = chatgpt_token(Some("acct-1234"));
        let c = AgentCredential::parse(&json!({"env": {CHATGPT_TOKEN: token}})).unwrap();
        let mut argv: Vec<String> =
            ["codex", "-c", "model_provider=\"openai\"", "app-server"].map(str::to_owned).into();
        let mut e = env(&[
            ("OPENAI_BASE_URL", "https://coderouter.cmux.internal/v1"),
            (CHATGPT_ACCOUNT, "acct-stale"),
        ]);
        assert!(apply(&c, "codex", &mut argv, &mut e));
        assert_eq!(e[CHATGPT_TOKEN], token);
        assert_eq!(e[CHATGPT_ACCOUNT], "acct-1234");
        assert!(!e.contains_key("OPENAI_BASE_URL"));
        let joined = argv.join(" ");
        assert!(joined.contains("model_provider=\"openai_chatgpt_plan\""));
        assert!(!joined.contains("model_provider=\"openai\""), "{joined}");
        assert!(!joined.contains("api.openai.com"), "{joined}");
        for want in [
            "model_providers.openai_chatgpt_plan.base_url=\"https://chatgpt.com/backend-api/codex\"",
            "model_providers.openai_chatgpt_plan.env_key=\"CMUX_CHATGPT_ACCESS_TOKEN\"",
            "model_providers.openai_chatgpt_plan.env_http_headers.chatgpt-account-id=\"CMUX_CHATGPT_ACCOUNT_ID\"",
            "model_providers.openai_chatgpt_plan.wire_api=\"responses\"",
            "model_providers.openai_chatgpt_plan.requires_openai_auth=false",
            "model_providers.openai_chatgpt_plan.supports_websockets=false",
        ] {
            assert!(argv.iter().any(|a| a == want), "{want} in {joined}");
        }
        assert!(!joined.contains(&token), "the token is never on the command line");
        assert!(!joined.contains("tool_search"));
        assert_eq!(argv.first().map(String::as_str), Some("codex"));
        // After the subcommand, where codex keeps it beside the subcommand's own overrides.
        let sub = argv.iter().position(|a| a == "app-server").unwrap();
        let picked = argv.iter().position(|a| a == "model_provider=\"openai_chatgpt_plan\"");
        assert!(picked.unwrap() > sub, "{joined}");
        // A token that names no account sends no header, and a stale account never stays.
        let bare = AgentCredential::parse(&json!({"env": {CHATGPT_TOKEN: chatgpt_token(None)}}));
        let mut e = env(&[(CHATGPT_ACCOUNT, "acct-stale")]);
        assert!(apply(&bare.unwrap(), "codex", &mut vec!["codex".to_owned()], &mut e));
        assert!(!e.contains_key(CHATGPT_ACCOUNT));
    }

    /// cmux#45774: acpmux's codex line ends `app-server -c developer_instructions=…`, and codex
    /// drops every override before a subcommand that has its own: the provider goes after it.
    #[test]
    fn the_provider_goes_after_the_app_server_word_beside_its_own_overrides() {
        let c = AgentCredential::parse(&json!({"env": {OPENAI_KEY: "sk-proj-abc"}})).unwrap();
        let mut argv: Vec<String> = [
            "/opt/cmux/current/bin/codex",
            "-c",
            "agents.max_depth=16",
            "app-server",
            "-c",
            "model_provider=\"cmux\"",
            "-c",
            "developer_instructions=\"x\"",
        ]
        .map(str::to_owned)
        .into();
        assert!(apply(&c, "codex", &mut argv, &mut BTreeMap::new()));
        assert_eq!(
            argv[..5],
            ["/opt/cmux/current/bin/codex", "-c", "agents.max_depth=16", "app-server", "-c"]
        );
        assert_eq!(argv[5], "model_provider=\"openai_api_key\"");
        assert_eq!(argv.iter().filter(|a| a.starts_with("model_provider=")).count(), 1, "{argv:?}");
        assert_eq!(argv[argv.len() - 2..], ["-c", "developer_instructions=\"x\""]);
        // A line with no subcommand takes it right after the program.
        assert_eq!(codex_config_index(&["codex".to_owned()]), 1);
        assert_eq!(codex_config_index(&[]), 0);
    }

    #[test]
    fn codex_on_an_openai_key_reads_that_key() {
        let c = AgentCredential::parse(&json!({"env": {OPENAI_KEY: "sk-proj-abc"}})).unwrap();
        let (mut argv, mut e) =
            (vec!["codex".to_owned(), "app-server".to_owned()], BTreeMap::new());
        assert!(apply(&c, "codex", &mut argv, &mut e));
        assert_eq!(e[OPENAI_KEY], "sk-proj-abc");
        assert!(
            argv.iter().any(|a| a == "model_providers.openai_api_key.env_key=\"OPENAI_API_KEY\"")
        );
    }

    #[test]
    fn local_openai_key_route_does_not_use_codex_login() {
        let mut argv =
            ["codex", "-c", "model_provider=\"openai\"", "app-server"].map(str::to_owned).to_vec();
        let mut env = BTreeMap::from([
            ("OPENAI_BASE_URL".into(), OPENAI_BASE.into()),
            (OPENAI_KEY.into(), "fixture-key".into()),
            (CHATGPT_TOKEN.into(), "fixture-plan-token".into()),
        ]);
        configure_local_codex_route(&mut argv, &mut env);
        assert!(!env.contains_key(CHATGPT_TOKEN));
        assert!(argv.iter().any(|arg| arg == "model_provider=\"openai_api_key\""));
        assert!(
            argv.iter()
                .any(|arg| arg == "model_providers.openai_api_key.requires_openai_auth=false")
        );
        assert!(
            argv.iter()
                .any(|arg| arg == "model_providers.openai_api_key.env_key=\"OPENAI_API_KEY\"")
        );
        assert!(!argv.iter().any(|arg| arg.contains("fixture-key")));
    }

    #[test]
    fn apply_marks_the_agent_with_the_variable_name_only() {
        let c =
            AgentCredential::parse(&json!({"env": {CLAUDE_OAUTH: "sk-ant-oat01-abc"}})).unwrap();
        let (mut argv, mut e) = (vec!["claude".to_owned()], BTreeMap::new());
        assert!(apply(&c, "claude", &mut argv, &mut e));
        assert_eq!(e[MARKER], CLAUDE_OAUTH);
    }

    fn environ(pairs: &[(&str, &str)]) -> Vec<u8> {
        pairs.iter().flat_map(|(k, v)| format!("{k}={v}\0").into_bytes()).collect()
    }

    #[test]
    fn the_marked_variable_comes_back_from_the_agents_env() {
        let c =
            AgentCredential::parse(&json!({"env": {CLAUDE_OAUTH: "sk-ant-oat01-abc"}})).unwrap();
        let (mut argv, mut e) = (vec!["claude".to_owned()], env(&[("HOME", "/home/cmux")]));
        assert!(apply(&c, "claude", &mut argv, &mut e));
        let pairs: Vec<(&str, &str)> = e.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        assert_eq!(recovered(&environ(&pairs)), Some(c));
    }

    #[test]
    fn an_inherited_or_unchecked_variable_never_comes_back() {
        // A login the agent merely inherited: no marker.
        assert_eq!(recovered(&environ(&[(CLAUDE_OAUTH, "sk-ant-oat01-abc")])), None);
        // A marker naming a variable a credential never sets.
        assert_eq!(recovered(&environ(&[(MARKER, "PATH"), ("PATH", "/evil")])), None);
        // A marked value that is not a token, or no value at all.
        assert_eq!(recovered(&environ(&[(MARKER, CLAUDE_OAUTH), (CLAUDE_OAUTH, "a b")])), None);
        assert_eq!(recovered(&environ(&[(MARKER, CLAUDE_OAUTH)])), None);
        assert_eq!(recovered(b""), None);
        assert_eq!(recovered_from_pid(u32::MAX), None);
    }

    #[test]
    fn a_credential_of_another_family_is_not_applied() {
        let c =
            AgentCredential::parse(&json!({"env": {CLAUDE_OAUTH: "sk-ant-oat01-abc"}})).unwrap();
        let mut argv = vec!["codex".to_owned()];
        let mut e = env(&[("OPENAI_BASE_URL", "https://coderouter.cmux.internal/v1")]);
        assert!(!apply(&c, "codex", &mut argv, &mut e));
        assert!(!apply(&c, "opencode", &mut argv, &mut e));
        assert_eq!(e["OPENAI_BASE_URL"], "https://coderouter.cmux.internal/v1");
        assert!(!e.contains_key(CLAUDE_OAUTH));
    }
}

#[cfg(test)]
#[test]
fn delivered_claude_api_key_isolated_in_settings_and_absent_from_argv() {
    let credential = AgentCredential::parse(&serde_json::json!({
        "env": {ANTHROPIC_KEY: "fixture-secret"},
        "connection": "anthropic-personal",
    }))
    .unwrap();
    let mut argv = ["claude", "--settings", "project.json", "--setting-sources=project,user"]
        .into_iter()
        .map(ToOwned::to_owned)
        .collect();
    let mut env =
        BTreeMap::from([("ANTHROPIC_BASE_URL".to_owned(), "https://wrong.example".to_owned())]);
    assert!(apply(&credential, "claude", &mut argv, &mut env));
    assert_eq!(env["ANTHROPIC_BASE_URL"], "https://api.anthropic.com");
    assert!(env[ANTHROPIC_KEY] == "fixture-secret");
    assert_eq!(argv.iter().filter(|arg| arg.as_str() == "--settings").count(), 1);
    assert!(!argv.iter().any(|arg| arg.contains("fixture-secret") || arg.contains("project.json")));
    let settings: Value = serde_json::from_str(argv.last().unwrap()).unwrap();
    for key in crate::claude_cloud_auth::TEAM_CLEARS {
        assert_eq!(settings["env"][key], "");
    }
}

#[cfg(test)]
#[test]
fn delivered_vertex_express_key_uses_the_gemini_cli_without_project_auth() {
    let cred =
        AgentCredential::parse(&serde_json::json!({"env": {VERTEX_EXPRESS_KEY: "AQ.fixture"}}))
            .unwrap();
    let mut env = BTreeMap::from([("GOOGLE_CLOUD_PROJECT".into(), "prior-project".into())]);
    let mut argv = vec!["gemini".into(), "--acp".into()];
    assert_eq!(cred.family(), Family::Gemini);
    assert!(apply(&cred, "gemini", &mut argv, &mut env));
    assert_eq!(env["GEMINI_CLI_AUTH_OVERRIDE"], "vertex-ai");
    assert_eq!(env["GOOGLE_VERTEX_BASE_URL"], "https://aiplatform.googleapis.com");
    assert_eq!(env["GOOGLE_CLOUD_PROJECT"], "");
    assert_eq!(env["GEMINI_CLI_TRUST_WORKSPACE"], "false");
    assert!(!argv.iter().any(|arg| arg.contains("AQ.fixture")));
}
