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
//! `--hold-seconds S` keeps the link up for S seconds instead and probes it:
//! a 16-byte echo every `--probe-ms` (200), one JSON event line per answer
//! (`probe`, with its send time and RTT), per path change (`path`) and per
//! redial (`redial`). `--watch-net` polls this host's IPv4 addresses every
//! 250 ms and calls the link's `network_changed` when they change, as the
//! app does on an `NWPathMonitor` update. `--dead-after-ms MS` redials when
//! no probe has been answered for MS (0, the default, never redials). The
//! connectivity harness (cmuxterm-hq docs/architecture/connectivity-harness)
//! times recovery from these lines.

use std::sync::OnceLock;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

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
    dead_after_ms: u64,
    device_file: Option<String>,
    turn_ca: Option<String>,
    network_probe_ms: u64,
}

static PROCESS_START: OnceLock<Instant> = OnceLock::new();

fn epoch_ms() -> f64 {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    (now.as_secs_f64() * 10_000_000.0).round() / 10_000.0
}

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
    let mut turn_ca = None;
    let mut network_probe_ms = 1000;
    let (mut hold_seconds, mut probe_ms, mut watch_net, mut dead_after_ms) = (0.0, 200, false, 0);
    let mut device_file = None;
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
            "--turn-ca" => turn_ca = Some(value()?),
            "--network-probe-ms" => network_probe_ms = value()?.parse()?,
            "--no-input-lane" => no_input_lane = true,
            "--daemon" => daemon = true,
            "--stock-ice-waits" => stock_ice_waits = true,
            "--local" => local = true,
            "--local-addr" => {
                local = true;
                local_addrs.push(value()?.parse().context("--local-addr is HOST:PORT")?);
            }
            "--hold-seconds" => hold_seconds = value()?.parse()?,
            "--probe-ms" => probe_ms = value()?.parse()?,
            "--watch-net" => watch_net = true,
            "--dead-after-ms" => dead_after_ms = value()?.parse()?,
            "--device-file" => device_file = Some(value()?),
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
        dead_after_ms,
        device_file,
        turn_ca,
        network_probe_ms,
    })
}

/// `--turn-ca PEM`: the roots TURN over TLS trusts in place of webpki-roots (a lab CA).
fn turn_roots(path: &str) -> Result<std::sync::Arc<rustls::RootCertStore>> {
    use rustls::pki_types::{CertificateDer, pem::PemObject};
    let mut roots = rustls::RootCertStore::empty();
    for cert in CertificateDer::pem_file_iter(path).with_context(|| format!("reading {path}"))? {
        roots.add(cert.with_context(|| format!("parsing {path}"))?)?;
    }
    Ok(std::sync::Arc::new(roots))
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
    // The phone's device id: registered once (the app does it at sign-in) when
    // --device-file keeps it, else a new device registered for this run.
    let kept = args.device_file.as_deref().and_then(|p| std::fs::read_to_string(p).ok());
    let device = match kept.map(|s| s.trim().to_owned()).filter(|s| !s.is_empty()) {
        Some(device) => device,
        None => {
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
            if let Some(p) = &args.device_file {
                std::fs::write(p, &device).with_context(|| format!("writing {p}"))?;
            }
            device
        }
    };
    let started = Instant::now();
    let timeline = cmux_mobile_link::Timeline::starting_at(started);
    // ICE servers and the signaling socket are independent: get both at once,
    // as the app's dial does (cmux-mobile-link-ffi `dial`).
    let ice = async {
        let at = Instant::now();
        let servers = api.ice().await.map(|c| c.ice_servers).unwrap_or_default();
        (servers, at.elapsed())
    };
    let (ice, signaling) =
        tokio::join!(ice, SignalingClient::connect(&args.base_url, &args.token, &args.team, &device));
    let (mut ice_servers, ice_fetch) = ice;
    let signaling = signaling?;
    if args.no_turn {
        for server in &mut ice_servers {
            server.urls.retain(|url| !url.starts_with("turn:") && !url.starts_with("turns:"));
        }
        ice_servers.retain(|server| !server.urls.is_empty());
    }
    let turn_urls = cmux_mobile_link::dial::turn_url_count(&ice_servers);
    let signaled = started.elapsed();
    timeline.mark("signaling_open");
    let measured =
        measure(args, kind, signaling, ice_servers, timeline, started, signaled, ice_fetch, device).await?;
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
    let mut result =
        measure(args, kind, signaling, Vec::new(), timeline, started, signaled, Duration::ZERO, device)
            .await?;
    result["local"] = json!(true);
    result["discover_ms"] = json!(millis(discover));
    result["hub_addresses"] = json!(addresses.iter().map(ToString::to_string).collect::<Vec<_>>());
    Ok(result)
}

#[allow(clippy::too_many_arguments)]
async fn measure(
    args: &Args,
    kind: TransportKind,
    signaling: SignalingClient,
    ice_servers: Vec<cmux_mobile_link::api::IceServer>,
    timeline: cmux_mobile_link::Timeline,
    started: Instant,
    signaled: Duration,
    ice_fetch: Duration,
    device: String,
) -> Result<serde_json::Value> {
    let options = DialOptions {
        ice_servers,
        exclude_cgnat: args.exclude_cgnat,
        relay_only: args.relay_only,
        block_udp: args.block_udp,
        input_lane: !args.no_input_lane,
        timeline: timeline.clone(),
        stock_ice_waits: args.stock_ice_waits,
        turn_tls_roots: args.turn_ca.as_deref().map(turn_roots).transpose()?,
        ..DialOptions::default()
    };
    let connected =
        cmux_mobile_link::dial::connect(&signaling, &args.mac, kind, &options, LinkConfig::default()).await?;
    let connect = started.elapsed();
    if args.hold_seconds > 0.0 {
        let path = format!("{:?}", *connected.path.borrow()).to_lowercase();
        println!(
            "{}",
            json!({
                "event": "link-ready",
                "transport": format!("{kind:?}").to_lowercase(),
                "path": path,
                "since_spawn_ms": millis(PROCESS_START.get().map(Instant::elapsed).unwrap_or_default()),
                "ice_fetch_ms": millis(ice_fetch),
                "signaling_ms": millis(signaled),
                "connect_ms": millis(connect),
                "epoch_ms": epoch_ms(),
            })
        );
        return hold(args, kind, connected, signaling, options, device).await;
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

/// This host's IPv4 addresses, sorted (the `--watch-net` snapshot).
fn ipv4_addresses() -> Vec<String> {
    let mut out = Vec::new();
    // SAFETY: getifaddrs fills a list that freeifaddrs releases; every
    // ifa_addr is checked for null and its family before it is read.
    unsafe {
        let mut list: *mut libc::ifaddrs = std::ptr::null_mut();
        if libc::getifaddrs(&mut list) != 0 {
            return out;
        }
        let mut cursor = list;
        while !cursor.is_null() {
            let addr = (*cursor).ifa_addr;
            if !addr.is_null() && i32::from((*addr).sa_family) == libc::AF_INET {
                let v4 = &*(addr as *const libc::sockaddr_in);
                let ip = std::net::Ipv4Addr::from(u32::from_be(v4.sin_addr.s_addr));
                if !ip.is_loopback() {
                    out.push(ip.to_string());
                }
            }
            cursor = (*cursor).ifa_next;
        }
        libc::freeifaddrs(list);
    }
    out.sort();
    out.dedup();
    out
}

fn event(value: serde_json::Value) {
    println!("{value}");
}

/// `--hold-seconds`: keep the link and probe it; see the header.
async fn hold(
    args: &Args,
    kind: TransportKind,
    mut connected: cmux_mobile_link::dial::Connected,
    mut signaling: SignalingClient,
    options: DialOptions,
    device: String,
) -> Result<serde_json::Value> {
    let deadline = Instant::now() + Duration::from_secs_f64(args.hold_seconds);
    let watch_paths = |mut path: tokio::sync::watch::Receiver<cmux_mobile_link::LinkPath>| {
        tokio::spawn(async move {
            while path.changed().await.is_ok() {
                let now = format!("{:?}", *path.borrow()).to_lowercase();
                event(json!({"event": "path", "path": now, "epoch_ms": epoch_ms()}));
            }
        })
    };
    let mut path_task = watch_paths(connected.path.clone());
    // The signaling socket the net-change path may replace; the redial below takes the newest one.
    let shared = std::sync::Arc::new(tokio::sync::Mutex::new(signaling.clone()));
    let net_task = args.watch_net.then(|| {
        let shared = std::sync::Arc::clone(&shared);
        let (base_url, token, team, device) =
            (args.base_url.clone(), args.token.clone(), args.team.clone(), device.clone());
        let _ = args.network_probe_ms; // the app's probe window now (`signaling::network_probe`)
        tokio::spawn(async move {
            let mut last = ipv4_addresses();
            loop {
                tokio::time::sleep(Duration::from_millis(250)).await;
                let now = ipv4_addresses();
                if now != last {
                    event(json!({"event": "net-change", "from": last, "to": now, "epoch_ms": epoch_ms()}));
                    last = now;
                    // As the app (cmux-mobile-link-ffi network_changed_on): roam, and at the same
                    // time open a new signaling socket, the old one probed beside it
                    // (`after_network_change`), and rehome onto the new one.
                    let roam = tokio::spawn(cmux_mobile_link::dial::wireguard::network_changed());
                    let current = shared.lock().await.clone();
                    let open = SignalingClient::connect(&base_url, &token, &team, &device);
                    use cmux_mobile_link::signaling::{AfterNetworkChange, after_network_change};
                    match after_network_change(Some(&current), open).await {
                        AfterNetworkChange::Opened(fresh) => {
                            let moved = cmux_mobile_link::dial::wireguard::rehome(&fresh);
                            event(json!({"event": "rehomed", "sessions": moved, "epoch_ms": epoch_ms()}));
                            current.close();
                            *shared.lock().await = fresh;
                        }
                        AfterNetworkChange::OldAnswered { .. } => {
                            event(json!({"event": "signaling-alive", "epoch_ms": epoch_ms()}));
                        }
                        AfterNetworkChange::Failed(error) => event(json!({
                            "event": "signaling-failed",
                            "error": error.map(|e| e.to_string()).unwrap_or_default(),
                            "epoch_ms": epoch_ms(),
                        })),
                    }
                    let roams = roam.await.unwrap_or_default();
                    event(json!({"event": "roam-started", "sessions": roams.len(), "epoch_ms": epoch_ms()}));
                }
            }
        })
    });
    let (mut answered, mut redials, mut seq) = (0u64, 0u64, 0u64);
    let dead_after = (args.dead_after_ms > 0).then(|| Duration::from_millis(args.dead_after_ms));
    while Instant::now() < deadline {
        match connected.link.open("echo", json!({})).await {
            Err(error) => {
                event(
                    json!({"event": "echo-open-failed", "error": error.to_string(), "epoch_ms": epoch_ms()}),
                );
            }
            Ok(channel) => {
                let (sender, mut receiver) = channel.split();
                let probe = Duration::from_millis(args.probe_ms);
                let first_seq = seq;
                let writer = tokio::spawn(async move {
                    let mut next = first_seq;
                    let mut tick = tokio::time::interval(probe);
                    loop {
                        tick.tick().await;
                        let mut frame = Vec::with_capacity(16);
                        frame.extend_from_slice(&next.to_be_bytes());
                        frame.extend_from_slice(&epoch_ms().to_bits().to_be_bytes());
                        if sender.send(Bytes::from(frame)).await.is_err() {
                            break;
                        }
                        next += 1;
                    }
                });
                let mut buffer: Vec<u8> = Vec::new();
                let mut last_answer = Instant::now();
                let reached_deadline = loop {
                    if Instant::now() >= deadline {
                        break true;
                    }
                    if dead_after.is_some_and(|dead| last_answer.elapsed() >= dead) {
                        event(
                            json!({"event": "dead", "silent_ms": millis(last_answer.elapsed()), "epoch_ms": epoch_ms()}),
                        );
                        break false;
                    }
                    match tokio::time::timeout(Duration::from_millis(100), receiver.recv()).await {
                        Err(_) => continue,
                        Ok(Some(ChannelEvent::Data(bytes))) => {
                            buffer.extend_from_slice(&bytes);
                            while buffer.len() >= 16 {
                                let frame: Vec<u8> = buffer.drain(..16).collect();
                                let mut n = [0u8; 8];
                                let mut sent = [0u8; 8];
                                n.copy_from_slice(&frame[..8]);
                                sent.copy_from_slice(&frame[8..]);
                                let n = u64::from_be_bytes(n);
                                let sent = f64::from_bits(u64::from_be_bytes(sent));
                                let now = epoch_ms();
                                answered += 1;
                                seq = seq.max(n + 1);
                                last_answer = Instant::now();
                                event(json!({
                                    "event": "probe", "seq": n, "sent_epoch_ms": sent, "epoch_ms": now,
                                    "rtt_ms": ((now - sent) * 10.0).round() / 10.0,
                                }));
                            }
                        }
                        Ok(other) => {
                            event(
                                json!({"event": "echo-ended", "detail": format!("{other:?}"), "epoch_ms": epoch_ms()}),
                            );
                            break false;
                        }
                    }
                };
                writer.abort();
                // Sequence numbers keep rising across redials, so every probe is unique.
                seq += 100_000;
                if reached_deadline {
                    break;
                }
            }
        }
        // Redial as the app's link machine does after a dead link: a fresh
        // signaling socket when one opens, then a new dial.
        redials += 1;
        let started = Instant::now();
        event(json!({"event": "redial-start", "n": redials, "epoch_ms": epoch_ms()}));
        connected.link.close("redial");
        let redialed = loop {
            if Instant::now() >= deadline {
                break None;
            }
            if let Ok(fresh) =
                SignalingClient::connect(&args.base_url, &args.token, &args.team, &device).await
            {
                shared.lock().await.close();
                signaling.close();
                signaling = fresh.clone();
                *shared.lock().await = fresh;
            }
            let attempt = tokio::time::timeout(
                Duration::from_secs(10),
                cmux_mobile_link::dial::connect(&signaling, &args.mac, kind, &options, LinkConfig::default()),
            )
            .await;
            match attempt {
                Ok(Ok(fresh)) => break Some(fresh),
                Ok(Err(error)) => {
                    event(
                        json!({"event": "redial-failed", "error": error.to_string(), "epoch_ms": epoch_ms()}),
                    );
                }
                Err(_) => {
                    event(json!({"event": "redial-failed", "error": "timeout 10 s", "epoch_ms": epoch_ms()}))
                }
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        };
        let Some(fresh) = redialed else { break };
        connected = fresh;
        path_task.abort();
        path_task = watch_paths(connected.path.clone());
        let path = format!("{:?}", *connected.path.borrow()).to_lowercase();
        event(
            json!({"event": "redial", "n": redials, "path": path, "ms": millis(started.elapsed()), "epoch_ms": epoch_ms()}),
        );
    }
    path_task.abort();
    if let Some(task) = net_task {
        task.abort();
    }
    connected.link.close("done");
    signaling.close();
    Ok(json!({
        "event": "hold-done", "transport": format!("{kind:?}").to_lowercase(),
        "answered": answered, "redials": redials, "epoch_ms": epoch_ms(),
    }))
}

#[tokio::main]
async fn main() -> Result<()> {
    let _ = PROCESS_START.set(Instant::now());
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
