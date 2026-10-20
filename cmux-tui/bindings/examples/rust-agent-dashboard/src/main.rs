use cmux::Config;
use cmux_rust_agent_dashboard::{
    NotificationTracker, RunOptions, run_connection, run_with_reconnect,
};
use std::env;
use std::io::{self, BufRead};
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::Duration;

#[derive(Debug)]
struct Arguments {
    session: String,
    socket: Option<PathBuf>,
    options: RunOptions,
    reconnect_delay: Duration,
}

fn main() -> ExitCode {
    let arguments: Vec<_> = env::args().skip(1).collect();
    if arguments.iter().any(|argument| matches!(argument.as_str(), "--help" | "-h")) {
        println!("{}", usage());
        return ExitCode::SUCCESS;
    }
    match parse_arguments(arguments.into_iter()).and_then(run) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("rust-agent-dashboard: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run(arguments: Arguments) -> Result<(), String> {
    let config = arguments.socket.map_or_else(
        || Config::from_env_or_default_session(&arguments.session),
        Config::from_socket_path,
    );
    let shutdown = Arc::new(AtomicBool::new(false));

    if arguments.options.watch_for.is_none() {
        eprintln!("Type q then Enter to close the dashboard cleanly.");
        let input_shutdown = Arc::clone(&shutdown);
        thread::spawn(move || {
            let stdin = io::stdin();
            for line in stdin.lock().lines() {
                match line {
                    Ok(line) if line.trim().eq_ignore_ascii_case("q") => {
                        input_shutdown.store(true, Ordering::Release);
                        break;
                    }
                    Ok(_) => {}
                    Err(_) => break,
                }
            }
        });
        let mut stdout = io::stdout().lock();
        let mut stderr = io::stderr().lock();
        run_with_reconnect(
            config,
            &arguments.options,
            arguments.reconnect_delay,
            shutdown,
            &mut stdout,
            &mut stderr,
        )
        .map_err(|error| error.to_string())
    } else {
        let mut notifications = NotificationTracker::default();
        run_connection(
            config,
            &arguments.options,
            shutdown.as_ref(),
            &mut notifications,
            &mut io::stdout().lock(),
        )
        .map_err(|error| error.to_string())
    }
}

fn parse_arguments(arguments: impl Iterator<Item = String>) -> Result<Arguments, String> {
    let mut session = "main".to_string();
    let mut socket = None;
    let mut options = RunOptions::default();
    let mut reconnect_delay = Duration::from_secs(1);
    let mut arguments = arguments;
    let mut session_was_explicit = false;

    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--session" => {
                session = next_value(&mut arguments, "--session")?;
                session_was_explicit = true;
            }
            "--socket" => {
                socket = Some(PathBuf::from(next_value(&mut arguments, "--socket")?));
            }
            "--poll-ms" => {
                options.agent_poll_interval = Duration::from_millis(parse_u64(
                    &next_value(&mut arguments, "--poll-ms")?,
                    "--poll-ms",
                )?);
            }
            "--reconnect-ms" => {
                reconnect_delay = Duration::from_millis(parse_u64(
                    &next_value(&mut arguments, "--reconnect-ms")?,
                    "--reconnect-ms",
                )?);
            }
            "--watch-seconds" => {
                options.watch_for = Some(Duration::from_secs(parse_u64(
                    &next_value(&mut arguments, "--watch-seconds")?,
                    "--watch-seconds",
                )?));
            }
            "--once" => options.watch_for = Some(Duration::ZERO),
            "--no-clear" => options.clear_screen = false,
            "--notify-blocked" => options.notify_blocked = true,
            unknown => return Err(format!("unknown option {unknown}\n\n{}", usage())),
        }
    }

    if session_was_explicit && socket.is_some() {
        return Err("--session and --socket are mutually exclusive".to_string());
    }
    if options.agent_poll_interval.is_zero() {
        return Err("--poll-ms must be greater than zero".to_string());
    }
    if reconnect_delay.is_zero() {
        return Err("--reconnect-ms must be greater than zero".to_string());
    }
    Ok(Arguments { session, socket, options, reconnect_delay })
}

fn next_value(
    arguments: &mut impl Iterator<Item = String>,
    option: &str,
) -> Result<String, String> {
    arguments.next().ok_or_else(|| format!("{option} requires a value"))
}

fn parse_u64(value: &str, option: &str) -> Result<u64, String> {
    value.parse().map_err(|_| format!("{option} requires an unsigned integer"))
}

fn usage() -> &'static str {
    "usage: rust-agent-dashboard [--session NAME | --socket PATH] [--poll-ms N]\n\
     \x20      [--notify-blocked] [--reconnect-ms N] [--watch-seconds N | --once]\n\
     \x20      [--no-clear]"
}
