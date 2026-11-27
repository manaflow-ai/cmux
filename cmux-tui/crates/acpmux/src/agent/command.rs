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
/// v4: a vmHost machine no longer runs remote Claude without the sandbox
/// (`hub/vm_host.rs`), so a host an older daemon started there is ended.
pub(crate) const REMOTE_ENV_POLICY_ID: &str = "remote-env-v4";
/// Reserved legacy projection marker. A profile cannot control internal
/// environment projection even if an older config used this valid env name.
const REMOTE_ENV_CLEARED_KEY: &str = "__ACPMUX_REMOTE_ENV_CLEARED";
/// Claude Code's switch for its to-do tools (TaskCreate, TaskUpdate) in a `-p`
/// session (Claude Code 2.1.312 offers neither them nor TodoWrite without it).
const TODO_TOOLS_ENV: &str = "CLAUDE_CODE_ENABLE_TODO_TOOLS";

/// Claude Code's own name for the session (`--name`): its acpmux name, so the
/// peer list and a held message's "From:" read as `acpmux ls` does, not as the
/// folder name and a number Claude Code derives (Leo: "it's called projects-34
/// but it's named differnetly in cmux-next"). A command line that names the
/// session keeps its own; a remote-origin chain (its env policy, `hub/spawn.rs`) passes no
/// flag its sandbox plan did not check. A local profile's `--strict-mcp-config` is still named.
fn claude_name_args(
    env: &std::collections::BTreeMap<String, String>,
    args: &[String],
    name: &str,
) -> Vec<String> {
    let name = name.trim();
    let remote = env.get(REMOTE_ENV_POLICY_KEY).is_some_and(|v| v == "1");
    let own = args.iter().any(|a| a == "--name" || a == "-n" || a.starts_with("--name="));
    if name.is_empty() || remote || own { Vec::new() } else { vec!["--name".into(), name.into()] }
}

/// `harness_command` for a spawn, the one every spawn path builds: when its
/// final env plan takes a login value only the shell holds (a cached start),
/// wait for the shell (at most `login_env::TIMEOUT`) and build it again with
/// the read's values; a base URL or `${env:X}` it still lacks refuses the
/// start (`login_env::ChildEnv`). A name the plan sets, unsets or never
/// inherits (a route's unset, a remote-origin launch) never waits; one a
/// scrub removes and the login import restores does. A read that ends while
/// the command is built builds it again (`login_env::build_ready`).
pub(crate) async fn harness_command_ready(
    name: &str,
    profile: &HarnessProfile,
    cwd: &std::path::Path,
    command_line: Option<(String, Vec<String>)>,
    session: Option<(&str, &str)>,
) -> Result<Command> {
    let family = crate::config::derive_family(name, profile);
    // Labs `labs.bundledCodexAppServer` (off by default): plain `codex app-server` runs the
    // bundle cmux ships when it is whole (`codex_bundle.rs`); a profile's CODEX_PATH still wins.
    let command_line = match command_line {
        None if crate::codex_app_server::is_profile_launch(&profile.argv) => {
            crate::codex_bundle::launch_for(&profile.argv).await
        }
        line => line,
    };
    let mut plan = crate::login_env::ChildEnv {
        family: &family,
        profile: Some(&profile.env),
        remote: profile.env.get(REMOTE_ENV_POLICY_KEY).map(String::as_str) == Some("1"),
        explicit: None,
    };
    crate::login_env::build_ready(
        &mut plan,
        || harness_command(name, profile, cwd, command_line.clone(), session),
        |cmd| explicit_env(cmd.as_std()),
        |e| anyhow!(e),
    )
    .await
}

/// The env changes `cmd` makes: a name it sets, or removes (`None`).
/// A tool call's bound (`CMUX_DEADLINE` and the tool that set it): never an agent's.
pub(crate) const CALL_BOUND_ENV: [&str; 2] = ["CMUX_DEADLINE", "CMUX_DEADLINE_OWNER"];
/// Where `lane-gh` finds its broker's socket (its default: the `ssh -R` forward's `broker.sock`).
#[cfg(unix)]
const LANE_GH_SOCKET_ENV: &str = "LANE_GH_SOCKET";

pub(crate) fn explicit_env(cmd: &std::process::Command) -> Vec<(String, Option<String>)> {
    cmd.get_envs()
        .map(|(k, v)| {
            (k.to_string_lossy().into_owned(), v.map(|v| v.to_string_lossy().into_owned()))
        })
        .collect()
}

/// The harness command line and environment, as acpmux runs it: the login
/// environment, no nested-agent markers, the session's `ACPMUX_*` caller
/// context, and the profile's env. Shared by direct children and hosts.
///
/// Every spawn builds through [`harness_command_ready`], never this directly:
/// the only direct callers are that function and tests that read the built
/// command without starting it.
///
/// A `codex app-server` started in a checkout still filling gets the PreToolUse hook that holds
/// each of its tools until the checkout is whole (`codex_repo_gate.rs`), when it can run one: the
/// command is built, and built again with the hook.
pub(crate) fn harness_command(
    name: &str,
    profile: &HarnessProfile,
    cwd: &std::path::Path,
    command_line: Option<(String, Vec<String>)>,
    session: Option<(&str, &str)>,
) -> Result<Command> {
    let (cmd, codex) =
        build_harness_command(name, profile, cwd, command_line.clone(), session, false)?;
    let gate = codex.is_some_and(|(program, args)| {
        crate::codex_repo_gate::wanted(&program, &args, cwd, &explicit_env(cmd.as_std()))
    });
    if !gate {
        return Ok(cmd);
    }
    Ok(build_harness_command(name, profile, cwd, command_line, session, true)?.0)
}

/// [`harness_command`], with the repository hook when `repo_gate` (a local `codex app-server`
/// launch only). Without it, a local `codex app-server` launch's program and arguments come
/// back too, for [`crate::codex_repo_gate::wanted`].
fn build_harness_command(
    name: &str,
    profile: &HarnessProfile,
    cwd: &std::path::Path,
    command_line: Option<(String, Vec<String>)>,
    session: Option<(&str, &str)>,
    repo_gate: bool,
) -> Result<(Command, Option<(String, Vec<String>)>)> {
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
    let mut plugin_hooks = false;
    let owned = if let (true, Some((session_id, session_name))) = (claude_session, session) {
        let (extra, prompt, hooks) = crate::agent_tools::claude_args_and_hooks_for(
            false,
            &profile.env,
            &owned.1,
            session_id,
            cwd,
        );
        plugin_hooks = hooks;
        let named = claude_name_args(&profile.env, &owned.1, session_name);
        let mut args = owned.1;
        // acpmux's own servers' instructions, which they then leave out: in the system prompt
        // every chat shares, not the first turn's (`AgentTools::instructions_in_prompt`).
        if let Some(prompt) = prompt {
            crate::agent_tools::append_system_prompt(&mut args, &prompt);
        }
        (owned.0, args.into_iter().chain(extra).chain(named).collect())
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
    // Decided on the profile's own program: a `CODEX_PATH` binary may be named anything (a fork,
    // a wrapper), and its launch still needs codex's overrides (`harness_limits::launch_args`).
    let codex_launch = crate::codex_app_server::is_launch(&owned.0, &owned.1);
    let owned = match env.get("CODEX_PATH").filter(|p| !p.is_empty()) {
        Some(path) if codex_launch => (path.clone(), owned.1),
        _ => owned,
    };
    // A bound route's provider variables the inherited env must not keep
    // (routes.rs): an earlier route's key never reaches this process.
    let route_unset = env.remove(crate::routes::UNSET_KEY);
    // The bound route's name, for `/status` only (`session_status.rs`).
    let route_name = env.remove(crate::routes::NAME_KEY);
    // Your own endpoint (byo_endpoint.rs): the marker is acpmux's own.
    let own_endpoint = crate::byo_endpoint::Kind::of_env(&env);
    env.remove(crate::byo_endpoint::OWN_ENDPOINT_KEY);
    env.remove(crate::routes::PROFILE_ROUTE_KEY);
    // The team-mode marker is for the remote chain's settings only (claude_cloud_auth.rs).
    env.remove(crate::claude_cloud_auth::TEAM_MARKER);
    // The session's workspace is for its computer use server only (agent_displays.rs).
    env.remove(crate::agent_displays::WORKSPACE_KEY);
    // The chat's turned-off servers are for the fold only (agent_tools.rs).
    env.remove(crate::agent_tools::OFF_ENV);
    // A person's chat asks sr2 for its reserve (`sr2_priority.rs`): the mark is the daemon's,
    // for the request header below only.
    let sr2_person = env.remove(crate::sr2_priority::PERSON_ENV).as_deref() == Some("1");
    // OpenCode asked to ask (`opencode_ask.rs`): its config is set below.
    let opencode_ask = env.remove(crate::opencode_ask::MARKER).is_some();
    // The person's `agents.envExclude` (agent_env.rs): removed last, below.
    let env_exclude = env
        .remove(crate::agent_env::EXCLUDE_MARKER)
        .map(|marker| crate::agent_env::patterns(&marker))
        .unwrap_or_default();
    // The caller token and its socket are acpmux's own (`hub/person.rs` (a)):
    // this env is layered after `caller_env`, so a profile, preset or
    // request value would replace them.
    for key in crate::person_tokens::CALLER_ENV_KEYS {
        env.remove(key);
    }
    // So is the CLI an agent runs (`cli_caller.rs`): never a profile's.
    env.remove(crate::cli_caller::BIN_ENV);
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
    if !remote_environment {
        crate::login_env::restore_machine_tokio(&mut cmd);
    }
    // Every other harness's login, from the daemon's env, the login shell or
    // machine env (`foreign_login.rs`). The profile's env, applied below, may
    // still set one on purpose. The agent is the one its command line runs.
    super::foreign_login::scrub(&mut cmd, name, profile);
    // Caller context, herdr-style: the agent knows which session it is.
    for (k, _) in std::env::vars_os() {
        if k.to_string_lossy().starts_with("ACPMUX_") {
            cmd.env_remove(&k);
        }
    }
    // A nested launch must not be taken for its parent's thread.
    cmd.env_remove("CODEX_THREAD_ID").env_remove("OMPCODE");
    // The daemon's own terminal (it may have started in a cmux terminal) is
    // not the agent's: a stale id would open the agent's tabs beside it.
    for key in crate::agent_tools::INHERITED_CALLER_ENV {
        cmd.env_remove(key);
    }
    // Nor is the cmux-tui Claude Code plugin of that terminal: its hooks
    // report to it. The agent keeps its other plugin folders; a profile's own
    // value, applied below, still wins. A remote base has none of the daemon's.
    if !remote_environment {
        let plugins = crate::agent_tools::CLAUDE_PLUGIN_DIRS_ENV;
        let inherited = match cmd.as_std().get_envs().find(|(key, _)| key.to_str() == Some(plugins))
        {
            Some((_, value)) => value.map(std::ffi::OsStr::to_os_string),
            None => std::env::var_os(plugins),
        };
        if let Some(inherited) = inherited {
            match crate::agent_tools::without_cmux_tui_plugins(&inherited) {
                Some(kept) => cmd.env(plugins, kept),
                None => cmd.env_remove(plugins),
            };
        }
    }
    // A cmux tool allowlist in the daemon's own env (a daemon started from a
    // Chief turn's shell) is not the agent's: a harness passes its env to
    // its MCP servers. A turn's preset puts its own value back (`envs`).
    cmd.env_remove(crate::agent_tools::MCP_TOOLS_ENV);
    // The app the daemon follows is not the agent's: a daemon its commands start must not
    // follow it too (`daemon/owner_exit.rs`).
    cmd.env_remove(crate::owner_exit::OWNER_APP_PID_ENV);
    // A tool call's bound in the daemon's env (a bounded command started the daemon) is not
    // the agent's: the fleet's orphan reaper ends a process past its CMUX_DEADLINE, so an agent
    // that inherited it was SIGTERMed (`subrouter: exit status 143`) mid-turn, also after a
    // relaunch handed it to the next daemon.
    for key in CALL_BOUND_ENV {
        cmd.env_remove(key);
    }
    cmd.env_remove(crate::agent_tools::UPSTREAMS_ENV);
    for k in route_unset.iter().flat_map(|list| list.split(',')) {
        cmd.env_remove(k);
    }
    // An endpoint harness: no inherited key (CMUX_BYO_API_KEY) and, for an
    // Anthropic one, no inherited ANTHROPIC_* or Claude provider switch (the
    // login shell's, the daemon's) overrides its own or reaches its URL.
    if let Some(kind) = own_endpoint {
        crate::byo_endpoint::clear_inherited(&mut cmd, kind, &env);
    }
    if let Some((id, sname)) = session {
        cmd.env("ACPMUX_ENV", "1")
            .env("ACPMUX_SESSION_ID", id)
            .env("ACPMUX_SESSION_NAME", sname)
            .env("ACPMUX_SOCKET", crate::config::socket_path())
            // With its home: a socket pairs only with an explicit home (`config::autostart_refusal`).
            .env("ACPMUX_HOME", crate::config::home())
            // Its caller token and the socket it is for (hub/person.rs (a)); the cmux CLI's caller.
            .envs(crate::person_tokens::caller_env(id))
            .env(crate::agent_tools::AGENT_SESSION_ENV, id);
        // RFD 0060 Weft move 3 (`laneGhCarrier`, off by default): lane-gh over the carrier forward
        // this daemon holds, while one of its owners is healthy; a profile's own value wins.
        #[cfg(unix)]
        if let Some(socket) = crate::cli::host_broker_forward::healthy_held_socket()
            && !cmd.as_std().get_envs().any(|(k, _)| k == LANE_GH_SOCKET_ENV)
            && !env.contains_key(LANE_GH_SOCKET_ENV)
        {
            cmd.env(LANE_GH_SOCKET_ENV, socket);
        }
        // This daemon's own acpmux, by absolute path: a login profile's PATH may find an older
        // one, which proves no caller (`cli_caller.rs`, bench round 4 A5).
        if let Some(bin) = crate::cli_caller::own_bin() {
            cmd.env(crate::cli_caller::BIN_ENV, bin);
        }
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
                let runtime = session_tmp::user_runtime_dir(uid);
                let mac = cfg!(target_os = "macos");
                cmd.envs(session_tmp::env_for(&dir, agent, blank, mac, runtime.as_deref(), uid));
            }
        }
    }
    // The durable store is bound by acpmux's profile spawn path; never
    // inherit a controller or shell value into another harness.
    cmd.env_remove("CMUX_HARNESS_SESSION_STORE_DIR");
    let launch =
        crate::harness_limits::launch_args(codex_launch, args, session.map(|_| (cwd, &env)));
    // `agents.sandbox.network` `allow` (agent_sandbox.rs): a chat's Codex sandbox reaches the
    // network. A remote chain's launch runs only what its plan checked.
    let launch = if codex_launch && session.is_some() && !remote_environment {
        let home = env.get("CODEX_HOME").map(std::path::PathBuf::from);
        crate::agent_sandbox::codex_args(crate::agent_sandbox::Sandbox::current(), launch, || {
            crate::harness_limits::codex_sets(
                args,
                cwd,
                home,
                crate::agent_sandbox::CODEX_NETWORK_KEY,
            )
        })
    } else {
        launch
    };
    // A remote chain's sandboxed launch runs only what its plan checked: no hook.
    let codex = (!remote_environment && codex_launch).then(|| (program.clone(), launch.clone()));
    let (launch, codex) = match codex {
        Some(_) if repo_gate => {
            (crate::codex_repo_gate::gated_args(&launch).unwrap_or(launch), None)
        }
        codex => (launch, codex),
    };
    cmd.args(launch).envs(env.iter());
    // The subagent mark is the daemon's to give (a workflow runner a subagent started,
    // `hub/workflow_runs.rs`), never a profile's: an agent's MCP servers would send as it.
    cmd.env_remove(crate::sender_env::SUBAGENT_ENV);
    // The profile's PATH first, never instead of the login PATH (login_env::with_agent_path).
    if !remote_environment && let Some(own) = env.get("PATH").filter(|p| !p.is_empty()) {
        cmd.env("PATH", crate::login_env::with_agent_path(own));
    }
    // The exec router's shims first (`placement/exec_router.rs`): on a Cloud machine with run
    // VMs on, a heavy build any process of this session starts (a script's, `make`'s, a
    // helper's) goes where the run VM placer sends it, not only Claude Code's own Bash calls.
    if session.is_some() && !remote_environment {
        let current = command_env_with(&cmd, true)
            .into_iter()
            .find(|(k, _)| k == "PATH")
            .map(|(_, v)| v)
            .unwrap_or_default();
        if let Some(path) = crate::placement::exec_router::session_path(&current) {
            cmd.env("PATH", path);
        }
    }
    // A machine a Mac lends GitHub: git's helper and the gh shim ask the Mac for a short-lived
    // App token (`github_session_env.rs`). The person's own git and gh auth still answer first.
    #[cfg(unix)]
    if session.is_some() && crate::github_session_env::lent() {
        let current = command_env_with(&cmd, !remote_environment);
        crate::github_session_env::apply(&mut cmd, &current);
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
    // And its own chat secrets, never another chat's (`chat_secrets.rs`).
    crate::chat_secrets::apply(&mut cmd, session.map(|(id, _)| id));
    crate::harness_limits::lift_claude(&mut cmd, profile, session.is_some(), !remote_environment);
    // A Chief turn or compactor (fresh process per turn): one sticky
    // subrouter account, so its prompt cache stays readable (subrouter_session.rs).
    let claude_code = profile.kind == crate::config::HarnessKind::ClaudeStdio
        || family.is_some_and(|f| f.starts_with("claude"));
    if claude_code {
        let env = command_env_with(&cmd, !remote_environment);
        let get = |k: &str| env.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone());
        // Claude Code 2.1 offers its to-do tools (TaskCreate, TaskUpdate) in a
        // `-p` session only when asked, and has no TodoWrite there. cmux shows
        // no agent to-do list (`todo_tools.rs`), so the switch is never on,
        // whatever the profile, the login or the daemon's env set.
        cmd.env_remove(TODO_TOOLS_ENV);
        // Claude Code's own cross-session messaging (ListAgents, SendMessage to other sessions,
        // its inbox socket) is off: its peer list is every Claude Code of the machine, whichever
        // daemon started it, and a message it holds shows nowhere; an agent here messages others
        // through acpmux (`hub/native_messaging.rs`). A value the profile or login set wins.
        // Undocumented in Claude Code: if it renames it, the PreToolUse gate still refuses a
        // SendMessage to an acpmux session; only the cross-daemon peer list comes back.
        if get(crate::claude_stdio::native_messaging::SWITCH_ENV).is_none() {
            cmd.env(crate::claude_stdio::native_messaging::SWITCH_ENV, "0");
        }
        if let Some(headers) = crate::subrouter_session::custom_headers(get) {
            cmd.env(crate::subrouter_session::HEADERS_ENV, headers);
        }
        // The sr and sr2 launchers reach their gateway with no base URL of their own.
        let launcher = [Some(program.as_str()), Some(name), family]
            .into_iter()
            .flatten()
            .any(|p| crate::sr2_priority::is_sr2_launcher(p) || is_sr_launcher(p));
        // Interactive or background (subrouter_priority.rs), after the lines already set; only
        // on a gateway's route, never on a direct Anthropic request.
        let env = command_env_with(&cmd, !remote_environment);
        let get = |k: &str| env.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone());
        if let Some(headers) = crate::subrouter_priority::custom_headers(get, launcher) {
            cmd.env(crate::subrouter_session::HEADERS_ENV, headers);
        }
        // sr2 cost labels (sr2_cost_labels.rs), over the lines set just above.
        let env = command_env_with(&cmd, !remote_environment);
        let get = |k: &str| env.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone());
        if let Some(headers) = crate::sr2_cost_labels::custom_headers(get) {
            cmd.env(crate::subrouter_session::HEADERS_ENV, headers);
        }
        // sr2 person priority (sr2_priority.rs), over the lines set just above. Never a
        // mark the daemon's own env carries.
        cmd.env_remove(crate::sr2_priority::PERSON_ENV);
        let env = command_env_with(&cmd, !remote_environment);
        let get = |k: &str| env.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone());
        let sr2_launcher = crate::sr2_priority::is_sr2_launcher(program)
            || crate::sr2_priority::is_sr2_launcher(name)
            || family.is_some_and(crate::sr2_priority::is_sr2_launcher);
        if let Some(headers) = crate::sr2_priority::custom_headers(get, sr2_launcher, sr2_person) {
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
        cmd.env(crate::questions::PREVIEW_FORMAT_ENV, format);
    }
    // A Claude agent's sign-in inputs, for a clear message if it has none (plain Claude Code)
    // and for `/status` (every Claude family, a launcher's too: `session_status.rs`).
    match (claude_code, session) {
        (true, Some((id, _))) => crate::claude_auth::remember(
            id,
            &command_env_with(&cmd, !remote_environment),
            route_unset.is_some() || route_name.is_some(),
            route_name,
            family == Some("claude"),
        ),
        (false, Some((id, _))) => crate::claude_auth::forget(id),
        _ => {}
    }
    // The compiler cache on a Cloud VM (`sccache_env.rs`): last, so a value the profile, the
    // login shell or this daemon's env gives wins, and a RUSTC_WRAPPER of theirs turns it off.
    #[cfg(unix)]
    {
        let env = command_env_with(&cmd, !remote_environment);
        crate::sccache_env::apply(&mut cmd, &env);
    }
    #[cfg(target_os = "linux")]
    if remote_environment {
        crate::linux_sandbox::scrub_loader_env(&mut cmd);
    }
    // `agents.envExclude`, last: whoever set a name (the daemon, the login shell, a profile,
    // `agents.env`, acpmux above), the agent never gets it; acpmux's session wiring stays.
    if !env_exclude.is_empty() {
        for (key, _) in command_env_with(&cmd, !remote_environment) {
            if crate::agent_env::excluded(&key, &env_exclude) {
                cmd.env_remove(&key);
            }
        }
    }
    // The hosted and direct translators take the hook home from this launch. Only the
    // selected local plugin enables its callbacks, regardless of inherited or profile env.
    cmd.env_remove(crate::bg_hook::HOME_ENV);
    if plugin_hooks && !remote_environment {
        cmd.env(crate::bg_hook::HOME_ENV, crate::config::home());
    }
    Ok((cmd, codex))
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

/// Whether `program` (or a profile name) is the subrouter launcher: `sr` (`sr claude ...`) or
/// the `claude-sr` profile named for it, which runs through the subrouter gateway.
fn is_sr_launcher(program: &str) -> bool {
    let base = std::path::Path::new(program.trim()).file_name().and_then(|n| n.to_str());
    base.is_some_and(|b| b == "sr" || b == "claude-sr")
}

/// How Claude Code started from `profile` writes its question previews
/// (`hub/questions.rs` `PreviewFormat`): its own
/// `CLAUDE_CODE_QUESTION_PREVIEW_FORMAT`, a reference resolved as the launch
/// resolves it. The hub labels the questions with it (`hub/tools.rs`) and
/// `harness_command` pins the agent to it, so the two never disagree.
pub(crate) fn preview_format(profile: &HarnessProfile) -> crate::questions::PreviewFormat {
    use crate::questions::{PREVIEW_FORMAT_ENV, PreviewFormat};
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
pub(crate) fn pinned_preview_format(cmd: &Command) -> crate::questions::PreviewFormat {
    use crate::questions::{PREVIEW_FORMAT_ENV, PreviewFormat};
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
pub(crate) fn resolved_profile_env(
    profile: &HarnessProfile,
) -> Result<std::collections::BTreeMap<String, String>> {
    let mut env = profile.env.clone();
    if !crate::config::profiles::has_env_refs(&env) {
        return Ok(env);
    }
    let resolve = |env: &mut std::collections::BTreeMap<String, String>| {
        crate::config::profiles::resolve_env_refs(
            env,
            &crate::login_env::reference_var,
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
    std::env::vars_os().filter(|(key, _)| host_env_allowed(&key.to_string_lossy())).collect()
}

/// [`host_environment`]'s names.
fn host_env_allowed(key: &str) -> bool {
    {
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
            // The QoS opt-out (`qos.rs`), so a daemon started with it starts
            // its hosts unclamped too.
            "ACPMUX_QOS",
            // This daemon's cloud build space (cmux-build-space): the `cmux` a harness runs
            // calls cmux Cloud in this build's space, never nightly's. A build tag, no secret.
            "CMUX_BUILD_SPACE",
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
    }
}

#[cfg(test)]
#[path = "command_tests.rs"]
mod tests;
