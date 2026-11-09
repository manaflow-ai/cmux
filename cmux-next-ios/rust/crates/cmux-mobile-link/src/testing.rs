//! An in-process stand-in for the backend's signaling Durable Object, for
//! tests: same routes, same JSON, same admission rule (a signal reaches a
//! device of the sender's own user, or answers an existing session), and
//! the same refusal of an older peer's binary relay frames
//! (`relay_retired`). The bearer token is `user:<userId>`.
//!
//! [`TestTurn`] is a TURN server on loopback, over UDP and over TLS (a
//! self-signed certificate the dial options trust).

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
            answer_http(&mut stream, &head, &ice).await;
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
                        if existing.is_none() {
                            state.sessions.insert(session, (device.clone(), to));
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

async fn answer_http(stream: &mut tokio::net::TcpStream, head: &str, ice: &[crate::api::IceServer]) {
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
        let mut servers = vec![json!({"urls": ["stun:stun.cloudflare.com:3478"]})];
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

/// TURN relayed ports of a [`TestTurn`] start here (each server takes 100):
/// above Linux's ephemeral range (32768 to 60999), so no tunnel socket
/// ever has a port a test takes for a relayed one.
pub const TEST_RELAY_PORTS_START: u16 = 61_000;
static NEXT_RELAY_PORTS: std::sync::atomic::AtomicU16 = std::sync::atomic::AtomicU16::new(0);

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
    /// While set, the UDP port drops everything (a network that blocks UDP
    /// to the TURN server).
    udp_blocked: Arc<std::sync::atomic::AtomicBool>,
}

/// The TURN server's UDP socket, which drops everything while `blocked`.
struct BlockableUdp {
    socket: tokio::net::UdpSocket,
    blocked: Arc<std::sync::atomic::AtomicBool>,
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
            if !self.blocked.load(std::sync::atomic::Ordering::Relaxed) {
                return Ok((len, from));
            }
        }
    }

    async fn send(&self, buf: &[u8]) -> webrtc::util::Result<usize> {
        Ok(self.socket.send(buf).await?)
    }

    async fn send_to(&self, buf: &[u8], target: std::net::SocketAddr) -> webrtc::util::Result<usize> {
        if self.blocked.load(std::sync::atomic::Ordering::Relaxed) {
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
        let udp_blocked = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let udp = BlockableUdp {
            socket: tokio::net::UdpSocket::bind("127.0.0.1:0").await.expect("bind TURN UDP"),
            blocked: Arc::clone(&udp_blocked),
        };
        let udp_port = udp.socket.local_addr().expect("addr").port();
        let server = Self::server(Arc::new(udp), relay_ports.clone()).await;
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
        let mut tasks = Vec::new();
        let mut stream_port = |secure: bool| {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind TURN TCP");
            listener.set_nonblocking(true).expect("nonblocking");
            let port = listener.local_addr().expect("addr").port();
            let listener = TcpListener::from_std(listener).expect("listener");
            let (acceptor, servers, ports, streams) =
                (acceptor.clone(), Arc::clone(&servers), relay_ports.clone(), Arc::clone(&streams));
            tasks.push(tokio::spawn(async move {
                while let Ok((tcp, client)) = listener.accept().await {
                    let (acceptor, servers, ports, streams) =
                        (acceptor.clone(), Arc::clone(&servers), ports.clone(), Arc::clone(&streams));
                    tokio::spawn(async move {
                        let _ = tcp.set_nodelay(true);
                        let Ok(local) = tcp.local_addr() else { return };
                        let conn: Arc<dyn webrtc::util::Conn + Send + Sync> = if secure {
                            let Ok(tls) = acceptor.accept(tcp).await else { return };
                            Arc::new(crate::dial::turn::StreamConn::new(tls, local, client))
                        } else {
                            Arc::new(crate::dial::turn::StreamConn::new(tcp, local, client))
                        };
                        streams.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        let server = Self::server(conn, ports).await;
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
        Self { ice, roots: Arc::new(roots), relay_ports, servers, tasks, streams, udp_blocked }
    }

    async fn server(
        conn: Arc<dyn webrtc::util::Conn + Send + Sync>,
        ports: std::ops::RangeInclusive<u16>,
    ) -> webrtc::turn::server::Server {
        webrtc::turn::server::Server::new(webrtc::turn::server::config::ServerConfig {
            conn_configs: vec![webrtc::turn::server::config::ConnConfig {
                conn,
                relay_addr_generator: Box::new(
                    webrtc::turn::relay::relay_range::RelayAddressGeneratorRanges {
                        relay_address: "127.0.0.1".parse().expect("ip"),
                        min_port: *ports.start(),
                        max_port: *ports.end(),
                        max_retries: 10,
                        address: "127.0.0.1".into(),
                        net: Arc::new(webrtc::util::vnet::net::Net::new(None)),
                    },
                ),
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
        self.udp_blocked.store(blocked, std::sync::atomic::Ordering::Relaxed);
    }

    /// Stream connections (TLS or TCP) the server accepted so far.
    pub fn stream_connections(&self) -> usize {
        self.streams.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// Whether `addr` is one of this server's relayed addresses.
    pub fn is_relayed(&self, addr: &std::net::SocketAddr) -> bool {
        addr.ip().is_loopback() && self.relay_ports.contains(&addr.port())
    }
}

impl Drop for TestTurn {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
        let servers = std::mem::take(&mut *self.servers.lock().unwrap_or_else(PoisonError::into_inner));
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                for server in servers {
                    let _ = server.close().await;
                }
            });
        }
    }
}
