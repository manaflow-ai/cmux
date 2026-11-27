use anyhow::Result;
use tracing_subscriber::EnvFilter;

const HELP: &str = "cmux-mobile-host: serve this Mac to cmux-next-ios phones.

Configuration is read from the environment; see cmux-next-ios/rust/README.md.
Required: CMUX_MOBILE_BASE_URL, CMUX_MOBILE_TEAM_ID, and CMUX_MOBILE_REFRESH_TOKEN(_FILE) or
CMUX_MOBILE_ACCESS_TOKEN(_FILE).

  --print-device-id   print this Mac's device id and exit

CMUX_MOBILE_CONTROL=stdio runs supervised by an app: access tokens and the acpmux
endpoint arrive as JSON lines on stdin, status events leave as JSON lines on
stdout, logs go to stderr, and the process exits when stdin ends.";

#[tokio::main]
async fn main() -> Result<()> {
    // stdout is the control stream when supervised, so logs always go to stderr.
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_env("CMUX_MOBILE_LOG").unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .init();
    match std::env::args().nth(1).as_deref() {
        Some("--help" | "-h") => {
            println!("{HELP}");
            return Ok(());
        }
        Some("--print-device-id") => {
            let id = match std::env::var("CMUX_MOBILE_DEVICE_ID") {
                Ok(id) if !id.trim().is_empty() => id,
                _ => cmux_mobile_host::config::persistent_device_id(
                    &cmux_mobile_host::config::default_state_dir(),
                )?,
            };
            println!("{id}");
            return Ok(());
        }
        Some(other) => anyhow::bail!("unknown argument {other}\n\n{HELP}"),
        None => {}
    }
    #[cfg(unix)]
    cmux_mobile_host::size_release::exit_on_sigterm();
    let supplied = cmux_mobile_host::control::enabled().then(cmux_mobile_host::control::spawn_stdin_reader);
    let config = cmux_mobile_host::config::HostConfig::from_env(supplied)?;
    tracing::info!(device_id = config.device_id, team = config.team_id, "starting");
    // `run` returns only when the owner removed this Mac: exit with its own status so
    // a supervisor never restarts it.
    cmux_mobile_host::host::run(config).await?;
    std::process::exit(cmux_mobile_host::host::EXIT_REMOVED)
}
