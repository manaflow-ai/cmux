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

/// The only names a Revision 2 credential may set (one of them).
pub const NAMES: [&str; 4] = [CLAUDE_OAUTH, ANTHROPIC_KEY, OPENAI_KEY, CHATGPT_TOKEN];

/// A provider credential (Revision 3, `crate::providers::wire`): the key, its provider and the
/// endpoints it goes to, every one checked here again; the agent's own variables are made from
/// them at the spawn ([`apply`]).
use crate::providers::wire as provider_wire;

/// Set by [`apply`] on a credentialed agent's env to the name of its variable (a name, never a
/// value): what lets a daemon that adopts the agent later take that variable back ([`recovered`]),
/// and never a variable the agent merely inherited.
pub const MARKER: &str = "ACPMUX_LAUNCH_CREDENTIAL";

/// What a credentialed agent never inherits: the machine's coderouter route, and every other
/// provider login or endpoint switch that would outrank the credential or send it elsewhere.
pub const UNSET: [&str; 24] = [
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
    "AWS_BEARER_TOKEN_BEDROCK",
    "CMUX_PROVIDER_API_KEY",
    "CMUX_PROVIDER_ID",
    "CMUX_PROVIDER_ANTHROPIC_URL",
    "CMUX_PROVIDER_ANTHROPIC_AUTH",
    "CMUX_PROVIDER_RESPONSES_URL",
    "CMUX_PROVIDER_REGION",
    "CMUX_OPENCODE_AUTH",
    "ANTHROPIC_BEDROCK_BASE_URL",
];

/// What a Bedrock credential's agent also never inherits: AWS credentials the image may carry
/// would outrank the Bedrock key (cmux#48428). Every other agent keeps them, so `aws` still works
/// from its shell.
pub const UNSET_FOR_BEDROCK: [&str; 5] = [
    "AWS_PROFILE",
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "AWS_REGION",
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

/// The Codex provider a provider credential's Responses endpoint runs on.
pub const PROVIDER_CODEX: &str = "cmux_provider";

/// The family a credential serves.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Family {
    Claude,
    Codex,
    OpenCode,
}

impl Family {
    /// The family of a harness family name (`claude`, `claude-…`, `codex`, `codex-…`,
    /// `opencode`, `opencode2`).
    pub fn of_harness(family: &str) -> Option<Self> {
        if family.starts_with("claude") {
            Some(Self::Claude)
        } else if family.starts_with("codex") {
            Some(Self::Codex)
        } else if family.starts_with("opencode") {
            Some(Self::OpenCode)
        } else {
            None
        }
    }

    /// The image launcher's own-or-team switch for this agent (`CMUX_<AGENT>_AUTH`).
    fn auth_switch(self) -> &'static str {
        match self {
            Self::Claude => "CMUX_CLAUDE_AUTH",
            Self::Codex => "CMUX_CODEX_AUTH",
            Self::OpenCode => "CMUX_OPENCODE_AUTH",
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
        if env.contains_key(provider_wire::KEY) {
            return Self::parse_provider(env).map_err(refused);
        }
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

    /// A provider credential: the names of [`provider_wire::NAMES`] only, the key and a provider
    /// this machine's catalog knows, token-shaped values, `https://` endpoints and a region and
    /// auth it can read, and at least one way to an agent.
    fn parse_provider(env: &serde_json::Map<String, Value>) -> Result<Self, &'static str> {
        let mut out = BTreeMap::new();
        for (name, value) in env {
            if !provider_wire::NAMES.contains(&name.as_str()) {
                return Err("a variable this launch does not take");
            }
            let value = value.as_str().ok_or("a value must be a string")?;
            if !token_shaped(value) {
                return Err("a value is not a token");
            }
            out.insert(name.clone(), value.to_owned());
        }
        let id = out.get(provider_wire::ID).ok_or("a provider credential names its provider")?;
        if crate::providers::find(id).is_none() {
            return Err("a provider this machine does not know");
        }
        for url in [provider_wire::ANTHROPIC_URL, provider_wire::RESPONSES_URL] {
            if let Some(v) = out.get(url)
                && crate::providers::check_base_url(v).as_deref() != Ok(v.as_str())
            {
                return Err("an endpoint is not an https URL");
            }
        }
        if let Some(v) = out.get(provider_wire::REGION)
            && crate::providers::check_region(v).is_err()
        {
            return Err("a region is not an AWS region");
        }
        let credential = Self { env: out };
        match credential.anthropic_auth() {
            Some(Err(())) => return Err("an Anthropic auth this machine does not know"),
            Some(Ok(crate::providers::AnthropicAuth::Bedrock))
                if !credential.env.contains_key(provider_wire::REGION) =>
            {
                return Err("Bedrock needs its region");
            }
            Some(Ok(a))
                if a != crate::providers::AnthropicAuth::Bedrock
                    && !credential.env.contains_key(provider_wire::ANTHROPIC_URL) =>
            {
                return Err("an Anthropic auth needs its endpoint");
            }
            _ => {}
        }
        if ![Family::Claude, Family::Codex, Family::OpenCode].iter().any(|f| credential.serves(*f))
        {
            return Err("a provider credential that reaches no agent");
        }
        Ok(credential)
    }

    fn provider(&self) -> Option<&str> {
        self.env.get(provider_wire::ID).map(String::as_str)
    }

    /// Whether it is an Amazon Bedrock key, whose agent must not inherit AWS credentials.
    fn is_bedrock(&self) -> bool {
        self.provider() == Some("bedrock")
            || matches!(self.anthropic_auth(), Some(Ok(crate::providers::AnthropicAuth::Bedrock)))
    }

    fn anthropic_auth(&self) -> Option<Result<crate::providers::AnthropicAuth, ()>> {
        self.env
            .get(provider_wire::ANTHROPIC_AUTH)
            .map(|a| crate::providers::AnthropicAuth::parse(a).ok_or(()))
    }

    /// Whether it serves a `family` agent: a Revision 2 credential its own agent (and OpenCode an
    /// Anthropic or OpenAI key, which OpenCode reads as they are); a provider credential each agent
    /// its endpoints reach.
    pub fn serves(&self, family: Family) -> bool {
        if let Some(id) = self.provider() {
            return match family {
                Family::Claude => matches!(self.anthropic_auth(), Some(Ok(_))),
                Family::Codex => self.env.contains_key(provider_wire::RESPONSES_URL),
                Family::OpenCode => crate::providers::opencode_env(id).is_some(),
            };
        }
        let has = |name: &str| self.env.contains_key(name);
        match family {
            Family::Claude => has(CLAUDE_OAUTH) || has(ANTHROPIC_KEY),
            Family::Codex => has(OPENAI_KEY) || has(CHATGPT_TOKEN),
            Family::OpenCode => has(ANTHROPIC_KEY) || has(OPENAI_KEY),
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
    if !credential.serves(harness) {
        return false;
    }
    let mut unset: Vec<String> = env
        .get(crate::routes::UNSET_KEY)
        .map(|l| l.split(',').filter(|k| !k.is_empty()).map(str::to_owned).collect())
        .unwrap_or_default();
    // Every variable OpenCode reads a catalog provider's key from goes too: an inherited one
    // would pick another provider than the delivered key's.
    let opencode = crate::providers::PROVIDERS.iter().filter_map(|p| p.opencode.map(|o| o.env));
    let bedrock = if credential.is_bedrock() { &UNSET_FOR_BEDROCK[..] } else { &[] };
    for key in UNSET.into_iter().chain(opencode).chain(bedrock.iter().copied()) {
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
    if credential.provider().is_some() {
        apply_provider(credential, harness, argv, env);
        return true;
    }
    if harness == Family::OpenCode {
        // OpenCode reads an Anthropic or OpenAI key as it is; the launcher keeps its own mode.
        env.insert(harness.auth_switch().to_owned(), "own".to_owned());
        return true;
    }
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

/// A provider credential's agent variables (Revision 3): Claude Code on its Anthropic endpoint (or
/// its Bedrock mode), Codex on a custom provider to its Responses endpoint reading
/// [`provider_wire::KEY`], OpenCode with the key in its provider's own variable (from this
/// machine's catalog, never a name the wire gave). The image launcher is pinned to the agent's own
/// sign-in mode, so it never layers the CodeRouter route over it.
fn apply_provider(
    credential: &AgentCredential,
    harness: Family,
    argv: &mut Vec<String>,
    env: &mut BTreeMap<String, String>,
) {
    let get = |name: &str| credential.env.get(name).cloned().unwrap_or_default();
    let key = get(provider_wire::KEY);
    env.insert(harness.auth_switch().to_owned(), "own".to_owned());
    match harness {
        Family::Claude => match credential.anthropic_auth() {
            Some(Ok(crate::providers::AnthropicAuth::Bedrock)) => {
                env.insert("CLAUDE_CODE_USE_BEDROCK".to_owned(), "1".to_owned());
                env.insert("AWS_BEARER_TOKEN_BEDROCK".to_owned(), key);
                env.insert("AWS_REGION".to_owned(), get(provider_wire::REGION));
            }
            Some(Ok(auth)) => {
                env.insert("ANTHROPIC_BASE_URL".to_owned(), get(provider_wire::ANTHROPIC_URL));
                let var = match auth {
                    crate::providers::AnthropicAuth::XApiKey => ANTHROPIC_KEY,
                    _ => "ANTHROPIC_AUTH_TOKEN",
                };
                env.insert(var.to_owned(), key);
            }
            _ => {}
        },
        Family::Codex => {
            let base = get(provider_wire::RESPONSES_URL);
            set_codex_provider(
                argv,
                &CodexProvider {
                    name: PROVIDER_CODEX,
                    base_url: &base,
                    env_key: provider_wire::KEY,
                    account: false,
                },
            );
        }
        Family::OpenCode => {
            if let Some(oc) = credential.provider().and_then(crate::providers::opencode_env) {
                env.insert(oc.env.to_owned(), key);
                if let Some(region) = credential.env.get(provider_wire::REGION) {
                    env.insert("AWS_REGION".to_owned(), region.clone());
                }
            }
        }
    }
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
    let mut env = serde_json::Map::new();
    for name in vars.get(MARKER)?.split(',') {
        if !NAMES.contains(&name) && !provider_wire::NAMES.contains(&name) {
            return None;
        }
        env.insert(name.to_owned(), Value::String((*vars.get(name)?).to_owned()));
    }
    AgentCredential::parse(&serde_json::json!({ "env": env })).ok()
}

/// The launch credential's variables in the env an agent was started with ([`MARKER`] and the
/// variable it names), which its agent host keeps and says to a daemon that adopts it
/// (`agent_host::LaunchCredential`). Empty when it was not launched on one.
pub fn launched_with(env: &[(String, String)]) -> Vec<(String, String)> {
    let vars: BTreeMap<&str, &str> = env.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    let Some(credential) = recovered_in(&vars) else { return Vec::new() };
    let mut out = vec![(MARKER.to_owned(), credential.names().collect::<Vec<_>>().join(","))];
    out.extend(credential.env);
    out
}

/// [`recovered`] over the variables an agent host said ([`launched_with`]).
pub fn recovered_from_launch(env: &[(String, String)]) -> Option<AgentCredential> {
    recovered_in(&env.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect())
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
mod tests {
    use super::*;
    use serde_json::json;

    const CHATGPT: &str = "eyJhbGciOi.eyJzdWIiOi.c2lnbmF0dXJl";

    fn env(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
    }

    #[test]
    fn only_one_known_token_shaped_variable_is_taken() {
        let ok = AgentCredential::parse(&json!({"env": {CLAUDE_OAUTH: "sk-ant-oat01-abc_DEF"}}));
        let ok = ok.unwrap();
        assert!(ok.serves(Family::Claude) && !ok.serves(Family::Codex));
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
    fn the_host_says_only_the_launch_credential_and_never_shows_its_value() {
        let c =
            AgentCredential::parse(&json!({"env": {CLAUDE_OAUTH: "sk-ant-oat01-abc"}})).unwrap();
        let (mut argv, mut e) = (vec!["claude".to_owned()], env(&[("HOME", "/home/cmux")]));
        assert!(apply(&c, "claude", &mut argv, &mut e));
        let spec_env: Vec<(String, String)> = e.into_iter().collect();
        let said = launched_with(&spec_env);
        assert!(said.iter().all(|(k, _)| k != "HOME"), "only the credential's variables: {said:?}");
        assert_eq!(recovered_from_launch(&said), Some(c));
        let shown = format!("{:?}", crate::agent_host::LaunchCredential(said));
        assert!(!shown.contains("sk-ant-oat01-abc"), "{shown}");
        assert!(launched_with(&[("HOME".into(), "/h".into())]).is_empty());
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

    fn provider(pairs: &[(&str, &str)]) -> Result<AgentCredential, RpcError> {
        let env: serde_json::Map<String, Value> =
            pairs.iter().map(|(k, v)| ((*k).to_owned(), json!(v))).collect();
        AgentCredential::parse(&json!({ "env": env }))
    }

    const OPENROUTER: &[(&str, &str)] = &[
        ("CMUX_PROVIDER_API_KEY", "sk-or-v1-abc"),
        ("CMUX_PROVIDER_ID", "openrouter"),
        ("CMUX_PROVIDER_ANTHROPIC_URL", "https://openrouter.ai/api"),
        ("CMUX_PROVIDER_ANTHROPIC_AUTH", "bearer"),
        ("CMUX_PROVIDER_RESPONSES_URL", "https://openrouter.ai/api/v1"),
    ];

    /// cmux#48428: a provider key reaches each agent its endpoints serve, in that agent's own
    /// variables, with the image launcher pinned to its own mode.
    #[test]
    fn a_provider_key_runs_claude_codex_and_opencode_on_its_own_endpoints() {
        let c = provider(OPENROUTER).unwrap();
        let mut e = env(&[
            ("ANTHROPIC_BASE_URL", "https://coderouter.cmux.internal"),
            ("ANTHROPIC_API_KEY", crate::cloud_model_plane::PLACEHOLDER),
        ]);
        assert!(apply(&c, "claude", &mut vec!["claude".to_owned()], &mut e));
        assert_eq!(e["ANTHROPIC_BASE_URL"], "https://openrouter.ai/api");
        assert_eq!(e["ANTHROPIC_AUTH_TOKEN"], "sk-or-v1-abc");
        assert!(!e.contains_key("ANTHROPIC_API_KEY"), "a bearer endpoint gets no x-api-key");
        assert_eq!(e["CMUX_CLAUDE_AUTH"], "own");

        let mut argv: Vec<String> = ["codex", "app-server"].map(str::to_owned).into();
        let mut e = BTreeMap::new();
        assert!(apply(&c, "codex", &mut argv, &mut e));
        let joined = argv.join(" ");
        assert!(joined.contains("model_provider=\"cmux_provider\""), "{joined}");
        assert!(
            joined.contains(
                "model_providers.cmux_provider.base_url=\"https://openrouter.ai/api/v1\""
            )
        );
        assert!(joined.contains("model_providers.cmux_provider.env_key=\"CMUX_PROVIDER_API_KEY\""));
        assert!(!joined.contains("sk-or-v1-abc"), "the key is never on the command line");
        assert_eq!(e["CMUX_CODEX_AUTH"], "own");

        let mut e = BTreeMap::new();
        assert!(apply(&c, "opencode", &mut vec!["opencode".to_owned()], &mut e));
        assert_eq!(e["OPENROUTER_API_KEY"], "sk-or-v1-abc");
        assert_eq!(e["CMUX_OPENCODE_AUTH"], "own");

        // An x-api-key endpoint and Bedrock's own mode.
        let kimi = provider(&[
            ("CMUX_PROVIDER_API_KEY", "sk-kimi-1"),
            ("CMUX_PROVIDER_ID", "kimi-code"),
            ("CMUX_PROVIDER_ANTHROPIC_URL", "https://api.kimi.com/coding"),
            ("CMUX_PROVIDER_ANTHROPIC_AUTH", "x-api-key"),
        ])
        .unwrap();
        let mut e = BTreeMap::new();
        assert!(apply(&kimi, "claude", &mut vec!["claude".to_owned()], &mut e));
        assert_eq!(e[ANTHROPIC_KEY], "sk-kimi-1");
        assert!(!apply(&kimi, "codex", &mut vec!["codex".to_owned()], &mut BTreeMap::new()));
        let bedrock = provider(&[
            ("CMUX_PROVIDER_API_KEY", "ABSKbedrock"),
            ("CMUX_PROVIDER_ID", "bedrock"),
            ("CMUX_PROVIDER_ANTHROPIC_AUTH", "bedrock"),
            ("CMUX_PROVIDER_REGION", "us-west-2"),
        ])
        .unwrap();
        let mut e = BTreeMap::new();
        assert!(apply(&bedrock, "claude", &mut vec!["claude".to_owned()], &mut e));
        assert_eq!(e["CLAUDE_CODE_USE_BEDROCK"], "1");
        assert_eq!(e["AWS_BEARER_TOKEN_BEDROCK"], "ABSKbedrock");
        assert_eq!(e["AWS_REGION"], "us-west-2");
        assert!(!e.contains_key("ANTHROPIC_BASE_URL"));
    }

    /// cmux#48428 review: only a Bedrock key clears the AWS credentials the agent inherited; an
    /// OpenRouter key or a Claude token leaves them, so `aws` still works from the agent's shell.
    #[test]
    fn only_a_bedrock_key_clears_inherited_aws_credentials() {
        let aws = [
            ("AWS_PROFILE", "work"),
            ("AWS_ACCESS_KEY_ID", "AKIAX"),
            ("AWS_SECRET_ACCESS_KEY", "s"),
            ("AWS_SESSION_TOKEN", "t"),
            ("AWS_REGION", "eu-west-1"),
        ];
        let unset_list = |e: &BTreeMap<String, String>| e[crate::routes::UNSET_KEY].clone();

        let openrouter = provider(OPENROUTER).unwrap();
        let token =
            AgentCredential::parse(&json!({"env": {CLAUDE_OAUTH: "sk-ant-oat01-abc"}})).unwrap();
        for (c, family) in [(&openrouter, "opencode"), (&openrouter, "claude"), (&token, "claude")]
        {
            let mut e = env(&aws);
            assert!(apply(c, family, &mut vec![family.to_owned()], &mut e));
            for (k, v) in aws {
                assert_eq!(e.get(k).map(String::as_str), Some(v), "{family} keeps {k}");
                assert!(!unset_list(&e).split(',').any(|u| u == k), "{family} unsets {k}");
            }
        }

        let bedrock = provider(&[
            ("CMUX_PROVIDER_API_KEY", "ABSKbedrock"),
            ("CMUX_PROVIDER_ID", "bedrock"),
            ("CMUX_PROVIDER_ANTHROPIC_AUTH", "bedrock"),
            ("CMUX_PROVIDER_REGION", "us-west-2"),
        ])
        .unwrap();
        let mut e = env(&aws);
        assert!(apply(&bedrock, "claude", &mut vec!["claude".to_owned()], &mut e));
        for k in ["AWS_PROFILE", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"]
        {
            assert!(!e.contains_key(k), "Bedrock drops {k}");
            assert!(unset_list(&e).split(',').any(|u| u == k), "Bedrock unsets {k}");
        }
        assert_eq!(e["AWS_REGION"], "us-west-2", "the key's own region replaces the inherited one");
    }

    #[test]
    fn a_provider_credential_takes_only_checked_names_endpoints_and_providers() {
        let with = |name: &str, value: &str| {
            let mut pairs: Vec<(&str, &str)> =
                OPENROUTER.iter().copied().filter(|(k, _)| *k != name).collect();
            pairs.push((name, value));
            provider(&pairs)
        };
        for (name, value) in [
            ("CMUX_PROVIDER_ID", "made-up"),
            ("CMUX_PROVIDER_ANTHROPIC_URL", "http://openrouter.ai/api"),
            ("CMUX_PROVIDER_RESPONSES_URL", "https://x.example/v1?k=1"),
            ("CMUX_PROVIDER_ANTHROPIC_AUTH", "basic"),
            ("CMUX_PROVIDER_REGION", "nowhere"),
            ("LD_PRELOAD", "/tmp/x.so"),
            ("CMUX_PROVIDER_API_KEY", "a b"),
        ] {
            assert!(with(name, value).is_err(), "{name}={value}");
        }
        // Bedrock without its region, an auth without its endpoint, nothing an agent can use.
        assert!(
            provider(&[
                ("CMUX_PROVIDER_API_KEY", "k"),
                ("CMUX_PROVIDER_ID", "bedrock"),
                ("CMUX_PROVIDER_ANTHROPIC_AUTH", "bedrock")
            ])
            .is_err()
        );
        assert!(
            provider(&[
                ("CMUX_PROVIDER_API_KEY", "k"),
                ("CMUX_PROVIDER_ID", "glm"),
                ("CMUX_PROVIDER_ANTHROPIC_AUTH", "bearer")
            ])
            .is_err()
        );
        assert!(
            provider(&[("CMUX_PROVIDER_API_KEY", "k"), ("CMUX_PROVIDER_ID", "custom")]).is_err()
        );
        // A provider OpenCode reads from its own variable serves OpenCode alone.
        let google =
            provider(&[("CMUX_PROVIDER_API_KEY", "AIza1"), ("CMUX_PROVIDER_ID", "google")])
                .unwrap();
        assert!(google.serves(Family::OpenCode));
        assert!(!google.serves(Family::Claude) && !google.serves(Family::Codex));
    }

    #[test]
    fn a_provider_credential_comes_back_whole_from_the_agents_env() {
        let c = provider(OPENROUTER).unwrap();
        let (mut argv, mut e) = (vec!["claude".to_owned()], env(&[("HOME", "/home/cmux")]));
        assert!(apply(&c, "claude", &mut argv, &mut e));
        let pairs: Vec<(&str, &str)> = e.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        assert_eq!(recovered(&environ(&pairs)), Some(c));
        // A marker naming a variable outside both sets brings back nothing.
        let bad = environ(&[
            (MARKER, "CMUX_PROVIDER_API_KEY,PATH"),
            ("CMUX_PROVIDER_API_KEY", "k"),
            ("PATH", "/x"),
        ]);
        assert_eq!(recovered(&bad), None);
    }

    #[test]
    fn opencode_runs_on_an_anthropic_or_openai_key_as_it_is() {
        let c = AgentCredential::parse(&json!({"env": {OPENAI_KEY: "sk-proj-abc"}})).unwrap();
        let mut e = BTreeMap::new();
        assert!(apply(&c, "opencode", &mut vec!["opencode".to_owned()], &mut e));
        assert_eq!(e[OPENAI_KEY], "sk-proj-abc");
        assert_eq!(e["CMUX_OPENCODE_AUTH"], "own");
    }
}
