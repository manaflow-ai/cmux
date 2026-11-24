//! cmux-mobile-dial: dial a Mac running cmux-mobile-host and measure the link.
//!
//!   cmux-mobile-dial --base-url URL --token-file PATH --team TEAM --mac MAC_DEVICE_ID
//!            [--transport webrtc|wireguard]... [--relay-only] [--block-udp]
//!            [--drop-wireguard] [--proxy-only]
//!            [--exclude-cgnat] [--bytes N] [--daemon] [--pings N] [--no-turn]
//!            [--no-turn-prewarm]
//!   cmux-mobile-dial --local --mac MAC_DEVICE_ID [--local-addr HOST:PORT]... [...]
//!
//! `--local` (ultra-connectivity P7) dials with no Worker and no internet:
//! it browses mDNS for the Mac's `_cmux-link._tcp` ad (or takes
//! `--local-addr`), signals through the Mac's local hub, and offers no ICE
//! servers. It needs no `--base-url`, `--token-file` or `--team`; the JSON
//! adds `discover_ms` (the browse) and `local: true`.
//!
//! Prints one JSON line per transport: connect time, path, RTT, echo
//! throughput, and the daemon `identify` answer.
//!
//! `--relay-only` (alias `--force-relay`) skips every direct path, as a
//! distant network would: WebRTC uses only TURN candidates, WireGuard only
//! TURN (UDP first, TLS when UDP gets no allocation). `--block-udp` makes
//! WireGuard act as on a network that drops UDP: no plain UDP and no TURN
//! over UDP, only TURN over TLS on 443 (path `turn-tls`). `--no-turn` drops
//! the TURN servers `/v1/ice` returned (with `--relay-only` or
//! `--block-udp` the dial then fails: there is no backend relay any more).
//! `--drop-wireguard` acts as behind a firewall that drops WireGuard (STUN
//! and TURN answer, WireGuard over UDP is dropped), so the link falls through
//! to TURN over TLS; `--proxy-only` blocks UDP and lets TURN over TLS out only
//! through the system's proxy (`CMUX_MOBILE_DEV_PROXY=http://host:port` sets
//! one). PROTOCOL.md "Corporate networks".
//!
//! As the app does, `GET /v1/ice` runs beside the signaling socket's open
//! (the device registration, which the app does at sign-in, comes first and
//! is not timed), and once ICE answers a WireGuard dial's TURN allocation
//! starts beside the rest of the open (`EarlyTurn`, as a redial's does beside
//! its reconnect). `--no-turn-prewarm` leaves the allocation to the dial.
//! `ice_fetch_ms` is `/v1/ice`'s time and `connect_ms` the time from its
//! answer to link up, so `ice_fetch_ms + connect_ms` stays the link up time
//! (now with ICE and signaling overlapped); `timings` count from the start of
//! both.

use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use bytes::Bytes;
use cmux_mobile_link::api::ApiClient;
use cmux_mobile_link::{ChannelEvent, DialOptions, LinkConfig, SignalingClient, TransportKind};
use serde_json::json;

struct Args {
    base_url: String,
    token: String,
    team: String,
    mac: String,
    transports: Vec<TransportKind>,
    relay_only: bool,
    block_udp: bool,
    /// The corporate network simulations (PROTOCOL.md "Corporate networks").
    drop_wireguard: bool,
    proxy_only: bool,
    no_turn: bool,
    no_input_lane: bool,
    exclude_cgnat: bool,
    bytes: usize,
    daemon: bool,
    pings: usize,
    stock_ice_waits: bool,
    no_turn_prewarm: bool,
    local: bool,
    local_addrs: Vec<std::net::SocketAddr>,
}

fn parse() -> Result<Args> {
    let mut args = std::env::args().skip(1);
    let (mut base_url, mut token_file, mut team, mut mac) = (None, None, None, None);
    let mut transports = Vec::new();
    let (mut relay_only, mut exclude_cgnat, mut daemon, mut no_turn) = (false, false, false, false);
    let (mut stock_ice_waits, mut block_udp) = (false, false);
    let (mut drop_wireguard, mut proxy_only) = (false, false);
    let (mut bytes, mut pings) = (10 * 1024 * 1024, 20);
    let (mut no_input_lane, mut no_turn_prewarm) = (false, false);
    let mut local = false;
    let mut local_addrs = Vec::new();
    while let Some(arg) = args.next() {
        let mut value = || args.next().with_context(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "--base-url" => base_url = Some(value()?),
            "--token-file" => token_file = Some(value()?),
            "--team" => team = Some(value()?),
            "--mac" => mac = Some(value()?),
            "--transport" => transports.push(match value()?.as_str() {
                "webrtc" => TransportKind::WebRtc,
                "wireguard" => TransportKind::WireGuard,
                other => bail!("unknown transport {other}"),
            }),
            "--bytes" => bytes = value()?.parse()?,
            "--pings" => pings = value()?.parse()?,
            "--relay-only" | "--force-relay" => relay_only = true,
            "--block-udp" => block_udp = true,
            "--drop-wireguard" => drop_wireguard = true,
            "--proxy-only" => proxy_only = true,
            "--exclude-cgnat" => exclude_cgnat = true,
            "--no-turn" => no_turn = true,
            "--no-input-lane" => no_input_lane = true,
            "--no-turn-prewarm" => no_turn_prewarm = true,
            "--daemon" => daemon = true,
            "--stock-ice-waits" => stock_ice_waits = true,
            "--local" => local = true,
            "--local-addr" => {
                local = true;
                local_addrs.push(value()?.parse().context("--local-addr is HOST:PORT")?);
            }
            other => bail!("unknown argument {other}"),
        }
    }
    let token = match (local, token_file) {
        (true, None) => String::new(),
        (_, token_file) => {
            let token_file = token_file.context("--token-file is required")?;
            std::fs::read_to_string(&token_file).with_context(|| format!("reading {token_file}"))?
        }
    };
    if transports.is_empty() {
        // A local dial is WireGuard's: the phone's link to a Mac beside it.
        transports = if local {
            vec![TransportKind::WireGuard]
        } else {
            vec![TransportKind::WebRtc, TransportKind::WireGuard]
        };
    }
    if local {
        base_url.get_or_insert_default();
        team.get_or_insert_default();
    }
    Ok(Args {
        base_url: base_url.context("--base-url is required")?,
        token: token.trim().to_owned(),
        team: team.context("--team is required")?,
        mac: mac.context("--mac is required")?,
        transports,
        relay_only,
        block_udp,
        drop_wireguard,
        proxy_only,
        no_turn,
        no_input_lane,
        exclude_cgnat,
        bytes,
        daemon,
        pings,
        stock_ice_waits,
        no_turn_prewarm,
        local,
        local_addrs,
    })
}

fn millis(duration: Duration) -> f64 {
    (duration.as_secs_f64() * 10_000.0).round() / 10.0
}

/// How long `--local` browses mDNS for the Mac's ad.
const BROWSE_WAIT: Duration = Duration::from_secs(5);

async fn run(args: &Args, kind: TransportKind) -> Result<serde_json::Value> {
    if args.local {
        return run_local(args, kind).await;
    }
    let api = ApiClient::new(&args.base_url, &args.token);
    let device = uuid::Uuid::new_v4().to_string();
    // The backend admits a signaling socket only for a registered device. The
    // app registers at sign-in, not per dial: not timed.
    api.register_device(&cmux_mobile_link::api::DeviceRegistration {
        device_id: device.clone(),
        kind: "phone".into(),
        name: "cmux-mobile-dial".into(),
        team_id: args.team.clone(),
        wg_public_key: None,
        machine_id: None,
        sibling_device_ids: Vec::new(),
    })
    .await
    .context("POST /v1/devices")?;
    let started = Instant::now();
    let timeline = cmux_mobile_link::Timeline::starting_at(started);
    let options = dial_options(args, &timeline);
    // `/v1/ice` beside the signaling socket's open, as the app does; the TURN
    // allocation starts once ICE answers.
    let ice = async {
        let mut ice_servers = api.ice().await.map(|c| c.ice_servers).unwrap_or_default();
        let ice_fetch = started.elapsed();
        timeline.mark("ice_answered");
        if args.no_turn {
            for server in &mut ice_servers {
                server.urls.retain(|url| !url.starts_with("turn:") && !url.starts_with("turns:"));
            }
            ice_servers.retain(|server| !server.urls.is_empty());
        }
        let early = if args.no_turn_prewarm {
            None
        } else {
            cmux_mobile_link::dial::EarlyTurn::for_dial(
                kind,
                &DialOptions { ice_servers: ice_servers.clone(), ..options.clone() },
            )
        };
        (ice_servers, ice_fetch, early)
    };
    let signaling = async {
        let signaling = SignalingClient::connect(&args.base_url, &args.token, &args.team, &device).await;
        let signaled = started.elapsed();
        timeline.mark("signaling_open");
        signaling.map(|signaling| (signaling, signaled))
    };
    let ((ice_servers, ice_fetch, early), signaling) = tokio::join!(ice, signaling);
    let (signaling, signaled) = signaling?;
    let turn_urls = cmux_mobile_link::dial::turn_url_count(&ice_servers);
    let options = DialOptions { ice_servers, ..options };
    // From ICE's answer, so that ice_fetch_ms + connect_ms is the link up time.
    let mut result = measure(args, kind, signaling, options, early, started + ice_fetch, signaled).await?;
    result["turn_prewarm"] = json!(!args.no_turn_prewarm);
    result["ice_beside_signaling"] = json!(true);
    result["ice_fetch_ms"] = json!(millis(ice_fetch));
    result["ice_turn_urls"] = json!(turn_urls);
    Ok(result)
}

/// `--local`: find the Mac's hub (mDNS, or `--local-addr`), signal through it.
async fn run_local(args: &Args, kind: TransportKind) -> Result<serde_json::Value> {
    let browse_started = Instant::now();
    let addresses = if args.local_addrs.is_empty() {
        cmux_mobile_host::local_link::browse(&args.mac, None, BROWSE_WAIT).await
    } else {
        cmux_mobile_link::local::ordered(args.local_addrs.clone())
    };
    let discover = browse_started.elapsed();
    if addresses.is_empty() {
        bail!("no local ad for Mac {} within {}s", args.mac, BROWSE_WAIT.as_secs());
    }
    let device = uuid::Uuid::new_v4().to_string();
    let started = Instant::now();
    let timeline = cmux_mobile_link::Timeline::starting_at(started);
    let signaling = cmux_mobile_link::local::connect_hub(&addresses, &device).await?;
    let signaled = started.elapsed();
    timeline.mark("signaling_open");
    let options = dial_options(args, &timeline);
    let mut result = measure(args, kind, signaling, options, None, started, signaled).await?;
    result["local"] = json!(true);
    result["discover_ms"] = json!(millis(discover));
    result["hub_addresses"] = json!(addresses.iter().map(ToString::to_string).collect::<Vec<_>>());
    Ok(result)
}

/// The dial's options from the flags, with no ICE servers yet.
fn dial_options(args: &Args, timeline: &cmux_mobile_link::Timeline) -> DialOptions {
    DialOptions {
        exclude_cgnat: args.exclude_cgnat,
        relay_only: args.relay_only,
        block_udp: args.block_udp || args.proxy_only,
        drop_wireguard_udp: args.drop_wireguard,
        egress: cmux_mobile_link::egress::Egress { require_proxy: args.proxy_only, ..Default::default() },
        input_lane: !args.no_input_lane,
        timeline: timeline.clone(),
        stock_ice_waits: args.stock_ice_waits,
        ..DialOptions::default()
    }
}

/// Dial, then measure the link. `connect_ms` counts from `connect_from`.
async fn measure(
    args: &Args,
    kind: TransportKind,
    signaling: SignalingClient,
    options: DialOptions,
    early: Option<cmux_mobile_link::dial::EarlyTurn>,
    connect_from: Instant,
    signaled: Duration,
) -> Result<serde_json::Value> {
    let timeline = options.timeline.clone();
    let connected = cmux_mobile_link::dial::connect_with_early_turn(
        &signaling,
        &args.mac,
        kind,
        &options,
        LinkConfig::default(),
        early,
    )
    .await?;
    let connect = connect_from.elapsed();
    let link = &connected.link;
    // The app's first request: a `daemon` channel and its first answer.
    let first_daemon = if args.daemon {
        let mut channel = link.open("daemon", json!({})).await?;
        timeline.mark("daemon_channel_open");
        channel.send(Bytes::from_static(b"{\"id\":1,\"cmd\":\"identify\"}\n")).await?;
        let _ = tokio::time::timeout(Duration::from_secs(10), channel.recv()).await?;
        timeline.mark("first_daemon_response");
        channel.close("done", "").await;
        Some(())
    } else {
        None
    };
    let _ = first_daemon;
    let marks: serde_json::Map<String, serde_json::Value> =
        timeline.marks().into_iter().map(|(name, at)| (name, json!(millis(at)))).collect();

    let mut rtts = Vec::new();
    for _ in 0..args.pings {
        rtts.push(link.ping().await?);
    }
    rtts.sort();
    let median = rtts.get(rtts.len() / 2).copied().unwrap_or_default();
    let p95 = rtts.get((rtts.len() * 95).div_ceil(100).saturating_sub(1)).copied().unwrap_or_default();

    // Echo: send `bytes` and read them back, writing and reading concurrently.
    let mut echo = link.open("echo", json!({})).await?;
    let first = Instant::now();
    echo.send(Bytes::from_static(b"x")).await?;
    let _ = echo.recv().await;
    let first_echo = first.elapsed();
    let payload = Bytes::from((0..args.bytes).map(|i| (i % 251) as u8).collect::<Vec<u8>>());
    let (sender, mut receiver) = echo.split();
    let started_echo = Instant::now();
    let total = payload.len();
    let writer = tokio::spawn(async move {
        let mut rest = payload;
        while !rest.is_empty() {
            let chunk = rest.split_to(rest.len().min(64 * 1024));
            sender.send(chunk).await?;
        }
        Ok::<_, cmux_mobile_link::LinkError>(sender)
    });
    let mut received = 0usize;
    while received < total {
        match tokio::time::timeout(Duration::from_secs(120), receiver.recv()).await? {
            Some(ChannelEvent::Data(bytes)) => received += bytes.len(),
            other => bail!("echo ended early: {other:?}"),
        }
    }
    let echo_time = started_echo.elapsed();
    let sender = writer.await??;
    sender.close("done", "").await;
    let mbps = (total as f64 * 8.0) / echo_time.as_secs_f64() / 1e6;

    let daemon = if args.daemon {
        let mut channel = link.open("daemon", json!({})).await?;
        channel
            .send(Bytes::from_static(
                b"{\"id\":1,\"cmd\":\"identify\"}\n{\"id\":2,\"cmd\":\"run\",\"argv\":[\"id\"]}\n",
            ))
            .await?;
        let mut text = Vec::new();
        while text.iter().filter(|&&b| b == b'\n').count() < 2 {
            match tokio::time::timeout(Duration::from_secs(10), channel.recv()).await? {
                Some(ChannelEvent::Data(bytes)) => text.extend_from_slice(&bytes),
                other => bail!("daemon ended: {other:?}"),
            }
        }
        channel.close("done", "").await;
        String::from_utf8_lossy(&text).trim().to_owned()
    } else {
        String::new()
    };
    let path = format!("{:?}", *connected.path.borrow()).to_lowercase();
    link.close("done");
    signaling.close();
    Ok(json!({
        "transport": format!("{kind:?}").to_lowercase(),
        "relay_only": args.relay_only,
        "block_udp": args.block_udp,
        "no_turn": args.no_turn,
        "path": path,
        "signaling_ms": millis(signaled),
        "connect_ms": millis(connect),
        "timings": marks,
        "pings": rtts.len(),
        "rtt_ms": {"min": millis(rtts[0]), "median": millis(median), "p95": millis(p95), "max": millis(*rtts.last().unwrap())},
        "first_echo_ms": millis(first_echo),
        "echo_bytes": total,
        "echo_seconds": (echo_time.as_secs_f64() * 1000.0).round() / 1000.0,
        "echo_mbit_per_s_each_way": (mbps * 10.0).round() / 10.0,
        "daemon": daemon,
    }))
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("CMUX_MOBILE_LOG")
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn")),
        )
        .with_writer(std::io::stderr)
        .init();
    let args = parse()?;
    let mut failed = false;
    for kind in args.transports.clone() {
        match run(&args, kind).await {
            Ok(result) => println!("{result}"),
            Err(error) => {
                failed = true;
                println!(
                    "{}",
                    json!({"transport": format!("{kind:?}").to_lowercase(), "relay_only": args.relay_only, "block_udp": args.block_udp, "error": format!("{error:#}")})
                );
            }
        }
    }
    if failed {
        std::process::exit(1);
    }
    Ok(())
}
