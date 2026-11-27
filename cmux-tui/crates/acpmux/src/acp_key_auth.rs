//! ACP API-key sign-in at the handshake: an agent whose `initialize` lists the `gemini-api-key`
//! auth method, started with a non-empty `GEMINI_API_KEY`, is told to use it (`authenticate`)
//! once, before `session/new`, `session/load` or `session/resume`.
//!
//! Antigravity's `agy acp` reads the key only after that call: without it `session/new` answers
//! "Authentication required" though the key is in its environment, so a chat on a key, or on a
//! Cloud machine's team gateway (`provider_cloud_auth.rs` sets the key there), never started.
//! An agent that offers no such method, or a launch with no key, is asked nothing: its own
//! sign-in stays as it was. Gemini CLI is left out though it lists the method: it reads the key
//! by itself, and its `authenticate` writes the choice into the person's `settings.json`. Used by the hub's starts (`hub/lifecycle.rs`, `hub/pool/start.rs`)
//! and `acpmux harness doctor` (`cli/harness.rs`).
//! A key the person saved in `~/.gemini/.env` (the Cloud sign-in card's) reaches Antigravity's
//! launch env too (`fill_key_from_gemini_dotenv`), since `agy` reads no dotenv file.

use serde_json::{Value, json};
use std::collections::BTreeMap;

/// The ACP auth method id that reads the key from the environment.
pub(crate) const GEMINI_API_KEY_METHOD: &str = "gemini-api-key";
/// The variable it reads.
pub(crate) const GEMINI_API_KEY_ENV: &str = "GEMINI_API_KEY";

/// The `authenticate` params to send once after `initialize`, when its answer lists the API-key
/// method and `key` reads a non-empty `GEMINI_API_KEY` for the launch; else None.
pub(crate) fn authenticate_params(
    family: &str,
    init: &Value,
    key: impl Fn(&str) -> Option<String>,
) -> Option<Value> {
    if family == "gemini" {
        return None;
    }
    let offered = init["authMethods"]
        .as_array()?
        .iter()
        .any(|m| m.get("id").and_then(Value::as_str) == Some(GEMINI_API_KEY_METHOD));
    let has_key = key(GEMINI_API_KEY_ENV).is_some_and(|v| !v.trim().is_empty());
    (offered && has_key).then(|| json!({"methodId": GEMINI_API_KEY_METHOD}))
}

/// The launch's value of `name` for a `family` agent: the profile's env (as acpmux spawns it,
/// team gateway included) over the daemon's own and the login shell's values that family gets
/// (`login_env::allowed`), which the child inherits.
pub(crate) fn launch_var(
    env: &BTreeMap<String, String>,
    family: &str,
    name: &str,
) -> Option<String> {
    env.get(name).cloned().or_else(|| std::env::var(name).ok()).or_else(|| {
        crate::login_env::var(name).filter(|v| crate::login_env::allowed(name, v, Some(family)))
    })
}

/// Antigravity's launch env with the person's own Gemini key from `~/.gemini/.env` (the Cloud
/// sign-in card saves it there, as Gemini CLI reads it), when the launch has none: `agy` reads
/// only its environment. A key the launch has (the profile's, the team gateway's placeholder from
/// `provider_cloud_auth`, the daemon's own) wins. `daemon` reads the daemon's environment.
pub(crate) fn fill_key_from_gemini_dotenv(
    env: &mut BTreeMap<String, String>,
    family: &str,
    daemon: impl Fn(&str) -> Option<String>,
) {
    let set = |v: Option<&String>| v.is_some_and(|v| !v.trim().is_empty());
    if family != "antigravity"
        || set(env.get(GEMINI_API_KEY_ENV))
        || set(daemon(GEMINI_API_KEY_ENV).as_ref())
    {
        return;
    }
    let var = |k: &str| env.get(k).cloned().or_else(|| daemon(k)).filter(|v| !v.is_empty());
    let Some(home) = var("GEMINI_CLI_HOME")
        .or_else(|| var("HOME"))
        .map(std::path::PathBuf::from)
        .or_else(dirs::home_dir)
    else {
        return;
    };
    let Ok(text) = std::fs::read_to_string(home.join(".gemini").join(".env")) else { return };
    if let Some(key) = crate::agent_login::dotenv_value(&text, GEMINI_API_KEY_ENV)
        .map(str::trim)
        .filter(|k| !k.is_empty())
    {
        env.insert(GEMINI_API_KEY_ENV.to_owned(), key.to_owned());
    }
}

#[cfg(test)]
#[path = "acp_key_auth_tests.rs"]
mod tests;
