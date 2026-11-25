//! cmux-mobile-dial: dial a Mac running cmux-mobile-host and measure the link.
//!
//!   cmux-mobile-dial --base-url URL --token-file PATH --team TEAM --mac MAC_DEVICE_ID
//!            [--transport webrtc|wireguard]... [--relay-only] [--block-udp]
//!            [--exclude-cgnat] [--bytes N] [--daemon] [--pings N] [--no-turn]
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
//!
//! `--hold-seconds H` (measurement only, cmuxterm-hq wg-iroh-bench.sh)
//! replaces the pings and the echo run: it holds the link H seconds and
//! sends an 8-byte echo every `--probe-ms` (200) on one echo channel,
//! printing one JSON event per line: `link-ready` (since_spawn_ms,
//! epoch_ms, connect_ms, path), `probe` (seq, sent_epoch_ms, epoch_ms,
//! rtt_ms), `path` on a route change, `net-change`, and `hold-done`.
//! `--watch-net` polls the local addresses and, when they change, tells
//! the link as the app does on an `NWPathMonitor` update: every WireGuard
//! session roams (`dial::wireguard::network_changed`) and a new signaling
//! socket opens and takes the sessions over (`dial::wireguard::rehome`).

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
    local: bool,
    local_addrs: Vec<std::net::SocketAddr>,
    hold_seconds: f64,
    probe_ms: u64,
    watch_net: bool,
}

static PROCESS_START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

fn parse() -> Result<Args> {
    let mut args = std::env::args().skip(1);
    let (mut base_url, mut token_file, mut team, mut mac) = (None, None, None, None);
    let mut transports = Vec::new();
    let (mut relay_only, mut exclude_cgnat, mut daemon, mut no_turn) = (false, false, false, false);
    let (mut stock_ice_waits, mut block_udp) = (false, false);
    let (mut bytes, mut pings) = (10 * 1024 * 1024, 20);
    let mut no_input_lane = false;
    let mut local = false;
    let mut local_addrs = Vec::new();
    let (mut hold_seconds, mut probe_ms, mut watch_net) = (0.0, 200, false);
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
            "--local" => local = true,
            "--hold-seconds" => hold_seconds = value()?.parse()?,
            "--probe-ms" => probe_ms = value()?.parse()?,
            "--watch-net" => watch_net = true,
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
        no_turn,
        no_input_lane,
        exclude_cgnat,
        bytes,
        daemon,
        pings,
        stock_ice_waits,
        local,
        local_addrs,
        hold_seconds,
        probe_ms: probe_ms.max(10),
        watch_net,
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
    let started = Instant::now();
    let timeline = cmux_mobile_link::Timeline::starting_at(started);
    let signaling = SignalingClient::connect(&args.base_url, &args.token, &args.team, &device).await?;
    let signaled = started.elapsed();
    timeline.mark("signaling_open");
    let measured =
        measure(args, kind, signaling, ice_servers, timeline, started, signaled, Some(&device)).await?;
    let mut result = measured;
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
    let mut result = measure(args, kind, signaling, Vec::new(), timeline, started, signaled, None).await?;
    result["local"] = json!(true);
    result["discover_ms"] = json!(millis(discover));
    result["hub_addresses"] = json!(addresses.iter().map(ToString::to_string).collect::<Vec<_>>());
    Ok(result)
}

// `device`: the signaling device id `--watch-net` reopens its socket as (none for `--local`).
#[allow(clippy::too_many_arguments)]
async fn measure(
    args: &Args,
    kind: TransportKind,
    signaling: SignalingClient,
    ice_servers: Vec<cmux_mobile_link::api::IceServer>,
    timeline: cmux_mobile_link::Timeline,
    started: Instant,
    signaled: Duration,
    device: Option<&str>,
) -> Result<serde_json::Value> {
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
    if args.hold_seconds > 0.0 {
        return hold(args, kind, &connected, signaling, connect, device).await;
    }
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

fn epoch_ms() -> f64 {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
    (now.as_secs_f64() * 10_000_000.0).round() / 10_000.0
}

fn event(value: serde_json::Value) {
    use std::io::Write;
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

/// The machine's non-loopback addresses (`--watch-net`).
fn local_ips() -> std::collections::BTreeSet<std::net::IpAddr> {
    let mut ips = std::collections::BTreeSet::new();
    // SAFETY: getifaddrs fills a list freed below; each entry is read only while it lives.
    unsafe {
        let mut list: *mut libc::ifaddrs = std::ptr::null_mut();
        if libc::getifaddrs(&mut list) != 0 {
            return ips;
        }
        let mut cur = list;
        while !cur.is_null() {
            let addr = (*cur).ifa_addr;
            if !addr.is_null() {
                match i32::from((*addr).sa_family) {
                    libc::AF_INET => {
                        let sin = &*(addr as *const libc::sockaddr_in);
                        ips.insert(std::net::Ipv4Addr::from(u32::from_be(sin.sin_addr.s_addr)).into());
                    }
                    libc::AF_INET6 => {
                        let sin6 = &*(addr as *const libc::sockaddr_in6);
                        ips.insert(std::net::Ipv6Addr::from(sin6.sin6_addr.s6_addr).into());
                    }
                    _ => {}
                }
            }
            cur = (*cur).ifa_next;
        }
        libc::freeifaddrs(list);
    }
    ips.retain(|ip| !ip.is_loopback());
    ips
}

/// At most this many echoes unanswered: a stalled link does not queue
/// thousands behind it (the gap shows as missing seqs), as rpc_probe.py.
const MAX_INFLIGHT: usize = 64;

/// `--hold-seconds`: hold the link and probe it with small echoes.
async fn hold(
    args: &Args,
    kind: TransportKind,
    connected: &cmux_mobile_link::dial::Connected,
    signaling: SignalingClient,
    connect: Duration,
    device: Option<&str>,
) -> Result<serde_json::Value> {
    use std::sync::{Arc, Mutex};
    let link = &connected.link;
    let echo = link.open("echo", json!({})).await?;
    let (sender, mut receiver) = echo.split();
    let sent: Arc<Mutex<std::collections::VecDeque<(u64, f64)>>> = Arc::default();
    let answered = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let since_spawn = PROCESS_START.get().map(|t| t.elapsed()).unwrap_or_default();
    let path_now = || format!("{:?}", *connected.path.borrow()).to_lowercase();
    event(json!({"event": "link-ready", "since_spawn_ms": millis(since_spawn), "epoch_ms": epoch_ms(),
        "connect_ms": millis(connect), "path": path_now(), "transport": format!("{kind:?}").to_lowercase()}));
    let reader = {
        let (sent, answered) = (Arc::clone(&sent), Arc::clone(&answered));
        tokio::spawn(async move {
            let mut pending = Vec::new();
            while let Some(ChannelEvent::Data(bytes)) = receiver.recv().await {
                let t = epoch_ms();
                pending.extend_from_slice(&bytes);
                while pending.len() >= 8 {
                    pending.drain(..8);
                    let Some((seq, t0)) = sent.lock().unwrap().pop_front() else { continue };
                    answered.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    event(json!({"event": "probe", "seq": seq, "sent_epoch_ms": t0, "epoch_ms": t,
                        "rtt_ms": ((t - t0) * 10.0).round() / 10.0, "ok": true}));
                }
            }
        })
    };
    let mut path_rx = connected.path.clone();
    let paths = tokio::spawn(async move {
        while path_rx.changed().await.is_ok() {
            let path = format!("{:?}", *path_rx.borrow_and_update()).to_lowercase();
            event(json!({"event": "path", "path": path, "epoch_ms": epoch_ms()}));
        }
    });
    // The app's network-change entry (cmux-mobile-link-ffi `network_changed`): roam every
    // WireGuard session and move them onto a fresh signaling socket.
    let watcher = (args.watch_net).then(|| {
        let (base_url, token, team) = (args.base_url.clone(), args.token.clone(), args.team.clone());
        let device = device.map(str::to_owned);
        tokio::spawn(async move {
            let mut last = local_ips();
            let mut sockets = Vec::new();
            loop {
                tokio::time::sleep(Duration::from_millis(20)).await;
                let now = local_ips();
                if now == last {
                    continue;
                }
                last = now;
                event(json!({"event": "net-change", "epoch_ms": epoch_ms(),
                    "addrs": last.iter().map(ToString::to_string).collect::<Vec<_>>()}));
                let roam = tokio::spawn(cmux_mobile_link::dial::wireguard::network_changed());
                if let Some(device) = &device
                    && let Ok(client) = SignalingClient::connect(&base_url, &token, &team, device).await
                {
                    let moved = cmux_mobile_link::dial::wireguard::rehome(&client);
                    event(json!({"event": "signaling-reopened", "moved": moved, "epoch_ms": epoch_ms()}));
                    sockets.push(client);
                }
                let _ = roam.await;
            }
        })
    });
    let deadline = Instant::now() + Duration::from_secs_f64(args.hold_seconds);
    let every = Duration::from_millis(args.probe_ms);
    let mut next = tokio::time::Instant::now();
    let mut seq = 0u64;
    while Instant::now() < deadline {
        let inflight = sent.lock().unwrap().len();
        if inflight < MAX_INFLIGHT {
            sent.lock().unwrap().push_back((seq, epoch_ms()));
            if sender.send(Bytes::copy_from_slice(&seq.to_be_bytes())).await.is_err() {
                break;
            }
            seq += 1;
        }
        next += every;
        tokio::time::sleep_until(next).await;
    }
    // Let answers in flight land (a probe's round trip at most), then stop.
    tokio::time::sleep(Duration::from_millis(500)).await;
    reader.abort();
    paths.abort();
    if let Some(watcher) = watcher {
        watcher.abort();
    }
    let answered = answered.load(std::sync::atomic::Ordering::Relaxed);
    event(json!({"event": "hold-done", "answered": answered, "sent": seq, "epoch_ms": epoch_ms()}));
    sender.close("done", "").await;
    link.close("done");
    signaling.close();
    Ok(json!({"event": "result", "transport": format!("{kind:?}").to_lowercase(), "path": path_now(),
        "connect_ms": millis(connect), "answered": answered, "sent": seq}))
}

#[tokio::main]
async fn main() -> Result<()> {
    PROCESS_START.get_or_init(Instant::now);
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("CMUX_MOBILE_LOG")
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn")),
        )
        .with_writer(std::io::stderr)
        .init();
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if cmux_mobile_host::dial_mailbox::wanted(&argv) {
        return cmux_mobile_host::dial_mailbox::main(&argv).await;
    }
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
