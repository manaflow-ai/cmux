//! Codex's sign-in mode on a cmux Cloud machine, for the launches acpmux makes itself.
//!
//! The image's `agent-config.sh` writes `~/.codex/config.toml` with `model_provider = "cmux"`: the
//! team's CodeRouter through the machine's TLS edge, `requires_openai_auth = false`. The image's
//! launcher (`/etc/cmux/codex`, through `/etc/cmux/agent-auth.sh` `cmux_codex_apply_auth_mode`)
//! picks team or own at each launch and, for own, starts codex with `-c model_provider="openai"`,
//! the built-in provider that uses `codex login`. The native image ships no launcher: acpmux starts
//! `/opt/cmux/current/bin/codex` itself, so a person's ChatGPT sign-in (the app's copy in
//! `auth.json`, or the Mac broker's access file) was ignored and, with no reachable edge, a turn
//! hung with no error (Cloud chat matrix, 2026-11-10). Leo, 2026-11-10: "I want to be able to have
//! that work for if somebody has a ChatGPT subscription".
//!
//! [`own_reason`] is `agent-auth.sh`'s rule, for an owner machine with that script:
//!   env       `CMUX_CODEX_AUTH=own|team` pins the launch;
//!   chosen    `~/.config/cmux/agent-auth/codex` holds `own` or `team` (`cr use`, the app's
//!             credential transfer, the chat's Sign in card);
//!   login     no choice; Codex has its own sign-in (`auth.json` tokens or key, `CODEX_API_KEY`) or
//!             the Mac broker's access file is installed;
//!   no-team-plane    no `https://` `CMUX_CODEROUTER_URL`: team mode has nowhere to send;
//!   team-unreachable the CodeRouter host does not resolve, so team mode could not work either.
//! Otherwise team. A team machine (vm-kind not `owner`) is left alone: every member is the same
//! Unix user there, and the image's shared-machine mode owns it.
//!
//! [`apply`] then does what the launcher does for own: `-c model_provider="openai"` (only over a
//! config cmux generated) and no model-plane `OPENAI_BASE_URL` / placeholder `OPENAI_API_KEY`, so
//! nothing outranks the person's sign-in and it is never sent to CodeRouter. A signed-out Codex in
//! own mode then fails at once with its own "sign in" error, which the chat shows as its Sign in
//! card, instead of hanging.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// The public placeholder every guest sends (`agent-auth.sh` `cmux_aa_placeholder`).
/// An owner's cmux Cloud machine whose image has the own-or-team script, under `root`.
pub(crate) fn owner_cloud_image_at(root: &Path) -> bool {
    root.join("etc/cmux/agent-auth.sh").is_file()
        && std::fs::read(root.join("etc/cmux/vm-kind"))
            .is_ok_and(|b| String::from_utf8_lossy(b.get(..64).unwrap_or(&b)).trim() == "owner")
}

pub const PLACEHOLDER_KEY: &str = "cmux-vm-edge-placeholder";
/// What the launch gains in own mode.
pub const OWN_PROVIDER_ARGS: [&str; 2] = ["-c", "model_provider=\"openai\""];

/// What the decision reads; every value as the launched codex would see it.
pub struct Inputs<'a> {
    /// The folder `etc/cmux` is read under (`/` outside tests).
    pub root: &'a Path,
    pub home: &'a Path,
    /// Sync: the spawn future holds it across the host lookup.
    pub var: &'a (dyn Fn(&str) -> Option<String> + Sync),
    /// The Mac broker's access file is installed (`codex_auth_file::read`).
    pub broker: bool,
}

impl Inputs<'_> {
    fn codex_home(&self) -> PathBuf {
        (self.var)("CODEX_HOME").map(PathBuf::from).unwrap_or_else(|| self.home.join(".codex"))
    }

    pub(crate) fn owner_cloud_image(&self) -> bool {
        owner_cloud_image_at(self.root)
    }

    fn choice(&self) -> Option<&'static str> {
        self.choice_for("codex")
    }

    /// The mode `cr use` recorded for `agent` (`~/.config/cmux/agent-auth/<agent>`).
    pub(crate) fn choice_for(&self, agent: &str) -> Option<&'static str> {
        let text =
            std::fs::read_to_string(self.home.join(".config/cmux/agent-auth").join(agent)).ok()?;
        mode(text.lines().next().unwrap_or(""))
    }

    fn own_login(&self) -> bool {
        (self.var)("CODEX_API_KEY").is_some()
            || crate::agent_login::signed_in_at(
                crate::agent_login::Agent::Codex,
                &self.codex_home(),
            )
    }

    /// The CodeRouter origin when it is `https://`: the launch's env, else the model-plane env file a
    /// login shell sources ([`Self::model_plane_file`]). The daemon's login-env import keeps no `CMUX_` name, so on a
    /// Cloud machine the env alone never has it, and every Codex with no sign-in was put in own mode
    /// with no login ("no-team-plane"), then failed on its missing `OPENAI_API_KEY`.
    pub(crate) fn team_origin(&self) -> Option<String> {
        (self.var)("CMUX_CODEROUTER_URL")
            .or_else(|| self.model_plane_var("CMUX_CODEROUTER_URL"))
            .filter(|u| u.starts_with("https://"))
    }

    /// `key` from the model-plane env file a login shell sources ([`Self::model_plane_file`]).
    pub(crate) fn model_plane_var(&self, key: &str) -> Option<String> {
        file_var(&self.model_plane_file(), key)
    }

    /// The model-plane env file a login shell sources (`agent-config.sh`): the per-home copy when it
    /// exists, else the image's. Only one is read, so a per-home file with no (or an empty) origin
    /// never falls through to the image's origin.
    fn model_plane_file(&self) -> PathBuf {
        let home = self.home.join(".config/cmux/model-plane.env");
        if home.is_file() { home } else { self.root.join(MODEL_PLANE_ENV) }
    }

    /// Whether `config.toml` is the one cmux generated (`model_provider = "cmux"`).
    pub fn cmux_config(&self) -> bool {
        std::fs::read_to_string(self.codex_home().join("config.toml"))
            .is_ok_and(|t| t.lines().any(|l| l.trim_end() == "model_provider = \"cmux\""))
    }
}

/// The image's model-plane env file, under `Inputs::root`.
const MODEL_PLANE_ENV: &str = "etc/cmux/model-plane.env";

/// One `export KEY='value'` (or `KEY=value`) line's value from a model-plane env file, unquoted;
/// None when the file or the key is missing or the value is empty.
fn file_var(path: &Path, key: &str) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    text.lines().rev().find_map(|line| {
        let line = line.trim();
        let rest = line.strip_prefix("export ").unwrap_or(line).trim_start();
        let value = rest.strip_prefix(key)?.strip_prefix('=')?.trim();
        let value = value
            .strip_prefix('\'')
            .and_then(|v| v.strip_suffix('\''))
            .or_else(|| value.strip_prefix('"').and_then(|v| v.strip_suffix('"')))
            .unwrap_or(value);
        (!value.is_empty()).then(|| value.to_owned())
    })
}

fn mode(value: &str) -> Option<&'static str> {
    match value.trim() {
        "own" => Some("own"),
        "team" => Some("team"),
        _ => None,
    }
}

/// Own mode's reason (module docs), or None for team or a machine this rule does not cover.
/// `resolves` answers whether the CodeRouter host resolves; it runs only when nothing else decides.
pub async fn own_reason<F, Fut>(inputs: &Inputs<'_>, resolves: F) -> Option<&'static str>
where
    F: FnOnce(String) -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    if !inputs.owner_cloud_image() {
        return None;
    }
    if let Some(m) = (inputs.var)("CMUX_CODEX_AUTH").as_deref().and_then(mode) {
        return (m == "own").then_some("env");
    }
    if let Some(m) = inputs.choice() {
        return (m == "own").then_some("chosen");
    }
    if inputs.own_login() || inputs.broker {
        return Some("login");
    }
    let Some(origin) = inputs.team_origin() else { return Some("no-team-plane") };
    let host = origin
        .trim_start_matches("https://")
        .split(['/', '?', '#'])
        .next()
        .unwrap_or("")
        .to_owned();
    if host.is_empty() || !resolves(host).await {
        return Some("team-unreachable");
    }
    None
}

/// The longest `host_resolves` waits for the resolver: a hang breaker only. A resolver still
/// coming up on a fresh machine answers in its own time (its own retries and timeouts), so a slow
/// answer is waited for rather than read as unreachable, which would switch Codex to own mode.
const RESOLVE_DEADLINE: std::time::Duration = std::time::Duration::from_secs(30);

/// Whether `host` resolves (`agent-auth.sh` treats curl's exit 6 as unreachable); a resolver that
/// gives no answer by `RESOLVE_DEADLINE` counts as unreachable.
pub async fn host_resolves(host: String) -> bool {
    let target = if host.contains(':') { host } else { format!("{host}:443") };
    let lookup = tokio::time::timeout(RESOLVE_DEADLINE, tokio::net::lookup_host(target));
    match lookup.await {
        Ok(Ok(mut addrs)) => addrs.next().is_some(),
        _ => false,
    }
}

/// Own mode for one codex launch (module docs): the provider override right after the program, and
/// the model-plane OpenAI pair out of the profile env and the inherited env (`routes::UNSET_KEY`).
/// A value the person set (any other base URL or key) stays.
pub fn apply(
    argv: &mut Vec<String>,
    env: &mut BTreeMap<String, String>,
    var: &dyn Fn(&str) -> Option<String>,
    cmux_config: bool,
) {
    if cmux_config && !argv.iter().any(|a| a.starts_with("model_provider=")) && !argv.is_empty() {
        for (i, a) in OWN_PROVIDER_ARGS.iter().enumerate() {
            argv.insert(1 + i, (*a).to_owned());
        }
    }
    let origin = var("CMUX_CODEROUTER_URL").map(|o| o.trim_end_matches('/').to_owned());
    let key = var("OPENAI_API_KEY");
    let placeholder = key.as_deref() == Some(PLACEHOLDER_KEY);
    let mut drop = Vec::new();
    if let Some(url) = var("OPENAI_BASE_URL") {
        let plane = match origin.as_deref().filter(|o| !o.is_empty()) {
            Some(o) => url.trim_end_matches('/') == format!("{o}/v1"),
            None => placeholder,
        };
        if plane {
            drop.push("OPENAI_BASE_URL");
        }
    }
    if placeholder {
        drop.push("OPENAI_API_KEY");
    }
    if drop.is_empty() {
        return;
    }
    let mut unset: Vec<String> = env
        .get(crate::routes::UNSET_KEY)
        .map(|l| l.split(',').filter(|k| !k.is_empty()).map(str::to_owned).collect())
        .unwrap_or_default();
    for k in drop {
        env.remove(k);
        if !unset.iter().any(|u| u == k) {
            unset.push(k.to_owned());
        }
    }
    env.insert(crate::routes::UNSET_KEY.to_owned(), unset.join(","));
}

#[cfg(test)]
mod tests;
