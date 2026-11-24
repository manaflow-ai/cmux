//! cmux-mobile-relay-rtt: the round trip through a link session's WebSocket
//! relay (PROTOCOL.md "WebSocket relay"), between two hosts, with the relay
//! placed the old way and the new way ("Relay placement").
//!
//!   cmux-mobile-relay-rtt --token-file PATH --role mac --mac ID [--seconds S]
//!   cmux-mobile-relay-rtt --token-file PATH --role phone --mac ID
//!            [--trials N] [--samples M] [--interval-ms MS] [--modes before,after]
//!            [--wait-mac S] [--out DIR] [--quit]
//!   common:  [--base-url URL] [--team TEAM]
//!
//! Run `--role mac` on host B and `--role phone` on host A, with the same
//! account's token and the same `--mac` (any UUID, chosen up front, so neither
//! side has to read the other's output). The phone waits up to `--wait-mac`
//! seconds for that Mac to be online, then runs `--trials` rounds; each round
//! runs one trial per mode, alternating which goes first. A trial is a new
//! session:
//!
//! 1. The phone sends a `wg-init` to the Mac, so the hub binds the session;
//!    its `lanes` carry the mode (`relay-rtt-probe:before|after`).
//! 2. `before`: the Mac closes its signal socket at once; the phone waits until
//!    the Mac's presence says offline, then joins `/v1/relay/<session>`. The
//!    peer has no live signal socket at the first join, so the Worker places
//!    the relay by the joiner's `locationHint` (the old placement). The Mac
//!    reconnects its signal socket after `--reconnect-ms` and joins.
//!    `after`: the Mac keeps its signal socket and joins at once; the phone
//!    checks the Mac is online and joins. Both signal sockets are live at the
//!    first join, so a Worker with both-ends placement uses both locations.
//!    On a Worker without it, both modes are the old placement.
//! 3. Each side times application pings (`ping`/`pong`, answered by the relay
//!    object without waking it) to the relay: its own leg. The Mac sends its
//!    leg and colo to the phone in a first datagram (`R`).
//! 4. The phone sends `--samples` datagram frames (`relay_frame`, kind
//!    datagrams) every `--interval-ms`; the Mac echoes each. RTT p50/p95.
//!
//! Where the relay is: Cloudflare does not say which colo runs a Durable
//! Object, so the report gives each end's ingress colo (hub diagnostics
//! `/v1/teams/:team/hub`) and its leg to the relay, and, on a Worker with
//! netcheck targets (`/v1/netcheck/:region`), each end's round trip to every
//! region and the region whose two round trips best match the two legs.
//!
//! Prints `RELAY-RTT` lines and one JSON object on stdout; `--out DIR` writes
//! `relay-rtt.json` and `relay-rtt.md` there. `--quit` tells the Mac to exit
//! when the phone is done.

use std::collections::{BTreeMap, HashMap};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use cmux_mobile_host::path_probe::Summary;
use cmux_mobile_link::SignalingClient;
use cmux_mobile_link::api::{ApiClient, DeviceRegistration};
use cmux_mobile_link::signaling::SignalPayload;
use cmux_transport::relay_frame::{FrameKind, PeerId, RelayFrame};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

const DEV_BASE_URL: &str = "https://cmux-mobile-api-dev.debussy.workers.dev";
const REGIONS: [&str; 9] = ["wnam", "enam", "sam", "weur", "eeur", "apac", "oc", "afr", "me"];
const LANE_PREFIX: &str = "relay-rtt-probe:";
const LEG_PINGS: usize = 10;

type Ws = WebSocketStream<MaybeTlsStream<TcpStream>>;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Role {
    Phone,
    Mac,
}

struct Args {
    base_url: String,
    token: String,
    team: Option<String>,
    role: Role,
    mac: String,
    seconds: u64,
    trials: usize,
    samples: usize,
    interval: Duration,
    modes: Vec<String>,
    wait_mac: Duration,
    reconnect: Duration,
    out: Option<std::path::PathBuf>,
    quit: bool,
}

fn parse() -> Result<Args> {
    let mut args = std::env::args().skip(1);
    let mut parsed = Args {
        base_url: DEV_BASE_URL.to_owned(),
        token: String::new(),
        team: None,
        role: Role::Phone,
        mac: String::new(),
        seconds: 1800,
        trials: 3,
        samples: 200,
        interval: Duration::from_millis(20),
        modes: vec!["before".into(), "after".into()],
        wait_mac: Duration::from_secs(1800),
        reconnect: Duration::from_millis(4000),
        out: None,
        quit: false,
    };
    let mut token_file = None;
    let mut role = None;
    while let Some(arg) = args.next() {
        let mut value = || args.next().with_context(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "--base-url" => parsed.base_url = value()?.trim_end_matches('/').to_owned(),
            "--token-file" => token_file = Some(value()?),
            "--team" => parsed.team = Some(value()?),
            "--role" => {
                role = Some(match value()?.as_str() {
                    "phone" => Role::Phone,
                    "mac" => Role::Mac,
                    other => bail!("--role is phone or mac, not {other}"),
                })
            }
            "--mac" => parsed.mac = value()?.to_lowercase(),
            "--seconds" => parsed.seconds = value()?.parse()?,
            "--trials" => parsed.trials = value()?.parse()?,
            "--samples" => parsed.samples = value()?.parse()?,
            "--interval-ms" => parsed.interval = Duration::from_millis(value()?.parse()?),
            "--modes" => {
                parsed.modes = value()?.split(',').map(|m| m.trim().to_owned()).collect();
                if let Some(bad) = parsed.modes.iter().find(|m| *m != "before" && *m != "after") {
                    bail!("--modes takes before and after, not {bad}");
                }
            }
            "--wait-mac" => parsed.wait_mac = Duration::from_secs(value()?.parse()?),
            "--reconnect-ms" => parsed.reconnect = Duration::from_millis(value()?.parse()?),
            "--out" => parsed.out = Some(value()?.into()),
            "--quit" => parsed.quit = true,
            other => bail!("unknown argument {other}"),
        }
    }
    parsed.role = role.context("--role phone|mac is required")?;
    if uuid::Uuid::parse_str(&parsed.mac).is_err() {
        bail!("--mac must be a UUID (the Mac's device id; pick one and give both sides the same)");
    }
    let token_file = token_file.context("--token-file is required")?;
    parsed.token = std::fs::read_to_string(&token_file)
        .with_context(|| format!("reading {token_file}"))?
        .trim()
        .to_owned();
    Ok(parsed)
}

fn ms(duration: Duration) -> f64 {
    (duration.as_secs_f64() * 1000.0 * 100.0).round() / 100.0
}

fn peer_id(device: &str) -> PeerId {
    PeerId(*uuid::Uuid::parse_str(device).map(|u| u.into_bytes()).as_ref().unwrap_or(&[0; 16]))
}

async fn register(api: &ApiClient, team: &str, device: &str, kind: &str) -> Result<()> {
    api.register_device(&DeviceRegistration {
        device_id: device.to_owned(),
        kind: kind.to_owned(),
        name: format!("cmux-mobile-relay-rtt {kind}"),
        team_id: team.to_owned(),
        wg_public_key: None,
        machine_id: None,
        sibling_device_ids: Vec::new(),
    })
    .await
    .with_context(|| format!("POST /v1/devices ({kind})"))?;
    Ok(())
}

/// Hub diagnostics: this host's ingress colo and the hub's colo.
async fn hub(args: &Args, team: &str) -> Value {
    let url = format!("{}/v1/teams/{team}/hub", args.base_url);
    let answer = async {
        let response = ApiClient::http_client().get(url).bearer_auth(&args.token).send().await?;
        anyhow::Ok(response.json::<Value>().await?)
    };
    answer.await.unwrap_or_else(|e| json!({"error": format!("{e:#}")}))
}

/// Where this host is: its GCP zone when it is a GCP VM, else null.
async fn gcp_zone() -> Value {
    let get = async {
        let response = reqwest::Client::new()
            .get("http://metadata.google.internal/computeMetadata/v1/instance/zone")
            .header("Metadata-Flavor", "Google")
            .timeout(Duration::from_secs(1))
            .send()
            .await?;
        let text = response.error_for_status()?.text().await?;
        anyhow::Ok(text.rsplit('/').next().unwrap_or_default().to_owned())
    };
    get.await.map(Value::from).unwrap_or(Value::Null)
}

fn wss(base: &str, path: &str) -> String {
    let base = base.replacen("https://", "wss://", 1).replacen("http://", "ws://", 1);
    format!("{base}{path}")
}

/// Open a WebSocket with the bearer and the relay subprotocol. `Err` carries
/// the HTTP status when the upgrade was refused.
async fn open(args: &Args, url: &str) -> std::result::Result<Ws, (Option<u16>, String)> {
    cmux_mobile_link::install_crypto_provider();
    let mut request = url.into_client_request().map_err(|e| (None, e.to_string()))?;
    let headers = request.headers_mut();
    headers.insert(
        "authorization",
        format!("Bearer {}", args.token).parse().map_err(|_| (None, "token".into()))?,
    );
    headers.insert("sec-websocket-protocol", "cmux-relay.v1".parse().expect("header"));
    match tokio::time::timeout(Duration::from_secs(10), tokio_tungstenite::connect_async(request)).await {
        Err(_) => Err((None, "no answer to the upgrade in 10 s".into())),
        Ok(Ok((ws, _))) => Ok(ws),
        Ok(Err(tokio_tungstenite::tungstenite::Error::Http(response))) => {
            let status = response.status().as_u16();
            let body =
                response.body().as_ref().map(|b| String::from_utf8_lossy(b).into_owned()).unwrap_or_default();
            Err((Some(status), body))
        }
        Ok(Err(e)) => Err((None, e.to_string())),
    }
}

/// Join the session's relay; a `403 not_in_session` is retried for 5 s (the
/// hub binds the session when it admits the first signal, which may land after
/// this join). Returns the socket, the join time and the relay's `joined` frame.
async fn join(args: &Args, session: &str, device: &str) -> Result<(Ws, f64, Value)> {
    let url = wss(&args.base_url, &format!("/v1/relay/{session}?deviceId={device}"));
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let started = Instant::now();
        match open(args, &url).await {
            Ok(mut ws) => {
                let took = ms(started.elapsed());
                let joined = loop {
                    match tokio::time::timeout(Duration::from_secs(5), ws.next()).await {
                        Ok(Some(Ok(Message::Text(text)))) => {
                            let v: Value =
                                serde_json::from_str(&text).unwrap_or(json!({"raw": text.as_str()}));
                            if v["type"] == "joined" {
                                break v;
                            }
                        }
                        Ok(Some(Ok(_))) => {}
                        _ => bail!("the relay sent no `joined`"),
                    }
                };
                return Ok((ws, took, joined));
            }
            Err((Some(403), _)) if Instant::now() < deadline => {
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
            Err((status, body)) => bail!("relay join refused: {status:?} {body}"),
        }
    }
}

/// `n` application pings on `ws` (answered by the relay object itself), in ms.
async fn pings(ws: &mut Ws, n: usize) -> Vec<Option<f64>> {
    let mut out = Vec::with_capacity(n);
    for _ in 0..n {
        let sent = Instant::now();
        if ws.send(Message::text("ping")).await.is_err() {
            out.push(None);
            continue;
        }
        let answered = tokio::time::timeout(Duration::from_secs(3), async {
            while let Some(Ok(message)) = ws.next().await {
                if matches!(&message, Message::Text(t) if t.as_str() == "pong") {
                    return true;
                }
            }
            false
        })
        .await;
        out.push(matches!(answered, Ok(true)).then(|| ms(sent.elapsed())));
    }
    out
}

/// This host's round trip to each netcheck region (the least of 4 pings), or
/// an empty map on a Worker without netcheck targets.
async fn netcheck(args: &Args) -> BTreeMap<String, f64> {
    let mut out = BTreeMap::new();
    for region in REGIONS {
        let Ok(mut ws) = open(args, &wss(&args.base_url, &format!("/v1/netcheck/{region}"))).await else {
            if region == REGIONS[0] {
                return out;
            }
            continue;
        };
        let best = pings(&mut ws, 4).await.into_iter().flatten().fold(f64::INFINITY, f64::min);
        if best.is_finite() {
            out.insert(region.to_owned(), best);
        }
        let _ = ws.close(None).await;
    }
    out
}

/// The region whose round trips from the two ends best match the two legs.
fn infer_region(a: &BTreeMap<String, f64>, b: &BTreeMap<String, f64>, leg_a: f64, leg_b: f64) -> Value {
    let mut best: Option<(&str, f64)> = None;
    for region in REGIONS {
        let (Some(ra), Some(rb)) = (a.get(region), b.get(region)) else { continue };
        let miss = (ra - leg_a).abs() + (rb - leg_b).abs();
        if best.is_none_or(|(_, m)| miss < m) {
            best = Some((region, miss));
        }
    }
    best.map(|(r, miss)| json!({"region": r, "miss_ms": (miss * 10.0).round() / 10.0})).unwrap_or(Value::Null)
}

fn datagram_frame(peer: PeerId, datagram: &[u8]) -> Message {
    let frame = RelayFrame::datagrams(peer, &[datagram]).expect("one small datagram fits");
    Message::binary(frame.encode().expect("encodes"))
}

fn datagrams_of(message: &Message) -> Vec<Vec<u8>> {
    let Message::Binary(bytes) = message else { return Vec::new() };
    let Ok(frame) = RelayFrame::decode(bytes) else { return Vec::new() };
    if frame.kind != FrameKind::Datagrams {
        return Vec::new();
    }
    frame.split_datagrams().map(|d| d.into_iter().map(<[u8]>::to_vec).collect()).unwrap_or_default()
}

fn team_of(args: &Args) -> Result<String> {
    Ok(match &args.team {
        Some(team) => team.clone(),
        None => format!(
            "personal-{}",
            cmux_mobile_host::auth::claims(&args.token).sub.context("the token has no sub; pass --team")?
        ),
    })
}

// ---------------------------------------------------------------- the Mac

async fn run_mac(args: Args) -> Result<Value> {
    let api = ApiClient::new(&args.base_url, &args.token);
    let team = team_of(&args)?;
    register(&api, &team, &args.mac, "mac").await?;
    let mut signaling = SignalingClient::connect(&args.base_url, &args.token, &team, &args.mac).await?;
    let hub = hub(&args, &team).await;
    let zone = gcp_zone().await;
    let nc = netcheck(&args).await;
    println!(
        "{}",
        json!({"role": "mac", "device": args.mac, "team": team, "seconds": args.seconds, "hub": hub, "zone": zone, "netcheck": nc})
    );
    let me = json!({"colo": hub["ingressColo"], "zone": zone, "netcheck": nc});
    let deadline = Instant::now() + Duration::from_secs(args.seconds);
    let mut served = 0usize;
    while Instant::now() < deadline {
        let left = deadline.saturating_duration_since(Instant::now());
        let session = match tokio::time::timeout(left, signaling.next_session()).await {
            Err(_) => break,
            Ok(Some(session)) => session,
            Ok(None) => {
                eprintln!(
                    "relay-rtt mac: signal socket closed ({:?}); reconnecting",
                    signaling.closed_reason()
                );
                tokio::time::sleep(Duration::from_secs(1)).await;
                signaling = SignalingClient::connect(&args.base_url, &args.token, &team, &args.mac).await?;
                continue;
            }
        };
        let first = session.first;
        let SignalPayload::WgInit { lanes, .. } = &first.payload else { continue };
        let Some(mode) = lanes.iter().find_map(|l| l.strip_prefix(LANE_PREFIX)).map(str::to_owned) else {
            continue;
        };
        signaling.unsubscribe(&first.session_id);
        if mode == "quit" {
            eprintln!("relay-rtt mac: the phone said quit");
            break;
        }
        if mode == "before" {
            // The peer of the phone's first join must have no live signal socket.
            signaling.close();
            tokio::time::sleep(args.reconnect).await;
            signaling = SignalingClient::connect(&args.base_url, &args.token, &team, &args.mac).await?;
        }
        match echo(&args, &first.session_id, &first.from, &me).await {
            Ok(n) => {
                served += 1;
                eprintln!("relay-rtt mac: session {} ({mode}) echoed {n}", first.session_id);
            }
            Err(e) => eprintln!("relay-rtt mac: session {} ({mode}) failed: {e:#}", first.session_id),
        }
    }
    signaling.close();
    Ok(json!({"role": "mac", "device": args.mac, "served": served, "done": true}))
}

/// Join, time the leg, tell the phone, echo every datagram until `X` or 60 s.
async fn echo(args: &Args, session: &str, phone: &str, me: &Value) -> Result<usize> {
    let (mut ws, join_ms, joined) = join(args, session, &args.mac).await?;
    let leg = pings(&mut ws, LEG_PINGS).await;
    let ready = json!({"leg_ms": leg, "join_ms": join_ms, "joined": joined, "mac": me});
    let mut datagram = b"R".to_vec();
    datagram.extend_from_slice(ready.to_string().as_bytes());
    let to = peer_id(phone);
    ws.send(datagram_frame(to, &datagram)).await?;
    // The relay drops a datagram whose peer has not joined yet, and the phone may join after this `R` (it waits
    // for the Mac's presence first): resend it every 500 ms until the phone's first `D` shows it arrived.
    let mut echoed = 0;
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let wait = if echoed == 0 { left.min(Duration::from_millis(500)) } else { left };
        let message = match tokio::time::timeout(wait, ws.next()).await {
            Ok(Some(Ok(message))) => message,
            Err(_) if echoed == 0 && !left.is_zero() => {
                ws.send(datagram_frame(to, &datagram)).await?;
                continue;
            }
            _ => break,
        };
        let mut done = false;
        for d in datagrams_of(&message) {
            match d.first() {
                Some(b'D') => {
                    ws.send(datagram_frame(to, &d)).await?;
                    echoed += 1;
                }
                Some(b'X') => done = true,
                _ => {}
            }
        }
        if done {
            break;
        }
    }
    let _ = ws.close(None).await;
    Ok(echoed)
}

// ---------------------------------------------------------------- the phone

async fn mac_online(api: &ApiClient, team: &str, mac: &str) -> Option<bool> {
    let macs = api.macs(team).await.ok()?;
    Some(macs.iter().any(|m| m.device_id.eq_ignore_ascii_case(mac) && m.online))
}

/// Poll the Mac's presence until it is `want`, for up to `wait`.
async fn until_online(api: &ApiClient, team: &str, mac: &str, want: bool, wait: Duration) -> bool {
    let deadline = Instant::now() + wait;
    loop {
        if mac_online(api, team, mac).await == Some(want) {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}

fn wg_init(mode: &str) -> SignalPayload {
    SignalPayload::WgInit {
        public_key: "relay-rtt-probe".into(),
        endpoints: Vec::new(),
        overlay_ip: "0.0.0.0".into(),
        lanes: vec![format!("{LANE_PREFIX}{mode}")],
        relayed: Vec::new(),
        relayed_tls: Vec::new(),
        version: 0,
    }
}

async fn trial(
    args: &Args,
    api: &ApiClient,
    signaling: &SignalingClient,
    team: &str,
    phone: &str,
    nc: &BTreeMap<String, f64>,
    mode: &str,
) -> Result<Value> {
    let session = uuid::Uuid::new_v4().to_string();
    signaling.send_signal(&args.mac, &session, wg_init(mode))?;
    // `before`: the Mac closes its signal socket on this signal; join once its presence says so.
    let peer_live = if mode == "before" {
        !until_online(api, team, &args.mac, false, Duration::from_secs(10)).await
    } else {
        until_online(api, team, &args.mac, true, Duration::from_secs(10)).await
    };
    let (mut ws, join_ms, joined) = join(args, &session, phone).await?;
    let leg = pings(&mut ws, LEG_PINGS).await;
    // The Mac's `R` datagram: its leg and where it is.
    let ready = tokio::time::timeout(Duration::from_secs(30), async {
        while let Some(Ok(message)) = ws.next().await {
            for d in datagrams_of(&message) {
                if d.first() == Some(&b'R') {
                    return serde_json::from_slice::<Value>(&d[1..]).ok();
                }
            }
        }
        None
    })
    .await
    .ok()
    .flatten()
    .context("the Mac never joined the relay (no `R` within 30 s)")?;

    let to = peer_id(&args.mac);
    let (mut sink, mut stream) = ws.split();
    let samples = args.samples;
    let (stop_tx, mut stop) = tokio::sync::oneshot::channel::<()>();
    let reader = tokio::spawn(async move {
        let mut got: HashMap<u32, Instant> = HashMap::new();
        loop {
            tokio::select! {
                message = stream.next() => {
                    let Some(Ok(message)) = message else { break };
                    for d in datagrams_of(&message) {
                        if d.first() == Some(&b'D') && d.len() >= 5 {
                            let seq = u32::from_be_bytes([d[1], d[2], d[3], d[4]]);
                            got.entry(seq).or_insert_with(Instant::now);
                        }
                    }
                    if got.len() >= samples { break }
                }
                _ = &mut stop => break,
            }
        }
        (got, stream)
    });
    let mut sent = Vec::with_capacity(samples);
    for seq in 0..samples as u32 {
        let mut datagram = vec![0u8; 64];
        datagram[0] = b'D';
        datagram[1..5].copy_from_slice(&seq.to_be_bytes());
        sent.push(Instant::now());
        sink.send(datagram_frame(to, &datagram)).await?;
        tokio::time::sleep(args.interval).await;
    }
    // Answers still in flight get 3 s after the last send.
    let mut reader = reader;
    let (got, stream) = match tokio::time::timeout(Duration::from_secs(3), &mut reader).await {
        Ok(joined) => joined?,
        Err(_) => {
            let _ = stop_tx.send(());
            reader.await?
        }
    };
    let rtts: Vec<Option<f64>> = sent
        .iter()
        .enumerate()
        .map(|(i, at)| got.get(&(i as u32)).map(|t| ms(t.duration_since(*at))))
        .collect();
    sink.send(datagram_frame(to, b"X")).await.ok();
    let mut ws = sink.reunite(stream).context("reunite")?;
    let _ = ws.close(None).await;

    let leg_a = Summary::of(&leg);
    let mac_leg: Vec<Option<f64>> = serde_json::from_value(ready["leg_ms"].clone()).unwrap_or_default();
    let leg_b = Summary::of(&mac_leg);
    let mac_nc: BTreeMap<String, f64> =
        serde_json::from_value(ready["mac"]["netcheck"].clone()).unwrap_or_default();
    let region = match (leg_a.p50, leg_b.p50) {
        (Some(a), Some(b)) => infer_region(nc, &mac_nc, a, b),
        _ => Value::Null,
    };
    Ok(json!({
        "mode": mode,
        "session": session,
        "mac_signal_live_at_first_join": peer_live,
        "phone_join_ms": join_ms,
        "phone_joined": joined,
        "mac_joined": ready["joined"],
        "rtt_ms": Summary::of(&rtts),
        "phone_leg_ms": leg_a,
        "mac_leg_ms": leg_b,
        "relay_region_inferred": region,
        "mac": ready["mac"],
    }))
}

async fn run_phone(args: Args) -> Result<Value> {
    let api = ApiClient::new(&args.base_url, &args.token);
    let team = team_of(&args)?;
    let phone = uuid::Uuid::new_v4().to_string();
    register(&api, &team, &phone, "phone").await?;
    let signaling = SignalingClient::connect(&args.base_url, &args.token, &team, &phone).await?;
    let hub = hub(&args, &team).await;
    let zone = gcp_zone().await;
    let nc = netcheck(&args).await;
    eprintln!("relay-rtt phone: {phone} at {} ({zone}); waiting for Mac {}", hub["ingressColo"], args.mac);
    if !until_online(&api, &team, &args.mac, true, args.wait_mac).await {
        bail!("Mac {} was not online within {} s", args.mac, args.wait_mac.as_secs());
    }
    let health: Value = ApiClient::http_client()
        .get(format!("{}/v1/health", args.base_url))
        .send()
        .await?
        .json()
        .await
        .unwrap_or(Value::Null);
    let mut trials = Vec::new();
    for round in 0..args.trials {
        let mut modes = args.modes.clone();
        if round % 2 == 1 {
            modes.reverse();
        }
        for mode in &modes {
            // The Mac is back on its signal socket between trials.
            until_online(&api, &team, &args.mac, true, Duration::from_secs(30)).await;
            let result = match trial(&args, &api, &signaling, &team, &phone, &nc, mode).await {
                Ok(v) => v,
                Err(e) => json!({"mode": mode, "error": format!("{e:#}")}),
            };
            let r = &result["rtt_ms"];
            println!(
                "RELAY-RTT round={round} mode={mode} p50={} p95={} loss={}% phone_leg_p50={} mac_leg_p50={} mac_signal_live={} region={} error={}",
                r["p50"],
                r["p95"],
                r["loss_pct"],
                result["phone_leg_ms"]["p50"],
                result["mac_leg_ms"]["p50"],
                result["mac_signal_live_at_first_join"],
                result["relay_region_inferred"]["region"],
                result["error"]
            );
            trials.push(result);
        }
    }
    if args.quit {
        signaling.send_signal(&args.mac, &uuid::Uuid::new_v4().to_string(), wg_init("quit")).ok();
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    signaling.close();
    let mut by_mode = BTreeMap::new();
    for mode in &args.modes {
        let all: Vec<Option<f64>> = trials
            .iter()
            .filter(|t| t["mode"] == mode.as_str())
            .filter_map(|t| t["rtt_ms"]["p50"].as_f64().map(Some))
            .collect();
        by_mode.insert(mode.clone(), json!({"trial_p50s": Summary::of(&all)}));
    }
    Ok(json!({
        "role": "phone",
        "base_url": args.base_url,
        "worker": health,
        "phone": {"device": phone, "colo": hub["ingressColo"], "hub": hub, "zone": zone, "netcheck": nc},
        "mac_device": args.mac,
        "samples": args.samples,
        "interval_ms": ms(args.interval),
        "trials": trials,
        "by_mode": by_mode,
    }))
}

fn markdown(report: &Value) -> String {
    let mut out = String::from(
        "| round | mode | Mac signal live at 1st join | RTT p50 | RTT p95 | loss | phone leg p50 | Mac leg p50 | relay region (inferred) |\n|---|---|---|---|---|---|---|---|---|\n",
    );
    let trials = report["trials"].as_array().cloned().unwrap_or_default();
    let per_round = report["by_mode"].as_object().map_or(1, |m| m.len().max(1));
    for (i, t) in trials.iter().enumerate() {
        if let Some(e) = t["error"].as_str() {
            out.push_str(&format!(
                "| {} | {} | | | | | | | error: {e} |\n",
                i / per_round,
                t["mode"].as_str().unwrap_or("")
            ));
            continue;
        }
        out.push_str(&format!(
            "| {} | {} | {} | {} | {} | {}% | {} | {} | {} |\n",
            i / per_round,
            t["mode"].as_str().unwrap_or(""),
            t["mac_signal_live_at_first_join"],
            t["rtt_ms"]["p50"],
            t["rtt_ms"]["p95"],
            t["rtt_ms"]["loss_pct"],
            t["phone_leg_ms"]["p50"],
            t["mac_leg_ms"]["p50"],
            t["relay_region_inferred"]["region"].as_str().unwrap_or("-"),
        ));
    }
    out
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = parse()?;
    let out = args.out.clone();
    let report = match args.role {
        Role::Mac => run_mac(args).await?,
        Role::Phone => run_phone(args).await?,
    };
    if let (Some(dir), Some("phone")) = (&out, report["role"].as_str()) {
        std::fs::create_dir_all(dir)?;
        std::fs::write(dir.join("relay-rtt.json"), serde_json::to_string_pretty(&report)?)?;
        std::fs::write(dir.join("relay-rtt.md"), markdown(&report))?;
    }
    println!("{report}");
    Ok(())
}
