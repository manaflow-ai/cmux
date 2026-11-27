//! Transport pair matrix, row `ios-mac` (both paths): the real phone `Link` (`Role::Phone`,
//! dialed with `dial::connect` over cmux-wg) to the real `cmux-mobile-host` services (`serve`
//! on every channel the Mac's answered link accepts), whose `acpmux` service splices each chat
//! request to an acpmux WebSocket.
//!
//! What is real and what stands in:
//!
//! - real: the phone's `Link` and WireGuard dialer (cmux-mobile-link), the Mac's answer and
//!   `Link`, the host's `acpmux` splice (exposure policy, session canonicalization over a side
//!   connection, deflate envelopes on the link hop, two independent halves), the park
//!   (`_link.park`, link.rs `PARK_SERVICE`), the roam (`wireguard::roam_session`,
//!   `resume_session`), TURN (`testing::TestTurn`, webrtc-rs's TURN server on loopback).
//! - stand-ins: signaling (`testing::FakeSignaling`), and acpmux itself: [`FakeAcpmux`], a
//!   WebSocket that answers `initialize`, `_acpmux/watch`, `_acpmux/info` and
//!   `_acpmux/attach` (newest page under `limit`/`maxBytes`, or every record after
//!   `afterSeq`) and streams `_acpmux/event` notifications, in the shapes cmux-tui
//!   `acpmux/tests/mobile_link_conditions.rs` reads from the real `Hub`. The real `Hub` is
//!   in the cmux-tui workspace (its `workspace = true` dependencies and a Python stand-in
//!   agent); this crate's own tests use a fake acpmux WebSocket too
//!   (`reliability_matrix.rs::fake_acpmux`).
//! - the network: every datagram either tunnel receives goes through one hook
//!   ([`pair_impair`], `DialOptions::impair_inbound`): it counts the bytes, drops everything
//!   during a blackout, drops the direct path when it is cut, and otherwise plays a named
//!   cmux-fault profile with `testing::shape_by_profile` (the per-datagram model of
//!   `cmux_fault::shaper::UdpShaper`: rate, delay, jitter, loss, tail drop). Not
//!   `UdpShaper` itself: WireGuard's peers learn each other's addresses from signaling and
//!   probe them directly, so there is no one address a UDP relay could stand in for
//!   (cmux-mobile-link `testing/shaped.rs`).
//!
//! Paths: `direct` = cmux-wg plain UDP on loopback; `relay` = the phone `relay_only` through
//! a `TestTurn` (the service listing two relays, A and B).
//!
//! Conditions (DESIGN.md of the pair matrix): `loss` (`lossy-3` the whole cell), `latency`
//! (`rtt-400`: the `lte` rate, 400 ms RTT, no loss, defined here), `handoff` (`5g-lte-handoff`:
//! the phone's network goes away, a 1-3 s stall drawn from the seed, then it roams onto a new
//! socket, as the app does on a path change), `sleep` (`lte`: the phone parks its link, then
//! 60 s with nothing through either way, then `resume` + `resume_session` + a 1.5 s probe, as
//! the app on foreground), `failover` (`lte`; relay: TURN server A dies and stays dead;
//! direct: the direct path dies and stays dead while a TURN relay is offered), `long` (`lte`,
//! one session held `PAIRMATRIX_LONG_MINUTES` with a steady chat stream, then a 5 s blackout).
//! Opt-in (not in the default list): `bulk-<profile>` (`bulk-lte`, `bulk-lossy-3`, any
//! link-profiles.json row): with the chat open (and streaming, under duress), one file of
//! `PAIRMATRIX_BULK_BYTES` (100 MiB) sent phone -> Mac on the host's `upload` channel the way
//! the app sends it (CmuxMobileTransport `LinkUpload.swift`: `{name, size}` as strings, 192 KiB
//! data frames, then the Mac's one `{path, size}` reply). Metrics: `bulk_ms` (channel open to
//! the reply), `bulk_bytes_per_s` (file bytes over that), `delta_bytes` (datagram bytes both
//! tunnels received during it), `fail` (no reply, a refusal, or a wrong size within
//! `PAIRMATRIX_BULK_BOUND_S`, 1500 s).
//! Whenever the link closes, the bench redials at once and re-attaches with `afterSeq`, as
//! the app does (its Swift timers are not in any number).
//!
//! Metrics per run: `ttfc_ms` (dial start to the chat's attach page on the phone),
//! `resume_ms` (condition end to the first record the fake acpmux wrote after it arriving on
//! the phone; for `loss` and `latency`, which never end, a record written 1 s into the cell),
//! `delta_bytes` (datagram bytes both tunnels received from the change to caught up; `long`:
//! bytes per minute over the hold), `fail` (no content within 90 s, or a record lost or
//! duplicated across the change).
//!
//! `cargo test --release -p cmux-mobile-host --test pair_matrix_ios_mac -- --ignored --nocapture --test-threads 1`
//! with the `PAIRMATRIX_*` env (N, SEED_BASE, CONDITIONS, LOADS, PATHS, LONG_MINUTES). Prints
//! `PAIRCELL {json}` lines, `PAIRCELL-NA` for an impossible cell, and `PAIRAUX` diagnostics.

use std::collections::HashMap;
use std::io::Read as _;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use bytes::Bytes;
use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::pairing::LinkAuth;
use cmux_mobile_host::services::{Peer, serve};
use cmux_mobile_link::chat_open::{self, ChatOpenRequests, ChatRpc, open_chat};
use cmux_mobile_link::dial::{self, SessionEvents, wireguard};
use cmux_mobile_link::link::{ChannelReceiver, ChannelSender};
use cmux_mobile_link::testing::{
    FakeOptions, FakeSignaling, LinkProfile, TestTurn, is_test_relay, set_link_profile, shape_by_profile,
};
use cmux_mobile_link::{
    ChannelEvent, Connected, DialOptions, LinkConfig, SignalingClient, Timeline, TransportKind,
};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::sync::{broadcast, mpsc, watch};
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::Message;

const PAIR: &str = "ios-mac";
const RIG: &str =
    "cmux-next-ios/rust/crates/cmux-mobile-host/tests/pair_matrix_ios_mac.rs::pair_matrix_ios_mac";
/// No wait is longer (DESIGN.md: a run that never reached content within 90 s failed).
const BOUND: Duration = Duration::from_secs(90);
/// The sleep condition's silence.
const SLEEP: Duration = Duration::from_secs(60);
/// The long condition's closing blip.
const BLIP: Duration = Duration::from_secs(5);
/// Duress and long: the chat streaming into the measured session, one record this often.
const STREAM_EVERY: Duration = Duration::from_millis(50);
const STREAM_RECORD_BYTES: usize = 400;

// cmux-next-ios AcpmuxHub.swift, as mobile_link_conditions.rs mirrors it.
const PAGE_SIZE: u64 = 400;
const OPEN_BYTES: u64 = 128 * 1024;
const TOOL_OUTPUT_MAX_BYTES: u64 = 64 * 1024;
const WATCH_LIMIT: u64 = 100;

/// `PAIRMATRIX_HOST_OS` (scripts/measure/transport-pair-matrix.sh sets it), else this build's OS.
fn host_os() -> String {
    std::env::var("PAIRMATRIX_HOST_OS")
        .ok()
        .filter(|os| !os.is_empty())
        .unwrap_or_else(|| std::env::consts::OS.to_owned())
}

fn ms(duration: Duration) -> f64 {
    (duration.as_secs_f64() * 10_000.0).round() / 10.0
}

// ---------------------------------------------------------------------------------------------
// The network: one hook on every datagram either tunnel receives

/// Datagram bytes either tunnel received (or would have, before a drop).
static WIRE_BYTES: AtomicU64 = AtomicU64::new(0);
/// Nothing through, either way.
static BLACKOUT: AtomicBool = AtomicBool::new(false);
/// Plain UDP between the two tunnels' own sockets is lost; TURN still works.
static DIRECT_DEAD: AtomicBool = AtomicBool::new(false);

fn pair_impair(via_turn: bool, from: &SocketAddr, len: usize) -> Option<Duration> {
    WIRE_BYTES.fetch_add(len as u64, Ordering::Relaxed);
    if BLACKOUT.load(Ordering::Relaxed) {
        return None;
    }
    // The phone hears the Mac through its allocation (`via_turn`); the Mac hears the phone
    // from the phone's relayed address. Anything else is the direct path.
    if DIRECT_DEAD.load(Ordering::Relaxed) && !via_turn && !is_test_relay(from) {
        return None;
    }
    shape_by_profile(via_turn, from, len)
}

fn reset_network() {
    BLACKOUT.store(false, Ordering::Relaxed);
    DIRECT_DEAD.store(false, Ordering::Relaxed);
    set_link_profile(None, 0);
}

fn profile_for(condition: &str) -> LinkProfile {
    if let Some(profile) = condition.strip_prefix("bulk-") {
        return LinkProfile::named(profile);
    }
    match condition {
        "loss" => LinkProfile::named("lossy-3"),
        "latency" => LinkProfile {
            name: "rtt-400".into(),
            up_kbit: 12_000,
            down_kbit: 12_000,
            rtt_ms: 400,
            jitter_ms: 0,
            loss_percent: 0.0,
        },
        "handoff" => LinkProfile::named("5g-lte-handoff"),
        _ => LinkProfile::named("lte"),
    }
}

/// SplitMix64, as cmux-fault's `Rng`.
fn splitmix(seed: u64) -> u64 {
    let mut z = seed.wrapping_add(0x9E37_79B9_7F4A_7C15);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

/// `5g-lte-handoff`'s `stall_ms: [1000, 3000]`, drawn from the seed.
fn handoff_stall(seed: u64) -> Duration {
    Duration::from_millis(1000 + splitmix(seed) % 2001)
}

// ---------------------------------------------------------------------------------------------
// Fake acpmux: sessions of records, attach with afterSeq, an event stream

struct ChatSession {
    id: String,
    title: String,
    /// Serialized records; record `i` has seq `i + 1`.
    records: Vec<Arc<str>>,
}

struct Store {
    sessions: Vec<ChatSession>,
}

struct FakeAcpmux {
    url: String,
    store: Arc<Mutex<Store>>,
    appended: broadcast::Sender<usize>,
    task: tokio::task::JoinHandle<()>,
}

fn record_text(seq: u64, role: &str, kind: &str, text: &str) -> String {
    json!({"seq": seq, "kind": "transcript", "type": kind, "role": role, "text": text}).to_string()
}

/// An answer of about `bytes` (the stand-in agent's prose).
fn prose(turn: u64, bytes: usize) -> String {
    let mut text = format!("Turn {turn}: ");
    while text.len() < bytes {
        text.push_str("The tests pass and the change is ready for review. ");
    }
    text.truncate(bytes);
    text
}

impl FakeAcpmux {
    /// `sessions` chats of `turns` turns each (a ~200 B prompt and a ~1 KB answer); session 0
    /// has `measured_turns` instead.
    async fn start(sessions: usize, turns: u64, measured_turns: u64) -> Self {
        let mut chats = Vec::with_capacity(sessions);
        for index in 0..sessions {
            let count = if index == 0 { measured_turns } else { turns };
            let mut records: Vec<Arc<str>> = Vec::with_capacity(count as usize * 2);
            for turn in 0..count {
                let seq = records.len() as u64 + 1;
                records.push(record_text(seq, "user", "user_message", &prose(turn, 200)).into());
                records.push(record_text(seq + 1, "assistant", "agent_message", &prose(turn, 1000)).into());
            }
            chats.push(ChatSession { id: format!("chat-{index}"), title: format!("Chat {index}"), records });
        }
        let store = Arc::new(Mutex::new(Store { sessions: chats }));
        let (appended, _) = broadcast::channel(4096);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("bind fake acpmux");
        let url = format!("ws://{}/", listener.local_addr().expect("addr"));
        let task = {
            let (store, appended) = (Arc::clone(&store), appended.clone());
            tokio::spawn(async move {
                loop {
                    let Ok((stream, _)) = listener.accept().await else { return };
                    tokio::spawn(acpmux_connection(stream, Arc::clone(&store), appended.clone()));
                }
            })
        };
        Self { url, store, appended, task }
    }

    fn session_id(&self, index: usize) -> String {
        self.store.lock().expect("store").sessions[index].id.clone()
    }

    /// Appends a record to session `index`; its seq.
    fn append(&self, index: usize, role: &str, kind: &str, text: &str) -> u64 {
        let seq = {
            let mut store = self.store.lock().expect("store");
            let records = &mut store.sessions[index].records;
            let seq = records.len() as u64 + 1;
            records.push(record_text(seq, role, kind, text).into());
            seq
        };
        let _ = self.appended.send(index);
        seq
    }
}

impl Drop for FakeAcpmux {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn reply(id: &Value, result: &str) -> String {
    format!(r#"{{"jsonrpc":"2.0","id":{id},"result":{result}}}"#)
}

async fn acpmux_connection(
    stream: tokio::net::TcpStream,
    store: Arc<Mutex<Store>>,
    appended: broadcast::Sender<usize>,
) {
    let Ok(socket) = tokio_tungstenite::accept_async(stream).await else { return };
    let (mut sink, mut source) = socket.split();
    let (out, mut queue) = mpsc::channel::<String>(256);
    let writer = tokio::spawn(async move {
        while let Some(text) = queue.recv().await {
            if sink.send(Message::Text(text.into())).await.is_err() {
                return;
            }
        }
    });
    let mut streams = tokio::task::JoinSet::new();
    while let Some(Ok(frame)) = source.next().await {
        let Message::Text(text) = frame else { continue };
        let Ok(request) = serde_json::from_str::<Value>(&text) else { continue };
        let id = request["id"].clone();
        let params = &request["params"];
        let answer = match request["method"].as_str() {
            Some("initialize") => reply(
                &id,
                &json!({"protocolVersion": 1, "agentCapabilities": {},
                        "_meta": {"acpmux": {"capabilities": []}}})
                .to_string(),
            ),
            Some("_acpmux/watch") => {
                let limit = params["limit"].as_u64().unwrap_or(WATCH_LIMIT) as usize;
                let sessions: Vec<Value> = {
                    let store = store.lock().expect("store");
                    store
                        .sessions
                        .iter()
                        .take(limit)
                        .map(|session| {
                            // About 2.7 KB a chat, as link_deflate.rs measured the Mac's list.
                            json!({"sessionId": session.id, "name": session.title, "harness": "claude",
                                   "cwd": "/Users/me/work/project", "status": "idle",
                                   "lastSeq": session.records.len(), "preview": prose(0, 2500)})
                        })
                        .collect()
                };
                reply(&id, &json!({"sessions": sessions}).to_string())
            }
            Some("_acpmux/info") => {
                reply(&id, &json!({"sessionId": params["sessionId"], "currentModeId": "default"}).to_string())
            }
            Some("_acpmux/attach") => {
                let session = params["sessionId"].as_str().unwrap_or_default().to_owned();
                // Subscribe before the page is cut, so no record falls between them.
                let mut rx = appended.subscribe();
                let page = {
                    let store = store.lock().expect("store");
                    store.sessions.iter().position(|s| s.id == session).map(|index| {
                        let records = &store.sessions[index].records;
                        let first = match params["afterSeq"].as_u64() {
                            Some(after) => (after as usize).min(records.len()),
                            None => {
                                let limit = params["limit"].as_u64().unwrap_or(PAGE_SIZE) as usize;
                                let max_bytes = params["maxBytes"].as_u64().unwrap_or(u64::MAX) as usize;
                                let mut first = records.len();
                                let mut bytes = 0usize;
                                while first > 0 && records.len() - first < limit {
                                    let next = records[first - 1].len();
                                    if bytes + next > max_bytes && first < records.len() {
                                        break;
                                    }
                                    bytes += next;
                                    first -= 1;
                                }
                                first
                            }
                        };
                        (index, records[first..].to_vec(), records.len() as u64)
                    })
                };
                match page {
                    None => format!(
                        r#"{{"jsonrpc":"2.0","id":{id},"error":{{"code":-32602,"message":"no session"}}}}"#
                    ),
                    Some((index, page, last)) => {
                        let events = page.iter().map(|r| &**r).collect::<Vec<&str>>().join(",");
                        let answer = reply(
                            &id,
                            &format!(r#"{{"sessionId":"{session}","lastSeq":{last},"events":[{events}]}}"#),
                        );
                        if out.send(answer).await.is_err() {
                            break;
                        }
                        if params["eventStream"].as_bool() == Some(true) {
                            let (store, out) = (Arc::clone(&store), out.clone());
                            streams.spawn(async move {
                                let mut sent = last as usize;
                                loop {
                                    match rx.recv().await {
                                        Ok(changed) if changed != index => continue,
                                        Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                                        Err(broadcast::error::RecvError::Closed) => return,
                                    }
                                    let batch: Vec<Arc<str>> =
                                        store.lock().expect("store").sessions[index].records[sent..].to_vec();
                                    for record in batch {
                                        sent += 1;
                                        let event = format!(
                                            r#"{{"jsonrpc":"2.0","method":"_acpmux/event","params":{{"sessionId":"{session}","seq":{sent},"event":{record}}}}}"#
                                        );
                                        if out.send(event).await.is_err() {
                                            return;
                                        }
                                    }
                                }
                            });
                        }
                        continue;
                    }
                }
            }
            _ => reply(&id, "{}"),
        };
        if out.send(answer).await.is_err() {
            break;
        }
    }
    streams.shutdown().await;
    writer.abort();
}

// ---------------------------------------------------------------------------------------------
// The phone's chat: the acpmux channel, as AcpmuxHub.swift opens it

/// Every record of the measured session the phone saw, across reconnects.
#[derive(Default)]
struct SeenState {
    last: Option<u64>,
    duplicates: u64,
    gaps: u64,
}

struct Seen {
    state: Mutex<SeenState>,
    /// (last seq, when it arrived).
    latest: watch::Sender<(u64, Instant)>,
}

impl Seen {
    fn new() -> Arc<Self> {
        Arc::new(Self { state: Mutex::default(), latest: watch::channel((0, Instant::now())).0 })
    }

    fn record(&self, seq: u64) {
        let mut state = self.state.lock().expect("seen");
        match state.last {
            Some(last) if seq <= last => state.duplicates += 1,
            Some(last) => {
                if seq > last + 1 {
                    state.gaps += 1;
                }
                state.last = Some(seq);
            }
            None => state.last = Some(seq),
        }
        let last = state.last.unwrap_or(0);
        drop(state);
        self.latest.send_replace((last, Instant::now()));
    }

    fn last(&self) -> Option<u64> {
        self.state.lock().expect("seen").last
    }

    fn faults(&self) -> (u64, u64) {
        let state = self.state.lock().expect("seen");
        (state.duplicates, state.gaps)
    }
}

/// The next whole acpmux message in `buffer`: a JSON text or a deflate envelope
/// (cmux-mobile-host `link_deflate.rs`: 0x00, text length u32 BE, deflate length u32 BE).
fn next_message(buffer: &mut Vec<u8>) -> Option<Value> {
    let start = buffer.iter().position(|b| !b.is_ascii_whitespace())?;
    buffer.drain(..start);
    if buffer[0] == 0x00 {
        if buffer.len() < 9 {
            return None;
        }
        let text_len = u32::from_be_bytes(buffer[1..5].try_into().ok()?) as usize;
        let deflated = u32::from_be_bytes(buffer[5..9].try_into().ok()?) as usize;
        if buffer.len() < 9 + deflated {
            return None;
        }
        let mut text = Vec::with_capacity(text_len);
        let inflated = flate2::read::DeflateDecoder::new(&buffer[9..9 + deflated]).read_to_end(&mut text);
        buffer.drain(..9 + deflated);
        return Some(match inflated {
            Ok(_) => serde_json::from_slice(&text).unwrap_or(Value::Null),
            Err(_) => Value::Null,
        });
    }
    let (value, used) = {
        let mut stream = serde_json::Deserializer::from_slice(buffer.as_slice()).into_iter::<Value>();
        match stream.next() {
            Some(Ok(value)) => (value, stream.byte_offset()),
            _ => return None,
        }
    };
    buffer.drain(..used);
    Some(value)
}

async fn read_chat(
    mut receiver: ChannelReceiver,
    replies: mpsc::UnboundedSender<(Instant, Value)>,
    seen: Arc<Seen>,
    session: String,
) {
    let mut buffer = Vec::new();
    while let Some(ChannelEvent::Data(bytes)) = receiver.recv().await {
        buffer.extend_from_slice(&bytes);
        while let Some(message) = next_message(&mut buffer) {
            let at = Instant::now();
            match message["method"].as_str() {
                Some("_acpmux/event") => {
                    if message["params"]["sessionId"] == session.as_str()
                        && let Some(seq) = message["params"]["seq"].as_u64()
                    {
                        seen.record(seq);
                    }
                }
                Some(_) => {}
                None => {
                    if message["result"]["sessionId"] == session.as_str()
                        && let Some(events) = message["result"]["events"].as_array()
                    {
                        for seq in events.iter().filter_map(|event| event["seq"].as_u64()) {
                            seen.record(seq);
                        }
                    }
                    let _ = replies.send((at, message));
                }
            }
        }
    }
}

struct Chat {
    sender: ChannelSender,
    replies: mpsc::UnboundedReceiver<(Instant, Value)>,
    reader: tokio::task::JoinHandle<()>,
}

impl Drop for Chat {
    fn drop(&mut self) {
        self.reader.abort();
    }
}

impl Chat {
    async fn post(&self, id: &str, method: &str, params: Value) -> Result<(), String> {
        let request = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.sender.send(Bytes::from(request.to_string())).await.map_err(|e| format!("send {method}: {e:?}"))
    }

    /// Opens the chat on `connected`'s link (`cmux_mobile_link::chat_open`): `initialize` and
    /// `_acpmux/watch` pipelined, then the attach, or all three at once with the flag on
    /// (`after`: a re-attach). The attach reply's arrival.
    async fn open(
        connected: &Connected,
        session: &str,
        after: Option<u64>,
        seen: &Arc<Seen>,
        deadline: Instant,
        timeline: Option<&Timeline>,
    ) -> Result<(Self, Instant), String> {
        let mark = |name: &str| {
            if let Some(timeline) = timeline {
                timeline.mark(name);
            }
        };
        let channel = tokio::time::timeout_at(
            deadline,
            connected.link.open("acpmux", json!({"compression": "deflate"})),
        )
        .await
        .map_err(|_| "acpmux channel open timed out".to_owned())?
        .map_err(|e| format!("acpmux channel: {e:?}"))?;
        mark("chat_channel_open");
        let (sender, receiver) = channel.split();
        let (replies_tx, replies) = mpsc::unbounded_channel();
        let reader = tokio::spawn(read_chat(receiver, replies_tx, Arc::clone(seen), session.to_owned()));
        let chat = Self { sender, replies, reader };
        let mut params = json!({"sessionId": session, "limit": PAGE_SIZE, "kinds": ["transcript"],
                                "eventStream": true});
        match after {
            None => {
                params["maxBytes"] = json!(OPEN_BYTES);
                params["toolOutputMaxBytes"] = json!(TOOL_OUTPUT_MAX_BYTES);
            }
            Some(after) => params["afterSeq"] = json!(after),
        }
        // `initialize` and the watch, then the attach once both are answered (the app), or
        // all three in one flight with `CMUX_PIPELINED_CHAT_OPEN=1` (cmux_mobile_link::chat_open).
        let requests = ChatOpenRequests {
            initialize: json!({"protocolVersion": 1, "clientInfo": {"name": "cmux-ios", "version": "1"},
                               "clientCapabilities": {}, "_meta": {"acpmux": {"chunkDeltas": true}}}),
            watch: json!({"enabled": true, "limit": WATCH_LIMIT}),
            attach: params,
        };
        let mut rpc =
            ChatRpcOver { chat, deadline, stash: HashMap::new(), arrived: HashMap::new(), timeline };
        let opened = open_chat(&mut rpc, &requests, chat_open::pipelined_from_env()).await?;
        let at = rpc.arrived.get(opened.attach_id).copied().unwrap_or_else(Instant::now);
        let ChatRpcOver { chat, .. } = rpc;
        let reply = opened.attach;
        let rows = reply["result"]["events"].as_array().map(Vec::len).unwrap_or_default();
        if after.is_none() && rows == 0 {
            return Err("attach page had no rows".into());
        }
        Ok((chat, at))
    }
}

/// [`ChatRpc`] over a [`Chat`]: replies kept by id whatever order they come in, each one's
/// arrival kept, and the open's legs marked (`chat_init_answered`, `chat_watch_answered`,
/// `chat_attach_answered`, by the first reply of each request).
struct ChatRpcOver<'t> {
    chat: Chat,
    deadline: Instant,
    stash: HashMap<String, (Instant, Value)>,
    arrived: HashMap<String, Instant>,
    timeline: Option<&'t Timeline>,
}

impl ChatRpc for ChatRpcOver<'_> {
    async fn post(&mut self, id: &str, method: &str, params: Value) -> Result<(), String> {
        self.chat.post(id, method, params).await
    }

    async fn answer(&mut self, id: &str) -> Result<Value, String> {
        let (at, reply) = match self.stash.remove(id) {
            Some(kept) => kept,
            None => loop {
                match tokio::time::timeout_at(self.deadline, self.chat.replies.recv()).await {
                    Err(_) => return Err(format!("no reply to {id} in time")),
                    Ok(None) => return Err(format!("channel closed before the reply to {id}")),
                    Ok(Some((at, reply))) if reply["id"] == id => break (at, reply),
                    Ok(Some((at, reply))) => {
                        if let Some(other) = reply["id"].as_str() {
                            self.stash.insert(other.to_owned(), (at, reply));
                        }
                    }
                }
            },
        };
        self.arrived.insert(id.to_owned(), at);
        if let Some(timeline) = self.timeline {
            let leg = id.split('.').next().unwrap_or(id);
            timeline.mark(&format!("chat_{leg}_answered"));
        }
        Ok(reply)
    }
}

// ---------------------------------------------------------------------------------------------
// Rig: phone signaling client, Mac answering with the host's services, fake acpmux

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Path {
    Direct,
    Relay,
}

impl Path {
    fn name(self) -> &'static str {
        match self {
            Path::Direct => "direct",
            Path::Relay => "relay",
        }
    }
}

struct Rig {
    _dir: tempfile::TempDir,
    _signaling: FakeSignaling,
    acpmux: FakeAcpmux,
    mac: tokio::task::JoinHandle<()>,
    phone: SignalingClient,
    mac_id: String,
    options: DialOptions,
    /// Relay A (the one the dial uses: `dial::turn::turn_servers` takes the first UDP server)
    /// and relay B.
    turns: Vec<Option<TestTurn>>,
}

impl Drop for Rig {
    fn drop(&mut self) {
        self.mac.abort();
    }
}

fn base_options() -> DialOptions {
    DialOptions {
        include_loopback: true,
        impair_inbound: Some(pair_impair),
        // A lost handshake message costs WireGuard a 5 s retry: room for a few.
        timeout: Duration::from_secs(40),
        ..DialOptions::default()
    }
}

impl Rig {
    /// `turns`: TURN servers to offer (relay: 2; direct with failover: 1).
    async fn start(path: Path, turns: usize, acpmux: FakeAcpmux) -> Self {
        let dir = tempfile::tempdir().expect("tempdir");
        let mut servers = Vec::new();
        for _ in 0..turns {
            servers.push(Some(TestTurn::start().await));
        }
        let ice: Vec<_> = servers.iter().flatten().map(TestTurn::udp_only).collect();
        let options =
            DialOptions { relay_only: path == Path::Relay, ice_servers: ice.clone(), ..base_options() };
        let mac_options = DialOptions { ice_servers: ice, ..base_options() };
        let config = Arc::new(ServiceConfig {
            tui_socket_dir: dir.path().to_owned(),
            default_session: "main".into(),
            default_socket: None,
            file_roots: vec![],
            acpmux: AcpmuxTarget::Fixed { url: acpmux.url.clone(), token: None },
            pairing: None,
            agent_tab_host: None,
            uploads_dir: dir.path().join("uploads"),
            chief_socket: None,
            browser: cmux_mobile_host::browser::BrowserConfig::new(None, 1),
            surface: cmux_mobile_host::surface::SurfaceConfig::new(None, 1),
            viewport_sync: None,
        });
        let signaling = FakeSignaling::start(FakeOptions::default()).await;
        let mac_id = uuid::Uuid::new_v4().to_string();
        let mac_client = SignalingClient::connect(&signaling.base_url, "user:alice", "team", &mac_id)
            .await
            .expect("mac signaling");
        let mac = tokio::spawn(async move {
            let mut links = tokio::task::JoinSet::new();
            while let Some(session) = mac_client.next_session().await {
                let events = SessionEvents {
                    backend: mac_client.events(),
                    session_id: session.first.session_id.clone(),
                    session: session.events,
                };
                let (mac_client, options, config) =
                    (mac_client.clone(), mac_options.clone(), Arc::clone(&config));
                links.spawn(async move {
                    let Ok(connected) =
                        dial::answer(&mac_client, session.first, events, &options, LinkConfig::default())
                            .await
                    else {
                        return;
                    };
                    let mut services = tokio::task::JoinSet::new();
                    while let Some(incoming) = connected.link.accept().await {
                        services.spawn(serve(
                            Arc::clone(&config),
                            Peer {
                                device_id: "pair-matrix-phone".into(),
                                session_id: connected.session_id.clone(),
                                video: None,
                                session_exposure: None,
                                route: None,
                                path: Some(connected.path.clone()),
                                viewport: None,
                            },
                            Arc::new(LinkAuth::default()),
                            incoming,
                        ));
                    }
                    services.shutdown().await;
                });
            }
            links.shutdown().await;
        });
        let phone_id = uuid::Uuid::new_v4().to_string();
        let phone = SignalingClient::connect(&signaling.base_url, "user:alice", "team", &phone_id)
            .await
            .expect("phone signaling");
        Self { _dir: dir, _signaling: signaling, acpmux, mac, phone, mac_id, options, turns: servers }
    }

    async fn dial(&self, deadline: Instant) -> Result<Connected, String> {
        self.dial_timed(deadline, None).await
    }

    /// [`Rig::dial`] marking the dialer's legs on `timeline` (`PAIRLEGS`).
    async fn dial_timed(&self, deadline: Instant, timeline: Option<&Timeline>) -> Result<Connected, String> {
        let options = match timeline {
            Some(timeline) => DialOptions { timeline: timeline.clone(), ..self.options.clone() },
            None => self.options.clone(),
        };
        let dial = dial::connect(
            &self.phone,
            &self.mac_id,
            TransportKind::WireGuard,
            &options,
            LinkConfig::default(),
        );
        match tokio::time::timeout_at(deadline, dial).await {
            Err(_) => Err("dial timed out".into()),
            Ok(Err(error)) => Err(format!("dial: {error:?}")),
            Ok(Ok(connected)) => Ok(connected),
        }
    }
}

/// The phone app's view: a link, the chat on it, and what it does when the link closes.
struct Phone {
    connected: Connected,
    chat: Chat,
    session: String,
    seen: Arc<Seen>,
    redials: u32,
    redial_errors: Vec<String>,
}

impl Phone {
    /// The first dial and attach, each leg marked on `timeline` (the dialer's marks, then
    /// the chat's: `chat_channel_open`, `chat_init_answered`, `chat_watch_answered`,
    /// `chat_attach_answered`).
    async fn open(
        rig: &Rig,
        session: &str,
        deadline: Instant,
        timeline: &Timeline,
    ) -> Result<(Self, Instant), String> {
        let seen = Seen::new();
        let connected = rig.dial_timed(deadline, Some(timeline)).await?;
        let (chat, at) = Chat::open(&connected, session, None, &seen, deadline, Some(timeline)).await?;
        Ok((
            Self {
                connected,
                chat,
                session: session.to_owned(),
                seen,
                redials: 0,
                redial_errors: Vec::new(),
            },
            at,
        ))
    }

    /// The app on a closed link: a new dial at once, the chat re-attached after the last seq.
    async fn redial(&mut self, rig: &Rig, deadline: Instant) -> Result<(), String> {
        self.redials += 1;
        let connected = rig.dial(deadline).await?;
        let after = self.seen.last();
        let (chat, _) = Chat::open(&connected, &self.session, after, &self.seen, deadline, None).await?;
        self.connected.link.close("redialed");
        self.connected = connected;
        self.chat = chat;
        Ok(())
    }

    /// Until the phone has record `target` (its arrival), or the deadline; redials whenever the
    /// link closes. `None` target: just keep the session up until the deadline.
    async fn drive(&mut self, rig: &Rig, target: Option<u64>, deadline: Instant) -> Option<Instant> {
        let mut latest = self.seen.latest.subscribe();
        loop {
            let mut closed = self.connected.link.closed_state();
            tokio::select! {
                reached = latest.wait_for(|(last, _)| target.is_some_and(|t| *last >= t)) => {
                    return reached.ok().map(|seen| seen.1);
                }
                closed_now = closed.wait_for(Option::is_some) => {
                    // The guard of the old link's watch must go before the redial closes it.
                    drop(closed_now);
                    if let Err(error) = self.redial(rig, deadline).await {
                        self.redial_errors.push(error);
                        if Instant::now() >= deadline {
                            return None;
                        }
                        // Not up again: the next attempt after a beat, as the app's backoff.
                        tokio::time::sleep(Duration::from_millis(250)).await;
                    }
                }
                _ = tokio::time::sleep_until(deadline) => return None,
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// One run

struct Cell<'a> {
    path: Path,
    condition: &'a str,
    label: String,
    load: &'a str,
    profile: String,
    run: u64,
    seed: u64,
}

impl Cell<'_> {
    fn emit(&self, metric: &str, value: Option<f64>, error: Option<&str>) {
        let mut line = json!({"pair": PAIR, "path": self.path.name(), "condition": self.label, "load": self.load,
                              "metric": metric, "value": value, "run": self.run, "seed": self.seed,
                              "host_os": host_os(), "rig": RIG, "profile": self.profile});
        if let Some(error) = error {
            line["error"] = json!(error);
        }
        println!("PAIRCELL {line}");
    }

    /// `PAIRLEGS {json}`: every mark of the first dial and attach, ms from the dial start.
    fn legs(&self, timeline: &Timeline) {
        let marks: serde_json::Map<String, Value> =
            timeline.marks().into_iter().map(|(name, at)| (name, json!(ms(at)))).collect();
        let line = json!({"pair": PAIR, "path": self.path.name(), "condition": self.label, "load": self.load,
                          "run": self.run, "seed": self.seed, "marks": marks});
        println!("PAIRLEGS {line}");
    }

    fn aux(&self, fields: Value) {
        let mut line = json!({"pair": PAIR, "path": self.path.name(), "condition": self.label, "load": self.load,
                              "run": self.run, "seed": self.seed});
        if let (Some(line), Some(fields)) = (line.as_object_mut(), fields.as_object()) {
            line.extend(fields.clone());
        }
        println!("PAIRAUX {line}");
    }
}

/// The fixture: idle = 5 chats of 20 turns; duress = 50 chats, the measured one at 250x
/// (5,000 turns, 10,000 messages), the others 20 turns.
async fn fixture(load: &str) -> FakeAcpmux {
    match load {
        "duress" => FakeAcpmux::start(50, 20, 5_000).await,
        _ => FakeAcpmux::start(5, 20, 20).await,
    }
}

/// The chat streaming into the measured session.
fn stream_into(acpmux: &FakeAcpmux, index: usize) -> tokio::task::JoinHandle<()> {
    let store = Arc::clone(&acpmux.store);
    let appended = acpmux.appended.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(STREAM_EVERY);
        let mut turn = 0u64;
        loop {
            tick.tick().await;
            {
                let mut store = store.lock().expect("store");
                let records = &mut store.sessions[index].records;
                let seq = records.len() as u64 + 1;
                records.push(
                    record_text(seq, "assistant", "agent_message_chunk", &prose(turn, STREAM_RECORD_BYTES))
                        .into(),
                );
            }
            let _ = appended.send(index);
            turn += 1;
        }
    })
}

fn long_minutes() -> u64 {
    std::env::var("PAIRMATRIX_LONG_MINUTES").ok().and_then(|v| v.parse().ok()).unwrap_or(60)
}

/// The app's upload chunk (CmuxMobileTransport `LinkUpload.swift` `chunkBytes`).
const UPLOAD_CHUNK: usize = 192 << 10;

/// One upload of `size` bytes on the link's `upload` channel, as `LinkUpload.send` does it:
/// the Mac's reply, or why there was none.
async fn upload(connected: &Connected, size: u64, run: u64, deadline: Instant) -> Result<Value, String> {
    let args = json!({"name": format!("pair-matrix-bulk-{run}.bin"), "size": size.to_string()});
    let channel = tokio::time::timeout_at(deadline, connected.link.open("upload", args))
        .await
        .map_err(|_| "upload channel open timed out".to_owned())?
        .map_err(|e| format!("upload channel: {e:?}"))?;
    let (sender, mut receiver) = channel.split();
    let began = Instant::now();
    let chunk = Bytes::from(vec![(run % 251) as u8; UPLOAD_CHUNK]);
    let sending = async {
        let mut sent = 0u64;
        while sent < size {
            let len = UPLOAD_CHUNK.min((size - sent) as usize);
            // A failed send is not the answer, the reply is (LinkUpload.swift).
            if let Err(error) = sender.send(chunk.slice(..len)).await {
                return (sent, Some(format!("{error}")));
            }
            sent += len as u64;
        }
        (sent, None)
    };
    let (sent, send_error) = match tokio::time::timeout_at(deadline, sending).await {
        Ok(sent) => sent,
        Err(_) => return Err("upload: not all bytes sent before the bound".into()),
    };
    let mut reply = Vec::new();
    loop {
        match tokio::time::timeout_at(deadline, receiver.recv()).await {
            Err(_) => return Err(format!("upload: no reply before the bound ({sent} of {size} bytes sent)")),
            Ok(Some(ChannelEvent::Data(bytes))) => {
                reply.extend_from_slice(&bytes);
                if let Ok(value) = serde_json::from_slice::<Value>(&reply) {
                    return Ok(value);
                }
            }
            Ok(closed) => {
                // Why it closed, so a failed cell names the cause: the channel's close,
                // the send's error, and the link's own close reason if the link went down.
                let link = connected.link.closed_state().borrow().clone();
                let close = match closed {
                    Some(ChannelEvent::Closed(info)) => format!("{info:?}"),
                    _ => "receiver ended".into(),
                };
                return serde_json::from_slice::<Value>(&reply).map_err(|_| {
                    format!(
                        "upload: channel closed without a reply ({sent} of {size} bytes sent, at {:.1} s; \
                         close {close}; send error {send_error:?}; link closed {link:?})",
                        began.elapsed().as_secs_f64()
                    )
                });
            }
        }
    }
}

/// `bulk-<profile>`: one file phone -> Mac with the chat open (and streaming, under duress).
async fn run_bulk(cell: &Cell<'_>, phone: &Phone, ttfc: f64) {
    let size = env_u64("PAIRMATRIX_BULK_BYTES", 100 << 20);
    let bound = Duration::from_secs(env_u64("PAIRMATRIX_BULK_BOUND_S", 1500));
    let from_bytes = WIRE_BYTES.load(Ordering::Relaxed);
    let began = Instant::now();
    let answer = upload(&phone.connected, size, cell.run, began + bound).await;
    let took = began.elapsed();
    let delta = WIRE_BYTES.load(Ordering::Relaxed) - from_bytes;
    let error = match &answer {
        Err(error) => Some(error.clone()),
        Ok(reply) if reply["size"].as_u64() == Some(size) => None,
        Ok(reply) => Some(format!("upload answered {reply}")),
    };
    if let Ok(reply) = &answer
        && let Some(path) = reply["path"].as_str()
    {
        let _ = std::fs::remove_file(path);
    }
    let ok = error.is_none();
    cell.emit("ttfc_ms", Some(ttfc), None);
    cell.emit("bulk_ms", ok.then(|| ms(took)), error.as_deref());
    cell.emit("bulk_bytes_per_s", ok.then(|| (size as f64 / took.as_secs_f64()).round()), error.as_deref());
    cell.emit("delta_bytes", Some(delta as f64), None);
    cell.emit("fail", Some(if ok { 0.0 } else { 1.0 }), error.as_deref());
    cell.aux(json!({"bytes": size, "elapsed_ms": ms(took), "redials": phone.redials,
                    "path_at_end": format!("{:?}", *phone.connected.path.borrow()),
                    "link_closed": phone.connected.link.is_closed()}));
}

async fn run_cell(cell: &Cell<'_>) {
    reset_network();
    WIRE_BYTES.store(0, Ordering::Relaxed);
    let profile = profile_for(cell.condition);
    set_link_profile(Some(profile), cell.seed);
    let acpmux = fixture(cell.load).await;
    let turns = match (cell.path, cell.condition) {
        (Path::Relay, _) => 2,
        (Path::Direct, "failover") => 1,
        _ => 0,
    };
    let mut rig = Rig::start(cell.path, turns, acpmux).await;
    let session = rig.acpmux.session_id(0);
    let began = Instant::now();
    // The dial's legs from the same start as `ttfc_ms` (`PAIRLEGS`, one line per run).
    let timeline = Timeline::starting_at(began.into_std());
    let opened = Phone::open(&rig, &session, began + BOUND, &timeline).await;
    cell.legs(&timeline);
    let (mut phone, attached) = match opened {
        Ok(opened) => opened,
        Err(error) => {
            for metric in ["ttfc_ms", "resume_ms", "delta_bytes"] {
                cell.emit(metric, None, Some(&error));
            }
            cell.emit("fail", Some(1.0), Some(&error));
            reset_network();
            return;
        }
    };
    let ttfc = ms(attached - began);
    let streaming = (cell.load == "duress" || cell.condition == "long").then(|| stream_into(&rig.acpmux, 0));
    tokio::time::sleep(Duration::from_secs(1)).await;
    if cell.condition.starts_with("bulk-") {
        run_bulk(cell, &phone, ttfc).await;
        if let Some(streaming) = streaming {
            streaming.abort();
        }
        phone.connected.link.close("pair matrix done");
        drop(phone);
        drop(rig);
        reset_network();
        tokio::time::sleep(Duration::from_millis(300)).await;
        return;
    }

    let mut notes = json!({});
    let mut per_minute = None;
    let changed_from = WIRE_BYTES.load(Ordering::Relaxed);
    let change_end = match cell.condition {
        "handoff" => {
            let session_id = phone.connected.session_id.clone();
            let hit = wireguard::simulate_network_loss(Some(session_id.as_str()), true);
            let stall = handoff_stall(cell.seed);
            tokio::time::sleep(stall).await;
            let end = Instant::now();
            tokio::spawn(async move { wireguard::roam_session(&session_id, true).await });
            notes = json!({"stall_ms": ms(stall), "sessions_hit": hit});
            end
        }
        "sleep" => {
            let parked = phone.connected.link.park(Duration::from_secs(600), Duration::from_secs(5)).await;
            BLACKOUT.store(true, Ordering::Relaxed);
            tokio::time::sleep(SLEEP).await;
            BLACKOUT.store(false, Ordering::Relaxed);
            let end = Instant::now();
            let resumed = phone.connected.link.resume();
            wireguard::resume_session(&phone.connected.session_id);
            notes = json!({"parked": format!("{parked:?}"), "resumed": resumed});
            end
        }
        "failover" => {
            match cell.path {
                // Relay A dies and stays dead.
                Path::Relay => drop(rig.turns[0].take()),
                // The direct path dies and stays dead; the offered relay may take over.
                Path::Direct => DIRECT_DEAD.store(true, Ordering::Relaxed),
            }
            Instant::now()
        }
        "long" => {
            let minutes = long_minutes();
            let hold_from = WIRE_BYTES.load(Ordering::Relaxed);
            let held = Instant::now();
            phone.drive(&rig, None, held + Duration::from_secs(minutes * 60)).await;
            let bytes = WIRE_BYTES.load(Ordering::Relaxed) - hold_from;
            per_minute = Some(bytes as f64 / (held.elapsed().as_secs_f64() / 60.0));
            BLACKOUT.store(true, Ordering::Relaxed);
            tokio::time::sleep(BLIP).await;
            BLACKOUT.store(false, Ordering::Relaxed);
            Instant::now()
        }
        // loss, latency: the condition holds for the whole cell.
        _ => Instant::now(),
    };
    let from_bytes = if cell.condition == "long" { WIRE_BYTES.load(Ordering::Relaxed) } else { changed_from };
    let marker = rig.acpmux.append(0, "assistant", "agent_message", "fresh after the change");
    if cell.condition == "sleep" {
        // The app's probe right after resume (it ends the Mac's park).
        let probe = phone.connected.link.probe(Duration::from_millis(1500)).await;
        notes["probe"] = json!(format!("{probe:?}"));
    }
    let arrived = phone.drive(&rig, Some(marker), change_end + BOUND).await;
    let delta = WIRE_BYTES.load(Ordering::Relaxed) - from_bytes;
    let (duplicates, gaps) = phone.seen.faults();
    let resume = arrived.map(|at| ms(at.saturating_duration_since(change_end)));
    let error = match (arrived, duplicates, gaps) {
        (None, ..) => Some(format!("record {marker} never arrived within {}s", BOUND.as_secs())),
        (Some(_), 0, 0) => None,
        (Some(_), d, g) => Some(format!("afterSeq exactly-once broken: {d} duplicates, {g} gaps")),
    };
    cell.emit("ttfc_ms", Some(ttfc), None);
    cell.emit("resume_ms", resume, arrived.is_none().then_some(error.as_deref().unwrap_or("")));
    match per_minute {
        Some(per_minute) => cell.emit("delta_bytes", Some(per_minute.round()), None),
        None => cell.emit(
            "delta_bytes",
            arrived.map(|_| delta as f64),
            arrived.is_none().then_some("never caught up"),
        ),
    }
    cell.emit("fail", Some(if error.is_some() { 1.0 } else { 0.0 }), error.as_deref());
    notes["redials"] = json!(phone.redials);
    notes["redial_errors"] = json!(phone.redial_errors);
    notes["duplicates"] = json!(duplicates);
    notes["gaps"] = json!(gaps);
    notes["path_at_end"] = json!(format!("{:?}", *phone.connected.path.borrow()));
    notes["link_closed"] = json!(phone.connected.link.is_closed());
    if cell.condition == "long" {
        notes["catch_up_bytes"] = json!(delta);
    }
    cell.aux(notes);
    if let Some(streaming) = streaming {
        streaming.abort();
    }
    phone.connected.link.close("pair matrix done");
    drop(phone);
    drop(rig);
    reset_network();
    // Let both tunnels and the TURN servers wind down before the next run.
    tokio::time::sleep(Duration::from_millis(300)).await;
}

fn env_list(name: &str, default: &str) -> Vec<String> {
    std::env::var(name)
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| default.to_owned())
        .split(',')
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .collect()
}

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// The whole row (or the `PAIRMATRIX_*` slice of it).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "transport pair matrix bench: timed, run alone in release with --ignored"]
async fn pair_matrix_ios_mac() {
    let runs = env_u64("PAIRMATRIX_N", 5);
    let seed_base = env_u64("PAIRMATRIX_SEED_BASE", 0);
    let conditions = env_list("PAIRMATRIX_CONDITIONS", "loss,latency,handoff,sleep,failover,long");
    let loads = env_list("PAIRMATRIX_LOADS", "idle,duress");
    let paths = env_list("PAIRMATRIX_PATHS", "direct,relay");
    // libtest's `test pair_matrix_ios_mac ... ` has no newline under --nocapture: end it, so the
    // first PAIRCELL line starts a line (`^PAIRCELL` readers dropped it otherwise).
    println!();
    for condition in &conditions {
        for load in &loads {
            for path in &paths {
                let path = match path.as_str() {
                    "direct" => Path::Direct,
                    "relay" => Path::Relay,
                    other => panic!("unknown path {other}"),
                };
                let (label, n) = if condition == "long" {
                    let minutes = long_minutes();
                    let label = if minutes >= 60 { "long".to_owned() } else { format!("long-{minutes}m") };
                    // One session held for the hour is the cell; PAIRMATRIX_LONG_N for more.
                    (label, env_u64("PAIRMATRIX_LONG_N", 1))
                } else {
                    (condition.clone(), runs)
                };
                for run in 0..n {
                    let cell = Cell {
                        path,
                        condition,
                        label: label.clone(),
                        load,
                        profile: profile_for(condition).name,
                        run,
                        seed: seed_base + run,
                    };
                    let started = Instant::now();
                    run_cell(&cell).await;
                    eprintln!(
                        "pair matrix {PAIR} {} {label} {load} run {run}: {:.1}s",
                        path.name(),
                        started.elapsed().as_secs_f64()
                    );
                }
            }
        }
    }
}

/// [`ChatRpc`] straight over a WebSocket to the bench's fake acpmux. Replies are kept by id,
/// and their arrival order is recorded.
struct WsRpc {
    socket: tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    stash: HashMap<String, Value>,
    order: Vec<String>,
}

impl ChatRpc for WsRpc {
    async fn post(&mut self, id: &str, method: &str, params: Value) -> Result<(), String> {
        let request = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.socket.send(Message::Text(request.to_string().into())).await.map_err(|e| format!("{e}"))
    }

    async fn answer(&mut self, id: &str) -> Result<Value, String> {
        if let Some(reply) = self.stash.remove(id) {
            return Ok(reply);
        }
        loop {
            let frame = tokio::time::timeout(Duration::from_secs(10), self.socket.next())
                .await
                .map_err(|_| format!("no reply to {id}"))?
                .ok_or("closed")?
                .map_err(|e| format!("{e}"))?;
            let Message::Text(text) = frame else { continue };
            let reply: Value = serde_json::from_str(&text).map_err(|e| format!("{e}"))?;
            let Some(got) = reply["id"].as_str().map(str::to_owned) else { continue };
            self.order.push(got.clone());
            if got == id {
                return Ok(reply);
            }
            self.stash.insert(got, reply);
        }
    }
}

/// The pipelined open against the bench's fake acpmux: the attach sent before `initialize` is
/// answered is answered after it, in request order, with the chat's page.
#[tokio::test]
async fn pipelined_open_against_fake_acpmux_answers_in_order() {
    let acpmux = FakeAcpmux::start(2, 3, 3).await;
    let (socket, _) = tokio_tungstenite::connect_async(acpmux.url.as_str()).await.expect("connect");
    let mut rpc = WsRpc { socket, stash: HashMap::new(), order: Vec::new() };
    let requests = ChatOpenRequests {
        initialize: json!({"protocolVersion": 1}),
        watch: json!({"enabled": true, "limit": WATCH_LIMIT}),
        attach: json!({"sessionId": acpmux.session_id(0), "limit": PAGE_SIZE, "kinds": ["transcript"]}),
    };
    let opened = open_chat(&mut rpc, &requests, true).await.expect("open");
    assert_eq!(rpc.order, ["init", "watch", "attach"], "answered in request order");
    let rows = opened.attach["result"]["events"].as_array().map(Vec::len).unwrap_or_default();
    assert!(rows > 0, "attach page: {}", opened.attach);
}
