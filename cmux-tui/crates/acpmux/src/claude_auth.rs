//! Where Claude Code finds its sign-in, read the way Claude Code reads it,
//! never the values: the environment (`ANTHROPIC_API_KEY`,
//! `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, Bedrock / Vertex /
//! Foundry switches, `ANTHROPIC_BASE_URL`), the managed and user
//! `settings.json` (`env`, `apiKeyHelper`, AWS credential helpers), the
//! Claude home's `.credentials.json`. Never the macOS keychain item Claude
//! Code keeps (`Claude Code-credentials`): acpmux never asks the login
//! keychain on its own (cx-hh0vu). A `security` call from a tagged, DEV or
//! ad hoc signed acpmux left keychain dialogs on GUI test hosts, and a
//! locked keychain asks to unlock even for attributes. A sign-in kept only
//! in the keychain is not seen here: health says `unknown` for it, never
//! signed out.
//!
//! acpmux remembers each Claude agent's spawn environment (names, the Claude
//! home and the endpoint's host only) and, when a turn fails because Claude
//! is not signed in, replaces the bare "Not logged in · Please run /login"
//! with what this agent had, how the person's terminal signs in, and the fix.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// Environment keys that carry a Claude credential by themselves.
const TOKEN_KEYS: [(&str, &str); 3] = [
    ("ANTHROPIC_API_KEY", "an API key (ANTHROPIC_API_KEY)"),
    ("ANTHROPIC_AUTH_TOKEN", "a token (ANTHROPIC_AUTH_TOKEN)"),
    ("CLAUDE_CODE_OAUTH_TOKEN", "a sign-in token (CLAUDE_CODE_OAUTH_TOKEN)"),
];
/// Switches to a cloud provider whose credentials Claude does not keep.
const PROVIDER_KEYS: [(&str, &str); 3] = [
    ("CLAUDE_CODE_USE_BEDROCK", "Amazon Bedrock (CLAUDE_CODE_USE_BEDROCK)"),
    ("CLAUDE_CODE_USE_VERTEX", "Google Vertex AI (CLAUDE_CODE_USE_VERTEX)"),
    ("CLAUDE_CODE_USE_FOUNDRY", "Microsoft Foundry (CLAUDE_CODE_USE_FOUNDRY)"),
];
const BASE_URL: &str = "ANTHROPIC_BASE_URL";
/// The spawn-env keys remembered per agent (values of token keys are not).
const REMEMBERED: [&str; 4] = ["CLAUDE_CONFIG_DIR", "HOME", BASE_URL, "SHELL"];

/// What one environment gives Claude Code.
#[derive(Debug, Clone, Default)]
pub struct Found {
    /// The Claude home (`CLAUDE_CONFIG_DIR`, else `~/.claude`).
    pub home: PathBuf,
    /// `CLAUDE_CONFIG_DIR` is set.
    pub custom_home: bool,
    /// Each sign-in source, in plain words.
    pub sources: Vec<String>,
    /// A custom API endpoint, as `host[:port]` (never its path or user part).
    pub endpoint: Option<String>,
    /// Credential keys that came from the environment (not a file).
    pub env_keys: Vec<String>,
    /// The sole file login is positively expired and cannot refresh. Never set on macOS,
    /// where an uninspected keychain login can still work, or with another credential source.
    pub expired_file_login: bool,
    /// Project context was supplied and all candidate settings could be inspected.
    pub credential_sources_complete: bool,
}

impl Found {
    pub fn signed_in(&self) -> bool {
        !self.sources.is_empty()
    }
}

fn truthy(v: Option<&str>) -> bool {
    v.is_some_and(|v| !v.is_empty() && v != "0" && !v.eq_ignore_ascii_case("false"))
}

fn tilde(path: &Path) -> String {
    if let Some(home) = dirs::home_dir()
        && let Ok(rest) = path.strip_prefix(&home)
    {
        return format!("~/{}", rest.display());
    }
    path.display().to_string()
}

fn endpoint_host(url: &str) -> String {
    let rest = url.split_once("://").map(|(_, r)| r).unwrap_or(url);
    let authority = rest.split(['/', '?', '#']).next().unwrap_or(rest);
    authority.rsplit('@').next().unwrap_or(authority).to_owned()
}

/// The settings files Claude Code reads env and helpers from, outside a
/// project: managed settings, then the Claude home's `settings.json`.
fn settings_files(home: &Path) -> Vec<PathBuf> {
    let managed = if cfg!(target_os = "macos") {
        "/Library/Application Support/ClaudeCode/managed-settings.json"
    } else {
        "/etc/claude-code/managed-settings.json"
    };
    vec![PathBuf::from(managed), home.join("settings.json")]
}

/// The sign-in sources `env` gives Claude Code, from the environment and
/// files only (never the keychain).
pub fn find(env: &BTreeMap<String, String>) -> Found {
    find_sources(env, None)
}

/// Include project settings when evaluating a session's own credential sources. Helpers are
/// only recognized, never executed. Ancestor settings conservatively count as alternatives.
pub fn find_in(env: &BTreeMap<String, String>, cwd: &Path) -> Found {
    find_sources(env, Some(cwd))
}

fn find_sources(env: &BTreeMap<String, String>, cwd: Option<&Path>) -> Found {
    // Claude runs in the resolved directory: lexical ancestors of a symlink can miss its
    // actual project's settings. Failure to resolve context is never proof of missing auth.
    let project = cwd
        .filter(|path| path.is_absolute())
        .and_then(|path| std::fs::canonicalize(path).ok())
        .filter(|path| path.is_dir());
    let user_home = env
        .get("HOME")
        .filter(|h| !h.is_empty())
        .map(PathBuf::from)
        .or_else(dirs::home_dir)
        .unwrap_or_default();
    let custom = env.get("CLAUDE_CONFIG_DIR").filter(|d| !d.is_empty());
    let home = custom.map(PathBuf::from).unwrap_or_else(|| user_home.join(".claude"));
    let mut found = Found {
        home: home.clone(),
        custom_home: custom.is_some(),
        credential_sources_complete: project.is_some(),
        ..Found::default()
    };
    for (key, words) in PROVIDER_KEYS {
        if truthy(env.get(key).map(String::as_str)) {
            found.sources.push(words.to_owned());
            found.env_keys.push(key.to_owned());
        }
    }
    for (key, words) in TOKEN_KEYS {
        if env.get(key).is_some_and(|v| !v.is_empty()) {
            found.sources.push(words.to_owned());
            found.env_keys.push(key.to_owned());
        }
    }
    if let Some(url) = env.get(BASE_URL).filter(|v| !v.is_empty()) {
        found.endpoint = Some(endpoint_host(url));
    }
    let mut settings = settings_files(&home);
    if let Some(cwd) = project.as_deref() {
        for dir in cwd.ancestors() {
            settings.push(dir.join(".claude/settings.json"));
            settings.push(dir.join(".claude/settings.local.json"));
        }
    }
    for file in settings {
        let bytes = match std::fs::read(&file) {
            Ok(bytes) => bytes,
            Err(error) => {
                if error.kind() != std::io::ErrorKind::NotFound {
                    found.credential_sources_complete = false;
                }
                continue;
            }
        };
        let Ok(json) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
            found.credential_sources_complete = false;
            continue;
        };
        if !json.is_object() || json.get("env").is_some_and(|value| !value.is_object()) {
            found.credential_sources_complete = false;
        }
        let at = tilde(&file);
        if let Some(senv) = json.get("env").and_then(|e| e.as_object()) {
            let has = |k: &str| {
                senv.get(k).is_some_and(|v| {
                    // Provider switches select a credential source only when enabled,
                    // with the same semantics as the process environment above.
                    if PROVIDER_KEYS.iter().any(|(key, _)| *key == k) {
                        return match v {
                            serde_json::Value::String(value) => truthy(Some(value)),
                            serde_json::Value::Bool(_) | serde_json::Value::Number(_) => {
                                truthy(Some(&v.to_string()))
                            }
                            _ => false,
                        };
                    }
                    v.as_str().is_some_and(|s| !s.is_empty()) || v.is_boolean() || v.is_number()
                })
            };
            for (key, _) in PROVIDER_KEYS.iter().chain(TOKEN_KEYS.iter()) {
                if has(key) && !found.env_keys.iter().any(|k| k == key) {
                    found.sources.push(format!("{key} in {at}"));
                }
            }
            if found.endpoint.is_none()
                && let Some(url) =
                    senv.get(BASE_URL).and_then(|v| v.as_str()).filter(|v| !v.is_empty())
            {
                found.endpoint = Some(endpoint_host(url));
            }
        }
        for helper in ["apiKeyHelper", "awsCredentialExport", "awsAuthRefresh"] {
            if json.get(helper).and_then(|v| v.as_str()).is_some_and(|v| !v.is_empty()) {
                found.sources.push(format!("{helper} in {at}"));
            }
        }
    }
    // An API key `/login` saved: `<CLAUDE_CONFIG_DIR>/.claude.json`, else ~/.claude.json.
    let config = match custom {
        Some(dir) => PathBuf::from(dir).join(".claude.json"),
        None => user_home.join(".claude.json"),
    };
    match std::fs::read(&config) {
        Ok(bytes) => match serde_json::from_slice::<serde_json::Value>(&bytes) {
            Ok(json) => {
                if json
                    .get("primaryApiKey")
                    .and_then(|key| key.as_str())
                    .is_some_and(|key| !key.is_empty())
                {
                    found.sources.push(format!("the API key saved in {}", tilde(&config)));
                }
                if !json.is_object() {
                    found.credential_sources_complete = false;
                }
            }
            Err(_) => found.credential_sources_complete = false,
        },
        Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
            found.credential_sources_complete = false
        }
        Err(_) => {}
    }
    let credentials = home.join(".credentials.json");
    if credentials.is_file() {
        found.expired_file_login = !cfg!(target_os = "macos")
            && found.sources.is_empty()
            && std::fs::read(&credentials)
                .ok()
                .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
                .is_some_and(|json| unrefreshable_file_expiry(&json));
        found
            .sources
            .push(format!("the sign-in saved in {}", tilde(&home.join(".credentials.json"))));
    }
    found
}

/// Only a known OAuth expiry with no usable refresh token proves failure. Unknown fields,
/// missing timestamps and malformed token shapes retain the existing presence-only evidence.
fn unrefreshable_file_expiry(json: &serde_json::Value) -> bool {
    let Some(oauth) = json.get("claudeAiOauth") else { return false };
    let has_access = oauth
        .get("accessToken")
        .and_then(|v| v.as_str())
        .is_some_and(|token| !token.trim().is_empty());
    let no_refresh = match oauth.get("refreshToken") {
        None | Some(serde_json::Value::Null) => true,
        Some(serde_json::Value::String(token)) => token.trim().is_empty(),
        _ => false,
    };
    let expired = oauth.get("expiresAt").and_then(|v| v.as_u64()).is_some_and(|expiry| {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .is_ok_and(|now| u128::from(expiry) <= now.as_millis())
    });
    has_access && no_refresh && expired
}

/// The person's terminal: the daemon's environment with the login shell's
/// variables over it.
pub fn terminal_env() -> BTreeMap<String, String> {
    let mut env: BTreeMap<String, String> = std::env::vars().collect();
    if std::env::var_os("CLAUDECODE").is_some() {
        // A daemon inside a Claude Code session: those keys are the session's.
        env.retain(|k, _| !crate::config::is_nested_claude_key(k));
    }
    for k in crate::login_env::imported_keys() {
        if let Some(v) = crate::login_env::var(&k) {
            env.insert(k, v);
        }
    }
    env
}

/// Claude has a sign-in without the login shell: the daemon's own
/// environment, settings files or credentials file (never the keychain).
pub fn direct_sign_in() -> bool {
    let mut env: BTreeMap<String, String> = std::env::vars().collect();
    if std::env::var_os("CLAUDECODE").is_some() {
        env.retain(|k, _| !crate::config::is_nested_claude_key(k));
    }
    find(&env).signed_in()
}

#[derive(Clone)]
struct Spawned {
    env: BTreeMap<String, String>,
    routed: bool,
}

static SPAWNED: Mutex<Option<HashMap<String, Spawned>>> = Mutex::new(None);

/// Remember a Claude agent's spawn environment for its session: the
/// Claude home, HOME, the endpoint and shell as they are, and only the
/// presence of credential keys (their values are replaced), plus whether a route supplied
/// the environment. Logs a warning
/// when it has no sign-in at all.
pub fn remember(session_id: &str, env: &[(String, String)], routed: bool) {
    let mut kept = BTreeMap::new();
    for (k, v) in env {
        if REMEMBERED.contains(&k.as_str()) || PROVIDER_KEYS.iter().any(|(p, _)| p == k) {
            kept.insert(k.clone(), v.clone());
        } else if TOKEN_KEYS.iter().any(|(t, _)| t == k) && !v.is_empty() {
            kept.insert(k.clone(), "set".to_owned());
        }
    }
    let found = find(&kept);
    if !found.signed_in() {
        tracing::info!(session = session_id, home = %found.home.display(), "Claude agent starts with no sign-in in its env, settings or credentials file (a keychain sign-in is not checked)");
    }
    let mut map = SPAWNED.lock().unwrap_or_else(|e| e.into_inner());
    map.get_or_insert_with(HashMap::new)
        .insert(session_id.to_owned(), Spawned { env: kept, routed });
}

/// The session now runs another harness: its Claude spawn env no longer applies.
pub fn forget(session_id: &str) {
    if let Some(map) = SPAWNED.lock().unwrap_or_else(|e| e.into_inner()).as_mut() {
        map.remove(session_id);
    }
}

/// Claude's own words for "no usable sign-in": a missing login, and the API's refusal of the
/// credential it sent ("Failed to authenticate. API Error: 401 … authentication_error").
pub fn is_sign_in_failure(message: &str) -> bool {
    let m = message.to_lowercase();
    m.contains("not logged in")
        || m.contains("please run /login")
        || m.contains("invalid api key")
        || m.contains("oauth token has expired")
        || m.contains("authentication_failed")
        || m.contains("authentication_error")
        || m.contains("failed to authenticate. api error")
}

/// Whether `message` says a credential expired: "OAuth token has expired", "the token is
/// expired", "credential expired", "expired API key". One matcher for every place that tells an
/// expired sign-in from a missing one (a failed auth check, a failed turn), so the two never
/// drift. Only a statement that one expired counts: "invalid token expiry", "the credential
/// expires in 30 days" and a bare "session expired" do not.
pub fn is_expired_credential(message: &str) -> bool {
    // A constant pattern; the unit test proves it compiles.
    static EXPIRED: std::sync::LazyLock<Option<regex::Regex>> = std::sync::LazyLock::new(|| {
        regex::Regex::new(
            r"(?i)\b(?:tokens?|credentials?|api keys?|logins?|sign-ins?)(?:\s+(?:has|have|is|are|was|were))?\s+expired\b|\bexpired\s+(?:(?:oauth|access|refresh|auth|authentication|session)\s+)?(?:tokens?|credentials?|api keys?|logins?|sign-ins?)\b",
        )
        .ok()
    });
    EXPIRED.as_ref().is_some_and(|re| re.is_match(message))
}

/// Whether `message` says Claude's OAuth token was revoked ("Failed to authenticate: OAuth token
/// revoked", "OAuth token has been revoked"), and not that the provider was unreachable. A
/// fresh Cloud VM's first `claude -p` failed once this way and the same call 2 s later ran
/// (cmux#28111): the chat's first send is retried once on it (`hub/auto_resume/first_send.rs`).
/// An expired or missing sign-in is not this.
pub fn is_revoked_token(message: &str) -> bool {
    let m = message.to_lowercase();
    (m.contains("oauth token revoked") || m.contains("token has been revoked"))
        && !crate::hub::turn_errors::says_unreachable(message)
}

/// Whether [`explain`] rewrites `original`: a sign-in failure it has not explained yet, and not
/// one that says the provider was unreachable ("HTTP 503: OAuth token has expired"), which
/// stays as the agent said it, so its turn is retried and typed as the outage it is.
fn explains(original: &str) -> bool {
    is_sign_in_failure(original)
        && !crate::hub::turn_errors::says_unreachable(original)
        && !original.starts_with("Claude is not signed in here")
}

/// The explanation for a Claude agent's sign-in failure, or None when this
/// session is not a Claude agent acpmux started (or the text says another
/// thing). `original` is Claude's own text, kept at the end.
pub fn explain(session_id: &str, original: &str) -> Option<String> {
    if !explains(original) {
        return None;
    }
    let spawned =
        SPAWNED.lock().unwrap_or_else(|e| e.into_inner()).as_ref()?.get(session_id)?.clone();
    // File reads block: off a multi-thread runtime's workers.
    let work = || {
        let agent = find(&spawned.env);
        let terminal_env = terminal_env();
        let terminal = find(&terminal_env);
        compose(
            &agent,
            &terminal,
            terminal_env.get("SHELL").map(String::as_str),
            original,
            spawned.routed,
        )
    };
    let multi_thread = tokio::runtime::Handle::try_current()
        .is_ok_and(|h| h.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread);
    Some(if multi_thread { tokio::task::block_in_place(work) } else { work() })
}

fn list(items: &[String]) -> String {
    match items {
        [] => String::new(),
        [one] => one.clone(),
        [rest @ .., last] => format!("{} and {last}", rest.join(", ")),
    }
}

fn rc_file(shell: Option<&str>) -> &'static str {
    match shell.and_then(|s| s.rsplit('/').next()) {
        Some("bash") => "~/.bashrc",
        Some("fish") => "~/.config/fish/config.fish",
        _ => "~/.zshrc",
    }
}

fn compose(
    agent: &Found,
    terminal: &Found,
    shell: Option<&str>,
    original: &str,
    routed: bool,
) -> String {
    let mut out = String::from("Claude is not signed in here.");
    let with_endpoint = |f: &Found| match &f.endpoint {
        Some(host) => format!(" through a custom API endpoint ({host}, ANTHROPIC_BASE_URL)"),
        None => String::new(),
    };
    if agent.signed_in() {
        out.push_str(&format!(
            " This agent had {}{}, and Claude did not accept it.",
            list(&agent.sources),
            with_endpoint(agent)
        ));
    } else {
        out.push_str(&format!(
            " This agent found no sign-in (Claude home {}).",
            tilde(&agent.home)
        ));
    }
    if terminal.signed_in() {
        out.push_str(&format!(
            " Your terminal signs in with {}{}.",
            list(&terminal.sources),
            with_endpoint(terminal)
        ));
    } else {
        out.push_str(" Your terminal has no Claude sign-in either.");
    }
    let api_key = agent.env_keys.iter().any(|k| k == "ANTHROPIC_API_KEY");
    let fix = if routed && api_key {
        "Replace the credential in the selected model route, or select another route, then start a new chat."
            .to_owned()
    } else if agent.endpoint.is_none() && api_key {
        // Claude Code prefers ANTHROPIC_API_KEY over a `claude /login` sign-in, so logging in
        // again does not help while a rejected key is set. Not with an endpoint: a route or a
        // proxy set that key (routes.rs), and removing it would break the route.
        format!(
            "Claude uses ANTHROPIC_API_KEY before your `claude /login` sign-in. To use your Claude sign-in, remove ANTHROPIC_API_KEY from {} or this agent's profile and open a new terminal; or replace the key. Then send the message again.",
            rc_file(shell)
        )
    } else if agent.signed_in() {
        "Run `claude /login` in a terminal, or check that key, then send the message again."
            .to_owned()
    } else if terminal.signed_in() && agent.home != terminal.home {
        format!(
            "This agent uses the Claude home {}, your terminal uses {}. Remove CLAUDE_CONFIG_DIR from this agent's profile, or sign in for that home with `CLAUDE_CONFIG_DIR={} claude /login`, then send the message again.",
            tilde(&agent.home),
            tilde(&terminal.home),
            agent.home.display()
        )
    } else if terminal.signed_in() && !terminal.env_keys.is_empty() {
        let missing = crate::login_env::missing_secret_names();
        let why = match crate::login_env::outcome() {
            crate::login_env::Outcome::Failed => format!(
                " (your shell took longer than {} s to start, or failed)",
                crate::login_env::TIMEOUT.as_secs()
            ),
            _ if !missing.is_empty() => " (your shell was still starting)".to_owned(),
            _ => String::new(),
        };
        format!(
            "Your shell sets {} when it starts, and this agent did not get it{why}. Send the message again, or put it under \"env\" in {} so it does not depend on the shell.",
            list(&terminal.env_keys),
            tilde(&terminal.home.join("settings.json"))
        )
    } else {
        format!(
            "Run `claude /login` in a terminal, or set ANTHROPIC_API_KEY (or ANTHROPIC_BASE_URL with ANTHROPIC_AUTH_TOKEN) in {} and open a new terminal, then send the message again.",
            rc_file(shell)
        )
    };
    out.push(' ');
    out.push_str(&fix);
    out.push_str(&format!(" (Claude said: {})", original.trim()));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A sign-in failure is explained; one that says the provider was unreachable is not.
    #[test]
    fn an_outage_that_names_a_token_is_not_explained_as_a_sign_in() {
        assert!(super::explains("Not logged in · Please run /login"));
        assert!(super::explains("API Error: 401 OAuth token has expired"));
        assert!(!super::explains("HTTP 503: OAuth token has expired"));
        assert!(!super::explains("connection error: Not logged in"));
        assert!(!super::explains("Claude is not signed in here. Not logged in"));
    }

    /// Dogfood 2026-10-26: Claude Code's 401 ("Failed to authenticate") reached the person as
    /// raw API text instead of the sign-in explanation.
    #[test]
    fn a_rejected_credential_is_a_sign_in_failure() {
        let said = r#"Failed to authenticate. API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#;
        assert!(is_sign_in_failure(said));
        assert!(is_sign_in_failure("Not logged in · Please run /login"));
        assert!(!is_sign_in_failure("API Error: 529 overloaded_error"));
    }

    /// A rejected ANTHROPIC_API_KEY wins over `claude /login`, so the fix names the key, not a
    /// login that would not help.
    #[test]
    fn a_rejected_env_api_key_says_to_remove_it() {
        let agent = Found {
            home: PathBuf::from("/h/.claude"),
            sources: vec!["an API key (ANTHROPIC_API_KEY)".to_owned()],
            env_keys: vec!["ANTHROPIC_API_KEY".to_owned()],
            ..Found::default()
        };
        let text = compose(
            &agent,
            &agent,
            Some("/bin/zsh"),
            "Failed to authenticate. API Error: 401",
            false,
        );
        assert!(text.contains("remove ANTHROPIC_API_KEY from ~/.zshrc"), "{text}");
        assert!(!text.contains("Run `claude /login`"), "{text}");

        // Review of #25950: a route's key (with its endpoint) is not the person's to remove.
        let routed = Found { endpoint: Some("router.example:443".to_owned()), ..agent };
        let text = compose(
            &routed,
            &routed,
            Some("/bin/zsh"),
            "Failed to authenticate. API Error: 401",
            false,
        );
        assert!(!text.contains("remove ANTHROPIC_API_KEY"), "{text}");
    }

    #[test]
    fn a_subscription_route_without_a_key_keeps_login_advice() {
        let agent = Found::default();
        let text = compose(&agent, &agent, None, "Not logged in", true);
        assert!(text.contains("Run `claude /login`"), "{text}");
        assert!(!text.contains("selected model route"), "{text}");
    }

    #[test]
    fn a_routed_api_key_without_an_endpoint_says_to_change_the_route() {
        let home = tempfile::tempdir().unwrap();
        let mut profile: crate::config::HarnessProfile =
            serde_json::from_value(serde_json::json!({
                "kind": "claude-stdio",
                "argv": ["claude"],
                "env": {
                    "HOME": home.path(),
                    "CLAUDE_CONFIG_DIR": home.path(),
                    (crate::agent::REMOTE_ENV_POLICY_KEY): "1"
                }
            }))
            .unwrap();
        crate::routes::apply(
            &mut profile.env,
            &crate::routes::RouteEnv {
                set: BTreeMap::from([("ANTHROPIC_API_KEY".into(), "rejected-test-key".into())]),
                unset: crate::routes::SCRUBBED.iter().map(|key| (*key).to_owned()).collect(),
            },
        );
        let id = "claude-auth-routed-key-without-endpoint";
        let _command = crate::agent::harness_command(
            "claude",
            &profile,
            home.path(),
            None,
            Some((id, "route auth test")),
        )
        .unwrap();
        let text = explain(id, "Failed to authenticate. API Error: 401").unwrap();
        forget(id);
        assert!(text.contains("route"), "{text}");
        assert!(!text.contains("remove ANTHROPIC_API_KEY"), "{text}");
        assert!(!text.contains("rejected-test-key"), "{text}");
    }

    /// Only a revoked token is one: not an expired or missing sign-in, nor an outage.
    #[test]
    fn a_revoked_token_is_told_from_other_sign_in_failures() {
        use super::is_revoked_token as revoked;
        assert!(revoked("Failed to authenticate: OAuth token revoked"));
        assert!(revoked("Failed to authenticate: oauth TOKEN REVOKED"));
        assert!(revoked(
            r#"API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"OAuth token has been revoked. Please obtain a new token or refresh your existing token."}}"#
        ));
        assert!(!revoked("API Error: 401 OAuth token has expired"));
        assert!(!revoked("Not logged in · Please run /login"));
        assert!(!revoked("Invalid API key · Fix external API key"));
        assert!(!revoked("HTTP 503 service unavailable: OAuth token revoked"));
        assert!(!revoked("stream disconnected: OAuth token has been revoked"));
        assert!(!revoked("the revoked token list was refreshed"));
    }
}
