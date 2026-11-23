//! The program behind the `acpmux` binary, callable from another binary.
//! The cmux multicall binary runs it as `cmux agent …` or `cmux acp …`; `display_name` names
//! the command in help and errors, and `daemon_prefix` is what the detached
//! daemon is started with (`<current exe> <prefix…> daemon run`).

use crate::cli::command::{Cli, Command, RouterCmd, aliases, flatten};
use crate::cli::errors;
use crate::cli::run::run_client;
use crate::daemon::{DaemonOptions, connect};
use anyhow::Result;
use clap::{CommandFactory, FromArgMatches, Subcommand};
use std::ffi::OsString;

static ORIGINAL_ARGS: std::sync::OnceLock<Vec<String>> = std::sync::OnceLock::new();
static PROGRAM: std::sync::OnceLock<String> = std::sync::OnceLock::new();

/// The command the caller used, for follow-up commands printed by the CLI.
pub(crate) fn program() -> &'static str {
    PROGRAM.get().map_or("acpmux", String::as_str)
}

/// The engine arguments, with the executable or cmux scope removed.
pub(crate) fn original_args() -> Option<&'static [String]> {
    ORIGINAL_ARGS.get().map(Vec::as_slice)
}

pub struct Invocation {
    /// The standalone binary or the invoking cmux scope.
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

/// The whole `main` of a binary that is acpmux: the `acpmux` binary of this
/// package (the tests' and a local build's) and `acpmux-standalone`, the one
/// the packages ship, which has this crate without its `build-id` feature and
/// installs the build id itself first.
///
/// # Safety
///
/// Call it first in `main`, while no other thread runs: it removes variables
/// from the process environment.
pub unsafe fn process_main() -> Result<()> {
    // A terminal's launch credential names that one terminal: this process
    // and everything it starts serve many, so it is dropped before any thread
    // exists (plans/cmux-next/identity.md section 2).
    // SAFETY: the caller's contract: no other thread runs yet.
    unsafe { std::env::remove_var(crate::config::LAUNCH_CREDENTIAL_ENV) };
    // Nor does any of it act as the Chief whose host started it.
    for key in crate::config::CHIEF_CREDENTIAL_ENV {
        // SAFETY: as above, before any thread exists.
        unsafe { std::env::remove_var(key) };
    }
    crate::heap_profile::start();
    // glibc builds: two malloc arenas, not eight per core (malloc_arenas.rs).
    // SAFETY: as above, before any thread exists.
    unsafe {
        cmux_tui_platform::malloc_arenas::cap(cmux_tui_platform::malloc_arenas::DAEMON_ARENAS);
    }
    main(std::env::args_os().skip(1).collect(), Invocation::default())
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
        crate::oom_rank::raise_agent();
        crate::qos::enter(crate::qos::Role::AgentHost);
        return crate::agent_host::host::main();
    }
    // A background task's runner (`bg_run.rs`): one task, no CLI.
    if args.first().is_some_and(|a| a == crate::bg_run::RUN_ARG) {
        crate::oom_rank::raise_agent();
        crate::qos::enter(crate::qos::Role::BackgroundTaskRunner);
        return crate::bg_run::main();
    }
    // A bench's sized chat, written by this build's store (`god_fixture.rs`): no daemon, no CLI.
    if args.first().is_some_and(|a| a == crate::god_fixture::SEED_CHAT_ARG) {
        return crate::god_fixture::seed_chat_main(args.get(1..).unwrap_or_default());
    }
    // Claude Code's PreToolUse hook for background shells (`bg_hook.rs`).
    if args.first().is_some_and(|a| a == crate::bg_hook::HOOK_ARG) {
        return crate::bg_hook::main(args.get(1).map(std::path::PathBuf::from));
    }
    // A Codex start's PreToolUse hook in a filling checkout (`codex_repo_gate.rs`): no runtime.
    if args.first().is_some_and(|a| a == crate::codex_repo_gate::HOOK_ARG) {
        return crate::codex_repo_gate::main();
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
const STDIO_MCP_SERVERS: [&str; 9] = [
    "acpmux-mcp",
    "subsession-mcp",
    "forum-mcp",
    "offer-mcp",
    "secret-mcp",
    "computer-use-mcp",
    "repo-mcp",
    "hosted-mcp",
    "github-mcp",
];

/// Worker threads of a stdio MCP server: it answers one client's requests
/// on one pipe. Still a multi-thread runtime, so `block_in_place` works.
const MCP_WORKERS: usize = 2;
/// Worker threads of `tools-mcp` (`tools_mcp.rs`), acpmux's own servers in one process per chat:
/// each call is a daemon request it waits on, so one worker serves them, and the process is a
/// main thread, this worker and the parent watch. Still a multi-thread runtime, so
/// `block_in_place` works.
const TOOLS_MCP_WORKERS: usize = 1;
/// The longest a stopping daemon waits for its queued log lines to be written: a log output
/// that takes no bytes must not keep a stopped daemon from exiting.
// timeout: a hang breaker on a local log write at exit, not a wait for a slow path; lines not written in time are dropped
const LOG_FLUSH_BUDGET: std::time::Duration = std::time::Duration::from_secs(1);

/// The worker count `args` (without the program name) runs with: None is
/// tokio's default, one per core.
fn runtime_workers(args: &[OsString]) -> Option<usize> {
    let mut words = args.iter().filter(|a| *a != "--json" && *a != "--suppress-reads");
    let command = words.next()?;
    // `bridge mcp` is the desktop apps' stdio server (`cli/bridge.rs`).
    let bridge_mcp = command == "bridge" && words.next().is_some_and(|a| a == "mcp");
    if command == crate::tools_mcp::ARG {
        return Some(TOOLS_MCP_WORKERS);
    }
    (bridge_mcp || STDIO_MCP_SERVERS.iter().any(|name| command == name)).then_some(MCP_WORKERS)
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
    // The daemon outranks the work it supervises (`daemon_priority.rs`): its nice before any
    // runtime thread starts (they inherit it), and each runtime thread's QoS on macOS.
    if crate::daemon_priority::is_daemon_run(args) {
        crate::daemon_priority::raise();
        builder.on_thread_start(crate::daemon_priority::thread_start);
    }
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
    let name = PROGRAM.get_or_init(|| invocation.display_name.clone()).as_str();
    let build_grammar = |front_door| {
        crate::cli::help_examples::attach(Cli::command(), front_door).name(name).bin_name(name)
    };
    let mut grammar = build_grammar(false);
    let json_out = argv.iter().take_while(|a| *a != "--").any(|a| a == "--json");
    let matches = match grammar.try_get_matches_from_mut(argv.clone()) {
        Ok(matches) => matches,
        // A flag another command takes says which, and what this one does instead; a root word
        // a command group takes names that command; under --json any other is the envelope.
        Err(e) => {
            // Only help and errors need front-door spellings. Normal calls use the
            // unchanged engine grammar, including its canonical variant names.
            let e = if name == "cmux agent" {
                grammar = build_grammar(true);
                grammar.try_get_matches_from_mut(argv.clone()).err().unwrap_or(e)
            } else {
                e
            };
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
        Some(Command::Gh { args }) => crate::cli::gh_shim::run(args).await,
        // Before anything that reads or writes the home: this runs as root.
        #[cfg(target_os = "linux")]
        Some(Command::DaemonEnroll { person_key_fd }) => {
            let status = crate::daemon::provision::enroll_running(person_key_fd).await?;
            if json_out {
                crate::cli::output::print_json(&status);
            } else {
                println!(
                    "enrolled: personKey {} personInstance {}",
                    status.get("personKey").and_then(serde_json::Value::as_bool).unwrap_or(false),
                    status.get("personInstance").and_then(serde_json::Value::as_str).unwrap_or("")
                );
            }
            Ok(())
        }
        #[cfg(not(target_os = "linux"))]
        Some(Command::DaemonEnroll { .. }) => {
            Err(anyhow::anyhow!("daemon enroll runs only on Linux"))
        }
        None => {
            let client = connect(true).await?;
            crate::tui_entry::run(client, None).await
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
            insecure_network_listen,
            memory,
            log,
            ready_fd,
            person_key_fd,
            allow_dev_origin,
            dev,
            take_over,
        }) => {
            let logs = tracing_subscriber::fmt()
                .with_env_filter(
                    tracing_subscriber::EnvFilter::try_new(&log).unwrap_or_else(|_| "info".into()),
                )
                .with_target(false);
            // A logging thread only queues its line: a log output that takes no bytes (a full
            // pipe, a stalled disk) never stops the daemon (`log_sink.rs`).
            // Under systemd, each line also goes to a bounded `daemon.log` in the home, so a
            // daemon whose journal lines were dropped still leaves its evidence (`log_keep.rs`).
            let out = crate::log_keep::Tee {
                out: std::io::stdout(),
                kept: crate::log_keep::Kept::for_service(&crate::config::home()),
            };
            match crate::log_sink::Sink::start(out) {
                Ok(sink) => {
                    sink.install();
                    logs.with_writer(sink).init();
                }
                Err(e) => {
                    logs.init();
                    tracing::warn!(
                        "no log writer thread, lines are written where they are logged: {e}"
                    );
                }
            }
            // An acknowledged reply waits on the event journal's sync, which a utility disk tier
            // throttles 15-30x under another app's disk work (STATUS 11554): the daemon stays at
            // the default tier, and only its background threads yield.
            crate::qos::enter_daemon();
            // Which priority knobs took, for the duress bench (`daemon_priority.rs`).
            tracing::info!("{}", crate::daemon_priority::report().line());
            // Agents before the daemon for the OOM killer and earlyoom (`oom_rank.rs`).
            if let Some(p) = crate::oom_rank::protect_daemon() {
                tracing::info!("{}", crate::oom_rank::describe(p));
            }
            // Handoff writers retain the home lock until drained or process exit. This scope
            // outlives daemon::run's deadline and the final log flush below.
            let exit_tasks = cmux_scope::Scope::new("daemon-exit");
            let result = crate::daemon::run(
                DaemonOptions {
                    ws_listen: listen,
                    ws_token: token,
                    insecure_network_listen,
                    memory,
                    ready_fd,
                    person_key_fd,
                    dev_origins: allow_dev_origin,
                    dev,
                    take_over,
                },
                &exit_tasks,
            )
            .await;
            // The lines logged so far reach the log before the process ends.
            crate::log_sink::flush(crate::daemon::shutdown_time_left().unwrap_or(LOG_FLUSH_BUDGET));
            if let Err(error) = result {
                // A systemd start can race the daemon that is handing over
                // this home. Keep its lock refusal a distinct, prevented
                // restart status; detached clients still use the readiness
                // line and retry through `connect`.
                // A supervised owner (`--take-over`) exits 1 instead: the unit restarts it
                // (`Restart=always`) until the home is its own, never leaving the unit failed.
                if !take_over && error.to_string().starts_with("another acpmux daemon holds ") {
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
            // (a launcher `--version` check can take 20 s); 74 when its store
            // asked for a restart (`daemon::EXIT_REPAIR`).
            crate::heap_profile::finish();
            std::process::exit(crate::daemon::exit_status())
        }
        Some(Command::CliAgent {
            last_block,
            prompt_arg,
            after_echo,
            instructions,
            tty,
            prints_only,
            command,
        }) => {
            crate::cli::cli_agent::run(crate::cli::cli_agent::Options {
                command,
                last_block,
                prompt_arg,
                after_echo,
                instructions,
                tty,
                prints_only,
            })
            .await
        }
        Some(Command::UniichatAgent { action, url, home, whole_prompt }) => {
            let options = crate::cli::uniichat_agent::Options { url, home, whole_prompt };
            if action.as_deref() == Some("login") {
                crate::cli::uniichat_login::run(options).await
            } else {
                crate::cli::uniichat_agent::run(options).await
            }
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
        Some(Command::Race(cmd)) => {
            let json_out = cli.json;
            match crate::cli::race::run(cmd, json_out).await {
                Ok(()) => Ok(()),
                Err(e) => errors::exit_with(&e, json_out),
            }
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
        Some(Command::WhoElse(args)) => {
            let json_out = cli.json;
            match crate::cli::who_else::run(args, json_out).await {
                Ok(()) => Ok(()),
                Err(e) => errors::exit_with(&e, json_out),
            }
        }
        Some(Command::Ledger(args)) => {
            let json_out = cli.json;
            match crate::cli::ledger::run(args, json_out).await {
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
        Some(Command::Bridge(cmd)) => {
            let json_out = cli.json;
            match crate::cli::bridge::run(cmd, json_out).await {
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
        Some(Command::Desktop(cmd)) => match crate::cli::desktop::run(cmd, cli.json) {
            Ok(()) => Ok(()),
            Err(e) => errors::exit_with(&e, cli.json),
        },
        Some(Command::Watch(cmd)) => {
            let json_out = cli.json;
            match crate::cli::watch::run(cmd, json_out).await {
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
        Some(Command::ComputerUseMcp) => crate::computer_use::mcp::run(false).await,
        Some(Command::SecretMcp) => crate::secret_mcp::run().await,
        Some(Command::OfferMcp) => crate::offer_mcp::run().await,
        Some(Command::SubsessionMcp) => crate::subsession_mcp::run().await,
        Some(Command::ForumMcp) => crate::forum_mcp::run().await,
        Some(Command::RepoMcp) => crate::cloud_repo_mcp::run().await,
        Some(Command::HostedMcp) => crate::hosted_mcp::run().await,
        Some(Command::GithubMcp) => crate::github_mcp::run().await,
        Some(Command::AcpmuxMcp) => crate::acpmux_mcp::run().await,
        Some(Command::InboxRelay) => crate::claude_inbox_relay::serve().await,
        Some(Command::ToolsMcp) => crate::cli::tools_mcp::run().await,
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
        Some(Command::MachineAuth) => {
            // The report is already on stdout; a failed check leaves through the shared
            // error exit (status 1) like every other command.
            if crate::cli::machine_auth::run(cli.json) == 0 {
                Ok(())
            } else {
                let app = errors::AppError::new(
                    errors::Code::Runtime,
                    "machine_auth_not_ok",
                    "this machine's agents do not reach models through the Cloud service",
                )
                .with_exit(1);
                errors::exit_with(&anyhow::Error::new(app), cli.json)
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

/// A command the session engine accepts, including compatibility spellings.
/// The cmux CLI uses the same grammar when sharing its `agent` scope.
pub fn is_command(word: &str) -> bool {
    // Routing needs only the first word. Build the parser once the command has an owner.
    matches!(word, "stop" | "--skill" | "--guide")
        || Command::has_subcommand(word)
        || aliases::GROUPS.iter().any(|group| group.contains(&word))
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
#[path = "entry_tests.rs"]
mod tests;
