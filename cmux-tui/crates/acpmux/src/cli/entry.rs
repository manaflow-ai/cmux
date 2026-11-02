//! The program behind the `acpmux` binary, callable from another binary.
//! The cmux multicall binary runs it as `cmux acp …`; `display_name` names
//! the command in help and errors, and `daemon_prefix` is what the detached
//! daemon is started with (`<current exe> <prefix…> daemon run`).

use crate::cli::command::{Cli, Command, RouterCmd, flatten};
use crate::cli::errors;
use crate::cli::run::run_client;
use crate::daemon::{DaemonOptions, connect};
use anyhow::Result;
use clap::{CommandFactory, FromArgMatches};
use std::ffi::OsString;

static ORIGINAL_ARGS: std::sync::OnceLock<Vec<String>> = std::sync::OnceLock::new();

/// The acpmux arguments passed by its executable (also stripped of `cmux acp`).
pub(crate) fn original_args() -> Option<&'static [String]> {
    ORIGINAL_ARGS.get().map(Vec::as_slice)
}

pub struct Invocation {
    /// `acpmux`, or `cmux acp` inside cmux.
    pub display_name: String,
    /// Arguments before `daemon run` when this program starts its daemon.
    pub daemon_prefix: Vec<OsString>,
    /// State directory when `ACPMUX_HOME` is unset (default `~/.acpmux`).
    pub home: Option<std::path::PathBuf>,
}

impl Default for Invocation {
    fn default() -> Self {
        Self { display_name: "acpmux".into(), daemon_prefix: Vec::new(), home: None }
    }
}

/// Run the acpmux command line. `args` excludes the program name.
pub fn main(args: Vec<OsString>, invocation: Invocation) -> Result<()> {
    // A launcher can hand us a blocked signal mask (an app thread that
    // blocks SIGTERM, SIGCHLD, ...). exec keeps the mask, and threads
    // inherit it, so SIGTERM would stay pending forever and child exits
    // would never be seen. Clear it before the runtime starts its threads.
    #[cfg(unix)]
    unsafe {
        let mut empty: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut empty);
        libc::pthread_sigmask(libc::SIG_SETMASK, &empty, std::ptr::null_mut());
    }
    crate::daemon::set_daemon_prefix(invocation.daemon_prefix.clone());
    // An agent host serves one harness for its controller; it has no CLI.
    // Agent work yields CPU and disk to the app (`qos.rs`): before any thread
    // starts, since on macOS this re-executes the host in place under a clamp.
    if args.first().is_some_and(|a| a == crate::agent_host::HOST_ARG) {
        crate::qos::enter(crate::qos::Role::AgentHost);
        return crate::agent_host::host::main();
    }
    // A background task's runner (`bg_run.rs`): one task, no CLI.
    if args.first().is_some_and(|a| a == crate::bg_run::RUN_ARG) {
        crate::qos::enter(crate::qos::Role::BackgroundTaskRunner);
        return crate::bg_run::main();
    }
    // Claude Code's PreToolUse hook for background shells (`bg_hook.rs`).
    if args.first().is_some_and(|a| a == crate::bg_hook::HOOK_ARG) {
        return crate::bg_hook::main(args.get(1).map(std::path::PathBuf::from));
    }
    #[cfg(target_os = "linux")]
    if args.first().is_some_and(|a| a == "__remote-sandbox-canary-unix") {
        return crate::linux_sandbox::keeper::canary_unix(args.get(1..).unwrap_or_default())
            .map_err(anyhow::Error::msg);
    }
    #[cfg(target_os = "linux")]
    if args.first().is_some_and(|a| a == "__remote-sandbox-canary-rename") {
        return crate::linux_sandbox::keeper::canary_rename(args.get(1..).unwrap_or_default())
            .map_err(anyhow::Error::msg);
    }
    #[cfg(target_os = "linux")]
    if args.first().is_some_and(|a| a == "__remote-sandbox-init") {
        crate::linux_sandbox::init::main(args.into_iter().skip(1).collect());
    }
    #[cfg(target_os = "linux")]
    if args.first().is_some_and(|a| a == "__remote-sandbox-keeper") {
        crate::linux_sandbox::keeper::main(args.into_iter().skip(1).collect());
    }
    if let Some(home) = invocation.home.clone() {
        crate::config::set_home_override(home);
    }
    runtime(&args)?.block_on(async_main(args, invocation))
}

/// The stdio MCP servers acpmux gives each agent session (`agent_tools.rs`).
/// A harness starts a set of them for every thread it loads (a codex
/// subagent gets its own set, kept until the app-server exits), so a tokio
/// worker per core in each one adds up: about 100 tasks a set on a 32-core
/// machine, which filled the sessions slice's task cap on a fleet host.
const STDIO_MCP_SERVERS: [&str; 7] =
    ["acpmux-mcp", "subsession-mcp", "forum-mcp", "offer-mcp", "secret-mcp", "cua-mcp", "repo-mcp"];

/// Worker threads of a stdio MCP server: it answers one client's requests
/// on one pipe. Still a multi-thread runtime, so `block_in_place` works.
const MCP_WORKERS: usize = 2;

/// The worker count `args` (without the program name) runs with: None is
/// tokio's default, one per core.
fn runtime_workers(args: &[OsString]) -> Option<usize> {
    let command = args.iter().find(|a| *a != "--json" && *a != "--suppress-reads")?;
    STDIO_MCP_SERVERS.iter().any(|name| command == name).then_some(MCP_WORKERS)
}

/// Each runtime worker's stack: the main thread's default on Linux and macOS, not tokio's 2 MiB.
/// The daemon's request futures (`server/requests.rs` `dispatch_request` above all) are large in a
/// debug build, and a worker that polled one deep in adoption overflowed its stack and aborted the
/// daemon (`tests/durable_agents.rs`, about one run in three on Linux CI). The test processes give
/// their threads the same stack (`tests/support/daemon_env.rs`), so a hub they run in process polls
/// these futures on the stack the daemon gives them.
pub const WORKER_STACK_BYTES: usize = 8 << 20;

fn runtime(args: &[OsString]) -> std::io::Result<tokio::runtime::Runtime> {
    let mut builder = tokio::runtime::Builder::new_multi_thread();
    builder.thread_stack_size(WORKER_STACK_BYTES);
    if let Some(workers) = runtime_workers(args) {
        builder.worker_threads(workers);
    }
    builder.enable_all().build()
}

async fn async_main(args: Vec<OsString>, invocation: Invocation) -> Result<()> {
    // `acpmux ls | head` must end quietly, not panic on a closed pipe.
    #[cfg(unix)]
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }
    let _ = ORIGINAL_ARGS.set(args.iter().map(|a| a.to_string_lossy().into_owned()).collect());
    let mut argv: Vec<OsString> = Vec::with_capacity(args.len() + 2);
    argv.push(invocation.display_name.clone().into());
    argv.extend(args);
    // The command word, past any global flags before it
    // (`acpmux --json exec …`), so these rewrites see the same command.
    let at = command_index(&argv);
    // `acpmux daemon` with nothing after it means `daemon run`.
    if at + 1 == argv.len() && argv[at] == "daemon" {
        argv.push("run".into());
    }
    if argv.get(at).map(|a| a == "--skill" || a == "--guide").unwrap_or(false) {
        argv[at] = "skill".into();
    }
    // `acpmux stop NAME` stops that session (`session stop`), never the daemon (`daemon stop`).
    if let Some(word) = argv.get_mut(at).filter(|a| *a == "stop") {
        *word = "session".into();
        argv.insert(at + 1, "stop".into());
    }
    let run_alias = argv.get(at).map(|a| a == "run" || a == "exec").unwrap_or(false);
    let exec_alias = argv.get(at).map(|a| a == "exec").unwrap_or(false);
    // clap keeps command names as `&'static str`; one per process.
    let name: &'static str = Box::leak(invocation.display_name.clone().into_boxed_str());
    let mut grammar = crate::cli::help_examples::attach(Cli::command()).name(name).bin_name(name);
    let json_out = argv.iter().take_while(|a| *a != "--").any(|a| a == "--json");
    let matches = match grammar.try_get_matches_from_mut(argv.clone()) {
        Ok(matches) => matches,
        // A flag another command takes says which, and what this one does instead; a root word
        // a command group takes names that command; under --json any other is the envelope.
        Err(e) => {
            let refusal = crate::cli::unknown_flag::explain(&e, &grammar, &argv, at, name)
                .or_else(|| crate::cli::unknown_command::explain(&e, &grammar, &argv, at, name))
                .or_else(|| {
                    json_out.then(|| crate::cli::unknown_command::envelope(&e, name)).flatten()
                });
            match refusal {
                Some(refusal) => errors::exit_with(&refusal.into(), json_out),
                None => e.exit(),
            }
        }
    };
    let cli = Cli::from_arg_matches(&matches).unwrap_or_else(|e| e.exit());
    // `new`'s words are its prompt: a lone `-` among them would go as the text "-".
    if let Some(Command::New(_)) = &cli.command
        && let Some((_, new)) = matches.subcommand()
        && let Some(refusal) =
            crate::cli::unknown_command::stdin_dash(&grammar, new, &argv, at, name)
    {
        errors::exit_with(&refusal.into(), json_out)
    }
    let command = cli.command.map(flatten).map(|c| match c {
        Command::New(mut a) if run_alias => {
            a.quiet = true;
            a.detach = true;
            if exec_alias {
                a.ephemeral = true;
            }
            Command::New(a)
        }
        other => other,
    });
    match command {
        #[cfg(unix)]
        Some(Command::CodexAuthBroker { home, codex }) => {
            crate::cli::codex_auth_broker::run(home, codex).await
        }
        Some(Command::Gh { args }) => crate::cli::gh_shim::run(args).await,
        None => {
            let client = connect(true).await?;
            crate::tui::run(client, None).await
        }
        #[cfg(unix)]
        Some(Command::Router(RouterCmd::Serve)) => {
            cmux_coderouter::serve(crate::config::home()).await
        }
        // Windows: the router's folder owner-only, its admin socket a local
        // socket that refuses peers of another user (server/windows_socket.rs).
        #[cfg(windows)]
        Some(Command::Router(RouterCmd::Serve)) => {
            let home = crate::config::home();
            crate::owner_only::private_dir(&home.join("router"))?;
            cmux_coderouter::serve_with_admin(home, crate::server::router_admin).await
        }
        Some(Command::DaemonRun {
            listen,
            token,
            memory,
            log,
            ready_fd,
            person_key_fd,
            allow_dev_origin,
            dev,
        }) => {
            tracing_subscriber::fmt()
                .with_env_filter(
                    tracing_subscriber::EnvFilter::try_new(&log).unwrap_or_else(|_| "info".into()),
                )
                .with_target(false)
                .init();
            crate::qos::enter(crate::qos::Role::Daemon);
            let result = crate::daemon::run(DaemonOptions {
                ws_listen: listen,
                ws_token: token,
                memory,
                ready_fd,
                person_key_fd,
                dev_origins: allow_dev_origin,
                dev,
            })
            .await;
            if let Err(error) = result {
                // A systemd start can race the daemon that is handing over
                // this home. Keep its lock refusal a distinct, prevented
                // restart status; detached clients still use the readiness
                // line and retry through `connect`.
                if error.to_string().starts_with("another acpmux daemon holds ") {
                    let error: anyhow::Error = crate::cli::errors::AppError::new(
                        crate::cli::errors::Code::Runtime,
                        "daemon_lock_held",
                        error.to_string(),
                    )
                    .with_exit(75)
                    .into();
                    crate::cli::errors::exit_with(&error, false);
                }
                return Err(error);
            }
            // The daemon has stopped its agents and synced its store. Exit
            // now rather than wait for the runtime to drain blocking tasks
            // (a launcher `--version` check can take 20 s).
            std::process::exit(0)
        }
        Some(Command::CliAgent {
            last_block,
            prompt_arg,
            after_echo,
            instructions,
            tty,
            command,
        }) => {
            crate::cli::cli_agent::run(crate::cli::cli_agent::Options {
                command,
                last_block,
                prompt_arg,
                after_echo,
                instructions,
                tty,
            })
            .await
        }
        Some(Command::UniichatAgent { url, home, whole_prompt }) => {
            crate::cli::uniichat_agent::run(crate::cli::uniichat_agent::Options {
                url,
                home,
                whole_prompt,
            })
            .await
        }
        Some(Command::Stdio { model, preset, effort, policy }) => {
            let (harness, model) = match model {
                Some(target) => {
                    let (harness, model) = crate::cli::orchestrate::split_target(&target);
                    (Some(harness), model)
                }
                None => (None, None),
            };
            crate::cli::stdio::run(crate::cli::stdio::Defaults {
                harness,
                model,
                effort,
                policy,
                preset,
            })
            .await
        }
        Some(Command::Task(cmd)) => {
            let json_out = cli.json;
            match crate::cli::task::run(cmd, json_out).await {
                Ok(()) => Ok(()),
                Err(e) => errors::exit_with(&e, json_out),
            }
        }
        Some(Command::Resolve { query }) => {
            let json_out = cli.json;
            match crate::cli::resolve::run(query, json_out).await {
                Ok(()) => Ok(()),
                Err(e) => errors::exit_with(&e, json_out),
            }
        }
        Some(Command::Bead(cmd)) => {
            let json_out = cli.json;
            match crate::cli::beads::run(cmd, json_out).await {
                Ok(()) => Ok(()),
                Err(e) => errors::exit_with(&e, json_out),
            }
        }
        Some(Command::Forum(cmd)) => {
            let json_out = cli.json;
            match crate::cli::forum::run(cmd, json_out).await {
                Ok(()) => Ok(()),
                Err(e) => errors::exit_with(&e, json_out),
            }
        }
        Some(Command::Harness(cmd)) => {
            let json_out = cli.json;
            match crate::cli::harness::run(cmd, json_out).await {
                Ok(()) => Ok(()),
                Err(e) => errors::exit_with(&e, json_out),
            }
        }
        Some(Command::Hand(cmd)) => match crate::hand::run(cmd, cli.json).await {
            Ok(()) => Ok(()),
            Err(e) => {
                // Hand commands historically use exit 1 for every failure; keep that
                // contract while still emitting the shared --json envelope.
                let app = errors::classify(&e).with_exit(1);
                errors::exit_with(&anyhow::Error::new(app), cli.json)
            }
        },
        Some(Command::CuaMcp) => crate::cua_v2::run_bridge().await,
        Some(Command::SecretMcp) => crate::secret_mcp::run().await,
        Some(Command::OfferMcp) => crate::offer_mcp::run().await,
        Some(Command::SubsessionMcp) => crate::subsession_mcp::run().await,
        Some(Command::ForumMcp) => crate::forum_mcp::run().await,
        Some(Command::RepoMcp) => crate::cloud_repo_mcp::run().await,
        Some(Command::AcpmuxMcp) => crate::acpmux_mcp::run().await,
        Some(Command::Skill) => {
            use std::io::Write;
            let _ = std::io::stdout().write_all(crate::cli::orchestrate::guide().as_bytes());
            Ok(())
        }
        // No daemon: what this binary serves (`capabilities.rs`).
        Some(Command::TriggerChat { protocol, principal_fd }) => {
            match crate::cli::trigger_chat::run(&protocol, principal_fd).await {
                Ok(()) => Ok(()),
                Err(e) => errors::exit_with(&e, cli.json),
            }
        }
        Some(Command::Capabilities) => {
            use std::io::Write;
            let _ = std::io::stdout().write_all(crate::capabilities::render(cli.json).as_bytes());
            Ok(())
        }
        Some(cmd) => {
            let json_out = cli.json;
            match run_client(cmd, json_out, cli.suppress_reads).await {
                Ok(()) => Ok(()),
                Err(e) => errors::exit_with(&e, json_out),
            }
        }
    }
}

/// Index of the first argument after the program name that is not a global
/// flag (`--json`, `--suppress-reads`); `argv.len()` when there is none.
fn command_index(argv: &[OsString]) -> usize {
    argv.iter()
        .skip(1)
        .position(|a| a != "--json" && a != "--suppress-reads")
        .map(|i| i + 1)
        .unwrap_or(argv.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn os(args: &[&str]) -> Vec<OsString> {
        args.iter().map(OsString::from).collect()
    }

    #[test]
    fn a_stdio_mcp_server_runs_on_a_small_runtime() {
        for name in [
            "acpmux-mcp",
            "subsession-mcp",
            "forum-mcp",
            "offer-mcp",
            "secret-mcp",
            "cua-mcp",
            "repo-mcp",
        ] {
            assert_eq!(runtime_workers(&os(&[name])), Some(MCP_WORKERS), "{name}");
            assert_eq!(runtime_workers(&os(&["--json", name])), Some(MCP_WORKERS), "{name}");
        }
    }

    #[test]
    fn every_other_command_keeps_the_default_runtime() {
        for args in [&["ls"][..], &["daemon", "run"], &["send", "forum-mcp"], &[], &["--json"]] {
            assert_eq!(runtime_workers(&os(args)), None, "{args:?}");
        }
    }

    #[test]
    fn the_small_runtime_has_its_workers_and_not_one_per_core() {
        let small = runtime(&os(&["forum-mcp"])).unwrap();
        assert_eq!(small.metrics().num_workers(), MCP_WORKERS);
        // Every other command keeps tokio's default: one worker per core.
        let default = runtime(&os(&["ls"])).unwrap();
        if std::thread::available_parallelism().unwrap().get() > MCP_WORKERS {
            assert!(default.metrics().num_workers() > MCP_WORKERS);
        }
    }
}
