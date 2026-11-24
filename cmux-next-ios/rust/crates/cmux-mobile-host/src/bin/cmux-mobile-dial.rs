//! cmux-mobile-dial: dial a Mac running cmux-mobile-host and measure the link.
//!
//!   cmux-mobile-dial --base-url URL --token-file PATH --team TEAM --mac MAC_DEVICE_ID
//!            [--transport webrtc|wireguard]... [--relay-only] [--block-udp]
//!            [--exclude-cgnat] [--bytes N] [--daemon] [--pings N] [--no-turn]
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
    no_turn: bool,
    no_input_lane: bool,
    exclude_cgnat: bool,
    bytes: usize,
    daemon: bool,
    pings: usize,
    stock_ice_waits: bool,
    chat_id: Option<String>,
    chat_at_ms: u64,
    chat_wait_s: u64,
}

fn parse() -> Result<Args> {
    let mut args = std::env::args().skip(1);
    let (mut base_url, mut token_file, mut team, mut mac) = (None, None, None, None);
    let mut transports = Vec::new();
    let (mut relay_only, mut exclude_cgnat, mut daemon, mut no_turn) = (false, false, false, false);
    let (mut stock_ice_waits, mut block_udp) = (false, false);
    let (mut bytes, mut pings) = (10 * 1024 * 1024, 20);
    let mut no_input_lane = false;
    let (mut chat_id, mut chat_at_ms, mut chat_wait_s) = (None, 0u64, 30u64);
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
            "--exclude-cgnat" => exclude_cgnat = true,
            "--no-turn" => no_turn = true,
            "--no-input-lane" => no_input_lane = true,
            "--daemon" => daemon = true,
            "--stock-ice-waits" => stock_ice_waits = true,
            "--chat-id" => chat_id = Some(value()?),
            "--chat-at-ms" => chat_at_ms = value()?.parse()?,
            "--chat-wait-s" => chat_wait_s = value()?.parse()?,
            other => bail!("unknown argument {other}"),
        }
    }
    let token_file = token_file.context("--token-file is required")?;
    let token = std::fs::read_to_string(&token_file).with_context(|| format!("reading {token_file}"))?;
    if transports.is_empty() {
        transports = vec![TransportKind::WebRtc, TransportKind::WireGuard];
    }
    Ok(Args {
        base_url: base_url.context("--base-url is required")?,
        token: token.trim().to_owned(),
        team: team.context("--team is required")?,
        mac: mac.context("--mac is required")?,
        transports,
        relay_only,
        block_udp,
        no_turn,
        no_input_lane,
        exclude_cgnat,
        bytes,
        daemon,
        pings,
        stock_ice_waits,
        chat_id,
        chat_at_ms,
        chat_wait_s,
    })
}

fn millis(duration: Duration) -> f64 {
    (duration.as_secs_f64() * 10_000.0).round() / 10.0
}

static PROCESS_START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

async fn run(args: &Args, kind: TransportKind) -> Result<serde_json::Value> {
    let api = ApiClient::new(&args.base_url, &args.token);
    let ice_started = Instant::now();
    let mut ice_servers = api.ice().await.map(|c| c.ice_servers).unwrap_or_default();
    let ice_fetch = ice_started.elapsed();
    if args.no_turn {
        for server in &mut ice_servers {
            server.urls.retain(|url| !url.starts_with("turn:") && !url.starts_with("turns:"));
        }
        ice_servers.retain(|server| !server.urls.is_empty());
    }
    let turn_urls = cmux_mobile_link::dial::turn_url_count(&ice_servers);
    let device = uuid::Uuid::new_v4().to_string();
    let register_started = Instant::now();
    // The backend admits a signaling socket only for a registered device.
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
    let register_ms = register_started.elapsed();
    let started = Instant::now();
    let timeline = cmux_mobile_link::Timeline::starting_at(started);
    let signaling = SignalingClient::connect(&args.base_url, &args.token, &args.team, &device).await?;
    let signaled = started.elapsed();
    timeline.mark("signaling_open");
    let options = DialOptions {
        ice_servers,
        exclude_cgnat: args.exclude_cgnat,
        relay_only: args.relay_only,
        block_udp: args.block_udp,
        input_lane: !args.no_input_lane,
        timeline: timeline.clone(),
        stock_ice_waits: args.stock_ice_waits,
        ..DialOptions::default()
    };
    let connected =
        cmux_mobile_link::dial::connect(&signaling, &args.mac, kind, &options, LinkConfig::default()).await?;
    let connect = started.elapsed();
    // netlab: link up as the app counts it with its device registered at sign-in: process start to the link, no register.
    let link_up = PROCESS_START.get().map(|t| t.elapsed().saturating_sub(register_ms));
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
    // netlab sleep scenario: after the link is up, wait until --chat-at-ms since process start, send one keyed request on a
    // `daemon` channel (a chat message), wait up to --chat-wait-s for its answer, and report what happened.
    if let Some(id) = &args.chat_id {
        let at = Duration::from_millis(args.chat_at_ms);
        if let Some(t) = PROCESS_START.get() {
            tokio::time::sleep(at.saturating_sub(t.elapsed())).await;
        }
        let sent = Instant::now();
        let outcome: String = async {
            let mut channel = match link.open("daemon", json!({})).await {
                Ok(c) => c,
                Err(e) => return format!("open_failed: {e}"),
            };
            let line = format!("{{\"id\":\"{id}\",\"cmd\":\"send\",\"surface\":1,\"text\":\"hello\"}}\n");
            if let Err(e) = channel.send(Bytes::from(line)).await {
                return format!("send_failed: {e}");
            }
            match tokio::time::timeout(Duration::from_secs(args.chat_wait_s), channel.recv()).await {
                Ok(Some(ChannelEvent::Data(_))) => "answered".to_owned(),
                Ok(other) => format!("channel_ended: {other:?}"),
                Err(_) => "no_answer".to_owned(),
            }
        }
        .await;
        let path = format!("{:?}", *connected.path.borrow()).to_lowercase();
        println!(
            "{}",
            json!({"chat": {"id": id, "outcome": outcome, "sent_epoch": std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs_f64() - sent.elapsed().as_secs_f64(), "waited_ms": millis(sent.elapsed())}, "path": path, "link_up_ms": link_up.map(millis)})
        );
        link.close("done");
        signaling.close();
        return Ok(json!({"transport": format!("{kind:?}").to_lowercase(), "path": path}));
    }
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
        "ice_fetch_ms": millis(ice_fetch),
        "signaling_ms": millis(signaled),
        "connect_ms": millis(connect),
        "register_ms": millis(register_ms),
        "link_up_ms": link_up.map(millis),
        "timings": marks,
        "ice_turn_urls": turn_urls,
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
    PROCESS_START.get_or_init(Instant::now);
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
