//! Transport pair matrix, row `ios-linux` (measurement, not a check: `#[ignore]`d).
//!
//! How a phone reaches a Linux machine today: never directly. It opens `cloud-acpmux` on its
//! signed-in Mac's link (CmuxMobileLive/LiveCloudChats.swift:112), the Mac's `cmux-mobile-host`
//! connects that channel to the app-supplied carrier socket of that Cloud machine
//! (src/services.rs:415 `cloud_acpmux`, PROTOCOL.md:839-848), and the carrier (`cmux carrier
//! serve`, cmux-tui/src/carrier/serve.rs: one held session per machine, one mux stream per
//! accepted connection) reaches the machine's cmux-tui daemon through the cmux relay.
//! `cmux-mobile-host` ships only inside the signed macOS app (cmux-tui-core/src/tool_packs.rs:1-3,
//! IPhoneHostService.swift:21), so there is no phone->Linux direct path: the `direct` row is
//! PAIRCELL-NA.
//!
//! The `relay` path here, all in one process on a Linux runner:
//!
//! - phone: the real `Link` over cmux-wg (UDP on loopback), every tunnel datagram shaped by the
//!   condition's link profile (`DialOptions::impair_inbound` = cmux-mobile-link's
//!   `testing::shape_by_profile`, the same per-datagram model as cmux-fault's `UdpShaper`) and
//!   counted (both ways) for `delta_bytes`; signaling is the in-process `FakeSignaling`.
//! - Mac: the real `cmux_mobile_host::services::serve` for every channel; the app's
//!   `cloud_links` answer is played in-process (`control::answer_cloud_links`).
//! - carrier: a stand-in for `cmux carrier serve` on a Unix socket: one held circuit, one mux
//!   stream per accepted connection, a redial only once the held circuit is gone, relays tried
//!   in order (A, then B).
//! - second hop: the Mac's circuit reaches a real in-process `cmux_relay::Relay` through a
//!   cmux-fault TCP `Shaper` with `relay-80`; the relay protocol is the real one
//!   (Register / Connect / Allocated / Incoming / Join / Ready, then opaque binary frames).
//! - Linux: a fake cmux-tui daemon that registers its slot on both relays and serves the
//!   JSON-line commands the adapter (src/cloud_acp.rs) sends: identify, set-client-info,
//!   list-workspaces, agent-session-attach (pages with `hasMore` / `lastSeq`) and
//!   `agent-session-record` events.
//!
//! Not in the numbers: the carrier's Noise handshake and cmux-remote's mux (cmux-remote needs
//! the cmux-tui workspace's crossterm patch and ghostty-vt; this bench muxes with a 5-byte
//! header), the Swift client (LinkController timers, NWPathMonitor, its auto-rebind), the
//! app's stdin round trip for `cloud_links`, and the VM<->relay leg's latency (unshaped: the
//! machine and the relay share a datacenter).
//!
//! Conditions (`PAIRMATRIX_CONDITIONS`): loss (`lossy-3`), latency (`rtt-400`, a bench-local
//! 400 ms RTT profile: `lte` is already the sleep/failover/long profile), handoff
//! (`5g-lte-handoff` + the phone's network lost, a seeded 1-3 s stall, then a roam onto a new
//! socket), sleep (`lte`: `_link.park`, 60 s dark, wake + resume), failover (`lte`: relay A's
//! process dies; the carrier must reach relay B), long (`lte`: one session held
//! `PAIRMATRIX_LONG_MINUTES` under a chat stream, then a 5 s blip).
//!
//! Metrics: `ttfc_ms` dial start -> the measured chat's first attach page; `resume_ms` condition
//! end -> a record the daemon wrote at that moment arrives (loss/latency: the condition is
//! steady, so "end" is the app's reconnect: a new `cloud-acpmux` channel and an `afterSeq`
//! re-attach); `delta_bytes` phone-link tunnel bytes, both ways, from the change to caught up
//! (long: per minute); `fail` 1 when the run never reached content, never caught up within 90 s,
//! or lost or duplicated a record (afterSeq exactly-once).
//!
//! `cargo test --release -p cmux-mobile-host --test pair_matrix_ios_linux -- --ignored --nocapture --test-threads 1`

use std::collections::{BTreeSet, HashMap, HashSet};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_fault::shaper::{ProfileFile, Shaper};
use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::control::{self, CloudLink, CloudLinks};
use cmux_mobile_host::pairing::LinkAuth;
use cmux_mobile_host::services::{Peer, serve};
use cmux_mobile_link::dial::{self, SessionEvents, wireguard};
use cmux_mobile_link::testing::{
    FakeOptions, FakeSignaling, LinkProfile, set_link_profile, shape_by_profile,
};
use cmux_mobile_link::{
    Channel, ChannelEvent, DialOptions, Link, LinkConfig, SignalingClient, TransportKind,
};
use cmux_relay::{Relay, RelayConfig};
use cmux_remote_protocol::{CircuitId, LaneToken, REMOTE_PROTOCOL_VERSION, RelayControl, RelayRole};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UnixListener, UnixStream};
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};
use tokio_tungstenite::tungstenite::Message;

const PAIR: &str = "ios-linux";
const RIG: &str =
    "cmux-next-ios/rust/crates/cmux-mobile-host/tests/pair_matrix_ios_linux.rs::pair_matrix_ios_linux";
/// A run that has not reached content or caught up by then failed (DESIGN.md).
const BOUND: Duration = Duration::from_secs(90);
const MACHINE: &str = "pair-linux-vm";
const TEAM: &str = "pair-team";
const SLOT: &str = "pair-linux-slot";
/// The measured chat: the first tab (the 10,000-message chat under duress).
const MEASURED_SURFACE: u64 = 1000;
const MEASURED_SESSION: &str = "chat-0000";
/// The phone's attach page, as the app asks (acpmux/tests/mobile_link_conditions.rs).
const PAGE_LIMIT: u64 = 400;
/// The duress chat stream into the measured session: one record every 50 ms.
const DURESS_STREAM: Duration = Duration::from_millis(50);
/// The idle `long` stream (a steady chat, slower than duress's).
const IDLE_LONG_STREAM: Duration = Duration::from_millis(1000);
/// Bytes per mux data frame (the relay forwards frames up to 64 KiB).
const MUX_CHUNK: usize = 32 * 1024;
const OPEN: u8 = 0;
const DATA: u8 = 1;
const CLOSE: u8 = 2;

// ---------------------------------------------------------------------------
// Env, output
// ---------------------------------------------------------------------------

struct Env {
    n: usize,
    seed_base: u64,
    conditions: Vec<String>,
    loads: Vec<String>,
    paths: Vec<String>,
    long_minutes: u64,
}

fn list(name: &str, default: &str) -> Vec<String> {
    std::env::var(name)
        .unwrap_or_else(|_| default.to_owned())
        .split(',')
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .collect()
}

fn number(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.trim().parse().ok()).unwrap_or(default)
}

impl Env {
    fn read() -> Self {
        Self {
            n: number("PAIRMATRIX_N", 5) as usize,
            seed_base: number("PAIRMATRIX_SEED_BASE", 0),
            conditions: list("PAIRMATRIX_CONDITIONS", "loss,latency,handoff,sleep,failover,long"),
            loads: list("PAIRMATRIX_LOADS", "idle,duress"),
            paths: list("PAIRMATRIX_PATHS", "direct,relay"),
            long_minutes: number("PAIRMATRIX_LONG_MINUTES", 60).max(1),
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn cell(condition: &str, load: &str, metric: &str, value: &Result<f64, String>, run: usize, seed: u64) {
    let mut line = json!({"pair":PAIR,"path":"relay","condition":condition,"load":load,"metric":metric,
        "value":Value::Null,"run":run,"seed":seed,"host_os":std::env::consts::OS,"rig":RIG});
    match value {
        Ok(value) => line["value"] = json!((value * 10.0).round() / 10.0),
        Err(error) => line["error"] = json!(error),
    }
    println!("PAIRCELL {line}");
}

fn ms(duration: Duration) -> f64 {
    duration.as_secs_f64() * 1000.0
}

/// SplitMix64, as cmux-fault's `Rng`.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    fn range(&mut self, lo: u64, hi: u64) -> u64 {
        lo + self.next() % (hi - lo + 1)
    }
}

// ---------------------------------------------------------------------------
// The phone link's wire bytes (both ways)
// ---------------------------------------------------------------------------

static PHONE_WIRE_BYTES: AtomicU64 = AtomicU64::new(0);

/// `shape_by_profile`, counting every tunnel datagram either end receives.
fn counted_shape(via_turn: bool, from: &SocketAddr, len: usize) -> Option<Duration> {
    PHONE_WIRE_BYTES.fetch_add(len as u64, Ordering::Relaxed);
    shape_by_profile(via_turn, from, len)
}

fn wire_bytes() -> u64 {
    PHONE_WIRE_BYTES.load(Ordering::Relaxed)
}

fn phone_profile(condition: &str) -> LinkProfile {
    match condition {
        "loss" => LinkProfile::named("lossy-3"),
        // Bench-local: `lte`'s rate at a 400 ms round trip, no loss.
        "latency" => LinkProfile {
            name: "rtt-400".into(),
            up_kbit: 12_000,
            down_kbit: 12_000,
            rtt_ms: 400,
            jitter_ms: 20,
            loss_percent: 0.0,
        },
        "handoff" => LinkProfile::named("5g-lte-handoff"),
        _ => LinkProfile::named("lte"),
    }
}

// ---------------------------------------------------------------------------
// Relay, a killable relay process, relay WebSocket helpers
// ---------------------------------------------------------------------------

type Ws = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<TcpStream>>;

struct RelayServer {
    addr: SocketAddr,
    _relay: Relay,
    task: tokio::task::JoinHandle<()>,
}

impl RelayServer {
    async fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("relay listener");
        let addr = listener.local_addr().expect("relay addr");
        let relay = Relay::new(RelayConfig { allow_open: true, ..RelayConfig::default() }).expect("relay");
        let (listener, router) = relay.server_parts(listener);
        let task = tokio::spawn(async move {
            let _ = axum::serve(listener, router).await;
        });
        Self { addr, _relay: relay, task }
    }
}

impl Drop for RelayServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// A TCP front for a relay whose `kill` is the relay process dying: every connection through
/// it closes at once and new ones are refused.
struct Killable {
    addr: SocketAddr,
    handles: Arc<Mutex<Vec<tokio::task::AbortHandle>>>,
}

impl Killable {
    async fn start(upstream: SocketAddr) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("front listener");
        let addr = listener.local_addr().expect("front addr");
        let handles = Arc::new(Mutex::new(Vec::new()));
        let held = Arc::clone(&handles);
        let accept = tokio::spawn(async move {
            while let Ok((mut near, _)) = listener.accept().await {
                let task = tokio::spawn(async move {
                    let Ok(mut far) = TcpStream::connect(upstream).await else { return };
                    let _ = near.set_nodelay(true);
                    let _ = far.set_nodelay(true);
                    let _ = tokio::io::copy_bidirectional(&mut near, &mut far).await;
                });
                held.lock().unwrap().push(task.abort_handle());
            }
        });
        handles.lock().unwrap().push(accept.abort_handle());
        Self { addr, handles }
    }

    fn kill(&self) {
        for handle in self.handles.lock().unwrap().drain(..) {
            handle.abort();
        }
    }
}

impl Drop for Killable {
    fn drop(&mut self) {
        self.kill();
    }
}

async fn ws(addr: SocketAddr) -> Result<Ws, String> {
    let url = format!("ws://{addr}/v1/relay");
    match tokio::time::timeout(Duration::from_secs(10), tokio_tungstenite::connect_async(url)).await {
        Ok(Ok((socket, _))) => Ok(socket),
        Ok(Err(error)) => Err(format!("relay websocket: {error}")),
        Err(_) => Err("relay websocket timed out".into()),
    }
}

async fn send_control(socket: &mut Ws, control: &RelayControl) -> Result<(), String> {
    let text = serde_json::to_string(control).map_err(|e| e.to_string())?;
    socket.send(Message::Text(text.into())).await.map_err(|e| format!("relay send: {e}"))
}

async fn recv_control(socket: &mut Ws) -> Result<RelayControl, String> {
    loop {
        let message = tokio::time::timeout(Duration::from_secs(15), socket.next())
            .await
            .map_err(|_| "relay control timed out".to_owned())?
            .ok_or("relay closed")?
            .map_err(|e| format!("relay read: {e}"))?;
        match message {
            Message::Text(text) => {
                return serde_json::from_str(text.as_str()).map_err(|e| format!("relay control: {e}"));
            }
            Message::Ping(bytes) => {
                let _ = socket.send(Message::Pong(bytes)).await;
            }
            Message::Close(_) => return Err("relay closed".into()),
            _ => {}
        }
    }
}

fn refused(control: RelayControl, wanted: &str) -> String {
    match control {
        RelayControl::Error { code, message, .. } => format!("relay refused {wanted}: {code} {message}"),
        _ => format!("relay answered {wanted} out of turn"),
    }
}

async fn join(
    addr: SocketAddr,
    circuit: CircuitId,
    lane: LaneToken,
    generation: u64,
    ticket: String,
    role: RelayRole,
) -> Result<Ws, String> {
    let mut socket = ws(addr).await?;
    send_control(
        &mut socket,
        &RelayControl::Join {
            protocol: REMOTE_PROTOCOL_VERSION,
            slot: SLOT.into(),
            circuit,
            lane,
            generation,
            ticket,
            role,
        },
    )
    .await?;
    match recv_control(&mut socket).await? {
        RelayControl::Ready { .. } => Ok(socket),
        other => Err(refused(other, "join")),
    }
}

/// A circuit's socket: binary frames out from the sender, in to the receiver; the receiver
/// ends when the circuit does.
fn run_circuit(socket: Ws) -> (UnboundedSender<Bytes>, UnboundedReceiver<Bytes>) {
    let (out_tx, mut out_rx) = unbounded_channel::<Bytes>();
    let (in_tx, in_rx) = unbounded_channel::<Bytes>();
    tokio::spawn(async move {
        let (mut sink, mut stream) = socket.split();
        loop {
            tokio::select! {
                out = out_rx.recv() => match out {
                    Some(bytes) => if sink.send(Message::Binary(bytes)).await.is_err() { break },
                    None => break,
                },
                incoming = stream.next() => match incoming {
                    Some(Ok(Message::Binary(bytes))) => if in_tx.send(bytes).is_err() { break },
                    Some(Ok(Message::Ping(bytes))) => { let _ = sink.send(Message::Pong(bytes)).await; }
                    Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                    Some(Ok(_)) => {}
                },
            }
        }
    });
    (out_tx, in_rx)
}

fn frame(id: u32, kind: u8, payload: &[u8]) -> Bytes {
    let mut out = Vec::with_capacity(5 + payload.len());
    out.extend_from_slice(&id.to_be_bytes());
    out.push(kind);
    out.extend_from_slice(payload);
    Bytes::from(out)
}

fn parse_frame(bytes: &Bytes) -> Option<(u32, u8, Bytes)> {
    if bytes.len() < 5 {
        return None;
    }
    let id = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    Some((id, bytes[4], bytes.slice(5..)))
}

fn send_line(out: &UnboundedSender<Bytes>, stream: u32, value: &Value) -> bool {
    let mut bytes = serde_json::to_vec(value).unwrap_or_default();
    bytes.push(b'\n');
    bytes.chunks(MUX_CHUNK).all(|chunk| out.send(frame(stream, DATA, chunk)).is_ok())
}

// ---------------------------------------------------------------------------
// Carrier stand-in (the Mac's `cmux carrier serve`)
// ---------------------------------------------------------------------------

struct Held {
    out: UnboundedSender<Bytes>,
    streams: Arc<Mutex<HashMap<u32, UnboundedSender<Bytes>>>>,
    alive: Arc<AtomicBool>,
    next: AtomicU32,
    control: tokio::task::JoinHandle<()>,
}

impl Drop for Held {
    fn drop(&mut self) {
        self.control.abort();
    }
}

struct Carrier {
    /// The relays' shaped addresses, in the order the carrier tries them.
    relays: Vec<SocketAddr>,
    held: tokio::sync::Mutex<Option<Arc<Held>>>,
    generation: AtomicU64,
    dials: AtomicU64,
}

impl Carrier {
    async fn held(&self) -> Result<Arc<Held>, String> {
        let mut held = self.held.lock().await;
        if let Some(circuit) = held.as_ref()
            && circuit.alive.load(Ordering::SeqCst)
        {
            return Ok(Arc::clone(circuit));
        }
        *held = None;
        let mut errors = Vec::new();
        for relay in &self.relays {
            match self.dial(*relay).await {
                Ok(circuit) => {
                    let circuit = Arc::new(circuit);
                    *held = Some(Arc::clone(&circuit));
                    return Ok(circuit);
                }
                Err(error) => errors.push(error),
            }
        }
        Err(errors.join("; "))
    }

    async fn dial(&self, relay: SocketAddr) -> Result<Held, String> {
        self.dials.fetch_add(1, Ordering::Relaxed);
        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let mut control = ws(relay).await?;
        send_control(
            &mut control,
            &RelayControl::Connect {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: SLOT.into(),
                ticket: "pair-client-ticket".into(),
                lane: LaneToken("interactive".into()),
                generation,
                accepts_parked: false,
                grant: None,
                inline: false,
            },
        )
        .await?;
        let (circuit, lane, generation, ticket) = match recv_control(&mut control).await? {
            RelayControl::Allocated { circuit, lane, generation, join_ticket } => {
                (circuit, lane, generation, join_ticket)
            }
            other => return Err(refused(other, "connect")),
        };
        let socket = join(relay, circuit, lane, generation, ticket, RelayRole::Client).await?;
        // The client's control socket stays open beside the circuit, answering pings.
        let control = tokio::spawn(async move {
            while let Some(Ok(message)) = control.next().await {
                if let Message::Ping(bytes) = message {
                    let _ = control.send(Message::Pong(bytes)).await;
                }
            }
        });
        let (out, mut frames) = run_circuit(socket);
        let streams: Arc<Mutex<HashMap<u32, UnboundedSender<Bytes>>>> = Arc::default();
        let alive = Arc::new(AtomicBool::new(true));
        let (dispatch_streams, dispatch_alive) = (Arc::clone(&streams), Arc::clone(&alive));
        tokio::spawn(async move {
            while let Some(bytes) = frames.recv().await {
                let Some((id, kind, payload)) = parse_frame(&bytes) else { continue };
                let mut streams = dispatch_streams.lock().unwrap();
                match kind {
                    DATA => {
                        if let Some(stream) = streams.get(&id) {
                            let _ = stream.send(payload);
                        }
                    }
                    CLOSE => {
                        streams.remove(&id);
                    }
                    _ => {}
                }
            }
            // The circuit is gone: every stream on it closes (its connection sees EOF).
            dispatch_alive.store(false, Ordering::SeqCst);
            dispatch_streams.lock().unwrap().clear();
        });
        Ok(Held { out, streams, alive, next: AtomicU32::new(1), control })
    }

    async fn serve(self: Arc<Self>, listener: UnixListener) {
        while let Ok((connection, _)) = listener.accept().await {
            let carrier = Arc::clone(&self);
            tokio::spawn(async move { carrier.pipe(connection).await });
        }
    }

    async fn pipe(&self, connection: UnixStream) {
        let Ok(held) = self.held().await else { return };
        let id = held.next.fetch_add(1, Ordering::Relaxed);
        let (tx, mut rx) = unbounded_channel::<Bytes>();
        held.streams.lock().unwrap().insert(id, tx);
        if held.out.send(frame(id, OPEN, b"")).is_err() {
            return;
        }
        let (mut read, mut write) = connection.into_split();
        let out = held.out.clone();
        let up = tokio::spawn(async move {
            let mut buffer = vec![0_u8; MUX_CHUNK];
            loop {
                match read.read(&mut buffer).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if out.send(frame(id, DATA, &buffer[..n])).is_err() {
                            break;
                        }
                    }
                }
            }
            let _ = out.send(frame(id, CLOSE, b""));
        });
        while let Some(bytes) = rx.recv().await {
            if write.write_all(&bytes).await.is_err() {
                break;
            }
        }
        up.abort();
        drop(write);
        held.streams.lock().unwrap().remove(&id);
        let _ = held.out.send(frame(id, CLOSE, b""));
    }
}

// ---------------------------------------------------------------------------
// The Linux machine: a fake cmux-tui daemon behind the relay
// ---------------------------------------------------------------------------

struct Sub {
    key: u64,
    stream: u32,
    out: UnboundedSender<Bytes>,
    /// The log's end when this connection attached: pages stop there, the stream starts after.
    from: u64,
}

struct Chat {
    surface: u64,
    session: String,
    records: Vec<Value>,
    subs: Vec<Sub>,
}

struct Vm {
    chats: Mutex<Vec<Chat>>,
    rng: Mutex<Rng>,
    epoch: Instant,
    keys: AtomicU64,
}

const WORDS: [&str; 16] = [
    "the", "build", "passes", "now", "after", "fixing", "relay", "carrier", "session", "phone", "linux",
    "cache", "and", "tests", "stream", "resume",
];

impl Vm {
    fn new(load: &str, seed: u64) -> Arc<Self> {
        let (sessions, big) = if load == "duress" { (50, 10_000) } else { (5, 40) };
        let vm = Arc::new(Self {
            chats: Mutex::new(Vec::new()),
            rng: Mutex::new(Rng(seed ^ 0x11_0C_A1)),
            epoch: Instant::now(),
            keys: AtomicU64::new(1),
        });
        let mut chats = Vec::new();
        for index in 0..sessions {
            let session = format!("chat-{index:04}");
            let messages = if index == 0 { big } else { 40 };
            let records = (1..=messages).map(|seq| vm.record(&session, seq, None)).collect();
            chats.push(Chat { surface: MEASURED_SURFACE + index as u64, session, records, subs: Vec::new() });
        }
        *vm.chats.lock().unwrap() = chats;
        vm
    }

    /// One chat record (an ACP update, seq numbered): a user prompt or an agent reply.
    fn record(&self, session: &str, seq: u64, marker: Option<u64>) -> Value {
        let mut rng = self.rng.lock().unwrap();
        let words = if seq % 2 == 1 { rng.range(8, 30) } else { rng.range(40, 120) };
        let text = (0..words).map(|_| WORDS[(rng.next() % 16) as usize]).collect::<Vec<_>>().join(" ");
        let update = if seq % 2 == 1 { "user_message_chunk" } else { "agent_message_chunk" };
        let mut record = json!({"seq":seq,"sessionId":session,"kind":"update",
            "at":self.epoch.elapsed().as_millis() as u64,
            "update":{"sessionUpdate":update,"content":{"type":"text","text":text}}});
        if let Some(marker) = marker {
            record["marker"] = json!(marker);
        }
        record
    }

    /// Append a record to `surface`'s chat and stream it to every attached connection.
    fn push(&self, surface: u64, marker: Option<u64>) {
        let mut chats = self.chats.lock().unwrap();
        let Some(chat) = chats.iter_mut().find(|chat| chat.surface == surface) else { return };
        let seq = chat.records.len() as u64 + 1;
        let record = self.record(&chat.session, seq, marker);
        let event = json!({"event":"agent-session-record","surface":surface,"record":record});
        chat.records.push(record);
        chat.subs.retain(|sub| send_line(&sub.out, sub.stream, &event));
    }

    fn stream(self: &Arc<Self>, every: Duration) -> tokio::task::JoinHandle<()> {
        let vm = Arc::clone(self);
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(every);
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                tick.tick().await;
                vm.push(MEASURED_SURFACE, None);
            }
        })
    }

    fn directory(&self) -> Value {
        let chats = self.chats.lock().unwrap();
        let tabs = chats
            .iter()
            .map(|chat| {
                json!({"surface":chat.surface,"name":chat.session,
                    "conversation":{"agent_session":{"session":chat.session,"harness":"claude"}}})
            })
            .collect::<Vec<_>>();
        json!({"registry_id":"pair-registry","workspaces":[{"id":1,"kind":"normal","active":true,
            "screens":[{"panes":[{"tabs":tabs}]}]}]})
    }

    fn handle(&self, request: Value, key: u64, stream: u32, out: &UnboundedSender<Bytes>) {
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let ok = |data: Value| json!({"id":id,"ok":true,"data":data});
        let reply = match request.get("cmd").and_then(Value::as_str).unwrap_or("") {
            "identify" => ok(json!({"name":"pair-linux","capabilities":[
                cmux_mobile_link::names::CLOUD_MOBILE_CHAT,
                cmux_mobile_link::names::CONVERSATION_TABS,
                cmux_mobile_link::names::AGENT_SESSION_TABS]})),
            "list-workspaces" => ok(self.directory()),
            "agent-session-attach" => {
                let surface = request.get("surface").and_then(Value::as_u64).unwrap_or(0);
                let mut chats = self.chats.lock().unwrap();
                let Some(chat) = chats.iter_mut().find(|chat| chat.surface == surface) else {
                    send_line(out, stream, &json!({"id":id,"ok":false,"error":"no such surface"}));
                    return;
                };
                let end = chat.records.len() as u64;
                let cap = chat.subs.iter().find(|sub| sub.key == key).map_or(end, |sub| sub.from);
                let limit = request.get("limit").and_then(Value::as_u64).unwrap_or(100).max(1);
                let (from, to, has_more) = match request.get("after_seq").and_then(Value::as_u64) {
                    Some(after) => {
                        let to = (after + limit).min(cap);
                        (after.min(cap), to, to < cap)
                    }
                    None => (cap.saturating_sub(limit), cap, cap > limit),
                };
                let events = chat.records[from as usize..to as usize].to_vec();
                let reply = json!({"id":id,"ok":true,"data":{
                    "session":{"sessionId":chat.session,"name":chat.session,"harness":"claude",
                        "currentModeId":"default","enforcement":{"policy":"ask"}},
                    "events":events,"hasMore":has_more,"lastSeq":cap}});
                // The reply and the subscription under one lock: no record falls between them.
                send_line(out, stream, &reply);
                if !chat.subs.iter().any(|sub| sub.key == key) {
                    chat.subs.push(Sub { key, stream, out: out.clone(), from: end });
                }
                return;
            }
            "agent-session-detach" => {
                let surface = request.get("surface").and_then(Value::as_u64).unwrap_or(0);
                for chat in self.chats.lock().unwrap().iter_mut().filter(|chat| chat.surface == surface) {
                    chat.subs.retain(|sub| sub.key != key);
                }
                ok(json!({}))
            }
            _ => ok(json!({})),
        };
        send_line(out, stream, &reply);
    }

    fn unsubscribe(&self, key: u64) {
        for chat in self.chats.lock().unwrap().iter_mut() {
            chat.subs.retain(|sub| sub.key != key);
        }
    }

    /// Register the slot on `relay` and serve every circuit it hands this machine.
    async fn register(self: &Arc<Self>, relay: SocketAddr) -> Result<tokio::task::JoinHandle<()>, String> {
        let mut control = ws(relay).await?;
        send_control(
            &mut control,
            &RelayControl::Register {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: SLOT.into(),
                ticket: "pair-daemon-ticket".into(),
            },
        )
        .await?;
        match recv_control(&mut control).await? {
            RelayControl::Registered { .. } => {}
            other => return Err(refused(other, "register")),
        }
        let vm = Arc::clone(self);
        Ok(tokio::spawn(async move {
            let mut lease = tokio::time::interval(Duration::from_secs(10));
            let mut nonce = 0;
            loop {
                tokio::select! {
                    message = control.next() => match message {
                        Some(Ok(Message::Text(text))) => {
                            if let Ok(RelayControl::Incoming { circuit, lane, generation, join_ticket }) =
                                serde_json::from_str::<RelayControl>(text.as_str())
                            {
                                let vm = Arc::clone(&vm);
                                tokio::spawn(async move {
                                    if let Ok(socket) =
                                        join(relay, circuit, lane, generation, join_ticket, RelayRole::Daemon).await
                                    {
                                        vm.circuit(socket).await;
                                    }
                                });
                            }
                        }
                        Some(Ok(Message::Ping(bytes))) => { let _ = control.send(Message::Pong(bytes)).await; }
                        Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                        Some(Ok(_)) => {}
                    },
                    _ = lease.tick() => {
                        nonce += 1;
                        if send_control(&mut control, &RelayControl::Ping { nonce }).await.is_err() { break; }
                    }
                }
            }
        }))
    }

    async fn circuit(&self, socket: Ws) {
        let (out, mut frames) = run_circuit(socket);
        let mut connections: HashMap<u32, (u64, Vec<u8>)> = HashMap::new();
        while let Some(bytes) = frames.recv().await {
            let Some((id, kind, payload)) = parse_frame(&bytes) else { continue };
            match kind {
                OPEN => {
                    connections.insert(id, (self.keys.fetch_add(1, Ordering::Relaxed), Vec::new()));
                }
                DATA => {
                    let Some((key, buffer)) = connections.get_mut(&id) else { continue };
                    buffer.extend_from_slice(&payload);
                    while let Some(end) = buffer.iter().position(|b| *b == b'\n') {
                        let line: Vec<u8> = buffer.drain(..=end).collect();
                        if let Ok(request) = serde_json::from_slice::<Value>(&line) {
                            self.handle(request, *key, id, &out);
                        }
                    }
                }
                CLOSE => {
                    if let Some((key, _)) = connections.remove(&id) {
                        self.unsubscribe(key);
                        let _ = out.send(frame(id, CLOSE, b""));
                    }
                }
                _ => {}
            }
        }
        for (key, _) in connections.into_values() {
            self.unsubscribe(key);
        }
    }
}

// ---------------------------------------------------------------------------
// The rig: phone link -> Mac host -> carrier -> shaped hop -> relay A|B -> Linux daemon
// ---------------------------------------------------------------------------

struct Rig {
    _dir: tempfile::TempDir,
    _relay_a: RelayServer,
    _relay_b: RelayServer,
    relay_a_process: Killable,
    _hop_a: Shaper,
    _hop_b: Shaper,
    vm: Arc<Vm>,
    carrier: Arc<Carrier>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
    _server: FakeSignaling,
    phone: SignalingClient,
    mac_id: String,
    options: DialOptions,
}

impl Rig {
    async fn start(load: &str, seed: u64) -> Result<Self, String> {
        let dir = tempfile::tempdir().map_err(|e| e.to_string())?;
        let relay_a = RelayServer::start().await;
        let relay_b = RelayServer::start().await;
        let relay_a_process = Killable::start(relay_a.addr).await;
        let relay_80 = ProfileFile::builtin().get("relay-80").cloned().ok_or("no relay-80 profile")?;
        let trace = cmux_fault::Trace::new();
        let hop_a = Shaper::start(relay_a_process.addr, relay_80.clone(), seed, &trace)
            .await
            .map_err(|e| e.to_string())?;
        let hop_b =
            Shaper::start(relay_b.addr, relay_80, seed ^ 0xB, &trace).await.map_err(|e| e.to_string())?;
        let mut tasks = Vec::new();
        let vm = Vm::new(load, seed);
        tasks.push(vm.register(relay_a_process.addr).await?);
        tasks.push(vm.register(relay_b.addr).await?);

        let socket = dir.path().join("carrier.sock");
        let listener = UnixListener::bind(&socket).map_err(|e| e.to_string())?;
        let carrier = Arc::new(Carrier {
            relays: vec![hop_a.addr(), hop_b.addr()],
            held: tokio::sync::Mutex::new(None),
            generation: AtomicU64::new(0),
            dials: AtomicU64::new(0),
        });
        // The app keeps its carrier up: the circuit is held before the phone dials.
        carrier.held().await?;
        tasks.push(tokio::spawn(Arc::clone(&carrier).serve(listener)));
        tasks.push(tokio::spawn(answer_cloud_links(socket)));

        let config = Arc::new(ServiceConfig {
            tui_socket_dir: dir.path().to_owned(),
            default_session: "main".into(),
            default_socket: None,
            file_roots: vec![],
            acpmux: AcpmuxTarget::Fixed { url: "ws://127.0.0.1:1/".into(), token: None },
            pairing: None,
            agent_tab_host: None,
            uploads_dir: dir.path().join("uploads"),
            chief_socket: None,
            browser: cmux_mobile_host::browser::BrowserConfig::new(None, 1),
            surface: cmux_mobile_host::surface::SurfaceConfig::new(None, 1),
        });
        let options = DialOptions {
            include_loopback: true,
            impair_inbound: Some(counted_shape),
            timeout: Duration::from_secs(40),
            ..DialOptions::default()
        };
        let server = FakeSignaling::start(FakeOptions::default()).await;
        let mac_id = uuid::Uuid::new_v4().to_string();
        let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id)
            .await
            .map_err(|e| format!("mac signaling: {e:?}"))?;
        let mac_options = options.clone();
        tasks.push(tokio::spawn(async move {
            while let Some(session) = mac.next_session().await {
                let events = SessionEvents {
                    backend: mac.events(),
                    session_id: session.first.session_id.clone(),
                    session: session.events,
                };
                let (mac, options, config) = (mac.clone(), mac_options.clone(), Arc::clone(&config));
                tokio::spawn(async move {
                    let Ok(connected) =
                        dial::answer(&mac, session.first, events, &options, LinkConfig::default()).await
                    else {
                        return;
                    };
                    let session_id = connected.session_id.clone();
                    while let Some(incoming) = connected.link.accept().await {
                        tokio::spawn(serve(
                            Arc::clone(&config),
                            Peer {
                                device_id: "pair-phone".into(),
                                session_id: session_id.clone(),
                                video: None,
                                session_exposure: None,
                                route: None,
                                path: None,
                            },
                            Arc::new(LinkAuth::default()),
                            incoming,
                        ));
                    }
                });
            }
        }));
        let phone_id = uuid::Uuid::new_v4().to_string();
        let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id)
            .await
            .map_err(|e| format!("phone signaling: {e:?}"))?;
        Ok(Self {
            _dir: dir,
            _relay_a: relay_a,
            _relay_b: relay_b,
            relay_a_process,
            _hop_a: hop_a,
            _hop_b: hop_b,
            vm,
            carrier,
            tasks,
            _server: server,
            phone,
            mac_id,
            options,
        })
    }

    async fn dial(&self) -> Result<(Link, String), String> {
        let connected = dial::connect(
            &self.phone,
            &self.mac_id,
            TransportKind::WireGuard,
            &self.options,
            LinkConfig::default(),
        )
        .await
        .map_err(|e| format!("dial: {e:?}"))?;
        Ok((connected.link, connected.session_id))
    }
}

impl Drop for Rig {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
    }
}

/// Plays the app: every `cloud_links` request gets this Mac's one owned Cloud link.
async fn answer_cloud_links(socket: PathBuf) {
    loop {
        for request in control::pending_cloud_link_requests() {
            control::answer_cloud_links(
                request,
                CloudLinks {
                    paid: true,
                    desktops: false,
                    links: vec![CloudLink {
                        machine_id: MACHINE.into(),
                        team_id: TEAM.into(),
                        name: "pair-linux".into(),
                        socket: Some(socket.clone()),
                        owner: true,
                        status: "running".into(),
                        ran: true,
                    }],
                },
            );
        }
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
}

// ---------------------------------------------------------------------------
// The phone's ACP client on `cloud-acpmux`
// ---------------------------------------------------------------------------

#[derive(Default)]
struct Seen {
    seqs: BTreeSet<u64>,
    streamed: HashSet<u64>,
    paged: HashSet<u64>,
    duplicates: u64,
    markers: HashMap<u64, Instant>,
}

impl Seen {
    fn take(&mut self, record: &Value, streamed: bool) {
        if record.get("sessionId").and_then(Value::as_str) != Some(MEASURED_SESSION) {
            return;
        }
        let Some(seq) = record.get("seq").and_then(Value::as_u64) else { return };
        let fresh = if streamed { self.streamed.insert(seq) } else { self.paged.insert(seq) };
        if !fresh {
            self.duplicates += 1;
        }
        self.seqs.insert(seq);
        if let Some(marker) = record.get("marker").and_then(Value::as_u64) {
            self.markers.entry(marker).or_insert_with(Instant::now);
        }
    }

    fn last(&self) -> u64 {
        self.seqs.last().copied().unwrap_or(0)
    }

    /// Lost or duplicated records since the first one seen, if any.
    fn exactly_once(&self) -> Result<(), String> {
        let (Some(first), Some(last)) = (self.seqs.first(), self.seqs.last()) else {
            return Err("no records".into());
        };
        let lost = (last - first + 1) - self.seqs.len() as u64;
        if lost > 0 || self.duplicates > 0 {
            return Err(format!("afterSeq exactly-once: {lost} lost, {} duplicated", self.duplicates));
        }
        Ok(())
    }
}

struct Acp {
    channel: Channel,
    pending: Vec<u8>,
    next: u64,
}

impl Acp {
    async fn open(link: &Link) -> Result<Self, String> {
        let channel = link
            .open("cloud-acpmux", json!({"machine_id":MACHINE,"team_id":TEAM}))
            .await
            .map_err(|e| format!("open cloud-acpmux: {e:?}"))?;
        Ok(Self { channel, pending: Vec::new(), next: 0 })
    }

    async fn message(&mut self) -> Result<Value, String> {
        loop {
            if !self.pending.is_empty() {
                // One message per data frame, a large one split over several; two in one frame parse too.
                let mut values = serde_json::Deserializer::from_slice(&self.pending).into_iter::<Value>();
                let next = values.next();
                let used = values.byte_offset();
                match next {
                    Some(Ok(value)) => {
                        self.pending.drain(..used);
                        while self.pending.first().is_some_and(u8::is_ascii_whitespace) {
                            self.pending.remove(0);
                        }
                        return Ok(value);
                    }
                    None => self.pending.clear(),
                    Some(Err(error)) if error.is_eof() => {}
                    Some(Err(error)) => return Err(format!("bad ACP message: {error}")),
                }
            }
            match self.channel.recv().await {
                Some(ChannelEvent::Data(bytes)) => self.pending.extend_from_slice(&bytes),
                Some(ChannelEvent::Closed(info)) => {
                    return Err(format!("closed {}: {}", info.code, info.reason));
                }
                None => return Err("channel ended".into()),
            }
        }
    }

    /// The next message, recorded into `seen`; `Ok(None)` at `deadline`.
    async fn pump(&mut self, seen: &mut Seen, deadline: Instant) -> Result<Option<Value>, String> {
        let left = deadline.saturating_duration_since(Instant::now());
        let Ok(message) = tokio::time::timeout(left, self.message()).await else { return Ok(None) };
        let message = message?;
        if message.get("method").and_then(Value::as_str) == Some("_acpmux/event")
            && let Some(record) = message.get("params")
        {
            seen.take(record, true);
        }
        if let Some(events) = message.pointer("/result/events").and_then(Value::as_array) {
            for record in events {
                seen.take(record, false);
            }
        }
        Ok(Some(message))
    }

    async fn request(&mut self, seen: &mut Seen, method: &str, params: Value) -> Result<Value, String> {
        self.next += 1;
        let id = self.next;
        let request = json!({"jsonrpc":"2.0","id":id,"method":method,"params":params});
        self.channel.send(Bytes::from(request.to_string())).await.map_err(|e| format!("send: {e:?}"))?;
        let deadline = Instant::now() + BOUND;
        loop {
            let Some(message) = self.pump(seen, deadline).await? else {
                return Err(format!("{method} timed out"));
            };
            if message.get("id") == Some(&json!(id)) {
                if let Some(error) = message.get("error") {
                    return Err(format!("{method}: {error}"));
                }
                return Ok(message.get("result").cloned().unwrap_or(Value::Null));
            }
        }
    }

    /// initialize, the session list, then the measured chat: its newest page (cold) or every
    /// page after the last seq the phone holds (reconnect).
    async fn attach(&mut self, seen: &mut Seen, reconnect: bool) -> Result<(), String> {
        self.request(seen, "initialize", json!({"protocolVersion":1,"clientCapabilities":{}})).await?;
        let listed = self.request(seen, "_acpmux/watch", json!({"limit":100})).await?;
        let sessions = listed.get("sessions").and_then(Value::as_array).map_or(0, Vec::len);
        if sessions == 0 {
            return Err("empty session list".into());
        }
        loop {
            let mut params = json!({"sessionId":MEASURED_SESSION,"limit":PAGE_LIMIT,
                "kinds":["update","prompt"]});
            if reconnect {
                params["afterSeq"] = json!(seen.last());
            }
            let page = self.request(seen, "_acpmux/attach", params).await?;
            let count = page.get("events").and_then(Value::as_array).map_or(0, Vec::len);
            if !reconnect && count == 0 {
                return Err("first page has no records".into());
            }
            if !(reconnect && page.get("hasMore") == Some(&json!(true))) {
                return Ok(());
            }
        }
    }

    async fn until_marker(
        &mut self,
        seen: &mut Seen,
        marker: u64,
        deadline: Instant,
    ) -> Result<Instant, String> {
        loop {
            if let Some(at) = seen.markers.get(&marker) {
                return Ok(*at);
            }
            if self.pump(seen, deadline).await?.is_none() {
                return Err("no fresh record within 90 s".into());
            }
        }
    }

    /// Read (and record) everything for `span`.
    async fn drain(&mut self, seen: &mut Seen, span: Duration) -> Result<(), String> {
        let deadline = Instant::now() + span;
        while self.pump(seen, deadline).await?.is_some() {}
        Ok(())
    }
}

/// A new channel and an `afterSeq` re-attach, retried until it works or `deadline`.
async fn reconnect(link: &Link, seen: &mut Seen, deadline: Instant) -> Result<Acp, String> {
    let mut last = String::new();
    while Instant::now() < deadline {
        match Acp::open(link).await {
            Ok(mut acp) => match acp.attach(seen, true).await {
                Ok(()) => return Ok(acp),
                Err(error) => last = error,
            },
            Err(error) => last = error,
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    Err(format!("reconnect: {last}"))
}

// ---------------------------------------------------------------------------
// One run
// ---------------------------------------------------------------------------

struct Outcome {
    ttfc: Result<f64, String>,
    resume: Result<f64, String>,
    bytes: Result<f64, String>,
    fail: Option<String>,
}

impl Outcome {
    fn failed(error: String) -> Self {
        Self {
            ttfc: Err(error.clone()),
            resume: Err(error.clone()),
            bytes: Err(error.clone()),
            fail: Some(error),
        }
    }
}

async fn run_once(condition: &str, load: &str, seed: u64, long_minutes: u64) -> Outcome {
    let rig = match Rig::start(load, seed).await {
        Ok(rig) => rig,
        Err(error) => return Outcome::failed(format!("rig: {error}")),
    };
    set_link_profile(Some(phone_profile(condition)), seed);
    let stream = match (condition, load) {
        (_, "duress") => Some(rig.vm.stream(DURESS_STREAM)),
        ("long", _) => Some(rig.vm.stream(IDLE_LONG_STREAM)),
        _ => None,
    };
    let outcome = measure(&rig, condition, seed, long_minutes).await;
    if let Some(stream) = stream {
        stream.abort();
    }
    set_link_profile(None, 0);
    outcome
}

async fn measure(rig: &Rig, condition: &str, seed: u64, long_minutes: u64) -> Outcome {
    let mut seen = Seen::default();
    let started = Instant::now();
    let first = tokio::time::timeout(BOUND, async {
        let (link, session_id) = rig.dial().await?;
        let mut acp = Acp::open(&link).await?;
        acp.attach(&mut seen, false).await?;
        Ok::<_, String>((link, session_id, acp))
    })
    .await
    .unwrap_or_else(|_| Err("no content within 90 s".into()));
    let (link, session_id, mut acp) = match first {
        Ok(up) => up,
        Err(error) => return Outcome::failed(error),
    };
    let ttfc = ms(started.elapsed());
    let mut rng = Rng(seed ^ 0xC0DE);
    const MARKER: u64 = 1;

    let changed = async {
        // A moment of steady state (the duress stream flowing) before the change.
        acp.drain(&mut seen, Duration::from_secs(1)).await?;
        let mut per_minute = None;
        let (bytes_at_change, end) = match condition {
            "loss" | "latency" => {
                let bytes = wire_bytes();
                acp.channel.close("reconnect", "pair matrix reconnect").await;
                let end = Instant::now();
                rig.vm.push(MEASURED_SURFACE, Some(MARKER));
                acp = reconnect(&link, &mut seen, end + BOUND).await?;
                (bytes, end)
            }
            "handoff" => {
                let bytes = wire_bytes();
                if wireguard::simulate_network_loss(Some(session_id.as_str()), true) != 1 {
                    return Err("no phone session to lose".to_owned());
                }
                tokio::time::sleep(Duration::from_millis(rng.range(1_000, 3_000))).await;
                let end = Instant::now();
                rig.vm.push(MEASURED_SURFACE, Some(MARKER));
                let roaming = session_id.clone();
                tokio::spawn(async move { wireguard::roam_session(&roaming, true).await });
                (bytes, end)
            }
            "sleep" => {
                let bytes = wire_bytes();
                match link.park(Duration::from_secs(600), Duration::from_secs(5)).await {
                    Ok(true) => {}
                    other => return Err(format!("park: {other:?}")),
                }
                wireguard::simulate_blackout(Some(session_id.as_str()), true, true);
                tokio::time::sleep(Duration::from_secs(60)).await;
                wireguard::simulate_blackout(Some(session_id.as_str()), true, false);
                let end = Instant::now();
                rig.vm.push(MEASURED_SURFACE, Some(MARKER));
                link.resume();
                wireguard::resume_session(&session_id);
                // The app's probe right after resume: it ends the host's park, as the ios-mac
                // rig does. Without it the host stays parked and no record comes (every sleep
                // cell failed "no fresh record within 90 s").
                let probe = link.probe(Duration::from_millis(1500)).await;
                eprintln!("pairmatrix: sleep probe after resume: {probe:?}");
                (bytes, end)
            }
            "failover" => {
                let bytes = wire_bytes();
                rig.relay_a_process.kill();
                let end = Instant::now();
                rig.vm.push(MEASURED_SURFACE, Some(MARKER));
                // The channel ends with the carrier's circuit; the phone reconnects.
                let deadline = end + BOUND;
                loop {
                    match acp.pump(&mut seen, deadline).await {
                        Ok(Some(_)) => continue,
                        Ok(None) => return Err("relay A died but the channel stayed open 90 s".into()),
                        Err(_) => break,
                    }
                }
                acp = reconnect(&link, &mut seen, deadline).await?;
                (bytes, end)
            }
            _ => {
                // long: hold, reading the stream, reconnecting if the channel drops.
                let hold = Duration::from_secs(long_minutes * 60);
                let bytes = wire_bytes();
                let held = Instant::now();
                let mut drops = 0;
                while held.elapsed() < hold {
                    let deadline = (held + hold).min(Instant::now() + Duration::from_secs(5));
                    if acp.pump(&mut seen, deadline).await.is_err() {
                        drops += 1;
                        acp = reconnect(&link, &mut seen, Instant::now() + BOUND).await?;
                    }
                }
                per_minute = Some((wire_bytes() - bytes) as f64 / long_minutes as f64);
                if drops > 0 {
                    return Err(format!("the held session dropped {drops} times"));
                }
                // The blip at the end: 5 s dark on the same socket.
                let bytes = wire_bytes();
                wireguard::simulate_blackout(Some(session_id.as_str()), true, true);
                tokio::time::sleep(Duration::from_secs(5)).await;
                wireguard::simulate_blackout(Some(session_id.as_str()), true, false);
                let end = Instant::now();
                rig.vm.push(MEASURED_SURFACE, Some(MARKER));
                (bytes, end)
            }
        };
        let at = acp.until_marker(&mut seen, MARKER, end + BOUND).await?;
        let delta = per_minute.unwrap_or((wire_bytes() - bytes_at_change) as f64);
        Ok::<_, String>((ms(at.duration_since(end)), delta))
    }
    .await;
    link.close("pair matrix done");
    match changed {
        Ok((resume, delta)) => {
            let fail = seen.exactly_once().err();
            Outcome { ttfc: Ok(ttfc), resume: Ok(resume), bytes: Ok(delta), fail }
        }
        Err(error) => Outcome {
            ttfc: Ok(ttfc),
            resume: Err(error.clone()),
            bytes: Err(error.clone()),
            fail: Some(error),
        },
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "measurement: cargo test --release -p cmux-mobile-host --test pair_matrix_ios_linux -- --ignored --nocapture --test-threads 1"]
async fn pair_matrix_ios_linux() {
    let env = Env::read();
    if env.paths.iter().any(|path| path == "direct") {
        let line = json!({"pair":PAIR,"path":"direct","condition":"*","load":"*","metric":"*",
            "reason":"no phone->Linux route: cmux-mobile-host ships only in the macOS app (cmux-tui-core/src/tool_packs.rs:1-3, IPhoneHostService.swift:21); a phone reaches a Linux machine only through its Mac's cloud-acpmux carrier (cmux-mobile-host/src/services.rs:415, PROTOCOL.md:839)"});
        println!("PAIRCELL-NA {line}");
    }
    if !env.paths.iter().any(|path| path == "relay") {
        return;
    }
    for condition in &env.conditions {
        for load in &env.loads {
            let label = if condition == "long" && env.long_minutes < 60 {
                format!("long-{}m", env.long_minutes)
            } else {
                condition.clone()
            };
            // `long` is one held session per load.
            let runs = if condition == "long" { 1 } else { env.n };
            let mut summary = Vec::new();
            for run in 0..runs {
                let seed = env.seed_base + run as u64;
                let outcome = run_once(condition, load, seed, env.long_minutes).await;
                cell(&label, load, "ttfc_ms", &outcome.ttfc, run, seed);
                cell(&label, load, "resume_ms", &outcome.resume, run, seed);
                cell(&label, load, "delta_bytes", &outcome.bytes, run, seed);
                let fail = outcome.fail.clone().map_or(Ok(0.0), Err);
                let mut line = json!({"pair":PAIR,"path":"relay","condition":label,"load":load,"metric":"fail",
                    "value":if fail.is_ok() { 0 } else { 1 },"run":run,"seed":seed,
                    "host_os":std::env::consts::OS,"rig":RIG});
                if let Some(error) = &outcome.fail {
                    line["error"] = json!(error);
                }
                println!("PAIRCELL {line}");
                summary.push(outcome);
            }
            let p50 = |values: Vec<f64>| {
                let mut values = values;
                values.sort_by(f64::total_cmp);
                values.get(values.len() / 2).copied()
            };
            let ttfc = p50(summary.iter().filter_map(|o| o.ttfc.as_ref().ok().copied()).collect());
            let resume = p50(summary.iter().filter_map(|o| o.resume.as_ref().ok().copied()).collect());
            let bytes = p50(summary.iter().filter_map(|o| o.bytes.as_ref().ok().copied()).collect());
            let fails = summary.iter().filter(|o| o.fail.is_some()).count();
            println!(
                "PAIRSUM {}",
                json!({"pair":PAIR,"path":"relay","condition":label,"load":load,"ttfc_ms_p50":ttfc,
                    "resume_ms_p50":resume,"delta_bytes_p50":bytes,"fail":format!("{fails}/{}", summary.len())})
            );
        }
    }
}
