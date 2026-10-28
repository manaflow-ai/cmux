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
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;

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
    // SAFETY: `empty` is a local sigset_t (all-zero is a valid value) that
    // sigemptyset initializes before pthread_sigmask reads it; the old-set
    // pointer may be null.
    unsafe {
        let mut empty: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut empty);
        libc::pthread_sigmask(libc::SIG_SETMASK, &empty, std::ptr::null_mut());
    }
    crate::daemon::set_daemon_prefix(invocation.daemon_prefix.clone());
    // An agent host serves one harness for its controller; it has no CLI.
    if args.first().is_some_and(|a| a == crate::agent_host::HOST_ARG) {
        return crate::agent_host::host::main();
    }
    if let Some(home) = invocation.home.clone() {
        crate::config::set_home_override(home);
    }
    let mut runtime = tokio::runtime::Builder::new_multi_thread();
    runtime.enable_all();
    let poll_watch = DaemonPollWatch::instrument(&args, &mut runtime);
    runtime.build()?.block_on(async_main(args, invocation, poll_watch))
}

/// Lab builds only (cmux-tui/lab/stability.env): the daemon's poll watch
/// (cmux-blocking `poll_watch`) times every task poll of its runtime and
/// writes to the hang log the daemon installs. Other commands install no
/// hang log, so they get no watch. Empty in other builds.
struct DaemonPollWatch {
    #[cfg(all(tokio_unstable, feature = "cmux-stability"))]
    watch: Option<cmux_blocking::poll_watch::PollWatch>,
}

impl DaemonPollWatch {
    fn instrument(args: &[OsString], runtime: &mut tokio::runtime::Builder) -> Self {
        #[cfg(all(tokio_unstable, feature = "cmux-stability"))]
        {
            let watch = runs_daemon(args).then(|| {
                let watch = cmux_blocking::poll_watch::PollWatch::lab();
                watch.instrument(runtime);
                watch
            });
            Self { watch }
        }
        #[cfg(not(all(tokio_unstable, feature = "cmux-stability")))]
        {
            let _ = (args, runtime);
            Self {}
        }
    }

    /// The daemon exits without dropping its runtime: write the totals now.
    fn finish(&self) {
        #[cfg(all(tokio_unstable, feature = "cmux-stability"))]
        if let Some(watch) = &self.watch {
            watch.finish();
        }
    }
}

/// `args` (without the program name) run `daemon run`, the way
/// `async_main` reads them: past the global flags, `daemon` alone means
/// `daemon run`.
#[cfg(all(tokio_unstable, feature = "cmux-stability"))]
fn runs_daemon(args: &[OsString]) -> bool {
    let mut words = args.iter().skip_while(|arg| is_global_flag(arg));
    words.next().is_some_and(|arg| arg == "daemon") && words.next().is_none_or(|arg| arg == "run")
}

async fn async_main(
    args: Vec<OsString>,
    invocation: Invocation,
    poll_watch: DaemonPollWatch,
) -> Result<()> {
    // `acpmux ls | head` must end quietly, not panic on a closed pipe.
    #[cfg(unix)]
    // SAFETY: SIG_DFL is a valid disposition for SIGPIPE; no handler runs.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }
    let mut argv: Vec<OsString> = Vec::with_capacity(args.len() + 2);
    argv.push(invocation.display_name.clone().into());
    argv.extend(args);
    // The command word, past any global flags before it
    // (`acpmux --json exec …`), so these rewrites see the same command.
    let at = command_index(&argv);
    // `acpmux daemon` with nothing after it means `daemon run`.
    if at + 1 == argv.len() && argv.get(at).is_some_and(|a| a == "daemon") {
        argv.push("run".into());
    }
    if let Some(word) = argv.get_mut(at).filter(|a| *a == "--skill" || *a == "--guide") {
        *word = "skill".into();
    }
    let run_alias = argv.get(at).map(|a| a == "run" || a == "exec").unwrap_or(false);
    let exec_alias = argv.get(at).map(|a| a == "exec").unwrap_or(false);
    // clap keeps command names as `&'static str`; one per process.
    let name: &'static str = Box::leak(invocation.display_name.clone().into_boxed_str());
    let matches = Cli::command().name(name).bin_name(name).get_matches_from(argv);
    let cli = Cli::from_arg_matches(&matches).unwrap_or_else(|e| e.exit());
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
            // The log, and the same events as trace instants while a recording runs
            // (`trace_layer.rs`); the filter is the log's for both.
            tracing_subscriber::registry()
                .with(
                    tracing_subscriber::EnvFilter::try_new(&log).unwrap_or_else(|_| "info".into()),
                )
                .with(tracing_subscriber::fmt::layer().with_target(false))
                .with(crate::trace_layer::TraceLayer::new())
                .init();
            crate::daemon::run(DaemonOptions {
                ws_listen: listen,
                ws_token: token,
                memory,
                ready_fd,
                person_key_fd,
                dev_origins: allow_dev_origin,
                dev,
            })
            .await?;
            // The daemon has stopped its agents and synced its store. Exit
            // now rather than wait for the runtime to drain blocking tasks
            // (a launcher `--version` check can take 20 s).
            poll_watch.finish();
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
        Some(Command::Hand(cmd)) => crate::hand::run(cmd).await,
        Some(Command::CuaMcp) => crate::cua_v2::run_bridge().await,
        Some(Command::SecretMcp) => crate::secret_mcp::run().await,
        Some(Command::OfferMcp) => crate::offer_mcp::run().await,
        Some(Command::SubsessionMcp) => crate::subsession_mcp::run().await,
        Some(Command::ForumMcp) => crate::forum_mcp::run().await,
        Some(Command::Skill) => {
            use std::io::Write;
            let _ = std::io::stdout().write_all(crate::cli::orchestrate::guide().as_bytes());
            Ok(())
        }
        // No daemon: what this binary serves (`capabilities.rs`).
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
    argv.iter().skip(1).position(|a| !is_global_flag(a)).map(|i| i + 1).unwrap_or(argv.len())
}

/// A flag that may come before the command word.
fn is_global_flag(arg: &OsString) -> bool {
    arg == "--json" || arg == "--suppress-reads"
}

#[cfg(all(test, tokio_unstable, feature = "cmux-stability"))]
mod tests {
    use super::*;

    fn args(words: &[&str]) -> Vec<OsString> {
        words.iter().map(OsString::from).collect()
    }

    #[test]
    fn only_daemon_run_gets_the_poll_watch() {
        assert!(runs_daemon(&args(&["daemon", "run", "--memory"])));
        assert!(runs_daemon(&args(&["daemon"])));
        assert!(runs_daemon(&args(&["--json", "daemon", "run"])));
        assert!(!runs_daemon(&args(&["daemon", "status"])));
        assert!(!runs_daemon(&args(&["ls"])));
        assert!(!runs_daemon(&args(&[])));
    }
}
