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
    let user_home = env
        .get("HOME")
        .filter(|h| !h.is_empty())
        .map(PathBuf::from)
        .or_else(dirs::home_dir)
        .unwrap_or_default();
    let custom = env.get("CLAUDE_CONFIG_DIR").filter(|d| !d.is_empty());
    let home = custom.map(PathBuf::from).unwrap_or_else(|| user_home.join(".claude"));
    let mut found = Found { home: home.clone(), custom_home: custom.is_some(), ..Found::default() };
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
    for file in settings_files(&home) {
        let Ok(bytes) = std::fs::read(&file) else { continue };
        let Ok(json) = serde_json::from_slice::<serde_json::Value>(&bytes) else { continue };
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
    if std::fs::read(&config)
        .ok()
        .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
        .and_then(|v| v.get("primaryApiKey").and_then(|k| k.as_str()).map(|k| !k.is_empty()))
        == Some(true)
    {
        found.sources.push(format!("the API key saved in {}", tilde(&config)));
    }
    if home.join(".credentials.json").is_file() {
        found
            .sources
            .push(format!("the sign-in saved in {}", tilde(&home.join(".credentials.json"))));
    }
    found
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

static SPAWNED: Mutex<Option<HashMap<String, BTreeMap<String, String>>>> = Mutex::new(None);

/// Remember a Claude agent's spawn environment for its session: the
/// Claude home, HOME, the endpoint and shell as they are, and only the
/// presence of credential keys (their values are replaced). Logs a warning
/// when it has no sign-in at all.
pub fn remember(session_id: &str, env: &[(String, String)]) {
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
    map.get_or_insert_with(HashMap::new).insert(session_id.to_owned(), kept);
}

/// The session now runs another harness: its Claude spawn env no longer applies.
pub fn forget(session_id: &str) {
    if let Some(map) = SPAWNED.lock().unwrap_or_else(|e| e.into_inner()).as_mut() {
        map.remove(session_id);
    }
}

/// Claude's own words for "no usable sign-in".
pub fn is_sign_in_failure(message: &str) -> bool {
    let m = message.to_lowercase();
    m.contains("not logged in")
        || m.contains("please run /login")
        || m.contains("invalid api key")
        || m.contains("oauth token has expired")
        || m.contains("authentication_failed")
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
    let agent_env =
        SPAWNED.lock().unwrap_or_else(|e| e.into_inner()).as_ref()?.get(session_id)?.clone();
    // File reads block: off a multi-thread runtime's workers.
    let work = || {
        let agent = find(&agent_env);
        let terminal_env = terminal_env();
        let terminal = find(&terminal_env);
        compose(&agent, &terminal, terminal_env.get("SHELL").map(String::as_str), original)
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

fn compose(agent: &Found, terminal: &Found, shell: Option<&str>, original: &str) -> String {
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
    let fix = if agent.signed_in() {
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
    /// A sign-in failure is explained; one that says the provider was unreachable is not.
    #[test]
    fn an_outage_that_names_a_token_is_not_explained_as_a_sign_in() {
        assert!(super::explains("Not logged in · Please run /login"));
        assert!(super::explains("API Error: 401 OAuth token has expired"));
        assert!(!super::explains("HTTP 503: OAuth token has expired"));
        assert!(!super::explains("connection error: Not logged in"));
        assert!(!super::explains("Claude is not signed in here. Not logged in"));
    }
}
