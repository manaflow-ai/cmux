//! cmux-mobile-path-probe: every path the iPhone link can take to a Mac, measured
//! from this host, as JSON and a markdown table.
//!
//!   cmux-mobile-path-probe --token-file PATH [--base-url URL] [--team TEAM]
//!            [--role both|phone|mac] [--mac MAC_DEVICE_ID] [--mac-seconds S]
//!            [--paths wg-auto,wg-relay,wg-tls,webrtc-auto,webrtc-relay]
//!            [--dials N] [--pings M] [--ping-interval-ms MS] [--ping-timeout-ms MS]
//!            [--site-a LABEL:LAT,LON] [--site-b LABEL:LAT,LON] [--include-cgnat]
//!            [--out DIR]
//!
//! Per path it makes N dials (setup: `dial::connect` from the call until the
//! link is up, with the dial's timeline marks) and M link pings on each one
//! (RTT and loss: a ping unanswered within `--ping-timeout-ms` is lost). The
//! paths are the app's: WireGuard as dialed (`wg-auto`: direct when it
//! punches through, else TURN), WireGuard relay only (`wg-relay`, the debug
//! "simulate distant network" policy: TURN over UDP), WireGuard with UDP
//! blocked (`wg-tls`: TURN over TLS on 443), and WebRTC as dialed and relay
//! only. Beside the paths: `GET /v1/ice` time, the signaling socket's open
//! time and WebSocket ping RTT, the team hub's colos (`GET
//! /v1/teams/:id/hub`), one TURN allocation per transport timed alone, the
//! STUN Binding RTT and loss to the TURN server over UDP, and the TCP connect
//! time to its 443.
//!
//! `--role both` (the default) runs the Mac's side in this process too: a
//! device registered as a Mac that answers every dial, as the benches do. The
//! link's bytes still leave the host: relayed paths go to the TURN server and
//! back, so they measure this host's round trip to its TURN colo twice
//! over; a direct path between two sides on one host never leaves it.
//! For a real region pair run `--role mac` on host B (it prints its device id
//! and answers for `--mac-seconds`) and `--role phone --mac ID` on host A,
//! with the same account. `--site-a`/`--site-b` give the great-circle RTT
//! floor (light in fiber, 2/3 c) the paths are compared with.
//!
//! Prints one JSON object on stdout; `--out DIR` also writes
//! `path-probe.json` and `path-probe.md` there.

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use cmux_mobile_host::path_probe::{Row, Site, Summary, great_circle_km, markdown, rtt_floor_ms, stun};
use cmux_mobile_link::api::{ApiClient, DeviceRegistration, IceServer};
use cmux_mobile_link::dial::{self, SessionEvents, TurnTransport};
use cmux_mobile_link::{DialOptions, LinkConfig, LinkPath, SignalingClient, Timeline, TransportKind};
use serde_json::{Value, json};

const DEV_BASE_URL: &str = "https://cmux-mobile-api-dev.debussy.workers.dev";

#[derive(Clone, Copy, PartialEq, Eq)]
enum Role {
    Both,
    Phone,
    Mac,
}

/// One way the phone dials.
#[derive(Clone, Copy)]
struct PathSpec {
    name: &'static str,
    kind: TransportKind,
    relay_only: bool,
    block_udp: bool,
}

const PATHS: [PathSpec; 5] = [
    PathSpec { name: "wg-auto", kind: TransportKind::WireGuard, relay_only: false, block_udp: false },
    PathSpec { name: "wg-relay", kind: TransportKind::WireGuard, relay_only: true, block_udp: false },
    PathSpec { name: "wg-tls", kind: TransportKind::WireGuard, relay_only: false, block_udp: true },
    PathSpec { name: "webrtc-auto", kind: TransportKind::WebRtc, relay_only: false, block_udp: false },
    PathSpec { name: "webrtc-relay", kind: TransportKind::WebRtc, relay_only: true, block_udp: false },
];

struct Args {
    base_url: String,
    token: String,
    team: Option<String>,
    role: Role,
    mac: Option<String>,
    mac_seconds: u64,
    paths: Vec<PathSpec>,
    dials: usize,
    pings: usize,
    ping_interval: Duration,
    ping_timeout: Duration,
    site_a: Option<Site>,
    site_b: Option<Site>,
    exclude_cgnat: bool,
    out: Option<std::path::PathBuf>,
}

fn parse() -> Result<Args> {
    let mut args = std::env::args().skip(1);
    let mut parsed = Args {
        base_url: DEV_BASE_URL.to_owned(),
        token: String::new(),
        team: None,
        role: Role::Both,
        mac: None,
        mac_seconds: 900,
        paths: PATHS.to_vec(),
        dials: 5,
        pings: 50,
        ping_interval: Duration::from_millis(20),
        ping_timeout: Duration::from_millis(1000),
        site_a: None,
        site_b: None,
        exclude_cgnat: true,
        out: None,
    };
    let mut token_file = None;
    while let Some(arg) = args.next() {
        let mut value = || args.next().with_context(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "--base-url" => parsed.base_url = value()?,
            "--token-file" => token_file = Some(value()?),
            "--team" => parsed.team = Some(value()?),
            "--role" => {
                parsed.role = match value()?.as_str() {
                    "both" => Role::Both,
                    "phone" => Role::Phone,
                    "mac" => Role::Mac,
                    other => bail!("--role is both, phone or mac, not {other}"),
                }
            }
            "--mac" => parsed.mac = Some(value()?),
            "--mac-seconds" => parsed.mac_seconds = value()?.parse()?,
            "--paths" => {
                parsed.paths = value()?
                    .split(',')
                    .map(|name| {
                        PATHS.iter().find(|p| p.name == name.trim()).copied().with_context(|| {
                            let known: Vec<_> = PATHS.iter().map(|p| p.name).collect();
                            format!("unknown path {name}; known: {}", known.join(","))
                        })
                    })
                    .collect::<Result<_>>()?;
            }
            "--dials" => parsed.dials = value()?.parse()?,
            "--pings" => parsed.pings = value()?.parse()?,
            "--ping-interval-ms" => parsed.ping_interval = Duration::from_millis(value()?.parse()?),
            "--ping-timeout-ms" => parsed.ping_timeout = Duration::from_millis(value()?.parse()?),
            "--site-a" => parsed.site_a = Some(Site::parse(&value()?).context("--site-a is LABEL:LAT,LON")?),
            "--site-b" => parsed.site_b = Some(Site::parse(&value()?).context("--site-b is LABEL:LAT,LON")?),
            "--include-cgnat" => parsed.exclude_cgnat = false,
            "--out" => parsed.out = Some(value()?.into()),
            other => bail!("unknown argument {other}"),
        }
    }
    let token_file = token_file.context("--token-file is required")?;
    parsed.token = std::fs::read_to_string(&token_file)
        .with_context(|| format!("reading {token_file}"))?
        .trim()
        .to_owned();
    if parsed.role == Role::Phone && parsed.mac.is_none() {
        bail!("--role phone needs --mac (the device id `--role mac` printed)");
    }
    Ok(parsed)
}

fn ms(duration: Duration) -> f64 {
    duration.as_secs_f64() * 1000.0
}

fn path_name(path: LinkPath) -> &'static str {
    match path {
        LinkPath::Direct => "direct",
        LinkPath::Turn => "turn",
        LinkPath::TurnTls => "turn-tls",
        LinkPath::Hop => "hop",
        LinkPath::HttpsRelay => "https-relay",
        LinkPath::NoPath => "no-path",
    }
}

async fn register(api: &ApiClient, team: &str, device: &str, kind: &str) -> Result<()> {
    api.register_device(&DeviceRegistration {
        device_id: device.to_owned(),
        kind: kind.to_owned(),
        model_kind: None,
        name: format!("cmux-mobile-path-probe {kind}"),
        team_id: team.to_owned(),
        wg_public_key: None,
        machine_id: None,
        sibling_device_ids: Vec::new(),
    })
    .await
    .with_context(|| format!("POST /v1/devices ({kind})"))?;
    Ok(())
}

/// The Mac's side: answers every dial and keeps each link until the phone
/// closes it. Link pings are answered by the link itself.
async fn run_mac(args: &Args, team: &str, ice: Vec<IceServer>, device: &str) -> Result<SignalingClient> {
    let api = ApiClient::new(&args.base_url, &args.token);
    register(&api, team, device, "mac").await?;
    let signaling = SignalingClient::connect(&args.base_url, &args.token, team, device).await?;
    let options =
        DialOptions { ice_servers: ice, exclude_cgnat: args.exclude_cgnat, ..DialOptions::default() };
    let mac = signaling.clone();
    tokio::spawn(async move {
        while let Some(session) = mac.next_session().await {
            let first = session.first;
            let events = SessionEvents {
                backend: mac.events(),
                session_id: first.session_id.clone(),
                session: session.events,
            };
            let (mac, options) = (mac.clone(), options.clone());
            tokio::spawn(async move {
                match dial::answer(&mac, first, events, &options, LinkConfig::default()).await {
                    Ok(connected) => {
                        while let Some(incoming) = connected.link.accept().await {
                            incoming.channel.close("unknown_service", "").await;
                        }
                    }
                    Err(error) => tracing::warn!(%error, "answer failed"),
                }
            });
        }
    });
    Ok(signaling)
}

async fn hub(args: &Args, team: &str) -> Value {
    let url = format!("{}/v1/teams/{team}/hub", args.base_url.trim_end_matches('/'));
    let started = Instant::now();
    let answer = async {
        let response = ApiClient::http_client().get(url).bearer_auth(&args.token).send().await?;
        let status = response.status();
        let body: Value = response.json().await?;
        anyhow::Ok(if status.is_success() { body } else { json!({"status": status.as_u16(), "body": body}) })
    };
    match answer.await {
        Ok(mut body) => {
            body["ms"] = json!((ms(started.elapsed()) * 10.0).round() / 10.0);
            body
        }
        Err(error) => json!({"error": format!("{error:#}")}),
    }
}

/// `host:port` of the first `turn:`/`stun:` UDP URL, for the Binding RTT.
fn udp_server(ice: &[IceServer]) -> Option<String> {
    ice.iter().flat_map(|s| &s.urls).find_map(|url| {
        let rest = url.strip_prefix("turn:")?;
        let (host_port, query) = rest.split_once('?').unwrap_or((rest, ""));
        (query.is_empty() || query.contains("transport=udp")).then(|| host_port.to_owned())
    })
}

/// STUN Binding RTT to `server` over UDP, `count` times.
async fn stun_rtts(
    server: &str,
    count: usize,
    interval: Duration,
    timeout: Duration,
) -> (Vec<Option<f64>>, Value) {
    let mut samples = Vec::with_capacity(count);
    let mut seen = json!({});
    let Ok(socket) = tokio::net::UdpSocket::bind("0.0.0.0:0").await else { return (samples, seen) };
    if socket.connect(server).await.is_err() {
        return (samples, json!({"error": format!("cannot resolve {server}")}));
    }
    seen["server_ip"] = json!(socket.peer_addr().ok().map(|a| a.to_string()));
    let mut buffer = [0u8; 1500];
    for _ in 0..count {
        let mut transaction = [0u8; 12];
        transaction.copy_from_slice(&uuid::Uuid::new_v4().as_bytes()[..12]);
        let started = Instant::now();
        let _ = socket.send(&stun::binding_request(transaction)).await;
        let answer = tokio::time::timeout(timeout, async {
            loop {
                let len = socket.recv(&mut buffer).await.ok()?;
                if let Some(response) = stun::parse_binding_response(&buffer[..len], transaction) {
                    return Some(response);
                }
            }
        })
        .await;
        match answer {
            Ok(Some(response)) => {
                samples.push(Some(ms(started.elapsed())));
                seen["mapped"] = json!(response.mapped.map(|a| a.to_string()));
                if let Some(software) = response.software {
                    seen["software"] = json!(software);
                }
            }
            _ => samples.push(None),
        }
        tokio::time::sleep(interval).await;
    }
    (samples, seen)
}

/// TCP connect time (one SYN round trip) to `address`, `count` times.
async fn tcp_connects(address: &str, count: usize, timeout: Duration) -> Vec<Option<f64>> {
    let mut samples = Vec::with_capacity(count);
    for _ in 0..count {
        let started = Instant::now();
        let ok =
            matches!(tokio::time::timeout(timeout, tokio::net::TcpStream::connect(address)).await, Ok(Ok(_)));
        samples.push(ok.then(|| ms(started.elapsed())));
    }
    samples
}

struct PathResult {
    row: Row,
    json: Value,
}

async fn probe_path(
    args: &Args,
    spec: PathSpec,
    api: &ApiClient,
    signaling: &SignalingClient,
    mac: &str,
    ice: &[IceServer],
) -> PathResult {
    let mut setups = Vec::new();
    let mut rtts = Vec::new();
    let mut paths: BTreeMap<&'static str, usize> = BTreeMap::new();
    let mut marks: BTreeMap<String, Vec<Option<f64>>> = BTreeMap::new();
    let mut errors = Vec::new();
    for _ in 0..args.dials {
        let mut ice_servers = ice.to_vec();
        if spec.kind == TransportKind::WireGuard && !spec.block_udp {
            api.renew_hop_tickets(&mut ice_servers, Duration::from_secs(8)).await;
        }
        let timeline = Timeline::new();
        let options = DialOptions {
            ice_servers,
            exclude_cgnat: args.exclude_cgnat,
            relay_only: spec.relay_only,
            block_udp: spec.block_udp,
            timeline: timeline.clone(),
            ..DialOptions::default()
        };
        let started = Instant::now();
        let connected = match dial::connect(signaling, mac, spec.kind, &options, LinkConfig::default()).await
        {
            Ok(connected) => connected,
            Err(error) => {
                setups.push(None);
                errors.push(error.to_string());
                continue;
            }
        };
        setups.push(Some(ms(started.elapsed())));
        for (name, at) in timeline.marks() {
            marks.entry(name).or_default().push(Some(ms(at)));
        }
        for _ in 0..args.pings {
            let sent = Instant::now();
            let answered = tokio::time::timeout(args.ping_timeout, connected.link.ping()).await;
            rtts.push(matches!(answered, Ok(Ok(_))).then(|| ms(sent.elapsed())));
            tokio::time::sleep(args.ping_interval).await;
        }
        // The path at the end of the pings: a WireGuard link may move from
        // TURN to direct once a punch lands.
        *paths.entry(path_name(*connected.path.borrow())).or_default() += 1;
        connected.link.close("done");
    }
    let reported = paths.iter().map(|(path, n)| format!("{path} x{n}")).collect::<Vec<_>>().join(" ");
    let setup = Summary::of(&setups);
    let rtt = Summary::of(&rtts);
    let mut note = String::new();
    if !errors.is_empty() {
        note = format!("{} dial(s) failed: {}", errors.len(), errors[0]);
    }
    let marks: BTreeMap<String, Summary> =
        marks.into_iter().map(|(name, v)| (name, Summary::of(&v))).collect();
    let json = json!({
        "name": spec.name,
        "transport": format!("{:?}", spec.kind).to_lowercase(),
        "relay_only": spec.relay_only,
        "block_udp": spec.block_udp,
        "reported_paths": paths,
        "setup_ms": setup,
        "rtt_ms": rtt,
        "marks_ms": marks,
        "errors": errors,
    });
    PathResult {
        row: Row {
            name: spec.name.to_owned(),
            path: (!reported.is_empty()).then_some(reported),
            setup: Some(setup),
            rtt: Some(rtt),
            note,
        },
        json,
    }
}

async fn run(args: Args) -> Result<Value> {
    let api = ApiClient::new(&args.base_url, &args.token);
    let team = match &args.team {
        Some(team) => team.clone(),
        None => format!(
            "personal-{}",
            cmux_mobile_host::auth::claims(&args.token).sub.context("the token has no sub; pass --team")?
        ),
    };
    let mut ice_samples = Vec::new();
    let mut ice = None;
    for _ in 0..args.dials.max(1) {
        let started = Instant::now();
        match api.ice().await {
            Ok(config) => {
                ice_samples.push(Some(ms(started.elapsed())));
                ice.get_or_insert(config.ice_servers);
            }
            Err(_) => ice_samples.push(None),
        }
    }
    let ice = ice.context("GET /v1/ice failed every time")?;

    if args.role == Role::Mac {
        let device = args.mac.clone().unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        let signaling = run_mac(&args, &team, ice, &device).await?;
        println!("{}", json!({"role": "mac", "device": device, "team": team, "seconds": args.mac_seconds}));
        tokio::time::sleep(Duration::from_secs(args.mac_seconds)).await;
        signaling.close();
        return Ok(json!({"role": "mac", "device": device, "done": true}));
    }

    let hub = hub(&args, &team).await;

    // The signaling socket: open time and WebSocket ping RTT, fresh sockets.
    let phone = uuid::Uuid::new_v4().to_string();
    register(&api, &team, &phone, "phone").await?;
    let mut opens = Vec::new();
    let mut ws_rtts = Vec::new();
    for _ in 0..args.dials.max(1) {
        let started = Instant::now();
        match SignalingClient::connect(&args.base_url, &args.token, &team, &phone).await {
            Ok(socket) => {
                opens.push(Some(ms(started.elapsed())));
                for _ in 0..5 {
                    let sent = Instant::now();
                    let answered = socket.probe(args.ping_timeout).await;
                    ws_rtts.push(answered.then(|| ms(sent.elapsed())));
                }
                socket.close();
            }
            Err(_) => opens.push(None),
        }
    }

    // TURN: one allocation per transport, timed alone; Binding RTT; TCP 443.
    let mut turn = serde_json::Map::new();
    let mut rows = vec![
        Row { name: "GET /v1/ice".into(), setup: Some(Summary::of(&ice_samples)), ..Row::default() },
        Row {
            name: "signaling open".into(),
            setup: Some(Summary::of(&opens)),
            rtt: Some(Summary::of(&ws_rtts)),
            note: format!(
                "hub {} via {}",
                hub["hubColo"].as_str().unwrap_or("?"),
                hub["ingressColo"].as_str().unwrap_or("?")
            ),
            ..Row::default()
        },
    ];
    for (name, transport) in [("turn-udp", TurnTransport::Udp), ("turn-tls", TurnTransport::Tls)] {
        let mut samples = Vec::new();
        let mut relayed = Vec::new();
        let mut server = None;
        let mut errors = Vec::new();
        for _ in 0..args.dials.max(1) {
            match dial::timed_allocation(&ice, transport, &DialOptions::default()).await {
                Ok(allocation) => {
                    samples.push(Some(ms(allocation.elapsed)));
                    relayed.push(allocation.relayed.to_string());
                    server.get_or_insert(allocation.server);
                }
                Err(error) => {
                    samples.push(None);
                    errors.push(error);
                }
            }
        }
        let summary = Summary::of(&samples);
        rows.push(Row {
            name: format!("{name} allocate"),
            setup: Some(summary.clone()),
            note: server.clone().unwrap_or_default(),
            ..Row::default()
        });
        turn.insert(
            name.to_owned(),
            json!({"server": server, "allocate_ms": summary, "relayed": relayed, "errors": errors}),
        );
    }
    if let Some(server) = udp_server(&ice) {
        let (samples, seen) = stun_rtts(&server, args.pings, args.ping_interval, args.ping_timeout).await;
        let summary = Summary::of(&samples);
        rows.push(Row {
            name: "TURN server STUN RTT (UDP)".into(),
            rtt: Some(summary.clone()),
            note: seen["server_ip"].as_str().unwrap_or(&server).to_owned(),
            ..Row::default()
        });
        turn.insert("stun_rtt_udp".into(), json!({"server": server, "rtt_ms": summary, "seen": seen}));
        let host = server.rsplit_once(':').map_or(server.as_str(), |(host, _)| host);
        let tcp = Summary::of(
            &tcp_connects(&format!("{host}:443"), args.dials.max(1) * 2, args.ping_timeout).await,
        );
        rows.push(Row {
            name: "TURN server TCP connect :443".into(),
            rtt: Some(tcp.clone()),
            ..Row::default()
        });
        turn.insert("tcp_connect_443_ms".into(), json!(tcp));
    }

    // The Mac: this process, or the one `--mac` names.
    let (mac, mac_signaling) = match (&args.mac, args.role) {
        (Some(mac), Role::Phone) => (mac.clone(), None),
        _ => {
            let device = uuid::Uuid::new_v4().to_string();
            let signaling = run_mac(&args, &team, ice.clone(), &device).await?;
            (device, Some(signaling))
        }
    };
    let signaling = SignalingClient::connect(&args.base_url, &args.token, &team, &phone).await?;
    let mut paths = Vec::new();
    for spec in &args.paths {
        let result = probe_path(&args, *spec, &api, &signaling, &mac, &ice).await;
        rows.push(result.row);
        paths.push(result.json);
    }
    signaling.close();
    if let Some(mac) = mac_signaling {
        mac.close();
    }

    let floor = match (&args.site_a, &args.site_b) {
        (Some(a), Some(b)) => Some(json!({
            "a": a, "b": b,
            "km": (great_circle_km(a, b)).round(),
            "rtt_floor_ms": (rtt_floor_ms(a, b) * 10.0).round() / 10.0,
        })),
        _ => None,
    };
    // `hostname` exists on Linux and macOS; /etc/hostname is empty on some VMs and absent on Macs.
    let host = std::process::Command::new("hostname")
        .output()
        .ok()
        .map(|out| String::from_utf8_lossy(&out.stdout).trim().to_owned())
        .filter(|name| !name.is_empty())
        .or_else(|| std::env::var("HOSTNAME").ok())
        .unwrap_or_default();
    let mode = if args.role == Role::Both { "both ends on this host" } else { "phone here, Mac elsewhere" };
    let mut md = format!(
        "cmux-mobile-path-probe on `{host}` ({mode}), {} dials x {} pings per path, base {}\n\n",
        args.dials, args.pings, args.base_url
    );
    if let Some(floor) = &floor {
        md.push_str(&format!(
            "Great-circle floor {} <-> {}: {} km, {} ms RTT at 2/3 c\n\n",
            floor["a"]["label"].as_str().unwrap_or("a"),
            floor["b"]["label"].as_str().unwrap_or("b"),
            floor["km"],
            floor["rtt_floor_ms"]
        ));
    }
    md.push_str(&markdown(&rows));
    let result = json!({
        "host": host,
        "mode": mode,
        "base_url": args.base_url,
        "team_hub": hub,
        "dials": args.dials,
        "pings": args.pings,
        "ice_ms": Summary::of(&ice_samples),
        "signaling": {"open_ms": Summary::of(&opens), "ws_rtt_ms": Summary::of(&ws_rtts)},
        "turn": turn,
        "paths": paths,
        "floor": floor,
        "markdown": md,
    });
    if let Some(out) = &args.out {
        std::fs::create_dir_all(out)?;
        std::fs::write(out.join("path-probe.json"), serde_json::to_vec_pretty(&result)?)?;
        std::fs::write(out.join("path-probe.md"), &md)?;
    }
    eprintln!("{md}");
    Ok(result)
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
    let result = run(parse()?).await?;
    println!("{result}");
    Ok(())
}
