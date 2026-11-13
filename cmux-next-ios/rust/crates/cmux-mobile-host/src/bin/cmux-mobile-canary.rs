//! cmux-mobile-canary: the connectivity alerts' synthetic canary (PROTOCOL.md "Connectivity canary").
//!
//!   cmux-mobile-canary --base-url URL --team TEAM --mac MAC_DEVICE_ID
//!            [--state-dir DIR] [--refresh-token-file PATH | --credentials-file PATH]
//!            [--stack-project ID] [--publishable-key KEY] [--stack-api URL]
//!            [--probe wireguard|wireguard-turn-tls|webrtc|webrtc-relay]... [--interval SECS]
//!            [--once] [--no-report] [--sign-in-only]
//!
//! Every `--interval` seconds (default 60) it runs each probe through the real path a phone uses:
//! sign in (Stack refresh), `GET /v1/ice`, register its one stable device, open signaling, see the Mac
//! listed online, dial it over the probe's transport and forced path, and send one application ping
//! over the link. Each step has its own deadline. Each run is reported to
//! `POST /v1/diagnostics/connectivity-canary` as it ends (so the service reads the Mac's liveness for that
//! run, not minutes later); the service decides what to post. One JSON line per probe is printed to
//! stdout either way. `--sign-in-only` signs in, keeps the refresh token and exits (no device, no dial).
//!
//! Sign-in: a Stack refresh token from `--refresh-token-file`, or else from `<state-dir>/refresh-token`,
//! or else a password sign-in with `CMUX_CANARY_STACK_EMAIL` / `CMUX_CANARY_STACK_PASSWORD` (read from
//! `--credentials-file`, a KEY=VALUE file, or the environment) whose refresh token is then kept in
//! `<state-dir>/refresh-token` (mode 0600). Secrets are never printed.

use std::future::Future;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use cmux_mobile_host::auth::{DEFAULT_STACK_API, DEFAULT_STACK_PROJECT, TokenSource, Tokens};
use cmux_mobile_link::api::{ApiClient, DeviceRegistration};
use cmux_mobile_link::{DialOptions, LinkConfig, SignalingClient, TransportKind};
use serde_json::{Value, json};

/// The dev Stack project's publishable client key (wrangler.jsonc STACK_PROJECTS; not a secret).
const DEV_PUBLISHABLE_KEY: &str = "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g";

/// One probe: a transport and the path it is forced onto.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Probe {
    name: &'static str,
    kind: TransportKind,
    relay_only: bool,
    block_udp: bool,
}

const PROBES: [Probe; 4] = [
    Probe { name: "wireguard", kind: TransportKind::WireGuard, relay_only: false, block_udp: false },
    // UDP dropped: only TURN over TLS on 443 is left (path `turn-tls`).
    Probe { name: "wireguard-turn-tls", kind: TransportKind::WireGuard, relay_only: false, block_udp: true },
    Probe { name: "webrtc", kind: TransportKind::WebRtc, relay_only: false, block_udp: false },
    Probe { name: "webrtc-relay", kind: TransportKind::WebRtc, relay_only: true, block_udp: false },
];

fn probe_named(name: &str) -> Option<Probe> {
    PROBES.iter().copied().find(|p| p.name == name)
}

/// Where a run stopped (PROTOCOL.md: `auth`, `ice`, `register`, `signaling`, `presence`, `dial`, `ping`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Step {
    Auth,
    Ice,
    Register,
    Signaling,
    Presence,
    Dial,
    Ping,
}

impl Step {
    fn name(self) -> &'static str {
        match self {
            Step::Auth => "auth",
            Step::Ice => "ice",
            Step::Register => "register",
            Step::Signaling => "signaling",
            Step::Presence => "presence",
            Step::Dial => "dial",
            Step::Ping => "ping",
        }
    }

    /// Each step's deadline: past it the step fails, so a hang is a failure, not a stuck canary.
    fn deadline(self) -> Duration {
        Duration::from_secs(match self {
            Step::Auth => 20,
            Step::Ice | Step::Register | Step::Presence | Step::Ping => 10,
            Step::Signaling => 15,
            Step::Dial => 30,
        })
    }
}

#[derive(Debug)]
struct Failure {
    step: Step,
    error: String,
}

async fn step<T, E: std::fmt::Display>(step: Step, work: impl Future<Output = Result<T, E>>) -> Result<T, Failure> {
    step_within(step, step.deadline(), work).await
}

async fn step_within<T, E: std::fmt::Display>(step: Step, deadline: Duration, work: impl Future<Output = Result<T, E>>) -> Result<T, Failure> {
    match tokio::time::timeout(deadline, work).await {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(error)) => Err(Failure { step, error: format!("{error:#}").chars().take(300).collect() }),
        Err(_) => Err(Failure { step, error: format!("{} timed out after {deadline:?}", step.name()) }),
    }
}

struct Args {
    base_url: String,
    team: String,
    mac: String,
    state_dir: PathBuf,
    refresh_token_file: Option<PathBuf>,
    credentials_file: Option<PathBuf>,
    stack_project: String,
    publishable_key: String,
    stack_api: String,
    probes: Vec<Probe>,
    interval: Duration,
    once: bool,
    report: bool,
    sign_in_only: bool,
}

fn parse(args: impl IntoIterator<Item = String>) -> Result<Args> {
    let mut args = args.into_iter();
    let (mut base_url, mut team, mut mac) = (None, None, None);
    let mut state_dir = None;
    let (mut refresh_token_file, mut credentials_file) = (None, None);
    let mut stack_project = DEFAULT_STACK_PROJECT.to_owned();
    let mut publishable_key = DEV_PUBLISHABLE_KEY.to_owned();
    let mut stack_api = DEFAULT_STACK_API.to_owned();
    let mut probes = Vec::new();
    let (mut interval, mut once, mut report, mut sign_in_only) = (Duration::from_secs(60), false, true, false);
    while let Some(arg) = args.next() {
        let mut value = || args.next().with_context(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "--base-url" => base_url = Some(value()?),
            "--team" => team = Some(value()?),
            "--mac" => mac = Some(value()?.to_lowercase()),
            "--state-dir" => state_dir = Some(PathBuf::from(value()?)),
            "--refresh-token-file" => refresh_token_file = Some(PathBuf::from(value()?)),
            "--credentials-file" => credentials_file = Some(PathBuf::from(value()?)),
            "--stack-project" => stack_project = value()?,
            "--publishable-key" => publishable_key = value()?,
            "--stack-api" => stack_api = value()?,
            "--probe" => {
                let name = value()?;
                probes.push(probe_named(&name).with_context(|| format!("unknown probe {name}"))?);
            }
            "--interval" => {
                let secs: u64 = value()?.parse().context("--interval takes seconds")?;
                if secs < 10 {
                    bail!("--interval must be at least 10 seconds");
                }
                interval = Duration::from_secs(secs);
            }
            "--once" => once = true,
            "--no-report" => report = false,
            "--sign-in-only" => sign_in_only = true,
            other => bail!("unknown argument {other}"),
        }
    }
    if probes.is_empty() {
        probes = PROBES.to_vec();
    }
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    Ok(Args {
        base_url: base_url.context("--base-url is required")?.trim_end_matches('/').to_owned(),
        team: team.context("--team is required")?,
        mac: mac.context("--mac is required")?,
        state_dir: state_dir.unwrap_or_else(|| home.join(".cmux-mobile-canary")),
        refresh_token_file,
        credentials_file,
        stack_project,
        publishable_key,
        stack_api: stack_api.trim_end_matches('/').to_owned(),
        probes,
        interval,
        once,
        report,
        sign_in_only,
    })
}

/// KEY=VALUE lines (a `.env` file); blank lines and `#` comments are skipped, quotes trimmed.
fn read_env_file(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                return None;
            }
            let (key, value) = line.split_once('=')?;
            Some((key.trim().trim_start_matches("export ").to_owned(), value.trim().trim_matches('"').trim_matches('\'').to_owned()))
        })
        .collect()
}

fn write_private(path: &std::path::Path, text: &str) -> Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    }
    let mut file = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(path)?;
    file.write_all(text.as_bytes())?;
    Ok(())
}

/// The refresh token: a given file, the kept one, or a password sign-in (then kept). `fresh` skips the
/// kept one (its session was revoked or expired).
async fn refresh_token(args: &Args, http: &reqwest::Client, fresh: bool) -> Result<String> {
    if let Some(file) = &args.refresh_token_file
        && !fresh
    {
        return Ok(std::fs::read_to_string(file).with_context(|| format!("reading {}", file.display()))?.trim().to_owned());
    }
    let kept = args.state_dir.join("refresh-token");
    if !fresh
        && let Ok(text) = std::fs::read_to_string(&kept)
        && !text.trim().is_empty()
    {
        return Ok(text.trim().to_owned());
    }
    let mut vars: Vec<(String, String)> = match &args.credentials_file {
        Some(file) => read_env_file(&std::fs::read_to_string(file).with_context(|| format!("reading {}", file.display()))?),
        None => Vec::new(),
    };
    for key in ["CMUX_CANARY_STACK_EMAIL", "CMUX_CANARY_STACK_PASSWORD"] {
        if let Ok(value) = std::env::var(key) {
            vars.push((key.to_owned(), value));
        }
    }
    let get = |names: &[&str]| vars.iter().rev().find(|(k, _)| names.contains(&k.as_str())).map(|(_, v)| v.clone());
    // The UI-test account file names its keys CMUX_UITEST_STACK_*; either name works.
    let email = get(&["CMUX_CANARY_STACK_EMAIL", "CMUX_UITEST_STACK_EMAIL"]).context("no refresh token and no canary email to sign in with")?;
    let password = get(&["CMUX_CANARY_STACK_PASSWORD", "CMUX_UITEST_STACK_PASSWORD"]).context("no canary password to sign in with")?;
    let response = http
        .post(format!("{}/api/v1/auth/password/sign-in", args.stack_api))
        .header("x-stack-project-id", &args.stack_project)
        .header("x-stack-access-type", "client")
        .header("x-stack-publishable-client-key", &args.publishable_key)
        .json(&json!({"email": email, "password": password}))
        .send()
        .await
        .context("Stack password sign-in")?;
    let status = response.status();
    if !status.is_success() {
        bail!("Stack password sign-in returned {status}");
    }
    let body: Value = response.json().await.context("Stack sign-in answer")?;
    let token = body.get("refresh_token").and_then(Value::as_str).context("Stack sign-in returned no refresh token")?.to_owned();
    write_private(&kept, &token)?;
    Ok(token)
}

fn tokens_from(args: &Args, refresh_token: String) -> Tokens {
    Tokens::new(TokenSource::Refresh {
        refresh_token,
        project_id: args.stack_project.clone(),
        publishable_key: Some(args.publishable_key.clone()),
        api: args.stack_api.clone(),
    })
}

/// The canary's sign-in state: the token source and when it last signed in by password.
struct Session {
    tokens: Tokens,
    last_password_sign_in: Option<Instant>,
}

/// At most one password sign-in per this long, so a flaky Stack never piles up sessions.
const PASSWORD_SIGN_IN_EVERY: Duration = Duration::from_secs(600);

/// Whether a refresh failure is Stack refusing the session (expired or revoked), not a passing failure.
fn refused(error: &Failure) -> bool {
    ["failed with 400", "failed with 401", "failed with 403"].iter().any(|code| error.error.contains(code))
}

/// An access token. Only when Stack refuses the refresh token (its session expired or was revoked) does the
/// canary sign in again by password, at most once per PASSWORD_SIGN_IN_EVERY; a network or Stack outage
/// is an `auth` failure, never a new session.
async fn access(args: &Args, session: &mut Session, http: &reqwest::Client) -> Result<String, Failure> {
    let error = match step(Step::Auth, session.tokens.access_token()).await {
        Ok(token) => return Ok(token),
        Err(error) => error,
    };
    let recent = session.last_password_sign_in.is_some_and(|at| at.elapsed() < PASSWORD_SIGN_IN_EVERY);
    if !refused(&error) || recent {
        return Err(error);
    }
    session.last_password_sign_in = Some(Instant::now());
    let fresh = step(Step::Auth, refresh_token(args, http, true)).await?;
    session.tokens = tokens_from(args, fresh);
    step(Step::Auth, session.tokens.access_token()).await
}

/// One probe run; `Ok` is the path it connected over and the ping's round trip.
async fn run(args: &Args, tokens: &mut Session, http: &reqwest::Client, device: &str, probe: Probe) -> Result<(String, Duration, String), Failure> {
    let token = access(args, tokens, http).await?;
    let api = ApiClient::with_http(&args.base_url, &token, http.clone());
    let ice_servers = step(Step::Ice, api.ice()).await?.ice_servers;
    step(
        Step::Register,
        api.register_device(&DeviceRegistration {
            device_id: device.to_owned(),
            kind: "phone".into(),
            name: "cmux connectivity canary".into(),
            team_id: args.team.clone(),
            wg_public_key: None,
            machine_id: None,
            sibling_device_ids: Vec::new(),
        }),
    )
    .await?;
    let signaling = step(Step::Signaling, SignalingClient::connect(&args.base_url, &token, &args.team, device)).await?;
    let outcome = async {
        let macs = step(Step::Presence, api.macs(&args.team)).await?;
        let mac = macs.iter().find(|m| m.device_id.eq_ignore_ascii_case(&args.mac));
        let name = mac.map(|m| m.name.clone()).filter(|n| !n.is_empty()).unwrap_or_else(|| "canary Mac".into());
        match mac {
            Some(m) if m.online => {}
            Some(_) => return Err(Failure { step: Step::Presence, error: "the Mac is listed offline".into() }),
            None => return Err(Failure { step: Step::Presence, error: "the Mac is not listed on this team".into() }),
        }
        let options = DialOptions { ice_servers, relay_only: probe.relay_only, block_udp: probe.block_udp, ..DialOptions::default() };
        let connected = step(Step::Dial, cmux_mobile_link::dial::connect(&signaling, &args.mac, probe.kind, &options, LinkConfig::default())).await?;
        let path = path_name(&connected.path.borrow());
        let rtt = step(Step::Ping, connected.link.ping()).await;
        connected.link.close("canary done");
        rtt.map(|rtt| (path, rtt, name))
    }
    .await;
    signaling.close();
    outcome
}

/// `direct`, `turn`, `turn-tls`, ... (the variant's name in kebab case).
fn path_name(path: &cmux_mobile_link::dial::LinkPath) -> String {
    let mut out = String::new();
    for (i, c) in format!("{path:?}").chars().enumerate() {
        if c.is_ascii_uppercase() && i > 0 {
            out.push('-');
        }
        out.push(c.to_ascii_lowercase());
    }
    out
}

/// The JSON line and report entry for one run.
fn result_json(probe: Probe, at: &str, mac: &str, name: &str, elapsed: Duration, outcome: &Result<(String, Duration, String), Failure>) -> Value {
    let transport = match probe.kind {
        TransportKind::WireGuard => "wireguard",
        TransportKind::WebRtc => "webrtc",
    };
    let mut v = json!({
        "probe": probe.name,
        "at": at,
        "transport": transport,
        "durationMs": elapsed.as_millis() as u64,
        "mac": {"id": mac, "name": name},
    });
    match outcome {
        Ok((path, rtt, _)) => {
            v["outcome"] = json!("pass");
            v["path"] = json!(path);
            v["rttMs"] = json!(rtt.as_millis() as u64);
        }
        Err(failure) => {
            v["outcome"] = json!("fail");
            v["step"] = json!(failure.step.name());
            v["error"] = json!(failure.error);
        }
    }
    v
}

fn now_iso() -> String {
    // RFC 3339 in UTC without a date crate: seconds since the epoch, formatted by hand.
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
    iso_from_unix(secs.as_secs(), secs.subsec_millis())
}

fn iso_from_unix(secs: u64, millis: u32) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    // Howard Hinnant's civil-from-days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{millis:03}Z", rem / 3600, rem % 3600 / 60, rem % 60)
}

async fn report(args: &Args, tokens: &mut Session, http: &reqwest::Client, results: &[Value]) -> Result<()> {
    let token = access(args, tokens, http).await.map_err(|f| anyhow::anyhow!(f.error))?;
    let response = http
        .post(format!("{}/v1/diagnostics/connectivity-canary", args.base_url))
        .bearer_auth(token)
        .json(&json!({"results": results}))
        .send()
        .await?;
    let status = response.status();
    if !status.is_success() {
        bail!("report returned {status}");
    }
    Ok(())
}

async fn round(args: &Args, session: &mut Session, http: &reqwest::Client, device: &str) {
    let mut name = "canary Mac".to_owned();
    for probe in &args.probes {
        let at = now_iso();
        let started = Instant::now();
        let outcome = run(args, session, http, device, *probe).await;
        if let Ok((_, _, n)) = &outcome {
            name.clone_from(n);
        }
        let line = result_json(*probe, &at, &args.mac, &name, started.elapsed(), &outcome);
        println!("{line}");
        if !args.report {
            continue;
        }
        // One retry: a report that is lost twice is a gap the service's silence alarm hears about.
        for attempt in 0..2 {
            match report(args, session, http, std::slice::from_ref(&line)).await {
                Ok(()) => break,
                Err(error) => {
                    eprintln!("{}", json!({"msg": "canary report failed", "attempt": attempt + 1, "error": format!("{error:#}")}));
                    if attempt == 0 {
                        tokio::time::sleep(Duration::from_secs(5)).await;
                    }
                }
            }
        }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("CMUX_MOBILE_LOG").unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn")),
        )
        .with_writer(std::io::stderr)
        .init();
    let args = parse(std::env::args().skip(1))?;
    let http = ApiClient::http_client();
    let refresh = refresh_token(&args, &http, false).await?;
    if args.sign_in_only {
        return Ok(());
    }
    let device = cmux_mobile_host::config::persistent_device_id(&args.state_dir)?;
    let mut session = Session { tokens: tokens_from(&args, refresh), last_password_sign_in: None };
    let mut tick = tokio::time::interval(args.interval);
    // A round that runs long is not followed by a burst of catch-up rounds.
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tick.tick().await;
        round(&args, &mut session, &http, &device).await;
        if args.once {
            return Ok(());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Result<Args> {
        parse(list.iter().map(|s| (*s).to_owned()))
    }

    #[test]
    fn parses_every_probe_by_default_and_named_ones_when_asked() {
        let a = args(&["--base-url", "https://api.test/", "--team", "t", "--mac", "ABC"]).unwrap();
        assert_eq!(a.base_url, "https://api.test");
        assert_eq!(a.mac, "abc");
        assert_eq!(a.probes.iter().map(|p| p.name).collect::<Vec<_>>(), ["wireguard", "wireguard-turn-tls", "webrtc", "webrtc-relay"]);
        assert_eq!(a.interval, Duration::from_secs(60));
        assert!(a.report && !a.once);
        let b = args(&["--base-url", "u", "--team", "t", "--mac", "m", "--probe", "webrtc-relay", "--interval", "30", "--once", "--no-report"]).unwrap();
        assert_eq!(b.probes, vec![probe_named("webrtc-relay").unwrap()]);
        assert!(b.probes[0].relay_only && !b.probes[0].block_udp);
        assert!(b.once && !b.report);
        assert!(probe_named("wireguard-turn-tls").unwrap().block_udp);
    }

    #[test]
    fn refuses_missing_and_unknown_arguments() {
        assert!(args(&["--team", "t", "--mac", "m"]).is_err());
        assert!(args(&["--base-url", "u", "--team", "t", "--mac", "m", "--probe", "carrier-pigeon"]).is_err());
        assert!(args(&["--base-url", "u", "--team", "t", "--mac", "m", "--interval", "1"]).is_err());
        assert!(args(&["--base-url", "u", "--team", "t", "--mac", "m", "--bogus"]).is_err());
    }

    #[test]
    fn reports_the_failed_step_or_the_path() {
        let probe = probe_named("wireguard-turn-tls").unwrap();
        let fail = result_json(probe, "2026-11-13T00:00:00.000Z", "m", "Mac", Duration::from_millis(30_004), &Err(Failure { step: Step::Dial, error: "dial timed out after 30 s".into() }));
        assert_eq!(fail["outcome"], "fail");
        assert_eq!(fail["step"], "dial");
        assert_eq!(fail["transport"], "wireguard");
        assert_eq!(fail["durationMs"], 30_004);
        assert!(fail.get("path").is_none());
        let pass = result_json(probe, "2026-11-13T00:00:00.000Z", "m", "Mac", Duration::from_millis(900), &Ok(("turn-tls".into(), Duration::from_millis(42), "Mac".into())));
        assert_eq!(pass["outcome"], "pass");
        assert_eq!(pass["path"], "turn-tls");
        assert_eq!(pass["rttMs"], 42);
        assert!(pass.get("step").is_none());
    }

    #[tokio::test]
    async fn a_step_that_hangs_fails_at_its_deadline() {
        let hang = step_within(Step::Ping, Duration::from_millis(20), std::future::pending::<Result<(), String>>()).await.unwrap_err();
        assert_eq!(hang.step, Step::Ping);
        assert_eq!(hang.error, "ping timed out after 20ms");
        assert_eq!(Step::Dial.deadline(), Duration::from_secs(30));
        let err = step(Step::Ice, async { Err::<(), _>("503 from /v1/ice") }).await.unwrap_err();
        assert_eq!((err.step, err.error.as_str()), (Step::Ice, "503 from /v1/ice"));
    }

    #[test]
    fn signs_in_again_only_when_stack_refuses_the_session() {
        let fail = |error: &str| Failure { step: Step::Auth, error: error.into() };
        assert!(refused(&fail("Stack refresh failed with 401 Unauthorized")));
        assert!(refused(&fail("Stack refresh failed with 400 Bad Request")));
        assert!(!refused(&fail("Stack refresh failed with 503 Service Unavailable")));
        assert!(!refused(&fail("Stack refresh request: error sending request")));
        assert!(!refused(&fail("auth timed out after 20s")));
        let a = args(&["--base-url", "u", "--team", "t", "--mac", "m", "--sign-in-only"]).unwrap();
        assert!(a.sign_in_only);
    }

    #[test]
    fn names_paths_in_kebab_case() {
        use cmux_mobile_link::dial::LinkPath;
        assert_eq!(path_name(&LinkPath::Direct), "direct");
        assert_eq!(path_name(&LinkPath::TurnTls), "turn-tls");
    }

    #[test]
    fn formats_utc_times() {
        assert_eq!(iso_from_unix(0, 0), "1970-01-01T00:00:00.000Z");
        assert_eq!(iso_from_unix(1_794_608_055, 585), "2026-11-13T22:14:15.585Z");
        assert_eq!(iso_from_unix(951_782_400, 7), "2000-02-29T00:00:00.007Z");
    }

    #[test]
    fn reads_credentials_files_without_their_comments_or_quotes() {
        let vars = read_env_file("# canary\nexport CMUX_UITEST_STACK_EMAIL=\"a@b.c\"\n\nCMUX_UITEST_STACK_PASSWORD='p=w'\n");
        assert_eq!(vars, vec![("CMUX_UITEST_STACK_EMAIL".into(), "a@b.c".into()), ("CMUX_UITEST_STACK_PASSWORD".into(), "p=w".into())]);
    }
}
