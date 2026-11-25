//! An in-process hub relay for tests: `GET /v1/hub/:sessionId` with the
//! real [`HubRelayRule`], answering as the Worker's `HubRelay` does
//! (cmux-next-ios/backend/src/hub-relay.ts), or as each older relay a hub
//! client must fall back from ([`FakeHubMode`]). It checks no token: the
//! Worker's admission rules have their own tests.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, PoisonError};

use cmux_transport::hub::{HUB_SUBPROTOCOL, HubHeader, HubRelayRule, HubRole, HubRoute};
use cmux_transport::{FrameKind, PeerId, RelayFrame};
use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};

/// Which relay the fake plays.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FakeHubMode {
    /// Today's hub.
    Hub,
    /// A Worker from before the hub: 404.
    NoRoute,
    /// The kill switch: 503 `hub_off`.
    Off,
    /// Upgrades but echoes no subprotocol.
    NoEcho,
    /// Upgrades, echoes, then answers every frame `bad_frame:kind` (a two-party relay).
    KindRefused,
}

#[derive(Default)]
struct Room {
    rule: HubRelayRule,
    sources: HashMap<u8, (u64, [u8; 16], mpsc::UnboundedSender<Message>)>,
    viewers: Vec<(u64, mpsc::UnboundedSender<Message>)>,
}

#[derive(Default)]
struct State {
    rooms: HashMap<uuid::Uuid, Room>,
    next_socket: u64,
}

/// What the relay saw, for assertions.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct FakeHubStats {
    pub forwarded: u64,
    pub dropped: u64,
}

pub struct FakeHub {
    addr: SocketAddr,
    state: Arc<Mutex<State>>,
    task: tokio::task::JoinHandle<()>,
}

impl FakeHub {
    pub async fn start(mode: FakeHubMode) -> std::io::Result<Self> {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let addr = listener.local_addr()?;
        let state = Arc::new(Mutex::new(State::default()));
        let shared = Arc::clone(&state);
        let task = tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                let _ = stream.set_nodelay(true);
                tokio::spawn(serve(stream, mode, Arc::clone(&shared)));
            }
        });
        Ok(Self { addr, state, task })
    }

    pub fn addr(&self) -> SocketAddr {
        self.addr
    }

    pub fn base_url(&self) -> String {
        format!("http://{}", self.addr)
    }

    pub fn stats(&self, session: &uuid::Uuid) -> FakeHubStats {
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state
            .rooms
            .get(session)
            .map(|room| FakeHubStats { forwarded: room.rule.forwarded, dropped: room.rule.dropped })
            .unwrap_or_default()
    }
}

impl Drop for FakeHub {
    fn drop(&mut self) {
        self.task.abort();
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Side {
    Source(HubRole),
    Viewer,
}

fn parse(path_and_query: &str) -> Option<(uuid::Uuid, [u8; 16], Side)> {
    let (path, query) = path_and_query.split_once('?')?;
    let session = uuid::Uuid::parse_str(path.strip_prefix("/v1/hub/")?).ok()?;
    let (mut device, mut side) = (None, None);
    for pair in query.split('&') {
        match pair.split_once('=')? {
            ("deviceId", v) => device = Some(*uuid::Uuid::parse_str(v).ok()?.as_bytes()),
            ("role", "mac") => side = Some(Side::Source(HubRole::Mac)),
            ("role", "vm") => side = Some(Side::Source(HubRole::Vm)),
            ("role", "viewer") => side = Some(Side::Viewer),
            _ => {}
        }
    }
    Some((session, device?, side?))
}

fn refuse(status: u16, body: &str) -> ErrorResponse {
    let mut response = ErrorResponse::new(Some(body.to_owned()));
    *response.status_mut() =
        tokio_tungstenite::tungstenite::http::StatusCode::from_u16(status).unwrap_or_default();
    response
}

fn notice(value: serde_json::Value) -> Message {
    Message::Text(value.to_string().into())
}

async fn serve(stream: tokio::net::TcpStream, mode: FakeHubMode, state: Arc<Mutex<State>>) {
    let mut joined = None;
    #[allow(clippy::result_large_err)] // tungstenite's handshake callback signature
    let callback = |request: &Request, mut response: Response| -> Result<Response, ErrorResponse> {
        match mode {
            FakeHubMode::NoRoute => return Err(refuse(404, "not found")),
            FakeHubMode::Off => return Err(refuse(503, r#"{"error":"hub_off"}"#)),
            _ => {}
        }
        let target = request.uri().path_and_query().map(|p| p.as_str()).unwrap_or_default();
        let Some(parsed) = parse(target) else { return Err(refuse(400, "bad_hub")) };
        let offered = request
            .headers()
            .get("sec-websocket-protocol")
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v.split(',').any(|p| p.trim() == HUB_SUBPROTOCOL));
        if !offered {
            return Err(refuse(426, "cmux-hub.v1 required"));
        }
        if mode != FakeHubMode::NoEcho {
            response.headers_mut().insert("sec-websocket-protocol", HUB_SUBPROTOCOL.parse().expect("header"));
        }
        joined = Some(parsed);
        Ok(response)
    };
    let Ok(socket) = tokio_tungstenite::accept_hdr_async(stream, callback).await else { return };
    let Some((session, device, side)) = joined else { return };
    let (mut sink, mut incoming) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();
    let writer = tokio::spawn(async move {
        while let Some(message) = rx.recv().await {
            if sink.send(message).await.is_err() {
                break;
            }
        }
    });

    let id = {
        let mut state = state.lock().unwrap_or_else(PoisonError::into_inner);
        state.next_socket += 1;
        let id = state.next_socket;
        let room = state.rooms.entry(session).or_default();
        let online = |role: HubRole| room.sources.contains_key(&(role as u8));
        let _ = tx.send(notice(json!({
            "type": "joined", "hub": 1,
            "sources": { "mac": online(HubRole::Mac), "vm": online(HubRole::Vm) },
        })));
        match side {
            Side::Viewer => room.viewers.push((id, tx.clone())),
            Side::Source(role) => {
                if let Some((_, _, old)) = room.sources.insert(role as u8, (id, device, tx.clone())) {
                    let _ = old.send(Message::Close(None));
                }
                for (_, viewer) in &room.viewers {
                    let _ = viewer
                        .send(notice(json!({"type": "source", "role": role_name(role), "online": true})));
                }
            }
        }
        id
    };

    while let Some(Ok(message)) = incoming.next().await {
        let Message::Binary(bytes) = message else { continue };
        if mode == FakeHubMode::KindRefused {
            let _ = tx.send(notice(json!({"type": "error", "code": "bad_frame:kind"})));
            continue;
        }
        let Side::Source(role) = side else {
            let _ = tx.send(notice(json!({"type": "error", "code": "bad_hub:viewer"})));
            continue;
        };
        let Ok(mut frame) = RelayFrame::decode(&bytes) else {
            let _ = tx.send(notice(json!({"type": "error", "code": "bad_frame:bad_hub"})));
            continue;
        };
        if frame.kind != FrameKind::Hub {
            let _ = tx.send(notice(json!({"type": "error", "code": "bad_frame:kind"})));
            continue;
        }
        let Ok(header) = HubHeader::decode(&frame.payload) else { continue };
        if header.source != role {
            let _ = tx.send(notice(json!({"type": "error", "code": "bad_hub:role"})));
            continue;
        }
        if header.session != *session.as_bytes() {
            let _ = tx.send(notice(json!({"type": "error", "code": "bad_hub:session"})));
            continue;
        }
        frame.peer = PeerId(device);
        let Ok(out) = frame.encode() else { continue };
        let mut state = state.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(room) = state.rooms.get_mut(&session) else { continue };
        match room.rule.route(&header) {
            HubRoute::Viewers => {
                for (_, viewer) in &room.viewers {
                    let _ = viewer.send(Message::Binary(out.clone().into()));
                }
            }
            HubRoute::Source(to) => {
                if let Some((_, _, source)) = room.sources.get(&(to as u8)) {
                    let _ = source.send(Message::Binary(out.into()));
                }
            }
            HubRoute::Drop => {}
        }
    }

    {
        let mut state = state.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(room) = state.rooms.get_mut(&session) {
            match side {
                Side::Viewer => room.viewers.retain(|(v, _)| *v != id),
                Side::Source(role) => {
                    if room.sources.get(&(role as u8)).is_some_and(|(s, _, _)| *s == id) {
                        room.sources.remove(&(role as u8));
                        for (_, viewer) in &room.viewers {
                            let _ = viewer.send(notice(
                                json!({"type": "source", "role": role_name(role), "online": false}),
                            ));
                        }
                    }
                }
            }
        }
    }
    drop(tx);
    let _ = writer.await;
}

fn role_name(role: HubRole) -> &'static str {
    match role {
        HubRole::Mac => "mac",
        HubRole::Vm => "vm",
    }
}
