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
    if args.first().is_some_and(|a| a == crate::agent_host::HOST_ARG) {
        return crate::agent_host::host::main();
    }
    // A background task's runner (`bg_run.rs`): one task, no CLI.
    if args.first().is_some_and(|a| a == crate::bg_run::RUN_ARG) {
        return crate::bg_run::main();
    }
    #[cfg(target_os = "linux")]
    if args.first().is_some_and(|a| a == "__remote-sandbox-canary-unix") {
        return crate::linux_sandbox::keeper::canary_unix(&args[1..]).map_err(anyhow::Error::msg);
    }
    #[cfg(target_os = "linux")]
    if args.first().is_some_and(|a| a == "__remote-sandbox-canary-rename") {
        return crate::linux_sandbox::keeper::canary_rename(&args[1..]).map_err(anyhow::Error::msg);
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
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?
        .block_on(async_main(args, invocation))
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
    let run_alias = argv.get(at).map(|a| a == "run" || a == "exec").unwrap_or(false);
    let exec_alias = argv.get(at).map(|a| a == "exec").unwrap_or(false);
    // clap keeps command names as `&'static str`; one per process.
    let name: &'static str = Box::leak(invocation.display_name.clone().into_boxed_str());
    let mut grammar = Cli::command().name(name).bin_name(name);
    let matches = match grammar.try_get_matches_from_mut(argv.clone()) {
        Ok(matches) => matches,
        // A flag another command takes says which, and what this one does instead.
        Err(e) => match crate::cli::unknown_flag::explain(&e, &grammar, &argv, at, name) {
            Some(refusal) => {
                let json_out = argv.iter().take_while(|a| *a != "--").any(|a| a == "--json");
                errors::exit_with(&refusal.into(), json_out)
            }
            None => e.exit(),
        },
    };
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
        #[cfg(unix)]
        Some(Command::CodexAuthBroker { home, codex }) => {
            crate::cli::codex_auth_broker::run(home, codex).await
        }
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
        Some(Command::AcpmuxMcp) => crate::acpmux_mcp::run().await,
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
    argv.iter()
        .skip(1)
        .position(|a| a != "--json" && a != "--suppress-reads")
        .map(|i| i + 1)
        .unwrap_or(argv.len())
}
