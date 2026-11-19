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
//! file. A daemon that restarts forgets it; the agent host it hands over keeps the env it started
//! with, and the Mac's next refresh sets it again. Without one the agent keeps today's coderouter
//! route.
//!
//! At each spawn ([`apply`]) the agent gets the credential's variables and loses the machine's
//! coderouter route (`cloud_model_plane::KEYS`: base URLs, placeholder keys) and any other provider
//! login, through the route-unset list the spawn already honours (`routes::UNSET_KEY`). Codex with a
//! ChatGPT plan token runs on the OpenAI-documented custom provider (`-c` overrides, never an edit
//! of the shared `config.toml`); Codex with an OpenAI key the same shape on `OPENAI_API_KEY`; Codex
//! with the access token of the Mac's Codex CLI ChatGPT login (`codex login`, cmux#45774) the same
//! shape on the ChatGPT Codex backend Codex itself uses for that login, with the account the token
//! names (`codex_login_access.rs`): the plan route refuses such a token ("Missing scopes:
//! api.responses.write"). Claude needs only its env.

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
/// The access token of the Mac's Codex CLI ChatGPT login (serves Codex through
/// [`CODEX_LOGIN_PROVIDER`]); the account it names goes in [`CODEX_ACCOUNT`].
pub const CODEX_LOGIN_TOKEN: &str = "CMUX_CODEX_ACCESS_TOKEN";
/// The ChatGPT account a [`CODEX_LOGIN_TOKEN`] acts for, set at the spawn from the token itself
/// (never taken from the caller), and sent as `chatgpt-account-id`.
pub const CODEX_ACCOUNT: &str = "CMUX_CODEX_ACCOUNT_ID";

/// The only names a credential may set.
pub const NAMES: [&str; 5] =
    [CLAUDE_OAUTH, ANTHROPIC_KEY, OPENAI_KEY, CHATGPT_TOKEN, CODEX_LOGIN_TOKEN];

/// What a credentialed agent never inherits: the machine's coderouter route, and every other
/// provider login or endpoint switch that would outrank the credential or send it elsewhere.
pub const UNSET: [&str; 16] = [
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
    "CMUX_CODEX_AUTH",
    "CMUX_CODEX_ACCESS_TOKEN",
    "CMUX_CODEX_ACCOUNT_ID",
];

/// The Codex provider a ChatGPT plan token runs on (Revision 2's OpenAI-documented shape).
pub const CHATGPT_PROVIDER: &str = "openai_chatgpt_plan";
/// The Codex provider an OpenAI API key runs on: the same shape on `OPENAI_API_KEY`.
pub const OPENAI_KEY_PROVIDER: &str = "openai_api_key";
/// Where both of those Codex providers send.
pub const OPENAI_BASE: &str = "https://api.openai.com/v1";
/// The Codex provider a Codex CLI ChatGPT login's token runs on: the same shape on
/// [`CODEX_LOGIN_TOKEN`], to the ChatGPT Codex backend, with the account header.
pub const CODEX_LOGIN_PROVIDER: &str = "cmux_codex_login";

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
            // Its account goes with every request: a token that names none cannot be used.
            if name == CODEX_LOGIN_TOKEN && crate::codex_login_access::account_id(value).is_none() {
                return Err(refused("a Codex login token that names no ChatGPT account"));
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
    if harness == Family::Codex {
        let codex_login = credential.env.get(CODEX_LOGIN_TOKEN);
        let provider = if credential.is_chatgpt_plan() {
            CodexProvider {
                name: CHATGPT_PROVIDER,
                base_url: OPENAI_BASE,
                env_key: CHATGPT_TOKEN,
                account: false,
            }
        } else if codex_login.is_some() {
            CodexProvider {
                name: CODEX_LOGIN_PROVIDER,
                base_url: crate::codex_login_access::BASE_URL,
                env_key: CODEX_LOGIN_TOKEN,
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
        // `parse` took this token only when it names an account.
        if let Some(account) = codex_login.and_then(|t| crate::codex_login_access::account_id(t)) {
            env.insert(CODEX_ACCOUNT.to_owned(), account);
        }
        set_codex_provider(argv, &provider);
    }
    true
}

/// One custom Codex provider a credential runs on: where it sends, the variable its bearer is
/// read from, and whether it also sends the ChatGPT account ([`CODEX_ACCOUNT`]).
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
        let header = crate::codex_login_access::ACCOUNT_HEADER;
        args.push(format!("{table}.env_http_headers.{header}=\"{CODEX_ACCOUNT}\""));
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
    for (offset, arg) in codex_provider_args(provider).into_iter().enumerate() {
        argv.insert(1 + offset, arg);
    }
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

    #[test]
    fn codex_on_a_chatgpt_plan_runs_the_documented_provider() {
        let c = AgentCredential::parse(&json!({"env": {CHATGPT_TOKEN: CHATGPT}})).unwrap();
        let mut argv: Vec<String> =
            ["codex", "-c", "model_provider=\"openai\"", "app-server"].map(str::to_owned).into();
        let mut e = env(&[("OPENAI_BASE_URL", "https://coderouter.cmux.internal/v1")]);
        assert!(apply(&c, "codex", &mut argv, &mut e));
        assert_eq!(e[CHATGPT_TOKEN], CHATGPT);
        assert!(!e.contains_key("OPENAI_BASE_URL"));
        let joined = argv.join(" ");
        assert!(joined.contains("model_provider=\"openai_chatgpt_plan\""));
        assert!(!joined.contains("model_provider=\"openai\""), "{joined}");
        for want in [
            "model_providers.openai_chatgpt_plan.base_url=\"https://api.openai.com/v1\"",
            "model_providers.openai_chatgpt_plan.env_key=\"CMUX_CHATGPT_ACCESS_TOKEN\"",
            "model_providers.openai_chatgpt_plan.wire_api=\"responses\"",
            "model_providers.openai_chatgpt_plan.requires_openai_auth=false",
            "model_providers.openai_chatgpt_plan.supports_websockets=false",
        ] {
            assert!(argv.iter().any(|a| a == want), "{want} in {joined}");
        }
        assert!(!joined.contains(CHATGPT), "the token is never on the command line");
        assert!(!joined.contains("tool_search"));
        assert_eq!(argv.first().map(String::as_str), Some("codex"));
        assert_eq!(argv.last().map(String::as_str), Some("app-server"));
    }

    /// A Codex access token naming `account` (its `https://api.openai.com/auth` claim), unsigned.
    fn codex_cli_token(account: Option<&str>) -> String {
        use base64::Engine as _;
        let b64 = |v: &Value| {
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(v.to_string().as_bytes())
        };
        let mut claims = json!({"exp": 4_102_444_800_i64});
        if let Some(account) = account {
            claims["https://api.openai.com/auth"] = json!({"chatgpt_account_id": account});
        }
        format!("{}.{}.c2ln", b64(&json!({"alg": "RS256"})), b64(&claims))
    }

    /// cmux#45774: a Codex CLI ChatGPT login (the Mac's `codex login`) runs on the ChatGPT Codex
    /// backend with its token and the account the token names, never on the plan route
    /// (`api.openai.com/v1`), which refuses a Codex CLI token ("Missing scopes: api.responses.write").
    #[test]
    fn codex_on_its_cli_login_runs_the_chatgpt_codex_backend_for_the_tokens_account() {
        const NAME: &str = "CMUX_CODEX_ACCESS_TOKEN";
        let token = codex_cli_token(Some("acct-1234"));
        let c = AgentCredential::parse(&json!({"env": {NAME: token}})).unwrap();
        assert_eq!(c.family(), Family::Codex);
        let mut argv: Vec<String> =
            ["codex", "-c", "model_provider=\"cmux\"", "app-server"].map(str::to_owned).into();
        let mut e = env(&[
            ("OPENAI_BASE_URL", "https://coderouter.cmux.internal/v1"),
            ("OPENAI_API_KEY", crate::codex_cloud_auth::PLACEHOLDER_KEY),
        ]);
        assert!(apply(&c, "codex", &mut argv, &mut e));
        assert_eq!(e[NAME], token);
        assert_eq!(e["CMUX_CODEX_ACCOUNT_ID"], "acct-1234");
        assert!(!e.contains_key("OPENAI_BASE_URL"));
        assert!(!e.contains_key("OPENAI_API_KEY"));
        let joined = argv.join(" ");
        assert!(!joined.contains("model_provider=\"cmux\""), "{joined}");
        assert!(!joined.contains("api.openai.com"), "{joined}");
        for want in [
            "model_provider=\"cmux_codex_login\"",
            "model_providers.cmux_codex_login.base_url=\"https://chatgpt.com/backend-api/codex\"",
            "model_providers.cmux_codex_login.env_key=\"CMUX_CODEX_ACCESS_TOKEN\"",
            "model_providers.cmux_codex_login.env_http_headers.chatgpt-account-id=\"CMUX_CODEX_ACCOUNT_ID\"",
            "model_providers.cmux_codex_login.wire_api=\"responses\"",
            "model_providers.cmux_codex_login.requires_openai_auth=false",
            "model_providers.cmux_codex_login.supports_websockets=false",
        ] {
            assert!(argv.iter().any(|a| a == want), "{want} in {joined}");
        }
        assert!(!joined.contains(&token), "the token is never on the command line");
        assert_eq!(argv.last().map(String::as_str), Some("app-server"));
        // A token that names no account cannot be sent with one: refused, never applied without it.
        let bare = codex_cli_token(None);
        assert!(AgentCredential::parse(&json!({"env": {NAME: bare}})).is_err());
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
