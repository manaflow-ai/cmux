//! The harness command line and environment, as acpmux runs it, for direct
//! children (`agent.rs`) and agent hosts.

use crate::config::HarnessProfile;
use anyhow::{Result, anyhow};
use std::process::Stdio;
use tokio::process::Command;

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
    env.remove(crate::routes::PROFILE_ROUTE_KEY);
    let (program, args) = (&owned.0, &owned.1);
    let mut cmd = Command::new(program);
    // Startup files changed since the last read: refresh in the background.
    crate::login_env::refresh_if_changed();
    // The login shell's allow-list for this harness's family (login_env.rs).
    let family_name = crate::config::derive_family(name, profile);
    let family = Some(family_name.as_str());
    crate::login_env::apply_tokio_for(&mut cmd, family, Some(&env));
    crate::config::scrub_nested_claude_env_tokio_for(&mut cmd, family);
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
    for k in route_unset.iter().flat_map(|list| list.split(',')) {
        cmd.env_remove(k);
    }
    if let Some((id, sname)) = session {
        cmd.env("ACPMUX_ENV", "1")
            .env("ACPMUX_SESSION_ID", id)
            .env("ACPMUX_SESSION_NAME", sname)
            .env("ACPMUX_SOCKET", crate::config::socket_path())
            // The caller the cmux CLI names to the app: its tabs open in the
            // column right of this session's chat (beside_caller).
            .env(crate::agent_tools::AGENT_SESSION_ENV, id);
    }
    cmd.args(crate::harness_limits::launch_args(program, args, session.map(|_| (cwd, &env))))
        .envs(env.iter())
        // A terminal's launch credential names that one terminal; no agent
        // acts as the terminal that started acpmux, not even through a preset.
        .env_remove(crate::config::LAUNCH_CREDENTIAL_ENV)
        // Nor as the Chief whose host started acpmux (config::CHIEF_CREDENTIAL_ENV).
        .env_remove(crate::config::CHIEF_CREDENTIAL_ENV[0])
        .env_remove(crate::config::CHIEF_CREDENTIAL_ENV[1])
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
    crate::harness_limits::lift_claude(&mut cmd, profile, session.is_some());
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
    let mut env: std::collections::BTreeMap<String, String> = std::env::vars().collect();
    for (k, v) in cmd.as_std().get_envs() {
        let k = k.to_string_lossy().into_owned();
        match v {
            Some(v) => {
                env.insert(k, v.to_string_lossy().into_owned());
            }
            None => {
                env.remove(&k);
            }
        }
    }
    env.into_iter().collect()
}
