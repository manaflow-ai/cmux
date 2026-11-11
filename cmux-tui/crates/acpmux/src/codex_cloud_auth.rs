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

/// Whether `host` resolves within two seconds (`agent-auth.sh` treats curl's exit 6 as unreachable).
pub async fn host_resolves(host: String) -> bool {
    let target = if host.contains(':') { host } else { format!("{host}:443") };
    let lookup =
        tokio::time::timeout(std::time::Duration::from_secs(2), tokio::net::lookup_host(target));
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
mod tests {
    use super::*;
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

    fn machine(kind: Option<&str>, script: bool) -> Machine {
        static N: AtomicU32 = AtomicU32::new(0);
        let n = N.fetch_add(1, Ordering::SeqCst);
        let root = std::env::temp_dir()
            .join(format!("acpmux-codex-cloud-auth-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("etc/cmux")).unwrap();
        if let Some(kind) = kind {
            std::fs::write(root.join("etc/cmux/vm-kind"), format!("{kind}\n")).unwrap();
        }
        if script {
            std::fs::write(root.join("etc/cmux/agent-auth.sh"), "# image\n").unwrap();
        }
        let home = root.join("home");
        std::fs::create_dir_all(home.join(".codex")).unwrap();
        std::fs::write(
            home.join(".codex/config.toml"),
            "model_provider = \"cmux\"\n\n[model_providers.cmux]\nrequires_openai_auth = false\n",
        )
        .unwrap();
        Machine { root, home }
    }

    fn vars(pairs: &[(&str, &str)]) -> Box<dyn Fn(&str) -> Option<String> + Sync> {
        let map: BTreeMap<String, String> =
            pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
        Box::new(move |k: &str| map.get(k).cloned().filter(|v| !v.is_empty()))
    }

    async fn reason(
        m: &Machine,
        var: &(dyn Fn(&str) -> Option<String> + Sync),
        broker: bool,
        dns: bool,
    ) -> Option<&'static str> {
        let inputs = Inputs { root: &m.root, home: &m.home, var, broker };
        own_reason(&inputs, |_| async move { dns }).await
    }

    const TEAM: &[(&str, &str)] = &[("CMUX_CODEROUTER_URL", "https://coderouter.cmux.internal")];

    #[tokio::test]
    async fn the_image_rule_picks_own_or_team() {
        let m = machine(Some("owner"), true);
        // A team plane that resolves, no sign-in: team, as the launcher.
        assert_eq!(reason(&m, &vars(TEAM), false, true).await, None);
        // It does not resolve: team mode could not work (the 2026-11-10 hang).
        assert_eq!(reason(&m, &vars(TEAM), false, false).await, Some("team-unreachable"));
        // No team plane at all.
        assert_eq!(reason(&m, &vars(&[]), false, true).await, Some("no-team-plane"));
        // The Mac broker's access file, or the app's copy of `codex login`.
        assert_eq!(reason(&m, &vars(TEAM), true, true).await, Some("login"));
        std::fs::write(m.home.join(".codex/auth.json"), r#"{"tokens":{"access_token":"t"}}"#)
            .unwrap();
        assert_eq!(reason(&m, &vars(TEAM), false, true).await, Some("login"));
        // A recorded choice wins over the sign-in, and the env pin over both.
        let dir = m.home.join(".config/cmux/agent-auth");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("codex"), "team\n").unwrap();
        assert_eq!(reason(&m, &vars(TEAM), true, true).await, None);
        std::fs::write(dir.join("codex"), "own\n").unwrap();
        assert_eq!(reason(&m, &vars(TEAM), false, true).await, Some("chosen"));
        let pinned = [TEAM[0], ("CMUX_CODEX_AUTH", "team")];
        assert_eq!(reason(&m, &vars(&pinned), false, true).await, None);
    }

    #[tokio::test]
    async fn the_team_plane_comes_from_the_model_plane_file_too() {
        // The daemon's env has no CMUX_ name: the login shell's model-plane file says where the plane is.
        let m = machine(Some("owner"), true);
        std::fs::write(
            m.root.join(MODEL_PLANE_ENV),
            "# generated by cmux\nexport OPENAI_BASE_URL='https://coderouter.cmux.internal/v1'\n\
             export CMUX_CODEROUTER_URL='https://coderouter.cmux.internal'\n",
        )
        .unwrap();
        assert_eq!(reason(&m, &vars(&[]), false, true).await, None);
        // The per-home file (a boot env agent-config.sh persisted) replaces the image's.
        let dir = m.home.join(".config/cmux");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("model-plane.env"), "export CMUX_CODEROUTER_URL='http://plain'\n")
            .unwrap();
        assert_eq!(reason(&m, &vars(&[]), false, true).await, Some("no-team-plane"));
        // A per-home file with an empty or no origin is the one the shell reads: no image fallback.
        std::fs::write(dir.join("model-plane.env"), "export CMUX_CODEROUTER_URL=''\n").unwrap();
        assert_eq!(reason(&m, &vars(&[]), false, true).await, Some("no-team-plane"));
        std::fs::write(dir.join("model-plane.env"), "export OPENAI_BASE_URL='https://x/v1'\n")
            .unwrap();
        assert_eq!(reason(&m, &vars(&[]), false, true).await, Some("no-team-plane"));
        std::fs::write(dir.join("model-plane.env"), "export CMUX_CODEROUTER_URL='https://plane'\n")
            .unwrap();
        assert_eq!(reason(&m, &vars(&[]), false, true).await, None);
    }

    #[tokio::test]
    async fn only_an_owner_cloud_image() {
        // A team machine: shared-machine mode is the image's, never an own sign-in.
        let team = machine(Some("team"), true);
        assert_eq!(reason(&team, &vars(&[]), true, false).await, None);
        // Unreadable or missing vm-kind fails closed.
        let unknown = machine(None, true);
        assert_eq!(reason(&unknown, &vars(&[]), true, false).await, None);
        // Not a cmux Cloud image (a Mac, any other Linux box).
        let plain = machine(Some("owner"), false);
        assert_eq!(reason(&plain, &vars(&[]), true, false).await, None);
    }

    #[test]
    fn own_mode_switches_the_provider_and_drops_the_model_plane() {
        let var = vars(&[
            ("CMUX_CODEROUTER_URL", "https://coderouter.cmux.internal/"),
            ("OPENAI_BASE_URL", "https://coderouter.cmux.internal/v1"),
            ("OPENAI_API_KEY", PLACEHOLDER_KEY),
        ]);
        let mut argv = vec!["/opt/cmux/current/bin/codex".to_owned(), "app-server".to_owned()];
        let mut env = BTreeMap::from([
            ("OPENAI_API_KEY".to_owned(), PLACEHOLDER_KEY.to_owned()),
            (crate::routes::UNSET_KEY.to_owned(), "ANTHROPIC_API_KEY".to_owned()),
        ]);
        apply(&mut argv, &mut env, &var, true);
        assert_eq!(
            argv,
            ["/opt/cmux/current/bin/codex", "-c", "model_provider=\"openai\"", "app-server"]
        );
        // Still the app-server launch the bridge recognizes.
        assert!(crate::codex_app_server::is_profile_launch(&argv));
        assert!(!env.contains_key("OPENAI_API_KEY"));
        assert_eq!(
            env[crate::routes::UNSET_KEY],
            "ANTHROPIC_API_KEY,OPENAI_BASE_URL,OPENAI_API_KEY"
        );
        // Twice is once.
        apply(&mut argv, &mut env, &var, true);
        assert_eq!(argv.len(), 4);
    }

    #[test]
    fn a_persons_own_endpoint_and_config_stay() {
        let var = vars(&[
            ("CMUX_CODEROUTER_URL", "https://coderouter.cmux.internal"),
            ("OPENAI_BASE_URL", "https://api.example.test/v1"),
            ("OPENAI_API_KEY", "sk-own"),
        ]);
        let mut argv = vec!["codex".to_owned(), "app-server".to_owned()];
        let mut env = BTreeMap::new();
        // A config.toml the person wrote: no provider override.
        apply(&mut argv, &mut env, &var, false);
        assert_eq!(argv, ["codex", "app-server"]);
        assert!(env.is_empty());
        // No origin: a base URL with the placeholder key is the model plane's (agent-auth.sh).
        let var =
            vars(&[("OPENAI_BASE_URL", "https://edge/v1"), ("OPENAI_API_KEY", PLACEHOLDER_KEY)]);
        apply(&mut argv, &mut env, &var, true);
        assert_eq!(env[crate::routes::UNSET_KEY], "OPENAI_BASE_URL,OPENAI_API_KEY");
    }

    #[test]
    fn only_cmux_s_generated_config_counts() {
        let m = machine(Some("owner"), true);
        let var = vars(&[]);
        let inputs = Inputs { root: &m.root, home: &m.home, var: &var, broker: false };
        assert!(inputs.cmux_config());
        std::fs::write(m.home.join(".codex/config.toml"), "model_provider = \"azure\"\n").unwrap();
        assert!(!inputs.cmux_config());
    }
}
