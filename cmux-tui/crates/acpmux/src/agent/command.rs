//! The harness command line and environment, as acpmux runs it, for direct
//! children (`agent.rs`) and agent hosts.

use crate::config::HarnessProfile;
use anyhow::{Result, anyhow};
use std::process::Stdio;
use tokio::process::Command;

/// A spawn-only profile marker: remote-origin harnesses start from the
/// explicit base below, never the daemon's ambient environment. Removed
/// before the profile env is applied.
pub(crate) const REMOTE_ENV_POLICY_KEY: &str = "ACPMUX_REMOTE_ENV_POLICY";
/// Recorded with every remote durable host. A changed or missing id means
/// that host predates this process-authority boundary and is not adopted.
pub(crate) const REMOTE_ENV_POLICY_ID: &str = "remote-env-v3";
/// Reserved legacy projection marker. A profile cannot control internal
/// environment projection even if an older config used this valid env name.
const REMOTE_ENV_CLEARED_KEY: &str = "__ACPMUX_REMOTE_ENV_CLEARED";

/// The harness command line and environment, as acpmux runs it: the login
/// environment, no nested-agent markers, the session's `ACPMUX_*` caller
/// context, and the profile's env. Shared by direct children and hosts.
pub(crate) fn harness_command(
    name: &str,
    profile: &HarnessProfile,
    cwd: &std::path::Path,
    command_line: Option<(String, Vec<String>)>,
    session: Option<(&str, &str)>,
) -> Result<Command> {
    // A session's Claude Code (a planned command line) gets cmux's browser
    // and computer use tools and skills (agent_tools.rs); a remote chain's
    // sandboxed plan carries --strict-mcp-config and gets none.
    let claude_session = profile.kind == crate::config::HarnessKind::ClaudeStdio
        && command_line.is_some()
        && session.is_some();
    let owned: (String, Vec<String>) = match command_line {
        Some(c) => c,
        None => {
            let (program, args) = profile
                .argv
                .split_first()
                .ok_or_else(|| anyhow!("agent {name} has an empty argv"))?;
            (program.clone(), args.to_vec())
        }
    };
    if profile.kind == crate::config::HarnessKind::Terminal {
        return Err(anyhow!(
            "{name} is a terminal harness without ACP; open it with `cmux harness run {name}`"
        ));
    }
    let owned = if let (true, Some((session_id, _))) = (claude_session, session) {
        let extra =
            crate::agent_tools::claude_args_for(false, &profile.env, &owned.1, session_id, cwd);
        (owned.0, owned.1.into_iter().chain(extra).collect())
    } else {
        owned
    };
    let mut env = resolved_profile_env(profile)?;
    let remote_environment = env.remove(REMOTE_ENV_POLICY_KEY).as_deref() == Some("1");
    // Internal projection marker, never profile-controlled. A hosted agent
    // reconstructs the command's complete environment from this removal.
    env.remove(REMOTE_ENV_CLEARED_KEY);
    // The Codex bridge runs the configured codex binary: `CODEX_PATH` of the
    // profile or its family (`defaults.codex.env`), as the ACP adapter does.
    let owned = match env.get("CODEX_PATH").filter(|p| !p.is_empty()) {
        Some(path) if crate::codex_app_server::is_launch(&owned.0, &owned.1) => {
            (path.clone(), owned.1)
        }
        _ => owned,
    };
    // A bound route's provider variables the inherited env must not keep
    // (routes.rs): an earlier route's key never reaches this process.
    let route_unset = env.remove(crate::routes::UNSET_KEY);
    // Your own endpoint (byo_endpoint.rs): the marker is acpmux's own.
    let own_endpoint = crate::byo_endpoint::Kind::of_env(&env);
    env.remove(crate::byo_endpoint::OWN_ENDPOINT_KEY);
    env.remove(crate::routes::PROFILE_ROUTE_KEY);
    // The session's workspace is for its computer use server only (agent_displays.rs).
    env.remove(crate::agent_displays::WORKSPACE_KEY);
    // The chat's turned-off servers are for the fold only (agent_tools.rs).
    env.remove(crate::agent_tools::OFF_ENV);
    // OpenCode asked to ask (`opencode_ask.rs`): its config is set below.
    let opencode_ask = env.remove(crate::opencode_ask::MARKER).is_some();
    // The caller token and its socket are acpmux's own (`hub/person.rs` (a)):
    // this env is layered after `caller_env`, so a profile, preset or
    // request value would replace them.
    for key in crate::hub::person::CALLER_ENV_KEYS {
        env.remove(key);
    }
    let (program, args) = (&owned.0, &owned.1);
    let mut cmd =
        crate::session_scope::command(program, session.map(|(id, _)| id), &env, remote_environment);
    if remote_environment {
        apply_remote_base(&mut cmd);
    }
    // The daemon's own prompt-cache switches and turn-scoped values are
    // never the agent's (a daemon started from inside a Claude Code or Chief
    // turn can carry them). The profile, preset and session env below may
    // still set them. So may the login shell (`login_env`, applied after
    // this removal) when the daemon's own env lacks the key (a daemon from
    // `spawn_detached` always does); a key the daemon's env has hides the
    // login value (`login_env::for_children`) unless it started inside a
    // Claude Code turn (`nested_overrides`).
    for k in crate::config::inherited_caller_scoped_keys() {
        cmd.env_remove(k);
    }
    // Startup files changed since the last read: refresh in the background.
    crate::login_env::refresh_if_changed();
    // The login shell's allow-list for this harness's family (login_env.rs).
    let family_name = crate::config::derive_family(name, profile);
    let family = Some(family_name.as_str());
    if remote_environment {
        crate::login_env::apply_remote_tokio(&mut cmd);
    } else {
        crate::login_env::apply_tokio_for(&mut cmd, family, Some(&env));
    }
    crate::config::scrub_nested_claude_env_tokio_for(
        &mut cmd,
        if remote_environment { None } else { family },
    );
    // Caller context, herdr-style: the agent knows which session it is.
    for (k, _) in std::env::vars_os() {
        if k.to_string_lossy().starts_with("ACPMUX_") {
            cmd.env_remove(&k);
        }
    }
    // Helper tokens reach the cmux-cua MCP server through its own env only.
    crate::cua_socket::scrub_agent_env(&mut cmd);
    // A nested launch must not be taken for its parent's thread.
    cmd.env_remove("CODEX_THREAD_ID").env_remove("OMPCODE");
    // The daemon's own terminal (it may have started in a cmux terminal) is
    // not the agent's: a stale id would open the agent's tabs beside it.
    for key in crate::agent_tools::INHERITED_CALLER_ENV {
        cmd.env_remove(key);
    }
    // A cmux tool allowlist in the daemon's own env (a daemon started from a
    // Chief turn's shell) is not the agent's: a harness passes its env to
    // its MCP servers. A turn's preset puts its own value back (`envs`).
    cmd.env_remove(crate::agent_tools::MCP_TOOLS_ENV);
    cmd.env_remove(crate::agent_tools::UPSTREAMS_ENV);
    for k in route_unset.iter().flat_map(|list| list.split(',')) {
        cmd.env_remove(k);
    }
    // An Anthropic endpoint harness: no inherited ANTHROPIC_* or Claude
    // provider switch (the login shell's, the daemon's) overrides its own.
    if own_endpoint == Some(crate::byo_endpoint::Kind::Anthropic) {
        crate::byo_endpoint::clear_inherited(&mut cmd, &env);
    }
    if let Some((id, sname)) = session {
        cmd.env("ACPMUX_ENV", "1")
            .env("ACPMUX_SESSION_ID", id)
            .env("ACPMUX_SESSION_NAME", sname)
            .env("ACPMUX_SOCKET", crate::config::socket_path())
            // Its caller token and the socket it is for (hub/person.rs (a)); the cmux CLI's caller.
            .envs(crate::hub::person::caller_env(id))
            .env(crate::agent_tools::AGENT_SESSION_ENV, id);
        // Its own temporary folder (`session_tmp.rs`); a profile's TMPDIR
        // (applied below) still wins. A remote-origin chain keeps its base.
        #[cfg(unix)]
        if !remote_environment {
            use super::session_tmp;
            let base = session_tmp::per_user_base();
            if let Some(dir) = session_tmp::make(&base, &crate::config::home(), id) {
                let ambient = command_env(&cmd);
                let agent = |key: &str| {
                    env.get(key)
                        .cloned()
                        .or_else(|| ambient.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone()))
                };
                let blank = |key: &str| env.get(key).is_some_and(|v| v.is_empty());
                // SAFETY: getuid has no preconditions.
                let uid = unsafe { libc::getuid() };
                cmd.envs(session_tmp::env_for(&dir, agent, blank, cfg!(target_os = "macos"), uid));
            }
        }
    }
    // The durable store is bound by acpmux's profile spawn path; never
    // inherit a controller or shell value into another harness.
    cmd.env_remove("CMUX_HARNESS_SESSION_STORE_DIR");
    cmd.args(crate::harness_limits::launch_args(program, args, session.map(|_| (cwd, &env))))
        .envs(env.iter());
    // The profile's PATH first, never instead of the login PATH (login_env::with_agent_path).
    if !remote_environment && let Some(own) = env.get("PATH").filter(|p| !p.is_empty()) {
        cmd.env("PATH", crate::login_env::with_agent_path(own));
    }
    if opencode_ask {
        ask_opencode(&mut cmd, name, !remote_environment);
    }
    cmd
        // Claude refuses to nest inside another Claude session.
        .env_remove("CLAUDECODE")
        .env_remove("CLAUDE_CODE_ENTRYPOINT")
        .current_dir(cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    // Own process group, so stopping the session stops everything the
    // agent started underneath it (background shells included). Windows: a
    // job object (`job.rs`), made where the agent is spawned.
    #[cfg(unix)]
    cmd.process_group(0);
    // A sub-session's harness execs only in the folder its start checked (`cwd_pin.rs`).
    #[cfg(unix)]
    crate::cwd_pin::CwdPin::pin(crate::cwd_pin::CwdPin::current(), &mut cmd);
    // Only its own session's credential: never acpmux's, a preset's or a Chief's.
    crate::launch_credential::apply(&mut cmd, session.map(|(id, _)| id));
    crate::harness_limits::lift_claude(&mut cmd, profile, session.is_some(), !remote_environment);
    // A Chief turn or compactor (fresh process per turn): one sticky
    // subrouter account, so its prompt cache stays readable (subrouter_session.rs).
    let claude_code = profile.kind == crate::config::HarnessKind::ClaudeStdio
        || family.is_some_and(|f| f.starts_with("claude"));
    if claude_code {
        let env = command_env_with(&cmd, !remote_environment);
        let get = |k: &str| env.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone());
        if let Some(headers) = crate::subrouter_session::custom_headers(get) {
            cmd.env(crate::subrouter_session::HEADERS_ENV, headers);
        }
        // sr2 cost labels (sr2_cost_labels.rs), over the lines set just above.
        let env = command_env_with(&cmd, !remote_environment);
        let get = |k: &str| env.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone());
        if let Some(headers) = crate::sr2_cost_labels::custom_headers(get) {
            cmd.env(crate::subrouter_session::HEADERS_ENV, headers);
        }
    }
    // Claude Code's question previews in the format the hub labels them with
    // (`preview_format`, which the hub records at this launch): set last, so a
    // login or daemon value can never make the agent write HTML the hub would
    // show as text, or the reverse. `markdown` is Claude Code's own default
    // for this entrypoint.
    if profile.kind == crate::config::HarnessKind::ClaudeStdio {
        let format = preview_format(profile).claude_value();
        cmd.env(crate::hub::questions::PREVIEW_FORMAT_ENV, format);
    }
    // A Claude agent's sign-in inputs, for a clear message if it has none.
    match (family == Some("claude"), session) {
        (true, Some((id, _))) => {
            crate::claude_auth::remember(id, &command_env_with(&cmd, !remote_environment))
        }
        (false, Some((id, _))) => crate::claude_auth::forget(id),
        _ => {}
    }
    Ok(cmd)
}

/// OpenCode asked to ask (`opencode_ask.rs`): the `OPENCODE_CONFIG_CONTENT`
/// `cmd` gives its agent (the profile's, else the inherited one) asks before
/// every tool. One that is not a JSON object is kept, with a warning; the chat
/// logs `policy_unenforced` either way (`hub/policy_mode.rs`).
fn ask_opencode(cmd: &mut Command, name: &str, inherit_ambient: bool) {
    use crate::opencode_ask::{CONFIG_ENV, asking_config};
    let existing = command_env_with(cmd, inherit_ambient)
        .into_iter()
        .find(|(key, _)| key == CONFIG_ENV)
        .map(|(_, value)| value);
    match asking_config(existing.as_deref()) {
        Some(config) => {
            cmd.env(CONFIG_ENV, config);
        }
        None => tracing::warn!(
            harness = %name,
            "{CONFIG_ENV} is not a JSON object: kept as it is, so OpenCode is not asked to ask before each tool"
        ),
    }
}

/// How Claude Code started from `profile` writes its question previews
/// (`hub/questions.rs` `PreviewFormat`): its own
/// `CLAUDE_CODE_QUESTION_PREVIEW_FORMAT`, a reference resolved as the launch
/// resolves it. The hub labels the questions with it (`hub/tools.rs`) and
/// `harness_command` pins the agent to it, so the two never disagree.
pub(crate) fn preview_format(profile: &HarnessProfile) -> crate::hub::questions::PreviewFormat {
    use crate::hub::questions::{PREVIEW_FORMAT_ENV, PreviewFormat};
    let claude = profile.kind == crate::config::HarnessKind::ClaudeStdio;
    let Some(value) = profile.env.get(PREVIEW_FORMAT_ENV).filter(|_| claude) else {
        return PreviewFormat::Monospace;
    };
    let env = [(PREVIEW_FORMAT_ENV.to_owned(), value.clone())].into();
    let only = HarnessProfile { env, ..profile.clone() };
    resolved_profile_env(&only).map(|env| PreviewFormat::of(claude, &env)).unwrap_or_default()
}

/// The preview format `harness_command` pinned on `cmd`: what the agent it starts writes. The hub
/// records this one (`Hub::record_preview_format`), never a second resolution of the profile,
/// which a pooled agent started minutes earlier could disagree with.
pub(crate) fn pinned_preview_format(cmd: &Command) -> crate::hub::questions::PreviewFormat {
    use crate::hub::questions::{PREVIEW_FORMAT_ENV, PreviewFormat};
    let mut envs = cmd.as_std().get_envs();
    let pinned = envs.find(|(name, _)| *name == PREVIEW_FORMAT_ENV).and_then(|(_, value)| value);
    match pinned {
        Some(value) if value == PreviewFormat::Html.claude_value() => PreviewFormat::Html,
        _ => PreviewFormat::Monospace,
    }
}

/// The profile's env with its `${keychain:…}` and `${env:…}` references
/// resolved (`config::profiles`). The secret store is asked only when a
/// value holds a reference; the lookup blocks, so a multi-thread runtime
/// moves it off its worker first.
fn resolved_profile_env(
    profile: &HarnessProfile,
) -> Result<std::collections::BTreeMap<String, String>> {
    let mut env = profile.env.clone();
    if !crate::config::profiles::has_env_refs(&env) {
        return Ok(env);
    }
    let resolve = |env: &mut std::collections::BTreeMap<String, String>| {
        crate::config::profiles::resolve_env_refs(
            env,
            &|var| crate::login_env::allowed_var(var).or_else(|| std::env::var(var).ok()),
            &crate::config::profiles::keychain_lookup,
        )
    };
    let multi_thread = tokio::runtime::Handle::try_current()
        .is_ok_and(|h| h.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread);
    let result = if multi_thread {
        tokio::task::block_in_place(|| resolve(&mut env))
    } else {
        resolve(&mut env)
    };
    result.map_err(|e| anyhow!(e))?;
    Ok(env)
}

/// The full environment `cmd` gives its child (inherited, then changed).
pub(crate) fn command_env(cmd: &Command) -> Vec<(String, String)> {
    command_env_with(cmd, true)
}

/// The full environment of an `env_clear` command, for a remote durable
/// host's SpawnSpec. The caller owns the remote-origin fact; it is never
/// inferred from profile-controlled environment edits.
pub(crate) fn command_env_cleared(cmd: &Command) -> Vec<(String, String)> {
    command_env_with(cmd, false)
}

fn command_env_with(cmd: &Command, inherit_ambient: bool) -> Vec<(String, String)> {
    let changes: Vec<(String, Option<String>)> = cmd
        .as_std()
        .get_envs()
        .map(|(key, value)| {
            (
                key.to_string_lossy().into_owned(),
                value.map(|value| value.to_string_lossy().into_owned()),
            )
        })
        .collect();
    let mut env: std::collections::BTreeMap<String, String> =
        if inherit_ambient { std::env::vars().collect() } else { Default::default() };
    for (k, v) in changes {
        if k == REMOTE_ENV_CLEARED_KEY {
            continue;
        }
        match v {
            Some(v) => {
                env.insert(k, v);
            }
            None => {
                env.remove(&k);
            }
        }
    }
    env.into_iter().collect()
}

/// Start a remote-origin harness with operating-system identity and locale,
/// then layer the common login allowlist and its explicit profile/session
/// values. Unrelated tokens, SSH_AUTH_SOCK, and ambient CMUX_* never enter.
fn apply_remote_base(cmd: &mut Command) {
    cmd.env_clear().envs(host_environment());
}

/// Fixed non-secret process base for a remote harness and for the durable
/// host that contains it. The host receives no profile/session authority;
/// the harness gets those values separately through `SpawnSpec`.
pub(crate) fn host_environment() -> Vec<(std::ffi::OsString, std::ffi::OsString)> {
    let allowed = |key: &std::ffi::OsStr| {
        let key = key.to_string_lossy();
        [
            "HOME",
            "USER",
            "LOGNAME",
            "SHELL",
            "TMPDIR",
            "LANG",
            "LANGUAGE",
            "LC_ALL",
            "LC_COLLATE",
            "LC_CTYPE",
            "LC_MESSAGES",
            "LC_MONETARY",
            "LC_NUMERIC",
            "LC_TIME",
            "TERM",
            "COLORTERM",
            "TZ",
            // Windows process startup and temporary-directory basics.
            "SYSTEMROOT",
            "WINDIR",
            "COMSPEC",
            "PATHEXT",
            "TEMP",
            "TMP",
            "USERPROFILE",
        ]
        .iter()
        .any(|allowed| key.eq_ignore_ascii_case(allowed))
    };
    std::env::vars_os().filter(|(key, _)| allowed(key)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hosted_remote_environment_cannot_be_reopened_by_a_profile_key_collision() {
        let mut profile: HarnessProfile = serde_json::from_value(serde_json::json!({
            "argv": ["/usr/bin/true"],
            "env": {
                "ACPMUX_REMOTE_ENV_POLICY": "1",
                "__ACPMUX_REMOTE_ENV_CLEARED": "collision"
            }
        }))
        .unwrap();
        profile.kind = crate::config::HarnessKind::Acp;
        let command =
            harness_command("remote", &profile, &std::env::temp_dir(), None, None).unwrap();
        let env = command_env_cleared(&command);
        assert!(
            !env.iter().any(|(key, _)| key == "CARGO_MANIFEST_DIR"),
            "hosted projection recovered the daemon environment"
        );
    }

    /// Claude Code is pinned to the preview format the hub records for its
    /// launch (`preview_format`); another harness is neither pinned nor HTML.
    #[test]
    fn claude_code_is_pinned_to_the_preview_format_the_hub_records() {
        use crate::config::HarnessKind;
        use crate::hub::questions::{PREVIEW_FORMAT_ENV, PreviewFormat};
        let profile = |kind, value: &str| {
            let mut p: HarnessProfile =
                serde_json::from_value(serde_json::json!({"argv": ["/usr/bin/true"]})).unwrap();
            p.kind = kind;
            p.env.insert(PREVIEW_FORMAT_ENV.into(), value.into());
            p
        };
        let pinned = |p: &HarnessProfile| {
            let command = harness_command("local", p, &std::env::temp_dir(), None, None).unwrap();
            let env = command_env(&command);
            env.into_iter().find(|(k, _)| k == PREVIEW_FORMAT_ENV).map(|(_, v)| v)
        };
        let html = profile(HarnessKind::ClaudeStdio, " html ");
        assert_eq!(preview_format(&html), PreviewFormat::Html);
        assert_eq!(pinned(&html).as_deref(), Some("html"));
        let command = |p: &HarnessProfile| {
            pinned_preview_format(
                &harness_command("local", p, &std::env::temp_dir(), None, None).unwrap(),
            )
        };
        assert_eq!(command(&html), PreviewFormat::Html);
        let text = profile(HarnessKind::ClaudeStdio, "markdown");
        assert_eq!(preview_format(&text), PreviewFormat::Monospace);
        assert_eq!(pinned(&text).as_deref(), Some("markdown"));
        assert_eq!(command(&text), PreviewFormat::Monospace);
        // A reference that does not resolve starts no agent, and labels nothing HTML.
        let missing = profile(HarnessKind::ClaudeStdio, "${env:ACPMUX_TEST_NO_SUCH_FORMAT}");
        assert_eq!(preview_format(&missing), PreviewFormat::Monospace);
        assert_eq!(preview_format(&profile(HarnessKind::Acp, "html")), PreviewFormat::Monospace);
    }

    #[test]
    fn hosted_local_environment_keeps_the_daemon_base() {
        let profile: HarnessProfile = serde_json::from_value(serde_json::json!({
            "argv": ["/usr/bin/true"]
        }))
        .unwrap();
        let command =
            harness_command("local", &profile, &std::env::temp_dir(), None, None).unwrap();
        let env = command_env(&command);
        assert!(
            env.iter().any(|(key, _)| key == "CARGO_MANIFEST_DIR"),
            "hosted projection discarded the local daemon environment"
        );
    }

    /// The env `harness_command` gives a session `id` of `profile_env`, with
    /// the per-user directory in `base`.
    #[cfg(unix)]
    fn session_env(
        base: &std::path::Path,
        id: &str,
        profile_env: serde_json::Value,
    ) -> Vec<(String, String)> {
        let profile: HarnessProfile = serde_json::from_value(serde_json::json!({
            "argv": ["/usr/bin/true"],
            "env": profile_env
        }))
        .unwrap();
        let cmd = super::super::session_tmp::with_base(base, || {
            harness_command("local", &profile, &std::env::temp_dir(), None, Some((id, "lane")))
        })
        .unwrap();
        command_env(&cmd)
    }

    #[cfg(unix)]
    fn var(env: &[(String, String)], key: &str) -> Option<String> {
        env.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone())
    }

    #[cfg(unix)]
    #[test]
    fn every_local_session_gets_its_own_temporary_folder() {
        use super::super::session_tmp::{SESSION_TMPDIR_ENV, daemon_root};
        let scratch = std::env::temp_dir().join(format!(
            "acpmux-cmd-tmp-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7().simple()
        ));
        std::fs::create_dir_all(&scratch).unwrap();
        let base = scratch.join("acpmux-u");
        let (a, b) =
            ("01a15d7d-b692-76b3-b8de-a9a71809de2a", "01a15db7-20cd-7e10-8535-158031297e5c");
        let root = daemon_root(&base, &crate::config::home());
        let runtime = serde_json::json!({"XDG_RUNTIME_DIR": "/run/user/4242"});
        let env_a = session_env(&base, a, runtime.clone());
        let env_b = session_env(&base, b, runtime);
        let dir_a = root.join(a).display().to_string();
        assert_eq!(var(&env_a, "TMPDIR"), Some(dir_a.clone()));
        assert_eq!(var(&env_a, SESSION_TMPDIR_ENV), Some(dir_a.clone()));
        assert_eq!(var(&env_b, "TMPDIR"), Some(root.join(b).display().to_string()));
        assert!(root.join(a).is_dir() && root.join(b).is_dir());
        // A profile TMPDIR still wins; the session folder is still named.
        let env =
            session_env(&base, a, serde_json::json!({"TMPDIR": "/p/tmp", "XDG_RUNTIME_DIR": "/r"}));
        assert_eq!(var(&env, "TMPDIR").as_deref(), Some("/p/tmp"));
        assert_eq!(var(&env, SESSION_TMPDIR_ENV), Some(dir_a.clone()));
        // Without a runtime dir (when this test process has none): a Mac gives
        // the session its folder as TMPDIR and pins the socket base the agent
        // resolved before (the TMPDIR it has without a session); elsewhere
        // TMPDIR stays.
        if std::env::var_os("XDG_RUNTIME_DIR").is_none_or(|v| v.is_empty()) {
            let plain: HarnessProfile =
                serde_json::from_value(serde_json::json!({"argv": ["/usr/bin/true"]})).unwrap();
            let unsessioned =
                harness_command("local", &plain, &std::env::temp_dir(), None, None).unwrap();
            let before = var(&command_env(&unsessioned), "TMPDIR").filter(|v| !v.is_empty());
            let env = session_env(&base, a, serde_json::json!({}));
            assert_eq!(var(&env, SESSION_TMPDIR_ENV), Some(dir_a.clone()));
            match before.filter(|_| cfg!(target_os = "macos")) {
                Some(before) => {
                    assert_eq!(var(&env, "TMPDIR"), Some(dir_a.clone()));
                    assert_eq!(var(&env, "XDG_RUNTIME_DIR"), Some(before));
                }
                None => assert_eq!(
                    var(&env, "TMPDIR").filter(|v| !v.is_empty()),
                    var(&command_env(&unsessioned), "TMPDIR").filter(|v| !v.is_empty())
                ),
            }
            // A profile's TMPDIR still wins there too; the pinned base is that TMPDIR, the
            // base the agent resolves its sockets under.
            let env = session_env(&base, a, serde_json::json!({"TMPDIR": "/var/folders/x/T/"}));
            assert_eq!(var(&env, SESSION_TMPDIR_ENV), Some(dir_a.clone()));
            assert_eq!(var(&env, "TMPDIR").as_deref(), Some("/var/folders/x/T/"));
            if cfg!(target_os = "macos") {
                assert_eq!(var(&env, "XDG_RUNTIME_DIR").as_deref(), Some("/var/folders/x/T/"));
            }
        }
        // A profile that blanks XDG_RUNTIME_DIR: no pin can hold, TMPDIR stays.
        let env = session_env(&base, a, serde_json::json!({"XDG_RUNTIME_DIR": "", "TMPDIR": "/q"}));
        assert_eq!(var(&env, "TMPDIR").as_deref(), Some("/q"));
        assert_eq!(var(&env, SESSION_TMPDIR_ENV), Some(dir_a));
        let _ = std::fs::remove_dir_all(&scratch);
    }

    #[cfg(unix)]
    #[test]
    fn a_remote_session_keeps_its_environment() {
        let scratch = std::env::temp_dir().join(format!(
            "acpmux-cmd-remote-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7().simple()
        ));
        let base = scratch.join("acpmux-u");
        let profile: HarnessProfile = serde_json::from_value(serde_json::json!({
            "argv": ["/usr/bin/true"],
            "env": {"ACPMUX_REMOTE_ENV_POLICY": "1", "XDG_RUNTIME_DIR": "/run/user/4242"}
        }))
        .unwrap();
        let id = "01a15d7d-b692-76b3-b8de-a9a71809de2a";
        let cmd = super::super::session_tmp::with_base(&base, || {
            harness_command("remote", &profile, &std::env::temp_dir(), None, Some((id, "r")))
        })
        .unwrap();
        let env = command_env_cleared(&cmd);
        assert_eq!(var(&env, super::super::session_tmp::SESSION_TMPDIR_ENV), None);
        assert!(!var(&env, "TMPDIR").is_some_and(|t| t.starts_with(&*base.to_string_lossy())));
        assert!(!base.exists(), "a remote session made a local temporary folder");
        let _ = std::fs::remove_dir_all(&scratch);
    }

    /// A profile or preset PATH goes first but never hides the login PATH: the Chief's
    /// built-in subagent preset was saved with the daemon's bare launchd PATH
    /// (`<bundle>/bin:/usr/bin:/bin:/usr/sbin:/sbin`) before the login import ran, and every
    /// `claude` spawn then failed `spawn harness process: No such file or directory`.
    #[cfg(unix)]
    #[test]
    fn a_profile_path_keeps_the_login_path_after_it() {
        let scratch = std::env::temp_dir().join(format!(
            "acpmux-cmd-path-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7().simple()
        ));
        let base = scratch.join("acpmux-u");
        let bare = "/acpmux-test-bundle/bin:/usr/bin:/bin:/usr/sbin:/sbin";
        let login = crate::login_env::agent_path().expect("the test process has a PATH");
        let login: Vec<String> =
            std::env::split_paths(&login).map(|p| p.to_string_lossy().into_owned()).collect();
        let extra: Vec<&String> =
            login.iter().filter(|d| !d.is_empty() && !bare.split(':').any(|b| b == *d)).collect();
        assert!(!extra.is_empty(), "the login PATH must list a directory the bare PATH lacks");
        let env = session_env(
            &base,
            "01a15d7d-b692-76b3-b8de-a9a71809de2a",
            serde_json::json!({"PATH": bare}),
        );
        let path = var(&env, "PATH").expect("a PATH");
        let entries: Vec<&str> = path.split(':').collect();
        let first: Vec<&str> = bare.split(':').collect();
        assert_eq!(
            &entries[..first.len().min(entries.len())],
            &first[..],
            "the profile's PATH comes first"
        );
        for dir in extra {
            assert!(
                entries.contains(&dir.as_str()),
                "{dir} of the login PATH is missing from {path}"
            );
        }
        let unique: std::collections::BTreeSet<&str> = entries.iter().copied().collect();
        assert_eq!(entries.len(), unique.len(), "each directory once: {path}");
        let _ = std::fs::remove_dir_all(&scratch);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn remote_scope_never_probes_a_profile_path_runner() {
        use std::io::Write as _;
        use std::process::{Command as StdCommand, Stdio};

        let root = std::env::temp_dir().join(format!("acpmux-remote-scope-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let runner = root.join("systemd-run");
        let marker = root.join("probed");
        let mut writer = StdCommand::new("/bin/sh")
            .args(["-c", "cat >\"$1\" && chmod 755 \"$1\"", "sh"])
            .arg(&runner)
            .stdin(Stdio::piped())
            .spawn()
            .unwrap();
        writeln!(
            writer.stdin.take().unwrap(),
            "#!/bin/sh\nprintf probed >{}\nexit 1",
            marker.display()
        )
        .unwrap();
        assert!(writer.wait().unwrap().success());
        let profile: HarnessProfile = serde_json::from_value(serde_json::json!({
            "argv": ["/usr/bin/true"],
            "env": {
                "ACPMUX_REMOTE_ENV_POLICY": "1",
                "PATH": root
            }
        }))
        .unwrap();
        let _ = harness_command(
            "remote",
            &profile,
            &std::env::temp_dir(),
            None,
            Some(("session", "remote")),
        )
        .unwrap();
        assert!(!marker.exists(), "remote launch probed profile-controlled systemd-run");
        let _ = std::fs::remove_dir_all(&root);
    }
}
