//! The `cmux-mobile-host` command line: what its own binary (src/main.rs) runs,
//! and what the cmux-next app's bin/cmux runs when argv[0] names
//! `cmux-mobile-host` (cmux_tui::main FOLDED_HOSTS, CMUX-570). The app starts
//! it as `Contents/Resources/bin/cmux-mobile-host`, a link to bin/cmux, with
//! CMUX_MOBILE_CONTROL=stdio.

use std::process::ExitCode;

use tracing_subscriber::EnvFilter;

const HELP: &str = "cmux-mobile-host: serve this Mac to cmux-next-ios phones.

Configuration is read from the environment; see cmux-next-ios/rust/README.md.
Required: CMUX_MOBILE_BASE_URL, CMUX_MOBILE_TEAM_ID, and CMUX_MOBILE_REFRESH_TOKEN(_FILE) or
CMUX_MOBILE_ACCESS_TOKEN(_FILE).

  --print-device-id   print this Mac's device id and exit

CMUX_MOBILE_CONTROL=stdio runs supervised by an app: access tokens and the acpmux
endpoint arrive as JSON lines on stdin, status events leave as JSON lines on
stdout, logs go to stderr, and the process exits when stdin ends.";

/// Runs the host with `args` (argv without argv[0]) on a multi-thread tokio
/// runtime, as `#[tokio::main]` did, and returns its exit status. An error is
/// printed and exits 1, as a `main` returning `anyhow::Result` does. A run
/// that ends because the owner removed this Mac exits the process with
/// [`crate::host::EXIT_REMOVED`] itself and does not return.
pub fn run(args: Vec<String>) -> ExitCode {
    let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("Error: {error:?}");
            return ExitCode::FAILURE;
        }
    };
    match runtime.block_on(serve(args)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("Error: {error:?}");
            ExitCode::FAILURE
        }
    }
}

/// [`run`] for a binary whose panics unwind (the cmux-next app's bin/cmux, which
/// runs this host by argv[0]): a panic on any thread is reported as the default
/// hook does, then aborts the process. That is what the app's own copy does,
/// built panic=abort (scripts/cmux-next/build-mobile-host.sh): nothing in the
/// host catches a panic, and MobileHostSupervisor restarts a host that ends,
/// where an unwound task would leave a host that runs without it. The plain
/// cargo build (tests, the Linux tree) keeps calling [`run`] and unwinding.
pub fn run_aborting_on_panic(args: Vec<String>) -> ExitCode {
    let report = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        report(info);
        std::process::abort();
    }));
    run(args)
}

async fn serve(args: Vec<String>) -> anyhow::Result<()> {
    // stdout is the control stream when supervised, so logs always go to stderr.
    // Set as the global default directly, not with `.init()`: in bin/cmux
    // tracing-subscriber has its `tracing-log` feature (acpmux takes the
    // defaults), and `.init()` would then also turn every `log` record of
    // webrtc and its crates into a line here, which this host's own build never
    // writes (its graph has no tracing-log).
    let subscriber = tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_env("CMUX_MOBILE_LOG").unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .finish();
    tracing::subscriber::set_global_default(subscriber)?;
    match args.first().map(String::as_str) {
        Some("--help" | "-h") => {
            println!("{HELP}");
            return Ok(());
        }
        Some("--print-device-id") => {
            let id = match std::env::var("CMUX_MOBILE_DEVICE_ID") {
                Ok(id) if !id.trim().is_empty() => id,
                _ => crate::config::persistent_device_id(&crate::config::default_state_dir())?,
            };
            println!("{id}");
            return Ok(());
        }
        Some(other) => anyhow::bail!("unknown argument {other}\n\n{HELP}"),
        None => {}
    }
    #[cfg(unix)]
    crate::size_release::exit_on_sigterm();
    let supplied = crate::control::enabled().then(crate::control::spawn_stdin_reader);
    let config = crate::config::HostConfig::from_env(supplied)?;
    tracing::info!(device_id = config.device_id, team = config.team_id, "starting");
    // `run` returns only when the owner removed this Mac: exit with its own status so
    // a supervisor never restarts it.
    crate::host::run(config).await?;
    std::process::exit(crate::host::EXIT_REMOVED)
}
