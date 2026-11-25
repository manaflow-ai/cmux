//! An in-process stand-in for the backend's signaling Durable Object, for
//! tests: same routes, same JSON, same admission rule (a signal reaches a
//! device of the sender's own user, or answers an existing session), and
//! the same refusal of an older peer's binary relay frames
//! (`relay_retired`). The bearer token is `user:<userId>`. It also serves
//! the link's WebSocket relay (`GET /v1/relay/<session>?deviceId=`, the
//! Worker's `LinkRelay`): only the two devices of a session join, and a
//! frame goes to the other with its peer id set to the sender's device.
//!
//! [`TestTurn`] is a TURN server on loopback, over UDP and over TLS (a
//! self-signed certificate the dial options trust).
//!
//! [`shape_by_profile`] plays a named phone link profile (cmux-fault's
//! `link-profiles.json`) on a tunnel's received datagrams.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;

mod hub;
mod shaped;
pub use hub::{FakeHub, FakeHubMode, FakeHubStats};
pub use shaped::{
    Direction, LINK_PROFILES_JSON, LinkProfile, RadioModel, radio_wakes, set_link_profile, set_radio_model,
    shape_by_profile, shape_downlink, shape_uplink, shaped_counts,
};

#[derive(Debug, Clone, Default)]
pub struct FakeOptions {
    /// Remove every endpoint but the TURN relayed ones from wg-init and
    /// wg-resp, so WireGuard can only use TURN.
    pub strip_direct_endpoints: bool,
    /// Do not stamp `fromUserId` on forwarded signals.
    pub omit_from_user_id: bool,
    /// Remove `version` from wg-init and wg-resp, so each side takes the
    /// other for an older peer (protocol version 0).
    pub strip_wg_version: bool,
    /// What `GET /v1/ice` returns besides Cloudflare STUN (a [`TestTurn`]).
    pub ice_servers: Vec<crate::api::IceServer>,
    /// `GET /v1/ice` answers after this long (a slow Worker or TURN API).
    pub ice_delay: std::time::Duration,
    /// The STUN server `GET /v1/ice` names instead of Cloudflare's
    /// (`host:port`, say a local socket that never answers).
    pub ice_stun: Option<String>,
    /// Refuse every relay join with `503 relay_off` (the Worker's kill switch).
    pub relay_off: bool,
    /// A relay join's upgrade is answered this much later (a slow network or
    /// a far Worker), so a join can race a path that starts working.
    pub relay_join_delay: std::time::Duration,
}

/// How often the backend answers an older peer's relay frames for one
/// session (team-hub.ts `RELAY_ERROR_INTERVAL_MS`).
const RELAY_ERROR_INTERVAL: std::time::Duration = std::time::Duration::from_secs(5);

struct Device {
    user: String,
    out: mpsc::UnboundedSender<Message>,
}

#[derive(Default)]
struct State {
    devices: HashMap<String, Device>,
    /// sessionId → the two devices in it.
    sessions: HashMap<String, (String, String)>,
    refused_binary_frames: u64,
    /// When each signal was forwarded: (sessionId, payload kind, instant).
    forwarded: Vec<(String, String, std::time::Instant)>,
    /// The relay's joined sockets: sessionId → device → its socket.
    relays: HashMap<String, HashMap<String, mpsc::UnboundedSender<Message>>>,
    /// Each device's relay ticket per session, stamped on the `wg-*` signals
    /// sent to it (team-hub.ts `relayTicket`): (sessionId, device) → ticket.
    tickets: HashMap<(String, String), String>,
    relay_joins: u64,
    /// Each device's relay joins, in order: device → when.
    relay_joined: Vec<(String, std::time::Instant)>,
    relay_frames: u64,
}

pub struct FakeSignaling {
    pub base_url: String,
    state: Arc<Mutex<State>>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for FakeSignaling {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl FakeSignaling {
    pub async fn start(options: FakeOptions) -> Self {
        Self::start_on("127.0.0.1:0", options).await
    }

    /// Listen on `address` (for a fake backend reachable from another host).
    /// Besides the signaling WebSocket it answers `GET /v1/health`,
    /// `GET /v1/ice` (Cloudflare STUN only) and `POST /v1/devices`.
    pub async fn start_on(address: &str, options: FakeOptions) -> Self {
        let listener = TcpListener::bind(address).await.expect("bind");
        let base_url = format!("http://{}", listener.local_addr().expect("addr"));
        let state = Arc::new(Mutex::new(State::default()));
        let shared = Arc::clone(&state);
        let task = tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                tokio::spawn(serve(stream, Arc::clone(&shared), options.clone()));
            }
        });
        Self { base_url, state, task }
    }

    /// When the server forwarded the first `kind` signal (`wg-init`,
    /// `wg-resp`, ...) of `session`.
    pub fn forwarded_at(&self, session: &str, kind: &str) -> Option<std::time::Instant> {
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.forwarded.iter().find(|(s, k, _)| s == session && k == kind).map(|(_, _, at)| *at)
    }

    /// Every session the server forwarded a `kind` signal of, in order.
    pub fn sessions_with(&self, kind: &str) -> Vec<String> {
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.forwarded.iter().filter(|(_, k, _)| k == kind).map(|(s, _, _)| s.clone()).collect()
    }

    /// Relay joins admitted so far.
    pub fn relay_joins(&self) -> u64 {
        self.state.lock().unwrap_or_else(PoisonError::into_inner).relay_joins
    }

    /// When `device` joined the relay, each time it did.
    pub fn relay_joins_of(&self, device: &str) -> Vec<std::time::Instant> {
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.relay_joined.iter().filter(|(who, _)| who == device).map(|(_, at)| *at).collect()
    }

    /// Relay frames forwarded so far.
    pub fn relay_frames(&self) -> u64 {
        self.state.lock().unwrap_or_else(PoisonError::into_inner).relay_frames
    }

    /// Close every relay socket of `device` (a proxy that resets it).
    pub fn kick_relay(&self, device: &str) {
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        for sockets in state.relays.values() {
            if let Some(out) = sockets.get(device) {
                let _ = out.send(Message::Close(None));
            }
        }
    }

    /// Binary frames (an older peer's relay frames) refused so far.
    pub fn refused_binary_frames(&self) -> u64 {
        self.state.lock().unwrap_or_else(PoisonError::into_inner).refused_binary_frames
    }

    /// Test support: hold the server's bookkeeping for `duration`, as a
    /// loaded machine stalls it; returns once it is held.
    pub fn stall_for(&self, duration: std::time::Duration) {
        let state = Arc::clone(&self.state);
        let (held_tx, held_rx) = std::sync::mpsc::sync_channel(0);
        std::thread::spawn(move || {
            let _held = state.lock().unwrap_or_else(PoisonError::into_inner);
            let _ = held_tx.send(());
            std::thread::sleep(duration);
        });
        let _ = held_rx.recv();
    }

    /// Send `frame` (a JSON text frame) to `device`'s socket, as the backend
    /// does (a `mailbox` frame right after `hello`); false when it is not connected.
    pub fn send_to_device(&self, device: &str, frame: &serde_json::Value) -> bool {
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.devices.get(device).is_some_and(|d| d.out.send(Message::Text(frame.to_string().into())).is_ok())
    }

    /// Drop the socket of `device` (simulates a signaling outage).
    pub fn kick(&self, device: &str) {
        let removed = self.state.lock().unwrap_or_else(PoisonError::into_inner).devices.remove(device);
        if let Some(device) = removed {
            let _ = device.out.send(Message::Close(None));
        }
    }
}

#[allow(clippy::result_large_err)] // tungstenite's handshake callback signature
async fn serve(stream: tokio::net::TcpStream, state: Arc<Mutex<State>>, options: FakeOptions) {
    let ice = options.ice_servers.clone();
    let mut stream = stream;
    match peek_head(&stream).await {
        Some(head) if !head.to_ascii_lowercase().contains("upgrade: websocket") => {
            answer_http(&mut stream, &head, &ice, &options).await;
            return;
        }
        Some(head) if head.starts_with("GET /v1/relay/") => {
            serve_relay(stream, &head, state, &options).await;
            return;
        }
        Some(_) => {}
        None => return,
    }
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<Message>();
    let mut identity = None;
    let callback = |request: &Request, response: Response| -> Result<Response, ErrorResponse> {
        let user = request
            .headers()
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer user:"))
            .map(str::to_owned);
        let device = request
            .uri()
            .query()
            .and_then(|q| q.split('&').find_map(|kv| kv.strip_prefix("deviceId=")))
            .map(str::to_owned);
        let path_ok =
            request.uri().path().starts_with("/v1/teams/") && request.uri().path().ends_with("/signal");
        match (user, device, path_ok) {
            (Some(user), Some(device), true) => {
                // Record the device before this answer goes out: once the
                // client's `connect` returns, a dial to it must be routed.
                let _ = out_tx
                    .send(Message::Text(json!({"type":"hello","you":device,"macs":[]}).to_string().into()));
                let replaced = state
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .devices
                    .insert(device.clone(), Device { user: user.clone(), out: out_tx.clone() });
                // One live socket per device, as in the backend (team-hub.ts):
                // a reconnect closes the old socket with 4000 "replaced".
                if let Some(old) = replaced {
                    let _ = old.out.send(Message::Close(Some(CloseFrame {
                        code: CloseCode::Library(4000),
                        reason: "replaced".into(),
                    })));
                }
                identity = Some((user, device));
                Ok(response)
            }
            _ => {
                let mut refused = ErrorResponse::new(Some("unauthorized".into()));
                *refused.status_mut() = tokio_tungstenite::tungstenite::http::StatusCode::UNAUTHORIZED;
                Err(refused)
            }
        }
    };
    let accepted = tokio_tungstenite::accept_hdr_async(stream, callback).await;
    let Some((user, device)) = identity else { return };
    let Ok(socket) = accepted else {
        forget(&state, &device, &out_tx);
        return;
    };
    let (mut sink, mut source) = socket.split();
    tokio::spawn(async move {
        while let Some(message) = out_rx.recv().await {
            let close = matches!(message, Message::Close(_));
            if sink.send(message).await.is_err() || close {
                break;
            }
        }
        let _ = sink.close().await;
    });
    let mut relay_errors: HashMap<String, std::time::Instant> = HashMap::new();
    while let Some(Ok(message)) = source.next().await {
        // A replaced socket is closing: the backend ignores what it still
        // sends (team-hub.ts `replaced`).
        let current = state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .devices
            .get(&device)
            .is_some_and(|d| d.out.same_channel(&out_tx));
        if !current {
            continue;
        }
        match message {
            Message::Text(text) => {
                let Ok(mut value) = serde_json::from_str::<Value>(&text) else { continue };
                if value["type"] != "signal" {
                    continue;
                }
                let to = value["to"].as_str().unwrap_or_default().to_owned();
                let session = value["sessionId"].as_str().unwrap_or_default().to_owned();
                value["from"] = Value::String(device.clone());
                if options.omit_from_user_id {
                    if let Some(object) = value.as_object_mut() {
                        object.remove("fromUserId");
                    }
                } else {
                    value["fromUserId"] = Value::String(user.clone());
                }
                if options.strip_wg_version
                    && let Some(payload) = value["payload"].as_object_mut()
                {
                    payload.remove("version");
                }
                if options.strip_direct_endpoints
                    && matches!(value["payload"]["kind"].as_str(), Some("wg-init" | "wg-resp"))
                {
                    let relayed = value["payload"]["relayed"].clone();
                    value["payload"]["endpoints"] = if relayed.is_array() { relayed } else { json!([]) };
                }
                let mut state = state.lock().unwrap_or_else(PoisonError::into_inner);
                let existing = state.sessions.get(&session).cloned();
                let admitted = match &existing {
                    Some((a, b)) => (a == &device && b == &to) || (b == &device && a == &to),
                    None => state.devices.get(&to).is_some_and(|target| target.user == user),
                };
                let target = state.devices.get(&to).map(|d| d.out.clone());
                match (admitted, target) {
                    (true, Some(target)) => {
                        let kind = value["payload"]["kind"].as_str().unwrap_or_default().to_owned();
                        state.forwarded.push((session.clone(), kind.clone(), std::time::Instant::now()));
                        if existing.is_none() {
                            state.sessions.insert(session.clone(), (device.clone(), to.clone()));
                        }
                        // The recipient's own relay ticket, never a client's value.
                        if let Some(object) = value.as_object_mut() {
                            object.remove("relayTicket");
                        }
                        if kind.starts_with("wg-") {
                            let ticket = state
                                .tickets
                                .entry((session, to))
                                .or_insert_with(|| uuid::Uuid::new_v4().simple().to_string())
                                .clone();
                            value["relayTicket"] = Value::String(ticket);
                        }
                        let _ = target.send(Message::Text(value.to_string().into()));
                    }
                    (true, None) => {
                        let _ = out_tx.send(Message::Text(
                            json!({"type":"error","code":"offline","message":"device is offline"})
                                .to_string()
                                .into(),
                        ));
                    }
                    (false, _) => {
                        let _ = out_tx.send(Message::Text(
                            json!({"type":"error","code":"not_owner","message":"not your device"})
                                .to_string()
                                .into(),
                        ));
                    }
                }
            }
            // Relay frames are retired: refuse them, at most once per
            // session every 5 s, naming the session (never a sessionless
            // error, which would fail an older client's other dials).
            Message::Binary(bytes) => {
                state.lock().unwrap_or_else(PoisonError::into_inner).refused_binary_frames += 1;
                if bytes.len() < 16 {
                    continue;
                }
                let session = uuid::Uuid::from_slice(&bytes[..16]).map(|u| u.to_string()).unwrap_or_default();
                let now = std::time::Instant::now();
                if relay_errors
                    .get(&session)
                    .is_some_and(|last| now.duration_since(*last) < RELAY_ERROR_INTERVAL)
                {
                    continue;
                }
                relay_errors.insert(session.clone(), now);
                let _ = out_tx.send(Message::Text(
                    json!({"type":"error","code":"relay_retired",
                           "message":"WireGuard relay frames are retired; use TURN","sessionId":session})
                    .to_string()
                    .into(),
                ));
            }
            Message::Close(_) => break,
            _ => {}
        }
    }
    forget(&state, &device, &out_tx);
}

/// One relay socket: admitted only for a device of the session (the fake's
/// session table, bound by the first signal), by the session's user.
#[allow(clippy::result_large_err)] // tungstenite's handshake callback signature
async fn serve_relay(
    stream: tokio::net::TcpStream,
    head: &str,
    state: Arc<Mutex<State>>,
    options: &FakeOptions,
) {
    let target = head.lines().next().and_then(|line| line.split(' ').nth(1)).unwrap_or_default();
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    let session = path.trim_start_matches("/v1/relay/").to_owned();
    let device = query.split('&').find_map(|kv| kv.strip_prefix("deviceId=")).unwrap_or_default().to_owned();
    let user = head.lines().find_map(|line| {
        let lower = line.to_ascii_lowercase();
        lower
            .starts_with("authorization: bearer user:")
            .then(|| line["authorization: bearer user:".len()..].trim().to_owned())
    });
    let presented = head.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        name.trim().eq_ignore_ascii_case(crate::dial::relay::TICKET_HEADER).then(|| value.trim().to_owned())
    });
    let offered = head.lines().any(|line| {
        let lower = line.to_ascii_lowercase();
        lower.starts_with("sec-websocket-protocol:") && lower.contains(crate::dial::relay::SUBPROTOCOL)
    });
    let peer = {
        let state = state.lock().unwrap_or_else(PoisonError::into_inner);
        state.sessions.get(&session).and_then(|(a, b)| {
            let other = if *a == device {
                b
            } else if *b == device {
                a
            } else {
                return None;
            };
            let same_user = state.devices.get(&device).is_none_or(|d| Some(&d.user) == user.as_ref());
            // The joining device's own ticket, as the Worker requires.
            let ticket_ok = state
                .tickets
                .get(&(session.clone(), device.clone()))
                .is_some_and(|ticket| presented.as_deref() == Some(ticket.as_str()));
            (same_user && ticket_ok).then(|| other.clone())
        })
    };
    use tokio_tungstenite::tungstenite::http::StatusCode;
    let refusal = if user.is_none() {
        Some((StatusCode::UNAUTHORIZED, "unauthorized"))
    } else if options.relay_off {
        Some((StatusCode::SERVICE_UNAVAILABLE, "relay_off"))
    } else if peer.is_none() {
        Some((StatusCode::FORBIDDEN, "not_in_session"))
    } else {
        None
    };
    tokio::time::sleep(options.relay_join_delay).await;
    let callback = |_: &Request, mut response: Response| -> Result<Response, ErrorResponse> {
        if let Some((status, code)) = refusal {
            let body = json!({"error": {"code": code, "message": code}}).to_string();
            let mut refused = ErrorResponse::new(Some(body));
            *refused.status_mut() = status;
            return Err(refused);
        }
        if offered {
            response
                .headers_mut()
                .insert("sec-websocket-protocol", crate::dial::relay::SUBPROTOCOL.parse().expect("header"));
        }
        Ok(response)
    };
    let Ok(socket) = tokio_tungstenite::accept_hdr_async(stream, callback).await else { return };
    let Some(peer) = peer else { return };
    let Ok(device_bytes) = uuid::Uuid::parse_str(&device).map(|id| *id.as_bytes()) else { return };
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<Message>();
    let peer_out = {
        let mut state = state.lock().unwrap_or_else(PoisonError::into_inner);
        state.relay_joins += 1;
        state.relay_joined.push((device.clone(), std::time::Instant::now()));
        let sockets = state.relays.entry(session.clone()).or_default();
        if let Some(old) = sockets.insert(device.clone(), out_tx.clone()) {
            let _ = old.send(Message::Close(Some(CloseFrame {
                code: CloseCode::Library(4000),
                reason: "replaced".into(),
            })));
        }
        sockets.get(&peer).cloned()
    };
    let _ =
        out_tx.send(Message::Text(json!({"type":"joined","peer": peer_out.is_some()}).to_string().into()));
    if let Some(peer_out) = &peer_out {
        let _ = peer_out.send(Message::Text(json!({"type":"peer","online": true}).to_string().into()));
    }
    let (mut sink, mut source) = socket.split();
    tokio::spawn(async move {
        while let Some(message) = out_rx.recv().await {
            let close = matches!(message, Message::Close(_));
            if sink.send(message).await.is_err() || close {
                break;
            }
        }
        let _ = sink.close().await;
    });
    let peer_socket = |state: &Arc<Mutex<State>>| {
        let state = state.lock().unwrap_or_else(PoisonError::into_inner);
        state.relays.get(&session).and_then(|sockets| sockets.get(&peer).cloned())
    };
    while let Some(Ok(message)) = source.next().await {
        match message {
            Message::Binary(bytes) => {
                use cmux_transport::relay_frame::{FrameKind, PeerId, RelayFrame};
                let Ok(mut frame) = RelayFrame::decode(&bytes) else { continue };
                if frame.kind != FrameKind::Datagrams {
                    continue;
                }
                frame.peer = PeerId(device_bytes);
                let Ok(encoded) = frame.encode() else { continue };
                match peer_socket(&state) {
                    Some(target) => {
                        tracing::trace!(%session, from = %device, to = %peer, "fake relay forwards a frame");
                        state.lock().unwrap_or_else(PoisonError::into_inner).relay_frames += 1;
                        let _ = target.send(Message::Binary(encoded.into()));
                    }
                    None => {
                        tracing::debug!(%session, from = %device, to = %peer, "fake relay: the peer has not joined");
                        let _ = out_tx
                            .send(Message::Text(json!({"type":"peer","online": false}).to_string().into()));
                    }
                }
            }
            Message::Text(text) if text.as_str() == "ping" => {
                let _ = out_tx.send(Message::Text("pong".into()));
            }
            Message::Close(_) => break,
            _ => {}
        }
    }
    let mut state = state.lock().unwrap_or_else(PoisonError::into_inner);
    if let Some(sockets) = state.relays.get_mut(&session)
        && sockets.get(&device).is_some_and(|out| out.same_channel(&out_tx))
    {
        sockets.remove(&device);
        if let Some(peer_out) = sockets.get(&peer) {
            let _ = peer_out.send(Message::Text(json!({"type":"peer","online": false}).to_string().into()));
        }
    }
}

/// Drop `device`'s registration if it is still this socket's.
fn forget(state: &Mutex<State>, device: &str, out_tx: &mpsc::UnboundedSender<Message>) {
    let mut state = state.lock().unwrap_or_else(PoisonError::into_inner);
    if state.devices.get(device).is_some_and(|d| d.out.same_channel(out_tx)) {
        state.devices.remove(device);
    }
}

/// The request head (through the blank line), without consuming it.
async fn peek_head(stream: &tokio::net::TcpStream) -> Option<String> {
    let mut buffer = vec![0u8; 8192];
    for _ in 0..200 {
        let read = stream.peek(&mut buffer).await.ok()?;
        if read == 0 {
            return None;
        }
        let text = String::from_utf8_lossy(&buffer[..read]);
        if let Some(end) = text.find("\r\n\r\n") {
            return Some(text[..end + 4].to_owned());
        }
        if read == buffer.len() {
            return None;
        }
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    }
    None
}

async fn answer_http(
    stream: &mut tokio::net::TcpStream,
    head: &str,
    ice: &[crate::api::IceServer],
    options: &FakeOptions,
) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let length = head
        .lines()
        .find_map(|line| {
            line.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().to_owned())
        })
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(0);
    let mut request = vec![0u8; head.len() + length.min(1 << 20)];
    if stream.read_exact(&mut request).await.is_err() {
        return;
    }
    let body: Value = serde_json::from_slice(&request[head.len()..]).unwrap_or(Value::Null);
    let line = head.lines().next().unwrap_or_default();
    let authorized = head.lines().any(|l| l.to_ascii_lowercase().starts_with("authorization: bearer user:"));
    let (status, reply) = if line.starts_with("GET /v1/health") {
        ("200 OK", json!({"ok": true, "version": "fake"}))
    } else if !authorized {
        ("401 Unauthorized", json!({"error": "unauthorized"}))
    } else if line.starts_with("GET /v1/ice") {
        tokio::time::sleep(options.ice_delay).await;
        let stun = options.ice_stun.as_deref().unwrap_or("stun.cloudflare.com:3478");
        let mut servers = vec![json!({"urls": [format!("stun:{stun}")]})];
        servers.extend(ice.iter().map(|server| {
            json!({"urls": server.urls, "username": server.username, "credential": server.credential})
        }));
        ("200 OK", json!({"iceServers": servers, "ttl": 3600, "turn": !ice.is_empty()}))
    } else if line.starts_with("POST /v1/devices") {
        ("200 OK", json!({"device": body}))
    } else {
        ("404 Not Found", json!({"error": "not_found"}))
    };
    let reply = reply.to_string();
    let response = format!(
        "HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}",
        reply.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
}

/// TURN relayed ports of a [`TestTurn`] start here (each server takes 100).
/// The range overlaps macOS's ephemeral ports, so a port in it says nothing
/// about who owns it: tests ask [`is_test_relay`] instead.
pub const TEST_RELAY_PORTS_START: u16 = 61_000;
static NEXT_RELAY_PORTS: std::sync::atomic::AtomicU16 = std::sync::atomic::AtomicU16::new(0);

/// Every relayed address of a live [`TestTurn`] allocation in this process.
/// A relay socket holds its port while the allocation lives, so no tunnel
/// socket can have an address in this set; an address leaves it when its
/// relay socket closes, before the OS can give the port to another socket.
static RELAYED: Mutex<Vec<std::net::SocketAddr>> = Mutex::new(Vec::new());

/// Whether `addr` is a relayed address of a live [`TestTurn`] allocation.
/// For the plain `fn` hooks in `DialOptions` (`impair_inbound`,
/// `drop_udp_to`), which cannot hold a `TestTurn`.
pub fn is_test_relay(addr: &std::net::SocketAddr) -> bool {
    RELAYED.lock().unwrap_or_else(PoisonError::into_inner).contains(addr)
}

/// Allocates in the server's port range and records each relayed address.
struct RecordedRelays {
    inner: webrtc::turn::relay::relay_range::RelayAddressGeneratorRanges,
    allocated: Arc<Mutex<Vec<std::net::SocketAddr>>>,
}

#[async_trait::async_trait]
impl webrtc::turn::relay::RelayAddressGenerator for RecordedRelays {
    fn validate(&self) -> Result<(), webrtc::turn::Error> {
        self.inner.validate()
    }

    async fn allocate_conn(
        &self,
        use_ipv4: bool,
        requested_port: u16,
    ) -> Result<(Arc<dyn webrtc::util::Conn + Send + Sync>, std::net::SocketAddr), webrtc::turn::Error> {
        let (conn, relayed) = self.inner.allocate_conn(use_ipv4, requested_port).await?;
        // The relay socket listens on 127.0.0.1 and reports `relay_address`
        // (also 127.0.0.1): both spellings are the same socket.
        RELAYED.lock().unwrap_or_else(PoisonError::into_inner).push(relayed);
        self.allocated.lock().unwrap_or_else(PoisonError::into_inner).push(relayed);
        let conn = RecordedConn { inner: conn, relayed, allocated: Arc::clone(&self.allocated) };
        Ok((Arc::new(conn), relayed))
    }
}

/// A relay socket that leaves the registries when it closes (the
/// allocation was released or expired) or drops.
struct RecordedConn {
    inner: Arc<dyn webrtc::util::Conn + Send + Sync>,
    relayed: std::net::SocketAddr,
    allocated: Arc<Mutex<Vec<std::net::SocketAddr>>>,
}

impl RecordedConn {
    fn forget(&self) {
        let forget = |list: &Mutex<Vec<std::net::SocketAddr>>| {
            let mut list = list.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(index) = list.iter().position(|addr| *addr == self.relayed) {
                list.swap_remove(index);
            }
        };
        forget(&RELAYED);
        forget(&self.allocated);
    }
}

impl Drop for RecordedConn {
    fn drop(&mut self) {
        self.forget();
    }
}

#[async_trait::async_trait]
impl webrtc::util::Conn for RecordedConn {
    async fn connect(&self, addr: std::net::SocketAddr) -> webrtc::util::Result<()> {
        self.inner.connect(addr).await
    }

    async fn recv(&self, buf: &mut [u8]) -> webrtc::util::Result<usize> {
        self.inner.recv(buf).await
    }

    async fn recv_from(&self, buf: &mut [u8]) -> webrtc::util::Result<(usize, std::net::SocketAddr)> {
        self.inner.recv_from(buf).await
    }

    async fn send(&self, buf: &[u8]) -> webrtc::util::Result<usize> {
        self.inner.send(buf).await
    }

    async fn send_to(&self, buf: &[u8], target: std::net::SocketAddr) -> webrtc::util::Result<usize> {
        self.inner.send_to(buf, target).await
    }

    fn local_addr(&self) -> webrtc::util::Result<std::net::SocketAddr> {
        self.inner.local_addr()
    }

    fn remote_addr(&self) -> Option<std::net::SocketAddr> {
        self.inner.remote_addr()
    }

    async fn close(&self) -> webrtc::util::Result<()> {
        // Leave first: once the socket is closed its port is free to reuse.
        self.forget();
        self.inner.close().await
    }

    fn as_any(&self) -> &(dyn std::any::Any + Send + Sync) {
        self
    }
}

struct TestAuth;

impl webrtc::turn::auth::AuthHandler for TestAuth {
    fn auth_handle(
        &self,
        username: &str,
        realm: &str,
        _source: std::net::SocketAddr,
    ) -> Result<Vec<u8>, webrtc::turn::Error> {
        Ok(webrtc::turn::auth::generate_auth_key(username, realm, "secret"))
    }
}

/// A TURN server on loopback for tests: UDP on one port, TLS (RFC 5766 over
/// TLS, a self-signed certificate for 127.0.0.1) on another, and plain TCP
/// on a third. Relayed addresses are `127.0.0.1` with ports in
/// [`TestTurn::relay_ports`], so a test can tell TURN from direct paths.
pub struct TestTurn {
    /// `turn:...?transport=udp`, `turns:...?transport=tcp` and
    /// `turn:...?transport=tcp`, with credentials.
    pub ice: crate::api::IceServer,
    /// Trust these for TURN over TLS (`DialOptions::turn_tls_roots`).
    pub roots: Arc<rustls::RootCertStore>,
    pub relay_ports: std::ops::RangeInclusive<u16>,
    servers: Arc<Mutex<Vec<webrtc::turn::server::Server>>>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
    /// Stream connections accepted so far (TLS and TCP).
    streams: Arc<std::sync::atomic::AtomicUsize>,
    /// While on, the UDP port drops everything (a network that blocks UDP
    /// to the TURN server), and counts what it dropped.
    udp_block: Arc<UdpBlock>,
    /// Relayed addresses this server allocated (also in [`RELAYED`] until
    /// the server drops).
    allocated: Arc<Mutex<Vec<std::net::SocketAddr>>>,
    /// How long a new stream connection (TLS or TCP) waits before the
    /// server takes it, in milliseconds ([`Self::delay_streams`]).
    stream_delay: Arc<std::sync::atomic::AtomicU64>,
}

/// Whether the TURN server's UDP port drops everything, and what it dropped
/// so far: datagrams from its clients, and datagrams it would have sent them.
#[derive(Default)]
struct UdpBlock {
    on: std::sync::atomic::AtomicBool,
    dropped_from_clients: std::sync::atomic::AtomicU64,
    dropped_to_clients: std::sync::atomic::AtomicU64,
    /// Allocate success responses still to drop (a lossy link that loses
    /// the server's answer, so the client's retransmit meets an allocation
    /// that already exists).
    drop_allocate_successes: std::sync::atomic::AtomicU32,
}

/// Whether `datagram` is a STUN Allocate success response (type 0x0103).
fn is_allocate_success(datagram: &[u8]) -> bool {
    datagram.len() >= 20 && datagram[..2] == [0x01, 0x03]
}

/// How long the loopback TURN server's UDP answers to requests (Allocate,
/// Refresh, CreatePermission, ChannelBind) take to leave it, in
/// milliseconds: a TURN server a real round trip away, for the client's
/// control transactions only (data is shaped by `impair_inbound`). 0, the
/// default, answers at once.
static TURN_ANSWER_DELAY_MS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Sets [`TURN_ANSWER_DELAY_MS`] for every [`TestTurn`] in this process.
pub fn set_turn_answer_delay(delay: std::time::Duration) {
    TURN_ANSWER_DELAY_MS
        .store(u64::try_from(delay.as_millis()).unwrap_or(u64::MAX), std::sync::atomic::Ordering::Relaxed);
}

/// A STUN success or error response (not an indication, not ChannelData).
fn is_stun_response(datagram: &[u8]) -> bool {
    if datagram.len() < 20 || datagram[0] & 0xc0 != 0 || datagram[4..8] != [0x21, 0x12, 0xa4, 0x42] {
        return false;
    }
    let kind = u16::from_be_bytes([datagram[0], datagram[1]]);
    let class = ((kind >> 7) & 0x2) | ((kind >> 4) & 0x1);
    class >= 2
}

/// The TURN server's UDP socket, which drops everything while `block` is on.
struct BlockableUdp {
    socket: Arc<tokio::net::UdpSocket>,
    block: Arc<UdpBlock>,
}

#[async_trait::async_trait]
impl webrtc::util::Conn for BlockableUdp {
    async fn connect(&self, addr: std::net::SocketAddr) -> webrtc::util::Result<()> {
        Ok(self.socket.connect(addr).await?)
    }

    async fn recv(&self, buf: &mut [u8]) -> webrtc::util::Result<usize> {
        self.recv_from(buf).await.map(|(len, _)| len)
    }

    async fn recv_from(&self, buf: &mut [u8]) -> webrtc::util::Result<(usize, std::net::SocketAddr)> {
        loop {
            let (len, from) = self.socket.recv_from(buf).await?;
            if !self.block.on.load(std::sync::atomic::Ordering::Relaxed) {
                return Ok((len, from));
            }
            self.block.dropped_from_clients.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        }
    }

    async fn send(&self, buf: &[u8]) -> webrtc::util::Result<usize> {
        Ok(self.socket.send(buf).await?)
    }

    async fn send_to(&self, buf: &[u8], target: std::net::SocketAddr) -> webrtc::util::Result<usize> {
        if self.block.on.load(std::sync::atomic::Ordering::Relaxed) {
            self.block.dropped_to_clients.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            return Ok(buf.len());
        }
        if is_allocate_success(buf)
            && self
                .block
                .drop_allocate_successes
                .fetch_update(
                    std::sync::atomic::Ordering::Relaxed,
                    std::sync::atomic::Ordering::Relaxed,
                    |n| n.checked_sub(1),
                )
                .is_ok()
        {
            return Ok(buf.len());
        }
        let delay = TURN_ANSWER_DELAY_MS.load(std::sync::atomic::Ordering::Relaxed);
        if delay > 0 && is_stun_response(buf) {
            let (socket, answer) = (Arc::clone(&self.socket), buf.to_vec());
            tokio::spawn(async move {
                tokio::time::sleep(std::time::Duration::from_millis(delay)).await;
                let _ = socket.send_to(&answer, target).await;
            });
            return Ok(buf.len());
        }
        Ok(self.socket.send_to(buf, target).await?)
    }

    fn local_addr(&self) -> webrtc::util::Result<std::net::SocketAddr> {
        Ok(self.socket.local_addr()?)
    }

    fn remote_addr(&self) -> Option<std::net::SocketAddr> {
        None
    }

    async fn close(&self) -> webrtc::util::Result<()> {
        Ok(())
    }

    fn as_any(&self) -> &(dyn std::any::Any + Send + Sync) {
        self
    }
}

impl TestTurn {
    pub async fn start() -> Self {
        let slot = NEXT_RELAY_PORTS.fetch_add(1, std::sync::atomic::Ordering::Relaxed) % 45;
        let first = TEST_RELAY_PORTS_START + slot * 100;
        let relay_ports = first..=first + 99;
        let servers = Arc::new(Mutex::new(Vec::new()));
        let udp_block = Arc::new(UdpBlock::default());
        let allocated = Arc::new(Mutex::new(Vec::new()));
        let udp = BlockableUdp {
            socket: Arc::new(tokio::net::UdpSocket::bind("127.0.0.1:0").await.expect("bind TURN UDP")),
            block: Arc::clone(&udp_block),
        };
        let udp_port = udp.socket.local_addr().expect("addr").port();
        let server = Self::server(Arc::new(udp), relay_ports.clone(), Arc::clone(&allocated)).await;
        servers.lock().unwrap_or_else(PoisonError::into_inner).push(server);

        let certified =
            rcgen::generate_simple_self_signed(vec!["127.0.0.1".to_owned()]).expect("certificate");
        let mut roots = rustls::RootCertStore::empty();
        roots.add(certified.cert.der().clone()).expect("root");
        let key = rustls::pki_types::PrivateKeyDer::Pkcs8(rustls::pki_types::PrivatePkcs8KeyDer::from(
            certified.key_pair.serialize_der(),
        ));
        let tls =
            rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()
                .expect("TLS versions")
                .with_no_client_auth()
                .with_single_cert(vec![certified.cert.der().clone()], key)
                .expect("TLS server config");
        let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(tls));
        let streams = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let stream_delay = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let mut tasks = Vec::new();
        let mut stream_port = |secure: bool| {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind TURN TCP");
            listener.set_nonblocking(true).expect("nonblocking");
            let port = listener.local_addr().expect("addr").port();
            let listener = TcpListener::from_std(listener).expect("listener");
            let (acceptor, servers, ports, streams, allocated, delay) = (
                acceptor.clone(),
                Arc::clone(&servers),
                relay_ports.clone(),
                Arc::clone(&streams),
                Arc::clone(&allocated),
                Arc::clone(&stream_delay),
            );
            tasks.push(tokio::spawn(async move {
                while let Ok((tcp, client)) = listener.accept().await {
                    let (acceptor, servers, ports, streams, allocated) = (
                        acceptor.clone(),
                        Arc::clone(&servers),
                        ports.clone(),
                        Arc::clone(&streams),
                        Arc::clone(&allocated),
                    );
                    let delay = delay.load(std::sync::atomic::Ordering::Relaxed);
                    tokio::spawn(async move {
                        if delay > 0 {
                            tokio::time::sleep(std::time::Duration::from_millis(delay)).await;
                        }
                        let _ = tcp.set_nodelay(true);
                        let Ok(local) = tcp.local_addr() else { return };
                        let conn: Arc<dyn webrtc::util::Conn + Send + Sync> = if secure {
                            let Ok(tls) = acceptor.accept(tcp).await else { return };
                            Arc::new(crate::dial::turn::StreamConn::new(tls, local, client))
                        } else {
                            Arc::new(crate::dial::turn::StreamConn::new(tcp, local, client))
                        };
                        streams.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        let server = Self::server(conn, ports, allocated).await;
                        servers.lock().unwrap_or_else(PoisonError::into_inner).push(server);
                    });
                }
            }));
            port
        };
        let tls_port = stream_port(true);
        let tcp_port = stream_port(false);
        let ice = crate::api::IceServer {
            urls: vec![
                format!("turn:127.0.0.1:{udp_port}?transport=udp"),
                format!("turns:127.0.0.1:{tls_port}?transport=tcp"),
                format!("turn:127.0.0.1:{tcp_port}?transport=tcp"),
            ],
            username: Some("cmuxMobile".into()),
            credential: Some("secret".into()),
        };
        Self {
            ice,
            roots: Arc::new(roots),
            relay_ports,
            servers,
            tasks,
            streams,
            udp_block,
            allocated,
            stream_delay,
        }
    }

    async fn server(
        conn: Arc<dyn webrtc::util::Conn + Send + Sync>,
        ports: std::ops::RangeInclusive<u16>,
        allocated: Arc<Mutex<Vec<std::net::SocketAddr>>>,
    ) -> webrtc::turn::server::Server {
        webrtc::turn::server::Server::new(webrtc::turn::server::config::ServerConfig {
            conn_configs: vec![webrtc::turn::server::config::ConnConfig {
                conn,
                relay_addr_generator: Box::new(RecordedRelays {
                    inner: webrtc::turn::relay::relay_range::RelayAddressGeneratorRanges {
                        relay_address: "127.0.0.1".parse().expect("ip"),
                        min_port: *ports.start(),
                        max_port: *ports.end(),
                        max_retries: 10,
                        address: "127.0.0.1".into(),
                        net: Arc::new(webrtc::util::vnet::net::Net::new(None)),
                    },
                    allocated,
                }),
            }],
            realm: "cmuxMobile.test".into(),
            auth_handler: Arc::new(TestAuth),
            channel_bind_timeout: std::time::Duration::from_secs(0),
            alloc_close_notify: None,
        })
        .await
        .expect("TURN server")
    }

    /// Only the UDP URL (an older service, or a test of UDP TURN alone).
    pub fn udp_only(&self) -> crate::api::IceServer {
        crate::api::IceServer { urls: self.ice.urls[..1].to_vec(), ..self.ice.clone() }
    }

    /// Block (or unblock) UDP to the server, as a network that drops UDP.
    pub fn set_udp_blocked(&self, blocked: bool) {
        self.udp_block.on.store(blocked, std::sync::atomic::Ordering::Relaxed);
    }

    /// Hold each new stream connection (TLS or TCP) this long before the
    /// server takes it, as a slow path to the TURN host over TLS: an
    /// allocation over a stream then takes about this long.
    pub fn delay_streams(&self, delay: std::time::Duration) {
        let millis = u64::try_from(delay.as_millis()).unwrap_or(u64::MAX);
        self.stream_delay.store(millis, std::sync::atomic::Ordering::Relaxed);
    }

    /// Drop the next `count` Allocate success responses on the UDP port, as
    /// a lossy link that loses the server's answer to an allocation.
    pub fn drop_allocate_successes(&self, count: u32) {
        self.udp_block.drop_allocate_successes.store(count, std::sync::atomic::Ordering::Relaxed);
    }

    /// Datagrams the blocked UDP port dropped so far: (from its clients, to
    /// its clients). A blocked phone's leg counts what each end sent the
    /// other while it was cut off.
    pub fn udp_dropped(&self) -> (u64, u64) {
        let from = self.udp_block.dropped_from_clients.load(std::sync::atomic::Ordering::Relaxed);
        let to = self.udp_block.dropped_to_clients.load(std::sync::atomic::Ordering::Relaxed);
        (from, to)
    }

    /// Stream connections (TLS or TCP) the server accepted so far.
    pub fn stream_connections(&self) -> usize {
        self.streams.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// Allocations this server holds now (each until it is released or
    /// expires).
    pub fn allocations(&self) -> usize {
        self.allocated.lock().unwrap_or_else(PoisonError::into_inner).len()
    }

    /// Whether `addr` is one of this server's relayed addresses.
    pub fn is_relayed(&self, addr: &std::net::SocketAddr) -> bool {
        self.allocated.lock().unwrap_or_else(PoisonError::into_inner).contains(addr)
    }
}

impl Drop for TestTurn {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
        let servers = std::mem::take(&mut *self.servers.lock().unwrap_or_else(PoisonError::into_inner));
        let allocated = std::mem::take(&mut *self.allocated.lock().unwrap_or_else(PoisonError::into_inner));
        RELAYED.lock().unwrap_or_else(PoisonError::into_inner).retain(|addr| !allocated.contains(addr));
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                for server in servers {
                    let _ = server.close().await;
                }
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use webrtc::turn::relay::RelayAddressGenerator;

    use super::*;

    #[tokio::test]
    async fn a_released_relay_address_is_direct_again_when_reused() {
        let allocated = Arc::new(Mutex::new(Vec::new()));
        let relays = RecordedRelays {
            inner: webrtc::turn::relay::relay_range::RelayAddressGeneratorRanges {
                relay_address: "127.0.0.1".parse().expect("ip"),
                min_port: TEST_RELAY_PORTS_START + 4_500,
                max_port: u16::MAX,
                max_retries: 10,
                address: "127.0.0.1".into(),
                net: Arc::new(webrtc::util::vnet::net::Net::new(None)),
            },
            allocated: Arc::clone(&allocated),
        };
        let (conn, relayed) = relays.allocate_conn(true, 0).await.expect("allocate");
        assert!(is_test_relay(&relayed), "a live allocation is a relay");
        // The allocation is released: its socket closes, and the OS may
        // hand the port to a direct socket.
        conn.close().await.expect("close");
        drop(conn);
        assert!(!is_test_relay(&relayed), "a released allocation is not a relay");
        assert!(allocated.lock().unwrap_or_else(PoisonError::into_inner).is_empty());
        let direct = std::net::UdpSocket::bind(relayed).expect("rebind the released address");
        assert!(!is_test_relay(&direct.local_addr().expect("addr")), "the reused address is direct");
    }
}
