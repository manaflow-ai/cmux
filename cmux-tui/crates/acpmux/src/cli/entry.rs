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
        Some(Command::Router(RouterCmd::Serve)) => {
            cmux_coderouter::serve(crate::config::home()).await
        }
        Some(Command::DaemonRun {
            listen,
            token,
            memory,
            log,
            ready_fd,
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
                dev_origins: allow_dev_origin,
                dev,
            })
            .await?;
            // The daemon has stopped its agents and synced its store. Exit
            // now rather than wait for the runtime to drain blocking tasks
            // (a launcher `--version` check can take 20 s).
            std::process::exit(0)
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
        Some(Command::Harness(cmd)) => {
            let json_out = cli.json;
            match crate::cli::harness::run(cmd, json_out).await {
                Ok(()) => Ok(()),
                Err(e) => errors::exit_with(&e, json_out),
            }
        }
        Some(Command::CuaMcp) => crate::cua_v2::run_bridge().await,
        Some(Command::Skill) => {
            use std::io::Write;
            let _ = std::io::stdout().write_all(crate::cli::orchestrate::guide().as_bytes());
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

    #[test]
    fn command_index_skips_leading_global_flags() {
        let argv = |list: &[&str]| list.iter().map(|s| OsString::from(*s)).collect::<Vec<_>>();
        assert_eq!(command_index(&argv(&["acpmux", "exec", "hi"])), 1);
        assert_eq!(command_index(&argv(&["acpmux", "--json", "exec", "hi"])), 2);
        assert_eq!(command_index(&argv(&["acpmux", "--json", "--suppress-reads", "daemon"])), 3);
        assert_eq!(command_index(&argv(&["acpmux", "--json"])), 2);
    }
}
