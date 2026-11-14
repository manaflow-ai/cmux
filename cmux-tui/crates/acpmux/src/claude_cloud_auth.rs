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
    // The flag settings' env, which Claude applies over the process env. A JSON `true` or number
    // (`"CLAUDE_CODE_USE_BEDROCK": true`) is the value Claude reads, as the launcher's check
    // (`agent-auth.sh` `cmux_claude_settings_has`) counts it.
    let flag_env: BTreeMap<String, String> = flag
        .and_then(|s| s.get("env"))
        .and_then(Value::as_object)
        .map(|e| {
            e.iter()
                .filter_map(|(k, v)| {
                    let v = match v {
                        Value::String(s) => s.clone(),
                        Value::Bool(b) => b.to_string(),
                        Value::Number(n) => n.to_string(),
                        _ => return None,
                    };
                    Some((k.clone(), v))
                })
                .collect()
        })
        .unwrap_or_default();
    let set = |k: &str| var(k).is_some() || flag_env.get(k).is_some_and(|v| !v.is_empty());
    // A pair in the launch already (the person's, or a route's) wins, as in the launcher.
    if set("ANTHROPIC_BASE_URL") || set("ANTHROPIC_API_KEY") {
        return None;
    }
    // Managed settings outrank every `--settings`, so team mode cannot empty a credential there:
    // keep own mode, whatever was chosen, rather than send it to the team endpoint.
    if managed_credential(&inputs.root.join(MANAGED_SETTINGS)) {
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
                // A personal endpoint in a settings file (a proxy that signs requests itself)
                // is the person's too, as one in the env or the flag is above.
                let found = crate::claude_auth::find_in(&env, cwd);
                if flag_helper || found.signed_in() || found.endpoint.is_some() {
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

/// Claude's managed settings on Linux, under the machine root.
const MANAGED_SETTINGS: &str = "etc/claude-code/managed-settings.json";

/// Whether the managed settings at `path` name a credential, endpoint, provider switch or
/// helper. Claude applies them over every other source, `--settings` included, so team mode
/// could not clear one. A file that exists but does not read counts (fail safe: own mode).
fn managed_credential(path: &Path) -> bool {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(e) => return e.kind() != std::io::ErrorKind::NotFound,
    };
    let Ok(Value::Object(settings)) = serde_json::from_str::<Value>(&text) else {
        return true;
    };
    let on = |v: &Value| match v {
        Value::String(s) => {
            let s = s.trim();
            !s.is_empty() && s != "0" && !s.eq_ignore_ascii_case("false")
        }
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().is_some_and(|f| f != 0.0),
        _ => false,
    };
    let mut keys = ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL"]
        .into_iter()
        .chain(TEAM_CLEARS.into_iter().filter(|k| *k != HEADERS));
    let env = settings.get("env").and_then(Value::as_object);
    keys.any(|k| env.and_then(|e| e.get(k)).is_some_and(on))
        || HELPERS.iter().any(|h| settings.get(*h).is_some_and(on))
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

/// Whether `argv` starts Claude Code itself, not a launcher that picks Claude's provider on its
/// own (`claude-sr`'s `sr claude proxy`, `claude-cr`'s `cr <route>`, any wrapper of that kind).
/// Team mode is only for the former: its `--settings` env outranks the env such a launcher
/// exports, so it would send a route the person chose to the team's model plane.
pub(crate) fn launches_claude_itself(argv: &[String]) -> bool {
    argv.first()
        .and_then(|program| Path::new(program).file_name())
        .is_some_and(|name| name == "claude")
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
    // No personal credential helper answers the team endpoint, whatever a settings file names;
    // the pair's key alone does not guarantee that.
    for helper in HELPERS {
        settings.insert(helper.to_owned(), Value::String(String::new()));
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
    if !remote && let Some((program, args)) = argv.split_first() {
        let mut rest = settings_args(args).0;
        rest.insert(0, program.clone());
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
mod tests;
