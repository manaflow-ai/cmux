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
pub(crate) const REMOTE_ENV_POLICY_ID: &str = "remote-env-v2";
/// `Command` exposes its env edits but not `env_clear`; this removal records
/// that clear for the agent-host environment projection (`command_env`).
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
        let extra = crate::agent_tools::claude_args_for(false, &profile.env, &owned.1, session_id);
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
    }
    cmd.args(crate::harness_limits::launch_args(program, args, session.map(|_| (cwd, &env))))
        .envs(env.iter());
    if remote_environment {
        // Keep the hosted projection's env-clear proof after every profile
        // entry, even if an old config used the internal marker's name.
        cmd.env_remove(REMOTE_ENV_CLEARED_KEY);
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
    // Only its own session's credential: never acpmux's, a preset's or a Chief's.
    crate::launch_credential::apply(&mut cmd, session.map(|(id, _)| id));
    crate::harness_limits::lift_claude(&mut cmd, profile, session.is_some());
    // A Chief turn or compactor (fresh process per turn): one sticky
    // subrouter account, so its prompt cache stays readable (subrouter_session.rs).
    let claude_code = profile.kind == crate::config::HarnessKind::ClaudeStdio
        || family.is_some_and(|f| f.starts_with("claude"));
    if claude_code {
        let env = command_env(&cmd);
        let get = |k: &str| env.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone());
        if let Some(headers) = crate::subrouter_session::custom_headers(get) {
            cmd.env(crate::subrouter_session::HEADERS_ENV, headers);
        }
    }
    // A Claude agent's sign-in inputs, for a clear message if it has none.
    match (family == Some("claude"), session) {
        (true, Some((id, _))) => crate::claude_auth::remember(id, &command_env(&cmd)),
        (false, Some((id, _))) => crate::claude_auth::forget(id),
        _ => {}
    }
    Ok(cmd)
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
    let cleared =
        changes.iter().any(|(key, value)| key == REMOTE_ENV_CLEARED_KEY && value.is_none());
    let mut env: std::collections::BTreeMap<String, String> =
        if cleared { Default::default() } else { std::env::vars().collect() };
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
    // `Command::env_remove` need not retain a removal for a key it has never
    // seen. Set then remove so `command_env` can observe env_clear without
    // exposing the internal marker to either a direct or hosted child.
    cmd.env_clear()
        .envs(host_environment())
        .env(REMOTE_ENV_CLEARED_KEY, "1")
        .env_remove(REMOTE_ENV_CLEARED_KEY);
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
        let env = command_env(&command);
        assert!(
            !env.iter().any(|(key, _)| key == "CARGO_MANIFEST_DIR"),
            "hosted projection recovered the daemon environment"
        );
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

    #[cfg(target_os = "linux")]
    #[test]
    fn remote_scope_never_probes_a_profile_path_runner() {
        use std::io::Write as _;
        use std::os::unix::fs::PermissionsExt;
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
