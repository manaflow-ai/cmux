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
mod tests {
    use super::*;

    fn dotenv_home(text: &str) -> (std::path::PathBuf, BTreeMap<String, String>) {
        let home = std::env::temp_dir().join(format!("acp-key-dotenv-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(home.join(".gemini")).unwrap();
        std::fs::write(home.join(".gemini/.env"), text).unwrap();
        let env = BTreeMap::from([("HOME".to_owned(), home.display().to_string())]);
        (home, env)
    }

    #[test]
    fn antigravity_reads_the_saved_gemini_key() {
        let none = |_: &str| None;
        let (home, mut env) =
            dotenv_home("# saved by cmux\nOTHER=1\nexport GEMINI_API_KEY=\"AIza-own\"\n");
        fill_key_from_gemini_dotenv(&mut env, "antigravity", none);
        assert_eq!(env.get(GEMINI_API_KEY_ENV).map(String::as_str), Some("AIza-own"));

        // The launch's own key, the gateway's included, wins; so does the daemon's.
        let (_, mut gateway) = dotenv_home("GEMINI_API_KEY='AIza-own'\n");
        gateway.insert(GEMINI_API_KEY_ENV.to_owned(), "placeholder".to_owned());
        fill_key_from_gemini_dotenv(&mut gateway, "antigravity", none);
        assert_eq!(gateway[GEMINI_API_KEY_ENV], "placeholder");
        let (_, mut daemon) = dotenv_home("GEMINI_API_KEY=AIza-own\n");
        fill_key_from_gemini_dotenv(&mut daemon, "antigravity", |k| {
            (k == GEMINI_API_KEY_ENV).then(|| "daemon".to_owned())
        });
        assert!(!daemon.contains_key(GEMINI_API_KEY_ENV));

        // Other families, an empty value and no file leave the env alone.
        let (_, mut gemini) = dotenv_home("GEMINI_API_KEY=AIza-own\n");
        fill_key_from_gemini_dotenv(&mut gemini, "gemini", none);
        assert!(!gemini.contains_key(GEMINI_API_KEY_ENV));
        let (_, mut empty) = dotenv_home("GEMINI_API_KEY=\"\"\n");
        fill_key_from_gemini_dotenv(&mut empty, "antigravity", none);
        assert!(!empty.contains_key(GEMINI_API_KEY_ENV));
        std::fs::remove_file(home.join(".gemini/.env")).unwrap();
        fill_key_from_gemini_dotenv(&mut env, "antigravity", none);
        let mut gone = BTreeMap::from([("HOME".to_owned(), home.display().to_string())]);
        fill_key_from_gemini_dotenv(&mut gone, "antigravity", none);
        assert!(!gone.contains_key(GEMINI_API_KEY_ENV));
    }

    fn init(ids: &[&str]) -> Value {
        json!({"authMethods": ids.iter().map(|id| json!({"id": id, "name": id})).collect::<Vec<_>>()})
    }

    fn key(v: Option<&str>) -> impl Fn(&str) -> Option<String> {
        let v = v.map(str::to_owned);
        move |name| (name == GEMINI_API_KEY_ENV).then(|| v.clone()).flatten()
    }

    #[test]
    fn a_key_and_the_method_authenticate() {
        let params = authenticate_params(
            "antigravity",
            &init(&["oauth-personal", "gemini-api-key"]),
            key(Some("k")),
        );
        assert_eq!(params, Some(json!({"methodId": "gemini-api-key"})));
    }

    #[test]
    fn no_key_or_no_method_asks_nothing() {
        assert_eq!(authenticate_params("antigravity", &init(&["gemini-api-key"]), key(None)), None);
        assert_eq!(
            authenticate_params("antigravity", &init(&["gemini-api-key"]), key(Some("  "))),
            None
        );
        assert_eq!(
            authenticate_params("antigravity", &init(&["oauth-personal"]), key(Some("k"))),
            None
        );
        assert_eq!(authenticate_params("antigravity", &json!({}), key(Some("k"))), None);
    }

    #[test]
    fn gemini_cli_reads_its_key_itself() {
        assert_eq!(authenticate_params("gemini", &init(&["gemini-api-key"]), key(Some("k"))), None);
    }

    #[test]
    fn the_profile_env_wins_over_the_daemon() {
        let mut env = BTreeMap::new();
        env.insert("ACPMUX_KEY_AUTH_TEST_VAR".to_owned(), "from-profile".to_owned());
        assert_eq!(
            launch_var(&env, "antigravity", "ACPMUX_KEY_AUTH_TEST_VAR").as_deref(),
            Some("from-profile")
        );
    }
}
