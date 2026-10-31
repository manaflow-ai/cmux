//! cmux-mobile-lanebench: keystroke latency while a terminal on the Mac floods output
//! (cmux-next-ios/verify/terminal-input-lane.md). It dials the Mac app's bundled
//! cmux-mobile-host like the phone does and drives the Mac's real daemon over the
//! `daemon` service.
//!
//!   cmux-mobile-lanebench --base-url URL --token-file PATH --team TEAM --mac MAC_DEVICE_ID
//!                 --transport webrtc|wireguard [--no-input-lane] [--samples N]
//!                 [--flood COMMAND] [--exclude-cgnat] [--relay-only] [--block-udp]
//!
//! It creates two workspaces (A and B), attaches to both on their own
//! `daemon` channels like the app, and starts COMMAND (default
//! `yes | head -c 50000000`) in A. While A floods it types one letter at a
//! time into B and measures:
//!
//! - `echo_ms`: from the keystroke until B's shell echoes it (B's output
//!   travels the main stream next to A's flood);
//! - `ack_ms`: until the `send` request's reply arrives.
//!
//! Then it sends ^C to A followed by `printf 'lane%s\n' done` and measures
//! `interrupt_ms`, until the Mac's screen of A (`read-screen`) shows
//! `lanedone`, and `interrupt_seen_ms`, until A's attach stream carries it. Keystrokes go on an input-lane
//! `daemon` channel, as the app sends them; `--no-input-lane` sends them on
//! the attach channel and offers no lane, as the app and the link did before.
//! Prints one JSON line. The workspaces are closed at the end.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use base64::Engine;
use bytes::Bytes;
use cmux_mobile_link::api::ApiClient;
use cmux_mobile_link::link::{ChannelReceiver, ChannelSender};
use cmux_mobile_link::{ChannelEvent, DialOptions, Lane, LinkConfig, SignalingClient, TransportKind};
use serde_json::{Value, json};
use tokio::sync::{Notify, oneshot};

struct Args {
    base_url: String,
    token: String,
    team: String,
    mac: String,
    transport: TransportKind,
    input_lane: bool,
    samples: usize,
    flood: String,
    exclude_cgnat: bool,
    relay_only: bool,
    block_udp: bool,
}

fn parse() -> Result<Args> {
    let mut args = std::env::args().skip(1);
    let (mut base_url, mut token_file, mut team, mut mac, mut transport) = (None, None, None, None, None);
    let (mut input_lane, mut samples, mut exclude_cgnat, mut relay_only) = (true, 20, false, false);
    let mut flood = "yes | head -c 50000000".to_owned();
    let mut block_udp = false;
    while let Some(arg) = args.next() {
        let mut value = || args.next().with_context(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "--base-url" => base_url = Some(value()?),
            "--token-file" => token_file = Some(value()?),
            "--team" => team = Some(value()?),
            "--mac" => mac = Some(value()?),
            "--transport" => {
                transport = Some(match value()?.as_str() {
                    "webrtc" => TransportKind::WebRtc,
                    "wireguard" => TransportKind::WireGuard,
                    other => bail!("unknown transport {other}"),
                });
            }
            "--no-input-lane" => input_lane = false,
            "--samples" => samples = value()?.parse()?,
            "--flood" => flood = value()?,
            "--exclude-cgnat" => exclude_cgnat = true,
            "--relay-only" => relay_only = true,
            "--block-udp" => block_udp = true,
            other => bail!("unknown argument {other}"),
        }
    }
    let token_file = token_file.context("--token-file is required")?;
    let token = std::fs::read_to_string(&token_file).with_context(|| format!("reading {token_file}"))?;
    Ok(Args {
        base_url: base_url.context("--base-url is required")?,
        token: token.trim().to_owned(),
        team: team.context("--team is required")?,
        mac: mac.context("--mac is required")?,
        transport: transport.context("--transport is required")?,
        input_lane,
        samples,
        flood,
        exclude_cgnat,
        relay_only,
        block_udp,
    })
}

/// A `daemon` channel speaking the v12 JSON-lines protocol: requests with
/// replies, and output events per surface.
struct Daemon {
    sender: Arc<ChannelSender>,
    next: std::sync::atomic::AtomicU64,
    pending: Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>>,
}

/// Output bytes and when they arrived.
type Chunk = (Instant, Vec<u8>);

/// Output seen per surface, with arrival times.
#[derive(Default)]
struct Screens {
    output: Mutex<HashMap<u64, Vec<Chunk>>>,
    bytes: Mutex<HashMap<u64, usize>>,
    changed: Notify,
}

impl Screens {
    /// Waits until `needle` appears in `surface`'s output after `since`.
    async fn wait_for(
        &self,
        surface: u64,
        since: Instant,
        needle: &[u8],
        timeout: Duration,
    ) -> Option<Instant> {
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let changed = self.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            {
                let output = self.output.lock().unwrap();
                if let Some(chunks) = output.get(&surface) {
                    let mut joined = Vec::new();
                    let mut first_at = None;
                    for (at, chunk) in chunks.iter().filter(|(at, _)| *at >= since) {
                        first_at.get_or_insert(*at);
                        joined.extend_from_slice(chunk);
                        if joined.windows(needle.len()).any(|w| w == needle) {
                            return Some(*at);
                        }
                    }
                }
            }
            if tokio::time::timeout_at(deadline, changed).await.is_err() {
                return None;
            }
        }
    }

    fn total(&self, surface: u64) -> usize {
        self.bytes.lock().unwrap().get(&surface).copied().unwrap_or(0)
    }

    /// Drops recorded chunks (keeps byte counts) so searches stay cheap.
    fn forget(&self, surface: u64) {
        self.output.lock().unwrap().remove(&surface);
    }
}

impl Daemon {
    fn new(channel: cmux_mobile_link::Channel, screens: Arc<Screens>, keep: bool) -> Self {
        let (sender, receiver) = channel.split();
        let pending: Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>> = Arc::default();
        tokio::spawn(read_lines(receiver, Arc::clone(&pending), screens, keep));
        Self { sender: Arc::new(sender), next: 1.into(), pending }
    }

    async fn request(&self, cmd: &str, mut params: Value) -> Result<Value> {
        let id = format!("b{}", self.next.fetch_add(1, std::sync::atomic::Ordering::Relaxed));
        params["id"] = json!(id);
        params["cmd"] = json!(cmd);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id, tx);
        let mut line = serde_json::to_vec(&params)?;
        line.push(b'\n');
        self.sender.send(Bytes::from(line)).await?;
        let reply = tokio::time::timeout(Duration::from_secs(60), rx).await.context("reply timed out")??;
        if reply.get("ok") == Some(&json!(false)) {
            bail!("{cmd}: {reply}");
        }
        Ok(reply)
    }
}

async fn read_lines(
    mut receiver: ChannelReceiver,
    pending: Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>>,
    screens: Arc<Screens>,
    keep: bool,
) {
    let mut buffer = Vec::new();
    while let Some(ChannelEvent::Data(bytes)) = receiver.recv().await {
        let at = Instant::now();
        buffer.extend_from_slice(&bytes);
        while let Some(newline) = buffer.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = buffer.drain(..=newline).collect();
            let Ok(value) = serde_json::from_slice::<Value>(&line) else { continue };
            if let Some(id) = value.get("id").and_then(Value::as_str) {
                if let Some(tx) = pending.lock().unwrap().remove(id) {
                    let _ = tx.send(value);
                }
                continue;
            }
            let event = value.get("event").and_then(Value::as_str).unwrap_or_default();
            if !matches!(event, "output" | "vt-state") {
                continue;
            }
            let Some(surface) = value.get("surface").and_then(Value::as_u64) else { continue };
            let Some(data) = value.get("data").and_then(Value::as_str) else { continue };
            let Ok(decoded) = base64::engine::general_purpose::STANDARD.decode(data) else { continue };
            *screens.bytes.lock().unwrap().entry(surface).or_default() += decoded.len();
            if keep {
                screens.output.lock().unwrap().entry(surface).or_default().push((at, decoded));
            }
            screens.changed.notify_waiters();
        }
    }
}

/// Types `text` into `surface` (`send`, base64).
async fn send(daemon: &Daemon, surface: u64, text: &[u8]) -> Result<()> {
    let bytes = base64::engine::general_purpose::STANDARD.encode(text);
    daemon.request("send", json!({"surface": surface, "bytes": bytes})).await.map(|_| ())
}

fn millis(duration: Duration) -> f64 {
    (duration.as_secs_f64() * 10_000.0).round() / 10.0
}

fn summary(mut values: Vec<f64>) -> Value {
    if values.is_empty() {
        return json!(null);
    }
    values.sort_by(f64::total_cmp);
    let at = |q: f64| values[((values.len() - 1) as f64 * q).round() as usize];
    json!({"n": values.len(), "min": at(0.0), "median": at(0.5), "p90": at(0.9), "max": at(1.0)})
}

/// Finds the id of the workspace named `name` anywhere in a reply.
fn workspace_id(value: &Value, name: &str) -> Option<Value> {
    match value {
        Value::Object(map) => {
            if map.get("name").and_then(Value::as_str) == Some(name)
                && let Some(id) = map.get("id").or_else(|| map.get("workspace"))
            {
                return Some(id.clone());
            }
            map.values().find_map(|v| workspace_id(v, name))
        }
        Value::Array(items) => items.iter().find_map(|v| workspace_id(v, name)),
        _ => None,
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    cmux_mobile_link::install_crypto_provider();
    let args = parse()?;
    let api = ApiClient::new(&args.base_url, &args.token);
    let ice_servers = api.ice().await.map(|c| c.ice_servers).unwrap_or_default();
    let device = uuid::Uuid::new_v4().to_string();
    api.register_device(&cmux_mobile_link::api::DeviceRegistration {
        device_id: device.clone(),
        kind: "phone".into(),
        name: "cmux-mobile-lanebench".into(),
        team_id: args.team.clone(),
        wg_public_key: None,
        machine_id: None,
        sibling_device_ids: Vec::new(),
    })
    .await
    .context("POST /v1/devices")?;
    let signaling = SignalingClient::connect(&args.base_url, &args.token, &args.team, &device).await?;
    let options = DialOptions {
        ice_servers,
        exclude_cgnat: args.exclude_cgnat,
        input_lane: args.input_lane,
        relay_only: args.relay_only,
        block_udp: args.block_udp,
        ..DialOptions::default()
    };
    let connected = cmux_mobile_link::dial::connect(
        &signaling,
        &args.mac,
        args.transport,
        &options,
        LinkConfig::default(),
    )
    .await?;
    let link = connected.link.clone();
    let screens = Arc::new(Screens::default());

    let control = Daemon::new(link.open("daemon", json!({})).await?, Arc::clone(&screens), false);
    let tag = &device[..8];
    let (name_a, name_b) = (format!("lane-a-{tag}"), format!("lane-b-{tag}"));
    let surface = |reply: &Value| reply["data"]["surface"].as_u64().context("no surface in reply");
    let a =
        surface(&control.request("new-workspace", json!({"name": name_a, "cols": 100, "rows": 30})).await?)?;
    let b =
        surface(&control.request("new-workspace", json!({"name": name_b, "cols": 100, "rows": 30})).await?)?;

    let attach_a = Daemon::new(link.open("daemon", json!({})).await?, Arc::clone(&screens), true);
    let attach_b = Daemon::new(link.open("daemon", json!({})).await?, Arc::clone(&screens), true);
    attach_a.request("attach-surface", json!({"surface": a})).await?;
    attach_b.request("attach-surface", json!({"surface": b})).await?;
    // Keystrokes: an input-lane channel like the app, or the attach channel.
    let lane = if args.input_lane {
        Some(Daemon::new(link.open_on("daemon", json!({}), Lane::Input).await?, Arc::clone(&screens), false))
    } else {
        None
    };
    let lane_state = format!("{:?}", link.input_lane());
    let input_a = lane.as_ref().unwrap_or(&attach_a);
    let input_b = lane.as_ref().unwrap_or(&attach_b);

    eprintln!("surfaces a={a} b={b} lane={lane_state} path={:?}", *connected.path.borrow());
    // Let both shells print their prompts.
    let started = Instant::now();
    for surface in [a, b] {
        send(if surface == a { input_a } else { input_b }, surface, b"printf 'ready%s\\n' ok\r").await?;
        screens
            .wait_for(surface, started, b"readyok", Duration::from_secs(20))
            .await
            .context("shell not ready")?;
    }

    eprintln!("shells ready");
    // Idle baseline: echo with no flood.
    let mut idle = Vec::new();
    for i in 0..5u8 {
        let letter = [b'a' + i];
        let at = Instant::now();
        send(input_b, b, &letter).await?;
        if let Some(seen) = screens.wait_for(b, at, &letter, Duration::from_secs(10)).await {
            idle.push(millis(seen - at));
        }
        tokio::time::sleep(Duration::from_millis(150)).await;
    }
    send(input_b, b, b"\x15").await?;

    eprintln!("idle echo done");
    // Flood A.
    screens.forget(a);
    let mut flood = args.flood.clone().into_bytes();
    flood.push(b'\r');
    send(input_a, a, &flood).await?;
    let flood_start = Instant::now();
    // Let the flood fill every queue between the PTY and this side.
    tokio::time::sleep(Duration::from_secs(3)).await;
    eprintln!("flood running: {} bytes so far", screens.total(a));
    let mut echoes = Vec::new();
    let mut acks = Vec::new();
    let mut missed = 0;
    for i in 0..args.samples {
        let letter = [b'a' + (i % 26) as u8];
        let at = Instant::now();
        if let Err(error) = send(input_b, b, &letter).await {
            let screen = control.request("read-screen", json!({"surface": b})).await;
            bail!("sample {i}: {error}; B screen {screen:?}");
        }
        acks.push(millis(at.elapsed()));
        match screens.wait_for(b, at, &letter, Duration::from_secs(20)).await {
            Some(seen) => echoes.push(millis(seen - at)),
            None => missed += 1,
        }
        screens.forget(a);
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    let flooded_bytes = screens.total(a);
    let flood_seconds = flood_start.elapsed().as_secs_f64();
    send(input_b, b, b"\x15").await?;

    // ^C in the flooding terminal, then a marker command.
    screens.forget(a);
    let at = Instant::now();
    let interrupt_ack = match send(input_a, a, b"\x03").await {
        Ok(()) => json!(millis(at.elapsed())),
        Err(error) => json!(format!("error: {error}")),
    };
    let interrupt = match send(input_a, a, b"printf 'lane%s\\n' done\r").await {
        Ok(()) => {
            // The Mac's screen of A (read-screen), polled: the ^C took effect
            // once the marker command ran.
            let mut done = None;
            while at.elapsed() < Duration::from_secs(120) {
                let screen = control.request("read-screen", json!({"surface": a})).await?;
                if screen.to_string().contains("lanedone") {
                    done = Some(millis(at.elapsed()));
                    break;
                }
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
            done
        }
        Err(_) => None,
    };
    let interrupt_seen =
        screens.wait_for(a, at, b"lanedone", Duration::from_secs(5)).await.map(|seen| millis(seen - at));

    let report = json!({
        "transport": format!("{:?}", args.transport),
        "path": format!("{:?}", *connected.path.borrow()),
        "input_lane": args.input_lane,
        "lane_state": lane_state,
        "flood": args.flood,
        "idle_echo_ms": summary(idle),
        "echo_ms": summary(echoes),
        "ack_ms": summary(acks),
        "missed": missed,
        "flood_mbps_received": (flooded_bytes as f64 * 8.0 / 1e6 / flood_seconds * 10.0).round() / 10.0,
        "interrupt_ack_ms": interrupt_ack,
        "interrupt_ms": interrupt,
        "interrupt_seen_ms": interrupt_seen,
    });
    println!("{report}");

    // Clean up the two workspaces.
    if let Ok(list) = control.request("list-workspaces", json!({})).await {
        for name in [&name_a, &name_b] {
            if let Some(id) = workspace_id(&list, name) {
                let _ = control.request("close-workspace", json!({"workspace": id})).await;
            }
        }
    }
    link.close("done");
    Ok(())
}
