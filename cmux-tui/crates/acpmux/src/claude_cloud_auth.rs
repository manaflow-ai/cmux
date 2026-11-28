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
//! `login_env::effective_for` layers them; for a remote-origin launch, which gets none of those,
//! only the host base and the profile: [`launch_env_now`]): a key or token, settings env or a
//! helper, the `.claude.json` API key or the saved sign-in;
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

/// Persisted in the session env by the owner start RPC, separate from a profile's team preference.
pub(crate) const REQUIRED_TEAM: &str = "ACPMUX_CLAUDE_TEAM_REQUIRED";

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
    if !inputs.owner_cloud_image() || !chooses_team(inputs, env, flag, cwd, true) {
        return None;
    }
    let origin = inputs.team_origin()?;
    let base = inputs.model_plane_var("ANTHROPIC_BASE_URL").unwrap_or_else(|| origin.clone());
    let key =
        inputs.model_plane_var("ANTHROPIC_API_KEY").unwrap_or_else(|| PLACEHOLDER_KEY.to_owned());
    cloud_pair(origin, base, key, resolves).await
}

/// An explicit Cloud start uses the image's team plane even if the profile carries a personal key.
/// Managed settings can outrank our settings flag, so refuse if they control provider selection.
pub(crate) async fn required_team_pair<F, Fut>(
    inputs: &Inputs<'_>,
    resolves: F,
) -> Option<[(String, String); 2]>
where
    F: FnOnce(String) -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    if !inputs.root.join("etc/cmux/agent-auth.sh").is_file()
        || managed_provider_override(inputs.root)
    {
        return None;
    }
    let path = inputs.root.join("etc/cmux/model-plane.env");
    let owner = inputs.owner_cloud_image();
    let var = |key| {
        if owner {
            inputs.model_plane_var(key)
        } else {
            crate::codex_cloud_auth::file_var(&path, key)
        }
    };
    let origin = var("CMUX_CODEROUTER_URL").filter(|origin| origin.starts_with("https://"))?;
    let base = var("ANTHROPIC_BASE_URL").unwrap_or_else(|| origin.clone());
    let key = var("ANTHROPIC_API_KEY").unwrap_or_else(|| PLACEHOLDER_KEY.to_owned());
    cloud_pair(origin, base, key, resolves).await
}

async fn cloud_pair<F, Fut>(
    origin: String,
    base: String,
    key: String,
    resolves: F,
) -> Option<[(String, String); 2]>
where
    F: FnOnce(String) -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    let host = origin.trim_start_matches("https://").split(['/', '?', '#']).next()?.to_owned();
    if host.is_empty() || !resolves(host).await {
        return None;
    }
    Some([("ANTHROPIC_BASE_URL".to_owned(), base), ("ANTHROPIC_API_KEY".to_owned(), key)])
}

/// Claude team mode on a machine joined to the cmux hub that is not a Cloud image
/// (`joined_model_plane.rs`): [`team_pair`]'s rules, but with no pin or `cr use` choice it stays
/// own. `join` is the machine's join now (`joined_model_plane::now`); `resolves` answers whether
/// the hub's host resolves. The pair is the hub origin and the public placeholder key; the
/// machine credential goes in a header the egress proxy fills (`joined_model_plane::claude_headers`).
pub async fn joined_pair<F, Fut>(
    inputs: &Inputs<'_>,
    env: &BTreeMap<String, String>,
    flag: Option<&Map<String, Value>>,
    cwd: &Path,
    join: Option<&crate::joined_model_plane::Join>,
    resolves: F,
) -> Option<[(String, String); 2]>
where
    F: FnOnce(String) -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    let join = join.filter(|_| !inputs.owner_cloud_image())?;
    if !chooses_team(inputs, env, flag, cwd, false) || !resolves(join.host().to_owned()).await {
        return None;
    }
    Some([
        ("ANTHROPIC_BASE_URL".to_owned(), join.origin().to_owned()),
        ("ANTHROPIC_API_KEY".to_owned(), PLACEHOLDER_KEY.to_owned()),
    ])
}

/// Why a joined launch that chose team still keeps own on purpose: a pair it sets itself, a
/// managed credential, or an `own` pin over the choice ([`joined_pair`]'s rules before the hub's
/// host is resolved). None: a [`joined_pair`] of None means the host did not resolve.
pub(crate) fn joined_own_reason(
    inputs: &Inputs<'_>,
    env: &BTreeMap<String, String>,
    flag: Option<&Map<String, Value>>,
    cwd: &Path,
) -> Option<&'static str> {
    team_or_own(inputs, env, flag, cwd, false).err()
}

/// Whether a Claude launch on a joined machine has nothing to sign in with: no
/// `CMUX_CLAUDE_AUTH` pin, no `cr use` choice, and no sign-in of its own, the one a Cloud image
/// would send to its team plane ([`chooses_team`]'s unchosen rule). The joined plane is opt-in,
/// so this launch would reach Claude's own host with no credential.
pub(crate) fn joined_without_sign_in(
    inputs: &Inputs<'_>,
    env: &BTreeMap<String, String>,
    flag: Option<&Map<String, Value>>,
    cwd: &Path,
) -> bool {
    let pinned =
        matches!((inputs.var)("CMUX_CLAUDE_AUTH").as_deref().map(str::trim), Some("own" | "team"));
    !pinned && inputs.choice_for("claude").is_none() && chooses_team(inputs, env, flag, cwd, true)
}

/// Whether a Claude launch takes a team plane (module docs; [`team_pair`] and [`joined_pair`]):
/// never over a pair the launch sets or a managed credential; then `CMUX_CLAUDE_AUTH=own|team`,
/// then `cr use`'s choice; with neither, `unchosen_team` and no sign-in of its own.
fn chooses_team(
    inputs: &Inputs<'_>,
    env: &BTreeMap<String, String>,
    flag: Option<&Map<String, Value>>,
    cwd: &Path,
    unchosen_team: bool,
) -> bool {
    team_or_own(inputs, env, flag, cwd, unchosen_team).is_ok()
}

/// [`chooses_team`] with the reason a launch keeps own, in words for a log.
fn team_or_own(
    inputs: &Inputs<'_>,
    env: &BTreeMap<String, String>,
    flag: Option<&Map<String, Value>>,
    cwd: &Path,
    unchosen_team: bool,
) -> Result<(), &'static str> {
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
    if set("ANTHROPIC_BASE_URL") {
        return Err("the launch sets ANTHROPIC_BASE_URL itself");
    }
    if set("ANTHROPIC_API_KEY") {
        return Err("the launch sets ANTHROPIC_API_KEY itself");
    }
    // Managed settings outrank every `--settings`, so team mode cannot empty a credential there:
    // keep own mode, whatever was chosen, rather than send it to the team endpoint.
    if managed_credential(&inputs.root.join(MANAGED_SETTINGS)) {
        return Err("a managed settings file holds a credential");
    }
    let pinned = match var("CMUX_CLAUDE_AUTH").as_deref().map(str::trim) {
        Some("own") => return Err("CMUX_CLAUDE_AUTH pins own"),
        Some("team") => true,
        _ => false,
    };
    if !pinned {
        match inputs.choice_for("claude") {
            Some("own") => return Err("the recorded choice is own"),
            Some(_) => {}
            None if !unchosen_team => return Err("no choice is recorded"),
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
                    return Err("the launch has a sign-in of its own");
                }
            }
        }
    }
    Ok(())
}

/// The env Claude's sign-in check reads for one launch with the resolved profile env `profile`,
/// over the daemon's own env `daemon` (less `machine.env`'s names), the vault's entries `vault`
/// and `machine.env`'s values `machine` (`provider_cloud_auth::LaunchEnv::new`). A `remote`
/// (remote-origin) launch starts from the fixed host base `daemon` and its profile only, so a
/// vault or `machine.env` value is no sign-in of its own (#43821).
#[cfg(test)]
pub(crate) fn launch_env(
    profile: BTreeMap<String, String>,
    daemon: BTreeMap<String, String>,
    vault: Vec<(String, String)>,
    machine: BTreeMap<String, String>,
    remote: bool,
) -> BTreeMap<String, String> {
    crate::provider_cloud_auth::LaunchEnv::new(
        "claude",
        profile,
        daemon,
        vault,
        machine,
        Vec::new(),
        remote,
    )
    .into_env()
}

/// The env Claude's sign-in check reads for one launch (`hub/spawn.rs`): this daemon's env, vault
/// and `machine.env` now under the resolved profile, or for a `remote` launch only the host base
/// it starts from and the profile (`provider_cloud_auth::LaunchEnv::now`; tests: `launch_env`).
pub(crate) fn launch_env_now(
    profile: BTreeMap<String, String>,
    remote: bool,
) -> BTreeMap<String, String> {
    crate::provider_cloud_auth::LaunchEnv::now("claude", profile, remote).into_env()
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

/// Managed provider settings outrank the endpoint's launch environment.
pub(crate) fn managed_provider_override(root: &Path) -> bool {
    managed_credential(&root.join(MANAGED_SETTINGS))
}

/// Keep the endpoint credential's launch independent of file and profile settings.
pub(crate) fn isolate_endpoint_settings(argv: &mut Vec<String>) {
    let Some((program, args)) = argv.split_first() else { return };
    let mut isolated = vec![program.clone(), "--setting-sources".to_owned(), String::new()];
    let (args, _) = settings_args(args);
    let mut words = args.into_iter();
    while let Some(word) = words.next() {
        if word == "--setting-sources" {
            words.next();
        } else if word == "--" {
            isolated.push(word);
            isolated.extend(words);
            break;
        } else if !word.starts_with("--setting-sources=") {
            isolated.push(word);
        }
    }
    *argv = isolated;
}

/// Start on the CLI's machine-wide account, clearing credentials from the profile, inherited
/// environment and Claude settings. The OAuth store remains in the same home as auth status.
pub(crate) fn apply_machine_login(
    env: &mut BTreeMap<String, String>,
    argv: &mut Vec<String>,
    mut account: BTreeMap<String, String>,
    generated_settings: Option<&Map<String, Value>>,
) -> bool {
    let at = argv.iter().position(|arg| arg == "--").unwrap_or(argv.len());
    // Claude takes only the last flag. Keep file settings in place, including policy rules,
    // and refuse a launch that would require copying an existing flag's settings into argv.
    if argv[..at].iter().any(|arg| arg == "--settings" || arg.starts_with("--settings=")) {
        return false;
    }
    let clears = [
        ("ANTHROPIC_BASE_URL".to_owned(), String::new()),
        ("ANTHROPIC_API_KEY".to_owned(), String::new()),
    ];
    argv.splice(at..at, ["--settings".to_owned(), team_settings(generated_settings, &clears, "")]);
    let unset = TEAM_CLEARS
        .into_iter()
        .chain([
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_BASE_URL",
            "CMUX_CLAUDE_TEAM_API_KEY",
            "CMUX_CLAUDE_TEAM_BASE_URL",
            "HOME",
            "CLAUDE_CONFIG_DIR",
            TEAM_MARKER,
            crate::routes::NAME_KEY,
            crate::routes::PROFILE_ROUTE_KEY,
            crate::byo_endpoint::OWN_ENDPOINT_KEY,
        ])
        .chain(env.get(crate::routes::UNSET_KEY).into_iter().flat_map(|list| list.split(',')))
        .filter(|key| !key.is_empty())
        .map(str::to_owned)
        .collect();
    account.insert("CMUX_CLAUDE_AUTH".into(), "own".into());
    crate::routes::apply(env, &crate::routes::RouteEnv { set: account, unset });
    true
}

/// The key itself stays in the process environment. The last settings overlay
/// pins the official origin and disables competing credential sources.
pub(crate) fn isolate_api_key_settings(argv: &mut Vec<String>) {
    isolate_endpoint_settings(argv);
    let at = argv.iter().position(|arg| arg == "--").unwrap_or(argv.len());
    argv.splice(at..at, ["--settings".to_owned(), api_key_settings(None)]);
}

pub(crate) fn api_key_settings(settings: Option<&Map<String, Value>>) -> String {
    team_settings(
        settings,
        &[
            ("ANTHROPIC_BASE_URL".to_owned(), "https://api.anthropic.com".to_owned()),
            ("CLAUDE_CODE_USE_BEDROCK".to_owned(), String::new()),
        ],
        "",
    )
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

/// Whether the last settings flag references a file.
pub(crate) fn has_file_flag_settings(argv: &[String]) -> bool {
    settings_args(argv).1.is_some_and(|value| !value.trim_start().starts_with('{'))
}

/// `argv` without any `--settings` (before a `--`): the rest of its words, in order.
pub(crate) fn without_settings(argv: &[String]) -> Vec<String> {
    settings_args(argv).0
}

/// `argv` without any `--settings` (before a `--`), and the last one's value.
pub(crate) fn settings_args(argv: &[String]) -> (Vec<String>, Option<String>) {
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
    Value::Object(team_settings_map(flag, pair, headers)).to_string()
}

/// Check only the parts of a settings file that survive the team overlay.
pub(crate) fn team_settings_would_copy_secret(flag: &Map<String, Value>) -> bool {
    let blank_pair = [
        ("ANTHROPIC_BASE_URL".to_owned(), String::new()),
        ("ANTHROPIC_API_KEY".to_owned(), String::new()),
    ];
    let settings = Value::Object(team_settings_map(Some(flag), &blank_pair, ""));
    contains_settings_secret(&settings, false)
}

fn contains_settings_secret(value: &Value, sensitive: bool) -> bool {
    match value {
        Value::Object(fields) => fields.iter().any(|(key, value)| {
            !crate::secret_scan::find(key).is_empty()
                || contains_settings_secret(
                    value,
                    sensitive
                        || crate::config::profiles::secret_looking(key)
                        || key.eq_ignore_ascii_case("headers"),
                )
        }),
        Value::Array(items) => items.iter().any(|item| contains_settings_secret(item, sensitive)),
        Value::String(text) => {
            !text.trim().is_empty() && (sensitive || !crate::secret_scan::find(text).is_empty())
        }
        Value::Number(_) => sensitive,
        Value::Null | Value::Bool(_) => false,
    }
}

fn team_settings_map(
    flag: Option<&Map<String, Value>>,
    pair: &[(String, String); 2],
    headers: &str,
) -> Map<String, Value> {
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
    settings
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
        let at = rest.iter().position(|arg| arg == "--").unwrap_or(rest.len());
        rest.splice(at..at, ["--settings".to_owned(), team_settings(flag, &pair, &kept)]);
        rest.insert(0, program.clone());
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
#[path = "claude_cloud_auth_tests.rs"]
mod tests;
