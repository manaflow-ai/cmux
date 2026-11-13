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
//! file. The meta keeps only its [`CredentialRef`] (the connection's id, the token's expiry and
//! whether it is a ChatGPT plan's; no value), so a daemon that restarted knows the chat ran on the
//! owner's credential: it does not start that agent on the coderouter route instead, but says the
//! chat needs the owner's Mac ([`blocked`]) until the Mac sends the credential again
//! (`agent/credentials.list` names those chats). A ChatGPT token past its expiry says the same.
//! A session that never had one keeps today's coderouter route.
//!
//! At each spawn ([`apply`]) the agent gets the credential's variables and loses the machine's
//! coderouter route (`cloud_model_plane::KEYS`: base URLs, placeholder keys) and any other provider
//! login, through the route-unset list the spawn already honours (`routes::UNSET_KEY`). Codex with a
//! ChatGPT plan token runs on the OpenAI-documented custom provider (`-c` overrides, never an edit
//! of the shared `config.toml`); Codex with an OpenAI key the same shape on `OPENAI_API_KEY`. Claude
//! needs only its env.
//!
//! Tool processes never see the credential: Claude Code runs with
//! `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` (it strips credentials from the env of its Bash commands,
//! hooks and MCP servers and keeps them for its own API calls), and Codex with
//! `shell_environment_policy.exclude` naming the credential variables (its shell tool's env).

use crate::rpc::RpcError;
use serde_json::Value;
use std::collections::BTreeMap;

/// The `_meta.acpmux` field of `session/new` that carries the launch credential.
pub const FIELD: &str = "credentials";
/// The method that replaces a session's credential (a refreshed ChatGPT token).
pub const UPDATE_METHOD: &str = "agent/credentials.update";
/// The method that lists the sessions that run on an owner's credential (no value).
pub const LIST_METHOD: &str = "agent/credentials.list";
/// The `data.reason` of a prompt or start refused until the owner's Mac sends the credential again.
pub const RECONNECT_REASON: &str = "credentials.reconnect";
/// Claude Code's switch that strips credentials from its tool processes' env.
pub const CLAUDE_SCRUB: &str = "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB";

/// Claude Code's long-lived token (`claude setup-token`).
pub const CLAUDE_OAUTH: &str = "CLAUDE_CODE_OAUTH_TOKEN";
/// An Anthropic API key (serves Claude).
pub const ANTHROPIC_KEY: &str = "ANTHROPIC_API_KEY";
/// An OpenAI API key (serves Codex).
pub const OPENAI_KEY: &str = "OPENAI_API_KEY";
/// A ChatGPT plan access token (serves Codex through [`CHATGPT_PROVIDER`]).
pub const CHATGPT_TOKEN: &str = "CMUX_CHATGPT_ACCESS_TOKEN";

/// The only names a credential may set.
pub const NAMES: [&str; 4] = [CLAUDE_OAUTH, ANTHROPIC_KEY, OPENAI_KEY, CHATGPT_TOKEN];

/// What a credentialed agent never inherits: the machine's coderouter route, and every other
/// provider login or endpoint switch that would outrank the credential or send it elsewhere.
pub const UNSET: [&str; 14] = [
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
];

/// The Codex provider a ChatGPT plan token runs on (Revision 2's OpenAI-documented shape).
pub const CHATGPT_PROVIDER: &str = "openai_chatgpt_plan";
/// The Codex provider an OpenAI API key runs on: the same shape on `OPENAI_API_KEY`.
pub const OPENAI_KEY_PROVIDER: &str = "openai_api_key";
/// Where both Codex providers send.
pub const OPENAI_BASE: &str = "https://api.openai.com/v1";

/// The longest value taken (a ChatGPT JWT is a few KiB).
const MAX_VALUE_BYTES: usize = 16 * 1024;
/// The longest connection id taken.
const MAX_CONNECTION_BYTES: usize = 128;

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

/// A launch credential: the variables one agent gets, and what the Mac says of them (its
/// connection's id and the token's expiry, neither a secret). Its `Debug` never shows a value.
#[derive(Clone, PartialEq, Eq)]
pub struct AgentCredential {
    env: BTreeMap<String, String>,
    connection: Option<String>,
    expires_at: Option<u64>,
}

impl std::fmt::Debug for AgentCredential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AgentCredential")
            .field("names", &self.env.keys().collect::<Vec<_>>())
            .field("connection", &self.connection)
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

/// What the session's meta keeps of its credential: no value, only that the chat runs on the
/// owner's credential, its connection and, for a ChatGPT plan token, when it expires.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CredentialRef {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub connection: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<u64>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub chatgpt: bool,
}

impl AgentCredential {
    /// `{env: {NAME: value}, connection?, expires_at?}`: one name of [`NAMES`] (a Claude token or
    /// key, or a Codex key or ChatGPT token), a value of token characters only; the connection's
    /// id (id characters) and the token's expiry (unix seconds). Anything else is refused, never
    /// trimmed.
    pub fn parse(value: &Value) -> Result<Self, RpcError> {
        let refused = |why: &str| {
            RpcError::invalid_params(format!("credentials: {why}"))
                .with_data(serde_json::json!({"reason": "credentials.invalid"}))
        };
        let object = value.as_object().ok_or_else(|| refused("must be an object"))?;
        if object.keys().any(|k| !matches!(k.as_str(), "env" | "connection" | "expires_at")) {
            return Err(refused("only `env`, `connection` and `expires_at` are taken"));
        }
        let connection = match object.get("connection") {
            None | Some(Value::Null) => None,
            Some(Value::String(id)) if connection_shaped(id) => Some(id.clone()),
            Some(_) => return Err(refused("`connection` is not a connection id")),
        };
        let expires_at = match object.get("expires_at") {
            None | Some(Value::Null) => None,
            Some(v) => Some(v.as_u64().ok_or_else(|| refused("`expires_at` is unix seconds"))?),
        };
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
        Ok(Self { env: out, connection, expires_at })
    }

    /// Whether `other` holds the same secret (a new expiry alone restarts nothing).
    pub fn same_secret(&self, other: &Self) -> bool {
        self.env == other.env
    }

    /// What the meta keeps of it.
    pub fn reference(&self) -> CredentialRef {
        CredentialRef {
            connection: self.connection.clone(),
            expires_at: self.expires_at,
            chatgpt: self.is_chatgpt_plan(),
        }
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

fn connection_shaped(id: &str) -> bool {
    (1..=MAX_CONNECTION_BYTES).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b"-._:".contains(&b))
}

/// Why a prompt to a chat that runs on the owner's credential cannot go now, if it cannot: the
/// daemon restarted and lost it (`reference` without `credential`), or its ChatGPT token expired
/// with no refresh (the owner's Mac is away). The chat says it needs that Mac, and never falls
/// back to the machine's coderouter route.
pub fn blocked(
    credential: Option<&AgentCredential>,
    reference: Option<&CredentialRef>,
    now: u64,
) -> Option<RpcError> {
    let chatgpt = match (credential, reference) {
        (None, Some(r)) => r.chatgpt,
        (Some(c), _) if c.is_chatgpt_plan() && c.expires_at.is_some_and(|at| at <= now) => true,
        _ => return None,
    };
    let message = if chatgpt {
        "This chat needs your Mac to reconnect ChatGPT. Open cmux on the Mac that started it."
    } else {
        "This chat needs your Mac to send its model connection again. Open cmux on the Mac that started it."
    };
    Some(RpcError::new(-32002, message).with_data(serde_json::json!({
        "reason": RECONNECT_REASON,
        "connection": credential.map(|c| c.reference()).or_else(|| reference.cloned()).and_then(|r| r.connection),
    })))
}

/// Claude Code's managed settings: above the env, so a route pinned there wins over a credential.
pub const CLAUDE_MANAGED: &str = "etc/claude-code/managed-settings.json";
/// Codex's legacy managed config: above `-c` overrides (codex-rs `ConfigLayerSource::precedence`,
/// `LegacyManagedConfigTomlFromFile` 40 over `SessionFlags` 30), so a provider pinned there wins.
pub const CODEX_MANAGED: &str = "etc/codex/managed_config.toml";

/// Whether this machine's image pins a model route in the managed layer of `family`'s agent (an
/// image baked before the route moved out of it): Claude settings with an `apiKeyHelper` or an
/// endpoint or credential variable in `env`, a Codex managed config with a `model_provider`. A
/// credential would go to that route instead of its provider. `root` is `/` (tests: a folder).
pub fn managed_route_pinned(family: Family, root: &std::path::Path) -> bool {
    match family {
        Family::Claude => {
            let Ok(text) = std::fs::read_to_string(root.join(CLAUDE_MANAGED)) else { return false };
            let Ok(settings) = serde_json::from_str::<Value>(&text) else { return false };
            let env = settings.get("env").and_then(Value::as_object);
            settings.get("apiKeyHelper").is_some()
                || env.is_some_and(|env| env.keys().any(|k| UNSET.contains(&k.as_str())))
        }
        Family::Codex => {
            let Ok(text) = std::fs::read_to_string(root.join(CODEX_MANAGED)) else { return false };
            toml::from_str::<toml::Table>(&text).is_ok_and(|t| t.contains_key("model_provider"))
        }
    }
}

/// The refusal of a start on such a machine.
pub fn managed_route_refusal() -> RpcError {
    RpcError::new(
        -32002,
        "This Cloud machine's image routes agents through cmux, so it cannot use your own model connection. Update the machine, then send again.",
    )
    .with_data(serde_json::json!({"reason": "credentials.managed_route"}))
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
    match harness {
        // Its Bash commands, hooks and MCP servers get no credential (Claude Code's scrub).
        Family::Claude => {
            env.insert(CLAUDE_SCRUB.to_owned(), "1".to_owned());
        }
        Family::Codex => {
            let (provider, key) = if credential.is_chatgpt_plan() {
                (CHATGPT_PROVIDER, CHATGPT_TOKEN)
            } else {
                (OPENAI_KEY_PROVIDER, OPENAI_KEY)
            };
            set_codex_provider(argv, provider, key);
        }
    }
    true
}

/// The `-c` override that keeps every credential variable out of the env of Codex's shell tool.
pub fn codex_shell_exclude() -> String {
    let names: Vec<String> =
        [CHATGPT_TOKEN, OPENAI_KEY, "CODEX_API_KEY"].iter().map(|n| format!("\"{n}\"")).collect();
    format!("shell_environment_policy.exclude=[{}]", names.join(","))
}

/// The `-c` overrides that select `provider` (a custom one on `env_key`), in place of any
/// `model_provider` the argv already chose (the image's `cmux` route, an own-mode `openai`).
pub fn codex_provider_args(provider: &str, env_key: &str) -> Vec<String> {
    let table = format!("model_providers.{provider}");
    [
        format!("model_provider=\"{provider}\""),
        format!("{table}.name=\"{provider}\""),
        format!("{table}.base_url=\"{OPENAI_BASE}\""),
        format!("{table}.env_key=\"{env_key}\""),
        format!("{table}.wire_api=\"responses\""),
        format!("{table}.requires_openai_auth=false"),
        format!("{table}.supports_websockets=false"),
    ]
    .into_iter()
    .flat_map(|value| ["-c".to_owned(), value])
    .collect()
}

fn set_codex_provider(argv: &mut Vec<String>, provider: &str, env_key: &str) {
    if argv.is_empty() {
        return;
    }
    // Every earlier `-c model_provider=…` (or `--config`) pair goes: the last one would win anyway,
    // and the argv then says one provider.
    let mut i = 1;
    while i < argv.len() {
        let flag = argv[i] == "-c" || argv[i] == "--config";
        if flag && argv.get(i + 1).is_some_and(|v| v.starts_with("model_provider=")) {
            argv.drain(i..i + 2);
        } else if argv[i].starts_with("--config=model_provider=")
            || argv[i].starts_with("-cmodel_provider=")
        {
            argv.remove(i);
        } else {
            i += 1;
        }
    }
    let mut args = codex_provider_args(provider, env_key);
    args.extend(["-c".to_owned(), codex_shell_exclude()]);
    for (offset, arg) in args.into_iter().enumerate() {
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
            json!({"env": {CLAUDE_OAUTH: "x"}, "connection": "a b"}),
            json!({"env": {CLAUDE_OAUTH: "x"}, "expires_at": "soon"}),
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
        assert_eq!(e[CLAUDE_SCRUB], "1", "its tool processes get no credential");
    }

    #[test]
    fn codex_keeps_the_credential_out_of_its_shell_tool() {
        for var in [CHATGPT_TOKEN, OPENAI_KEY] {
            let c = AgentCredential::parse(&json!({"env": {var: "sk-proj-abc"}})).unwrap();
            let (mut argv, mut e) =
                (vec!["codex".to_owned(), "app-server".to_owned()], BTreeMap::new());
            assert!(apply(&c, "codex", &mut argv, &mut e));
            let at = argv.iter().position(|a| a.starts_with("shell_environment_policy.exclude="));
            let at = at.expect("an exclude override");
            assert_eq!(argv[at - 1], "-c");
            for name in [CHATGPT_TOKEN, OPENAI_KEY, "CODEX_API_KEY"] {
                assert!(argv[at].contains(&format!("\"{name}\"")), "{name} in {}", argv[at]);
            }
        }
    }

    #[test]
    fn an_image_that_pins_the_route_in_the_managed_layer_is_seen() {
        let root = std::env::temp_dir().join(format!("acpmux-managed-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("etc/claude-code")).unwrap();
        std::fs::create_dir_all(root.join("etc/codex")).unwrap();
        assert!(!managed_route_pinned(Family::Claude, &root), "no file");
        assert!(!managed_route_pinned(Family::Codex, &root), "no file");
        let write = |path: &str, text: &str| std::fs::write(root.join(path), text).unwrap();
        write(
            CLAUDE_MANAGED,
            r#"{"cleanupPeriodDays": 99999, "skipDangerousModePermissionPrompt": true}"#,
        );
        write(
            CODEX_MANAGED,
            "check_for_update_on_startup = false\n[projects.\"/root\"]\ntrust_level = \"trusted\"\n",
        );
        assert!(!managed_route_pinned(Family::Claude, &root));
        assert!(!managed_route_pinned(Family::Codex, &root));
        write(
            CLAUDE_MANAGED,
            r#"{"env": {"ANTHROPIC_BASE_URL": "https://coderouter.cmux.internal"}}"#,
        );
        assert!(managed_route_pinned(Family::Claude, &root));
        write(CLAUDE_MANAGED, r#"{"apiKeyHelper": "printf %s cmux-vm-edge-placeholder"}"#);
        assert!(managed_route_pinned(Family::Claude, &root));
        write(CODEX_MANAGED, "model_provider = \"cmux\"\n");
        assert!(managed_route_pinned(Family::Codex, &root));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_meta_keeps_the_connection_and_expiry_never_the_value() {
        let c = AgentCredential::parse(
            &json!({"env": {CHATGPT_TOKEN: CHATGPT}, "connection": "chatgpt-1", "expires_at": 1_900_000_000u64}),
        )
        .unwrap();
        let r = c.reference();
        assert_eq!(r.connection.as_deref(), Some("chatgpt-1"));
        assert_eq!(r.expires_at, Some(1_900_000_000));
        assert!(r.chatgpt);
        assert!(!serde_json::to_string(&r).unwrap().contains(CHATGPT));
        assert!(!format!("{c:?}").contains(CHATGPT));
    }

    #[test]
    fn a_lost_or_expired_credential_says_the_chat_needs_the_owners_mac() {
        let c = AgentCredential::parse(
            &json!({"env": {CHATGPT_TOKEN: CHATGPT}, "connection": "chatgpt-1", "expires_at": 100}),
        )
        .unwrap();
        assert!(blocked(Some(&c), Some(&c.reference()), 99).is_none());
        let expired = blocked(Some(&c), Some(&c.reference()), 100).unwrap();
        assert_eq!(expired.data.as_ref().unwrap()["reason"], RECONNECT_REASON);
        assert!(expired.message.contains("reconnect ChatGPT"));
        let lost = blocked(None, Some(&c.reference()), 0).unwrap();
        assert_eq!(lost.data.unwrap()["connection"], "chatgpt-1");
        let claude =
            AgentCredential::parse(&json!({"env": {CLAUDE_OAUTH: "sk-ant-oat01-a"}})).unwrap();
        assert!(blocked(Some(&claude), Some(&claude.reference()), u64::MAX).is_none());
        assert!(!blocked(None, Some(&claude.reference()), 0).unwrap().message.contains("ChatGPT"));
        assert!(blocked(None, None, 0).is_none(), "a chat on the machine's route");
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
