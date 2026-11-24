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

use crate::rpc::RpcError;
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
pub const NAMES: [&str; 4] = [CLAUDE_OAUTH, ANTHROPIC_KEY, OPENAI_KEY, CHATGPT_TOKEN];

/// Set by [`apply`] on a credentialed agent's env to the name of its variable (a name, never a
/// value): what lets a daemon that adopts the agent later take that variable back ([`recovered`]),
/// and never a variable the agent merely inherited.
pub const MARKER: &str = "ACPMUX_LAUNCH_CREDENTIAL";

/// What a credentialed agent never inherits: the machine's coderouter route, and every other
/// provider login or endpoint switch that would outrank the credential or send it elsewhere.
pub const UNSET: [&str; 15] = [
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
}

impl Family {
    /// The family of a harness family name (`claude`, `claude-…`, `codex`, `codex-…`).
    pub fn of_harness(family: &str) -> Option<Self> {
        if family.starts_with("claude") {
            Some(Self::Claude)
        } else if family.starts_with("codex") {
            Some(Self::Codex)
        } else {
            None
        }
    }
}

/// A launch credential: the variables one agent gets. Its `Debug` never shows a value.
#[derive(Clone, PartialEq, Eq)]
pub struct AgentCredential {
    env: BTreeMap<String, String>,
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
        if object.keys().any(|k| k != "env") {
            return Err(refused("only `env` is taken"));
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
        Ok(Self { env: out })
    }

    /// The family its variable serves.
    pub fn family(&self) -> Family {
        if self.env.contains_key(CLAUDE_OAUTH) || self.env.contains_key(ANTHROPIC_KEY) {
            Family::Claude
        } else {
            Family::Codex
        }
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

/// Printable ASCII token characters, non-empty and bounded: no whitespace, quote, `$` or brace, so
/// no env expansion or shell reading can change it.
fn token_shaped(value: &str) -> bool {
    (1..=MAX_VALUE_BYTES).contains(&value.len())
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || b"-._~+/=:".contains(&b))
}

/// The credential `session/new`'s `_meta.acpmux` carries, if any.
pub fn requested(meta: Option<&Value>) -> Result<Option<AgentCredential>, RpcError> {
    match meta.and_then(|m| m.get(FIELD)) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => AgentCredential::parse(value).map(Some),
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
    for key in UNSET {
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
    if harness == Family::Codex {
        let provider = if credential.is_chatgpt_plan() {
            // The backend acts for the account the token names; a token that names none sends
            // no header (Codex skips a header whose variable is unset).
            if let Some(account) = credential.env.get(CHATGPT_TOKEN).and_then(|t| token_account(t))
            {
                env.insert(CHATGPT_ACCOUNT.to_owned(), account);
            }
            CodexProvider {
                name: CHATGPT_PROVIDER,
                base_url: crate::chatgpt::CODEX_BACKEND,
                env_key: CHATGPT_TOKEN,
                account: true,
            }
        } else {
            CodexProvider {
                name: OPENAI_KEY_PROVIDER,
                base_url: OPENAI_BASE,
                env_key: OPENAI_KEY,
                account: false,
            }
        };
        set_codex_provider(argv, &provider);
    }
    true
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
    if !NAMES.contains(&name) {
        return None;
    }
    let value = *vars.get(name)?;
    AgentCredential::parse(&serde_json::json!({"env": {name: value}})).ok()
}

/// [`recovered`] for the running process `pid` (this daemon's adopted agent), read through the
/// one-pid env reader `agent_host::tree::environ` (the env its exec was given). Linux only:
/// elsewhere (and when its env cannot be read) None.
pub fn recovered_from_pid(pid: u32) -> Option<AgentCredential> {
    #[cfg(target_os = "linux")]
    {
        let pairs = crate::agent_host::tree::environ(pid)?;
        let vars = pairs.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
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
    use base64::Engine as _;
    let payload = jwt.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload.trim_end_matches('='))
        .ok()?;
    let claims: Value = serde_json::from_slice(&bytes).ok()?;
    claims
        .pointer("/https:~1~1api.openai.com~1auth/chatgpt_account_id")
        .and_then(Value::as_str)
        .filter(|id| {
            !id.is_empty()
                && id.len() <= 128
                && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
        .map(str::to_owned)
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
#[path = "agent_credentials_tests.rs"]
mod tests;
