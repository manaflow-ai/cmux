//! Claude's model-plane pair on a cmux Cloud machine, for the launches acpmux makes itself.
//!
//! A login shell on the image (`agent-config.sh`, `cmux_claude_set_team_env_aside`) keeps the
//! model plane's `ANTHROPIC_BASE_URL` / `ANTHROPIC_API_KEY` out of the shell, under
//! `CMUX_CLAUDE_TEAM_*`, so the pair never outranks a person's own Claude sign-in. The image's
//! launcher (`/etc/cmux/claude`, `agent-auth.sh` `cmux_claude_apply_auth_mode`) puts it back in team
//! mode. acpmux starts Claude itself, and its login-env import keeps no `CMUX_` name, so a Claude
//! with no sign-in got neither and answered "Not logged in · Please run /login", through the
//! inference gateway too (gateway E2E on development and production, 2026-11-10).
//!
//! [`team_pair`] is that rule for an owner machine with that script (`codex_cloud_auth` has the
//! same one for Codex): `CMUX_CLAUDE_AUTH=own|team` pins it, then `cr use`'s recorded choice; a
//! sign-in of its own keeps own. That is any source `claude_auth::find_in` sees in the launch's
//! effective env (the login values, the vault, `machine.env`, then the profile, as
//! `login_env::effective_for` layers them): a key or token, settings env or a helper, the
//! `.claude.json` API key or the saved sign-in;
//! no `https://` team origin, or one that does not resolve, keeps own. Otherwise team: the pair the
//! shell set aside, read from the model-plane env file it was persisted to, or the origin and the
//! public placeholder. A pair the person set themselves stays.
//!
//! Claude applies its settings files' `env` over its process env, and a `--settings` flag over
//! those (Claude Code 2.1.322: a `settings.json` `ANTHROPIC_AUTH_TOKEN` reached the endpoint next
//! to the pair, and a later `--settings` replaces an earlier one whole). So the launch's own
//! `--settings` counts as a sign-in source ([`flag_settings`]), and team mode ([`apply_team`])
//! ends the command line with one `--settings`, the launch's own merged with the pair and
//! [`TEAM_CLEARS`] set empty, so no user, project or local settings file moves the endpoint or
//! adds a credential. The image's launcher does the same (`cmux-claude`).

use std::collections::BTreeMap;
use std::path::Path;

use serde_json::{Map, Value};

use crate::codex_cloud_auth::{Inputs, PLACEHOLDER_KEY};

/// The model-plane pair to add to a Claude launch in team mode, or None (own mode, a pair already
/// set, or not an owner Cloud image). `env` is the launch's effective env (`inputs.var` reads the
/// same), `cwd` its project for project settings, and `resolves` answers whether the team
/// origin's host resolves.
/// `flag` is the launch's own `--settings` ([`flag_settings`]).
pub async fn team_pair<F, Fut>(
    inputs: &Inputs<'_>,
    env: &BTreeMap<String, String>,
    flag: Option<&Map<String, Value>>,
    cwd: &Path,
    resolves: F,
) -> Option<[(String, String); 2]>
where
    F: FnOnce(String) -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    if !inputs.owner_cloud_image() {
        return None;
    }
    let var = |k: &str| (inputs.var)(k).filter(|v| !v.is_empty());
    // The flag settings' env, which Claude applies over the process env.
    let flag_env: BTreeMap<String, String> = flag
        .and_then(|s| s.get("env"))
        .and_then(Value::as_object)
        .map(|e| e.iter().filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_owned()))).collect())
        .unwrap_or_default();
    let set = |k: &str| var(k).is_some() || flag_env.get(k).is_some_and(|v| !v.is_empty());
    // A pair in the launch already (the person's, or a route's) wins, as in the launcher.
    if set("ANTHROPIC_BASE_URL") || set("ANTHROPIC_API_KEY") {
        return None;
    }
    let pinned = match var("CMUX_CLAUDE_AUTH").as_deref().map(str::trim) {
        Some("own") => return None,
        Some("team") => true,
        _ => false,
    };
    if !pinned {
        match inputs.choice_for("claude") {
            Some("own") => return None,
            Some(_) => {}
            None => {
                let mut env = env.clone();
                env.entry("HOME".to_owned())
                    .or_insert_with(|| inputs.home.to_string_lossy().into_owned());
                env.extend(flag_env.clone());
                let flag_helper = flag.is_some_and(|s| {
                    HELPERS.iter().any(|h| s.get(*h).is_some_and(|v| v.as_str() != Some("")))
                });
                if flag_helper || crate::claude_auth::find_in(&env, cwd).signed_in() {
                    return None;
                }
            }
        }
    }
    let origin = inputs.team_origin()?;
    let host = origin.trim_start_matches("https://").split(['/', '?', '#']).next()?.to_owned();
    if host.is_empty() || !resolves(host).await {
        return None;
    }
    let base = inputs.model_plane_var("ANTHROPIC_BASE_URL").unwrap_or_else(|| origin.clone());
    let key =
        inputs.model_plane_var("ANTHROPIC_API_KEY").unwrap_or_else(|| PLACEHOLDER_KEY.to_owned());
    Some([("ANTHROPIC_BASE_URL".to_owned(), base), ("ANTHROPIC_API_KEY".to_owned(), key)])
}

/// The credentials and provider switches team mode must not keep, as the image's launcher clears
/// them for a shared machine (`agent-auth.sh`): a personal token next to the pair would be sent to
/// the team's endpoint (`ANTHROPIC_AUTH_TOKEN` outranks `ANTHROPIC_API_KEY`), and a provider switch
/// would route the launch away from it. `ANTHROPIC_CUSTOM_HEADERS` keeps only its usage attribution
/// lines ([`cmux_headers`]).
pub(crate) const TEAM_CLEARS: [&str; 6] = [
    "ANTHROPIC_AUTH_TOKEN",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "ANTHROPIC_CUSTOM_HEADERS",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
];

/// The profile-env marker of a team-mode launch, for the remote chain's settings; never in the
/// child's env (`agent/command.rs` removes it).
pub(crate) const TEAM_MARKER: &str = "ACPMUX_CLAUDE_TEAM_PLANE";

/// The extra request headers team mode keeps: the usage attribution lines (`x-cmux-workspace-id`,
/// `x-cmux-surface-id`; `agent-config.sh` sets them in every cmux terminal), never a person's own.
pub(crate) const HEADERS: &str = "ANTHROPIC_CUSTOM_HEADERS";

/// The `x-cmux-*` lines of a `ANTHROPIC_CUSTOM_HEADERS` value, one per line.
pub(crate) fn cmux_headers(value: &str) -> String {
    value
        .lines()
        .filter(|l| l.trim_start().to_ascii_lowercase().starts_with("x-cmux-"))
        .collect::<Vec<_>>()
        .join("\n")
}

/// The team pair of a profile env [`apply_team`] marked, or None.
pub(crate) fn marked_pair(env: &BTreeMap<String, String>) -> Option<[(String, String); 2]> {
    env.get(TEAM_MARKER)?;
    let get = |k: &str| Some((k.to_owned(), env.get(k)?.clone()));
    Some([get("ANTHROPIC_BASE_URL")?, get("ANTHROPIC_API_KEY")?])
}

/// The settings keys that run a credential helper (`claude_auth.rs` counts the same).
const HELPERS: [&str; 3] = ["apiKeyHelper", "awsCredentialExport", "awsAuthRefresh"];

/// The flag settings Claude would read from `argv` (after its program): the value of its last
/// `--settings` (or `--settings=`), inline JSON or a file relative to `cwd`, as Claude takes it.
/// `Ok(None)` without one; `Err` when it cannot be read as a JSON object, so a caller keeps own.
pub(crate) fn flag_settings(
    argv: &[String],
    cwd: &Path,
) -> Result<Option<Map<String, Value>>, String> {
    let Some(value) = settings_args(argv).1 else { return Ok(None) };
    let text = if value.trim_start().starts_with('{') {
        value
    } else {
        let path = cwd.join(&value);
        std::fs::read_to_string(&path).map_err(|e| format!("--settings {}: {e}", path.display()))?
    };
    match serde_json::from_str::<Value>(&text) {
        Ok(Value::Object(map)) => Ok(Some(map)),
        Ok(_) => Err("--settings is not a JSON object".to_owned()),
        Err(e) => Err(format!("--settings: {e}")),
    }
}

/// `argv` without any `--settings` (before a `--`), and the last one's value.
fn settings_args(argv: &[String]) -> (Vec<String>, Option<String>) {
    let mut rest = Vec::with_capacity(argv.len());
    let mut last = None;
    let mut words = argv.iter();
    while let Some(word) = words.next() {
        // Positional words follow `--`: none is a flag.
        if word == "--" {
            rest.push(word.clone());
            rest.extend(words.cloned());
            break;
        }
        if word == "--settings" {
            last = words.next().cloned().or(last);
        } else if let Some(value) = word.strip_prefix("--settings=") {
            last = Some(value.to_owned());
        } else {
            rest.push(word.clone());
        }
    }
    (rest, last)
}

/// The one `--settings` a team-mode launch ends with: `flag` (the launch's own) with the pair
/// and every [`TEAM_CLEARS`] name set empty in its `env`, over any settings file's.
/// `headers` is the launch's `ANTHROPIC_CUSTOM_HEADERS`, of which only [`cmux_headers`] stays.
pub(crate) fn team_settings(
    flag: Option<&Map<String, Value>>,
    pair: &[(String, String); 2],
    headers: &str,
) -> String {
    let mut settings = flag.cloned().unwrap_or_default();
    let env = settings.entry("env").or_insert_with(|| Value::Object(Map::new()));
    if !env.is_object() {
        *env = Value::Object(Map::new());
    }
    if let Value::Object(env) = env {
        for key in TEAM_CLEARS {
            env.insert(key.to_owned(), Value::String(String::new()));
        }
        env.insert(HEADERS.to_owned(), Value::String(cmux_headers(headers)));
        for (k, v) in pair {
            env.insert(k.clone(), Value::String(v.clone()));
        }
    }
    Value::Object(settings).to_string()
}

/// Put team mode in a Claude launch: the pair in the profile env, without [`TEAM_CLEARS`] there,
/// and with them on the list the launch removes from the inherited env (`routes::UNSET_KEY`, read
/// by `agent/command.rs`); and `argv`'s `--settings` replaced by [`team_settings`] at its end, so
/// no settings file adds one either.
/// A remote chain's command line refuses a profile `--settings` and ends with its own
/// (`hub/remote_sandbox.rs`), so `remote` leaves `argv` alone: the chain merges
/// [`team_settings`] into its own when the profile env carries [`TEAM_MARKER`].
pub(crate) fn apply_team(
    env: &mut BTreeMap<String, String>,
    argv: &mut Vec<String>,
    flag: Option<&Map<String, Value>>,
    pair: [(String, String); 2],
    headers: &str,
    remote: bool,
) {
    env.insert(TEAM_MARKER.to_owned(), "1".to_owned());
    let kept = cmux_headers(headers);
    if !remote && !argv.is_empty() {
        let mut rest = settings_args(&argv[1..]).0;
        rest.insert(0, argv[0].clone());
        rest.push("--settings".to_owned());
        rest.push(team_settings(flag, &pair, &kept));
        *argv = rest;
    }
    let mut unset: Vec<String> = env
        .get(crate::routes::UNSET_KEY)
        .map(|list| list.split(',').filter(|k| !k.is_empty()).map(str::to_owned).collect())
        .unwrap_or_default();
    for key in TEAM_CLEARS {
        env.remove(key);
        // The kept usage headers replace the inherited value (the profile env goes on after it);
        // an unset name would remove them too.
        if key == HEADERS && !kept.is_empty() {
            unset.retain(|k| k != key);
            env.insert(key.to_owned(), kept.clone());
        } else if !unset.iter().any(|k| k == key) {
            unset.push(key.to_owned());
        }
    }
    env.insert(crate::routes::UNSET_KEY.to_owned(), unset.join(","));
    env.extend(pair);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU32, Ordering};

    struct Machine {
        root: PathBuf,
        home: PathBuf,
    }

    impl Drop for Machine {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    fn machine(kind: &str) -> Machine {
        static N: AtomicU32 = AtomicU32::new(0);
        let n = N.fetch_add(1, Ordering::SeqCst);
        let root = std::env::temp_dir()
            .join(format!("acpmux-claude-cloud-auth-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("etc/cmux")).unwrap();
        std::fs::write(root.join("etc/cmux/vm-kind"), format!("{kind}\n")).unwrap();
        std::fs::write(root.join("etc/cmux/agent-auth.sh"), "# image\n").unwrap();
        std::fs::write(
            root.join("etc/cmux/model-plane.env"),
            "export CMUX_CODEROUTER_URL='https://coderouter.cmux.internal'\n\
             export ANTHROPIC_BASE_URL='https://coderouter.cmux.internal'\n\
             export ANTHROPIC_API_KEY='cmux-vm-edge-placeholder'\n",
        )
        .unwrap();
        let home = root.join("home");
        std::fs::create_dir_all(home.join(".claude")).unwrap();
        Machine { root, home }
    }

    async fn pair(m: &Machine, var: &[(&str, &str)], dns: bool) -> Option<[(String, String); 2]> {
        let mut env: BTreeMap<String, String> =
            var.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
        env.insert("HOME".to_owned(), m.home.to_string_lossy().into_owned());
        let map = env.clone();
        let var = move |k: &str| map.get(k).cloned();
        let inputs = Inputs { root: &m.root, home: &m.home, var: &var, broker: false };
        team_pair(&inputs, &env, None, &m.home, |_| async move { dns }).await
    }

    #[tokio::test]
    async fn a_claude_with_no_sign_in_gets_the_model_plane_pair() {
        let m = machine("owner");
        let got = pair(&m, &[], true).await.expect("team");
        assert_eq!(
            got[0],
            ("ANTHROPIC_BASE_URL".to_owned(), "https://coderouter.cmux.internal".to_owned())
        );
        assert_eq!(got[1], ("ANTHROPIC_API_KEY".to_owned(), PLACEHOLDER_KEY.to_owned()));
        // The origin does not resolve: team mode could not work, so Claude shows its own sign-in.
        assert_eq!(pair(&m, &[], false).await, None);
    }

    #[tokio::test]
    async fn a_sign_in_a_choice_or_a_persons_pair_keeps_own() {
        let m = machine("owner");
        assert_eq!(pair(&m, &[("ANTHROPIC_API_KEY", "sk-own")], true).await, None);
        assert_eq!(
            pair(&m, &[("ANTHROPIC_BASE_URL", "https://api.example.test")], true).await,
            None
        );
        assert_eq!(pair(&m, &[("CLAUDE_CODE_OAUTH_TOKEN", "t")], true).await, None);
        assert_eq!(pair(&m, &[("CMUX_CLAUDE_AUTH", "own")], true).await, None);
        let dir = m.home.join(".config/cmux/agent-auth");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("claude"), "own\n").unwrap();
        assert_eq!(pair(&m, &[], true).await, None);
        // `cr use team` over a sign-in of its own: team.
        std::fs::write(dir.join("claude"), "team\n").unwrap();
        std::fs::write(m.home.join(".claude/.credentials.json"), r#"{"claudeAiOauth":{"a":1}}"#)
            .unwrap();
        assert!(pair(&m, &[], true).await.is_some());
        // No choice: the sign-in keeps own.
        std::fs::remove_file(dir.join("claude")).unwrap();
        assert_eq!(pair(&m, &[], true).await, None);
        // The env pin wins over it.
        assert!(pair(&m, &[("CMUX_CLAUDE_AUTH", "team")], true).await.is_some());
        std::fs::remove_file(m.home.join(".claude/.credentials.json")).unwrap();
        assert!(pair(&m, &[], true).await.is_some());
        // A key from the vault or `machine.env` is in the effective env: own.
        assert_eq!(pair(&m, &[("ANTHROPIC_AUTH_TOKEN", "t")], true).await, None);
        // Settings credentials and helpers, and the `.claude.json` API key, keep own too.
        std::fs::write(m.home.join(".claude/settings.json"), r#"{"apiKeyHelper":"/bin/key"}"#)
            .unwrap();
        assert_eq!(pair(&m, &[], true).await, None);
        std::fs::remove_file(m.home.join(".claude/settings.json")).unwrap();
        std::fs::write(m.home.join(".claude.json"), r#"{"primaryApiKey":"sk-own"}"#).unwrap();
        assert_eq!(pair(&m, &[], true).await, None);
    }

    fn team_pair_value() -> [(String, String); 2] {
        [
            ("ANTHROPIC_BASE_URL".to_owned(), "https://coderouter.cmux.internal".to_owned()),
            ("ANTHROPIC_API_KEY".to_owned(), PLACEHOLDER_KEY.to_owned()),
        ]
    }

    #[test]
    fn team_mode_clears_personal_credentials_and_keeps_a_routes_list() {
        let mut env = BTreeMap::from([
            ("ANTHROPIC_AUTH_TOKEN".to_owned(), "personal".to_owned()),
            ("CLAUDE_CODE_OAUTH_TOKEN".to_owned(), "personal".to_owned()),
            (crate::routes::UNSET_KEY.to_owned(), "OPENAI_API_KEY".to_owned()),
        ]);
        let mut argv: Vec<String> = ["claude", "--settings", r#"{"model":"opus"}"#, "--verbose"]
            .map(str::to_owned)
            .to_vec();
        let flag = flag_settings(&argv[1..], Path::new("/")).unwrap();
        apply_team(
            &mut env,
            &mut argv,
            flag.as_ref(),
            team_pair_value(),
            "x-personal: 1\nx-cmux-workspace-id: ws-1",
            false,
        );
        // Only the usage attribution header stays, in place of the inherited value.
        assert_eq!(env[HEADERS], "x-cmux-workspace-id: ws-1");
        for key in TEAM_CLEARS.iter().filter(|k| **k != HEADERS) {
            assert!(!env.contains_key(*key));
        }
        let unset: Vec<&str> = env[crate::routes::UNSET_KEY].split(',').collect();
        assert_eq!(unset[0], "OPENAI_API_KEY");
        assert!(TEAM_CLEARS.iter().filter(|k| **k != HEADERS).all(|k| unset.contains(k)));
        assert!(!unset.contains(&HEADERS));
        assert_eq!(env["ANTHROPIC_API_KEY"], PLACEHOLDER_KEY);
        assert_eq!(marked_pair(&env), Some(team_pair_value()));
        // One --settings, last: the launch's own merged with the pair and the clears.
        assert_eq!(argv[..2], ["claude", "--verbose"]);
        assert_eq!(argv.iter().filter(|a| *a == "--settings").count(), 1);
        assert_eq!(argv[argv.len() - 2], "--settings");
        let settings: Value = serde_json::from_str(argv.last().unwrap()).unwrap();
        assert_eq!(settings["model"], "opus");
        assert_eq!(settings["env"]["ANTHROPIC_API_KEY"], PLACEHOLDER_KEY);
        for key in TEAM_CLEARS.iter().filter(|k| **k != HEADERS) {
            assert_eq!(settings["env"][*key], "");
        }
        assert_eq!(settings["env"][HEADERS], "x-cmux-workspace-id: ws-1");
        // A remote chain keeps its argv; its own settings take the pair (remote_sandbox.rs).
        let mut env = BTreeMap::new();
        let mut argv = vec!["claude".to_owned()];
        apply_team(&mut env, &mut argv, None, team_pair_value(), "x-personal: 1", true);
        assert_eq!(argv, ["claude"]);
        assert!(marked_pair(&env).is_some());
        // No usage header: the name goes on the unset list.
        assert!(!env.contains_key(HEADERS));
        assert!(env[crate::routes::UNSET_KEY].split(',').any(|k| k == HEADERS));
    }

    #[test]
    fn flag_settings_reads_the_last_inline_or_file_value() {
        let m = machine("owner");
        let words = |w: &[&str]| w.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
        assert_eq!(flag_settings(&words(&["--verbose"]), &m.home).unwrap(), None);
        let inline = flag_settings(
            &words(&["--settings", r#"{"env":{"A":"1"}}"#, "--settings={\"env\":{\"A\":\"2\"}}"]),
            &m.home,
        )
        .unwrap()
        .unwrap();
        assert_eq!(inline["env"]["A"], "2");
        std::fs::write(m.home.join("s.json"), r#"{"apiKeyHelper":"/bin/key"}"#).unwrap();
        let file = flag_settings(&words(&["--settings", "s.json"]), &m.home).unwrap().unwrap();
        assert_eq!(file["apiKeyHelper"], "/bin/key");
        assert!(flag_settings(&words(&["--settings", "missing.json"]), &m.home).is_err());
        assert!(flag_settings(&words(&["--settings", "[1]"]), &m.home).is_err());
    }

    #[tokio::test]
    async fn a_sign_in_in_the_launchs_own_settings_flag_keeps_own() {
        let m = machine("owner");
        let env = BTreeMap::from([("HOME".to_owned(), m.home.to_string_lossy().into_owned())]);
        let read = env.clone();
        let var = move |k: &str| read.get(k).cloned();
        let inputs = Inputs { root: &m.root, home: &m.home, var: &var, broker: false };
        let flag = |v: Value| v.as_object().cloned();
        let (inputs, home) = (&inputs, m.home.as_path());
        let pair = |f: Option<Map<String, Value>>| {
            let env = env.clone();
            async move { team_pair(inputs, &env, f.as_ref(), home, |_| async { true }).await }
        };
        assert!(pair(None).await.is_some());
        let token = flag(serde_json::json!({"env": {"ANTHROPIC_AUTH_TOKEN": "t"}}));
        assert_eq!(pair(token).await, None);
        let helper = flag(serde_json::json!({"apiKeyHelper": "/bin/key"}));
        assert_eq!(pair(helper).await, None);
        let endpoint = flag(serde_json::json!({"env": {"ANTHROPIC_BASE_URL": "https://x.test"}}));
        assert_eq!(pair(endpoint).await, None);
        // Settings with no credential stay team.
        assert!(pair(flag(serde_json::json!({"model": "opus"}))).await.is_some());
    }

    #[tokio::test]
    async fn only_an_owner_cloud_image_with_a_team_plane() {
        assert_eq!(pair(&machine("team"), &[], true).await, None);
        let m = machine("owner");
        std::fs::write(
            m.root.join("etc/cmux/model-plane.env"),
            "export OPENAI_BASE_URL='https://x/v1'\n",
        )
        .unwrap();
        assert_eq!(pair(&m, &[], true).await, None);
    }
}
