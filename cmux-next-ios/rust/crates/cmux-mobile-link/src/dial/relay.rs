//! The link's WebSocket relay (PROTOCOL.md "WebSocket relay"): WireGuard
//! datagrams in relay frames (`cmux_transport::relay_frame`, the frame the
//! host relay uses) over one WebSocket to the mobile Worker, on the host the
//! app already signs in and signals through. It is the last way a session
//! reaches its peer, after plain UDP and TURN (over UDP, then TLS on 443),
//! for networks that let only cmux's own domains out, or only real HTTP
//! inside TLS through an inspecting proxy: the join is a plain HTTP/1.1
//! `GET` with `Upgrade: websocket` on 443, the same as the signaling socket.
//!
//! The relay is one more carrier of the session's WireGuard tunnel
//! ([`super::wireguard`]): the Worker sees ciphertext and two device ids,
//! never the link. A side joins when nothing it tried reached the peer
//! (or the peer asks, or a debug option forces it), and leaves once a
//! better route carries both directions again.

use std::future::Future;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use cmux_transport::relay_frame::{FrameKind, PeerId, RELAY_FRAME_MAX_PAYLOAD, RelayFrame};
use futures_util::{SinkExt, StreamExt};
use serde::Serialize;
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use crate::build_space::BuildSpace;
use crate::class_queue::{ClassQueue, Queued, SendClass};

/// The WebSocket subprotocol a join offers (the Worker selects it).
pub const SUBPROTOCOL: &str = "cmux-relay.v1";
/// The header a join presents this device's relay ticket in: the
/// `relayTicket` the service stamped on the session's signals to this device.
pub const TICKET_HEADER: &str = "x-cmux-relay-ticket";
/// The relay's stand-in for the peer's address: a route through the relay
/// names no real address, and this one is never a peer endpoint.
pub const RELAY_PEER: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 443);
/// Bound on the join: TCP, TLS and the upgrade.
pub const JOIN_WAIT: Duration = Duration::from_secs(10);
/// The application ping (answered by the relay without waking it), so a
/// proxy or NAT that drops idle connections keeps this one.
const PING_EVERY: Duration = Duration::from_secs(20);
/// Nothing at all from the relay this long (pongs included): the socket is
/// dead (a middlebox that black-holed it without a reset).
const SILENT_DEAD: Duration = Duration::from_secs(50);
/// A write that takes longer than this means the stream is stuck.
const WRITE_WAIT: Duration = Duration::from_secs(10);
/// Datagrams received before new ones are dropped.
const INBOUND_QUEUE: usize = 1024;
/// The application ping and its answer (the signaling socket's, PROTOCOL.md).
const APP_PING: &str = "ping";

/// A current access token, asked for at each join (a session outlives any
/// one token).
pub type TokenFuture = Pin<Box<dyn Future<Output = Option<String>> + Send>>;

/// Where this side joins the relay, and as whom.
#[derive(Clone)]
pub struct RelayEndpoint {
    /// The Worker's base URL (`https://mobile-api.cmux.dev`), the one
    /// signaling uses.
    pub base_url: String,
    /// A dev build's build space, sent like on every other request.
    pub build_space: Option<BuildSpace>,
    /// This side's device id: the relay admits the two devices of the
    /// session.
    pub device_id: String,
    token: Arc<dyn Fn() -> TokenFuture + Send + Sync>,
}

impl std::fmt::Debug for RelayEndpoint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RelayEndpoint")
            .field("base_url", &self.base_url)
            .field("device_id", &self.device_id)
            .finish_non_exhaustive()
    }
}

impl RelayEndpoint {
    /// An endpoint that asks `token` for an access token at each join.
    pub fn new(
        base_url: impl Into<String>,
        build_space: Option<BuildSpace>,
        device_id: impl Into<String>,
        token: impl Fn() -> TokenFuture + Send + Sync + 'static,
    ) -> Self {
        Self { base_url: base_url.into(), build_space, device_id: device_id.into(), token: Arc::new(token) }
    }

    /// An endpoint with one fixed token (the phone's dial carries a fresh one).
    pub fn with_token(
        base_url: impl Into<String>,
        build_space: Option<BuildSpace>,
        device_id: impl Into<String>,
        token: impl Into<String>,
    ) -> Self {
        let token: String = token.into();
        Self::new(base_url, build_space, device_id, move || {
            let token = token.clone();
            Box::pin(async move { Some(token) })
        })
    }

    /// The host a join connects to (for the network diagnosis).
    pub fn host(&self) -> String {
        let rest = self.base_url.split_once("://").map_or(self.base_url.as_str(), |(_, rest)| rest);
        rest.split(['/', '?']).next().unwrap_or_default().to_owned()
    }
}

/// `https://host` → `wss://host/v1/relay/<session>?deviceId=<id>`.
pub fn relay_url(base_url: &str, session_id: &str, device_id: &str) -> Option<String> {
    let base = base_url.trim_end_matches('/');
    let ws = if let Some(rest) = base.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = base.strip_prefix("http://") {
        format!("ws://{rest}")
    } else if base.starts_with("ws://") || base.starts_with("wss://") {
        base.to_owned()
    } else {
        return None;
    };
    let id_ok = |text: &str| !text.is_empty() && text.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-');
    (id_ok(session_id) && id_ok(device_id))
        .then(|| format!("{ws}/v1/relay/{session_id}?deviceId={device_id}"))
}

/// Why a join failed: what the network diagnosis tells the person.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum RelayFailure {
    /// No access token to join with.
    NoToken,
    /// The service answered and refused (`401` a token, `403`
    /// `not_in_session`, `404` an older service without the relay, `503`
    /// `relay_off`), or something between answered with this status (a
    /// proxy's `403`).
    Refused { status: u16, code: String },
    /// The TLS handshake failed: a certificate this side does not trust,
    /// as a TLS-inspecting proxy presents.
    TlsRejected { detail: String },
    /// No connection: DNS, TCP refused or reset, no route.
    Unreachable { detail: String },
    /// No answer within [`JOIN_WAIT`].
    Timeout,
}

impl RelayFailure {
    /// A short line for logs and the diagnosis.
    pub fn describe(&self) -> String {
        match self {
            Self::NoToken => "no access token".into(),
            Self::Refused { status, code } if code.is_empty() => format!("refused ({status})"),
            Self::Refused { status, code } => format!("refused ({status} {code})"),
            Self::TlsRejected { detail } => format!("TLS rejected: {detail}"),
            Self::Unreachable { detail } => format!("unreachable: {detail}"),
            Self::Timeout => format!("no answer in {} s", JOIN_WAIT.as_secs()),
        }
    }

    /// The relay is turned off (`503 relay_off`) or absent (`404`, an older
    /// service): retrying in this session does not help.
    pub fn is_final(&self) -> bool {
        matches!(self, Self::Refused { status: 404 | 503, .. } | Self::Refused { status: 403, .. })
    }
}

/// The failed upgrade as a [`RelayFailure`].
fn classify(error: tokio_tungstenite::tungstenite::Error) -> RelayFailure {
    use tokio_tungstenite::tungstenite::Error;
    match error {
        Error::Http(response) => {
            let status = response.status().as_u16();
            let code = response
                .body()
                .as_deref()
                .and_then(|body| serde_json::from_slice::<serde_json::Value>(body).ok())
                .and_then(|value| {
                    value["error"]["code"].as_str().or_else(|| value["error"].as_str()).map(str::to_owned)
                })
                .unwrap_or_default();
            RelayFailure::Refused { status, code }
        }
        Error::Tls(error) => RelayFailure::TlsRejected { detail: error.to_string() },
        Error::Io(error) => match error.get_ref().and_then(|inner| inner.downcast_ref::<rustls::Error>()) {
            Some(tls) => RelayFailure::TlsRejected { detail: tls.to_string() },
            None => RelayFailure::Unreachable { detail: format!("{:?}: {error}", error.kind()) },
        },
        other => RelayFailure::Unreachable { detail: other.to_string() },
    }
}

/// A joined relay socket as a carrier of the session's tunnel: what is
/// queued goes to the peer's socket, by class (the TURN carrier's queue), packed
/// into as few frames as fit; what the peer sends arrives on `inbound`.
pub struct RelayCarrier {
    queue: Arc<ClassQueue>,
    pub(crate) inbound: mpsc::Receiver<Bytes>,
    dead: watch::Receiver<bool>,
    peer_online: watch::Receiver<bool>,
    tasks: Vec<JoinHandle<()>>,
    /// When the join answered.
    pub joined_at: Instant,
}

impl std::fmt::Debug for RelayCarrier {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RelayCarrier").field("dead", &self.is_dead()).finish_non_exhaustive()
    }
}

impl RelayCarrier {
    /// Join session `session_id`'s relay as `endpoint`'s device, with its
    /// `ticket` for the session; only frames that name `peer_device` (the
    /// relay stamps the sender) are taken.
    pub async fn join(
        endpoint: &RelayEndpoint,
        session_id: &str,
        peer_device: &str,
        ticket: Option<&str>,
    ) -> Result<Self, RelayFailure> {
        crate::install_crypto_provider();
        let url = relay_url(&endpoint.base_url, session_id, &endpoint.device_id)
            .ok_or_else(|| RelayFailure::Unreachable { detail: "not a relay URL".into() })?;
        let token = (endpoint.token)().await.ok_or(RelayFailure::NoToken)?;
        let mut request = url
            .into_client_request()
            .map_err(|error| RelayFailure::Unreachable { detail: error.to_string() })?;
        let headers = request.headers_mut();
        let header = |text: &str| {
            text.parse().map_err(|_| RelayFailure::Unreachable { detail: "not a header value".into() })
        };
        headers.insert("authorization", header(&format!("Bearer {token}"))?);
        headers.insert("sec-websocket-protocol", header(SUBPROTOCOL)?);
        if let Some(ticket) = ticket {
            headers.insert(TICKET_HEADER, header(ticket)?);
        }
        if let Some(space) = &endpoint.build_space {
            headers.insert(crate::build_space::HEADER, header(space.as_str())?);
        }
        let (socket, _) = tokio::time::timeout(
            JOIN_WAIT,
            cmux_egress::ws::connect_async(request, "cmux_mobile_link::dial::relay"),
        )
        .await
        .map_err(|_| RelayFailure::Timeout)?
        .map_err(classify)?;
        let expected = uuid::Uuid::parse_str(peer_device).ok().map(|id| PeerId(*id.as_bytes()));
        Ok(Self::run(socket, expected))
    }

    fn run<S>(socket: tokio_tungstenite::WebSocketStream<S>, expected: Option<PeerId>) -> Self
    where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
    {
        let (mut sink, mut source) = socket.split();
        let queue = Arc::new(ClassQueue::default());
        let (inbound_tx, inbound) = mpsc::channel(INBOUND_QUEUE);
        let (dead_tx, dead) = watch::channel(false);
        let dead_tx = Arc::new(dead_tx);
        let (peer_tx, peer_online) = watch::channel(false);
        let writer = {
            let (queue, dead_tx) = (Arc::clone(&queue), Arc::clone(&dead_tx));
            tokio::spawn(async move {
                let mut ping = tokio::time::interval_at(Instant::now() + PING_EVERY, PING_EVERY);
                let mut carry: Option<Queued> = None;
                loop {
                    let first = match carry.take() {
                        Some(item) => item,
                        None => tokio::select! {
                            item = queue.next() => match item {
                                Some(item) => item,
                                None => break,
                            },
                            _ = ping.tick() => {
                                let sent = tokio::time::timeout(WRITE_WAIT, sink.send(Message::Text(APP_PING.into()))).await;
                                if !matches!(sent, Ok(Ok(()))) {
                                    break;
                                }
                                continue;
                            }
                        },
                    };
                    // Every datagram that is ready now, in one frame.
                    let mut batch = vec![first.datagram];
                    let mut size = 2 + batch[0].len();
                    while let Some(next) = queue.try_next() {
                        if size + 2 + next.datagram.len() > RELAY_FRAME_MAX_PAYLOAD {
                            carry = Some(next);
                            break;
                        }
                        size += 2 + next.datagram.len();
                        batch.push(next.datagram);
                    }
                    let records: Vec<&[u8]> = batch.iter().map(|datagram| &datagram[..]).collect();
                    let Ok(frame) =
                        RelayFrame::datagrams(PeerId([0; 16]), &records).and_then(|frame| frame.encode())
                    else {
                        // A datagram no frame can carry (empty, or larger than a frame).
                        continue;
                    };
                    tracing::trace!(datagrams = records.len(), bytes = frame.len(), "relay frame out");
                    let sent =
                        tokio::time::timeout(WRITE_WAIT, sink.send(Message::Binary(frame.into()))).await;
                    if !matches!(sent, Ok(Ok(()))) {
                        tracing::debug!("relay write failed or stalled; the relay socket is dead");
                        break;
                    }
                }
                queue.close();
                dead_tx.send_replace(true);
                let _ = sink.close().await;
            })
        };
        let reader = {
            let (queue, dead_tx) = (Arc::clone(&queue), Arc::clone(&dead_tx));
            tokio::spawn(async move {
                let mut heard = Instant::now();
                loop {
                    let next = tokio::select! {
                        next = source.next() => next,
                        () = tokio::time::sleep_until(heard + SILENT_DEAD) => {
                            tracing::debug!("relay socket silent; dead");
                            break;
                        }
                    };
                    let message = match next {
                        Some(Ok(message)) => message,
                        Some(Err(error)) => {
                            tracing::debug!(%error, "relay socket failed");
                            break;
                        }
                        None => break,
                    };
                    heard = Instant::now();
                    match message {
                        Message::Binary(bytes) => {
                            let Ok(frame) = RelayFrame::decode(&bytes) else { continue };
                            if frame.kind != FrameKind::Datagrams
                                || expected.is_some_and(|peer| peer != frame.peer)
                            {
                                tracing::debug!(kind = ?frame.kind, "relay frame from another than the peer dropped");
                                continue;
                            }
                            let Ok(datagrams) = frame.split_datagrams() else { continue };
                            for datagram in datagrams {
                                match inbound_tx.try_send(Bytes::copy_from_slice(datagram)) {
                                    Ok(()) | Err(mpsc::error::TrySendError::Full(_)) => {}
                                    Err(mpsc::error::TrySendError::Closed(_)) => return,
                                }
                            }
                        }
                        Message::Text(text) => {
                            let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
                                continue;
                            };
                            match value["type"].as_str() {
                                Some("joined") => {
                                    peer_tx.send_replace(value["peer"].as_bool().unwrap_or(false));
                                }
                                Some("peer") => {
                                    peer_tx.send_replace(value["online"].as_bool().unwrap_or(false));
                                }
                                Some("error") => {
                                    tracing::debug!(code = %value["code"], "relay refused a frame");
                                }
                                _ => {}
                            }
                        }
                        Message::Close(frame) => {
                            tracing::debug!(?frame, "relay socket closed by the service");
                            break;
                        }
                        _ => {}
                    }
                }
                queue.close();
                dead_tx.send_replace(true);
            })
        };
        Self { queue, inbound, dead, peer_online, tasks: vec![writer, reader], joined_at: Instant::now() }
    }

    /// Queue one datagram to the peer, in `class` (dropped past its class's
    /// bound; WireGuard and TCP retransmit).
    pub fn send(&self, datagram: &[u8], class: SendClass) {
        self.queue.push(Queued { datagram: Bytes::copy_from_slice(datagram), to: RELAY_PEER }, class);
    }

    /// Whether the socket failed, closed or went silent.
    pub fn is_dead(&self) -> bool {
        *self.dead.borrow()
    }

    /// Becomes `true` when the socket fails.
    pub fn dead(&self) -> watch::Receiver<bool> {
        self.dead.clone()
    }

    /// Whether the relay last said the peer's socket is joined.
    pub fn peer_online(&self) -> bool {
        *self.peer_online.borrow()
    }

    /// The relay's word on the peer's socket, as it changes.
    pub fn peer_online_watch(&self) -> watch::Receiver<bool> {
        self.peer_online.clone()
    }

    /// Debug and tests: close the socket, as a proxy that resets it would.
    pub fn kill(&self) {
        self.queue.close();
    }
}

impl Drop for RelayCarrier {
    fn drop(&mut self) {
        self.queue.close();
        for task in &self.tasks {
            task.abort();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_relay_url_is_the_signaling_host_with_the_session_and_device() {
        let session = "6f1c2a8e-1b7d-4c2e-9a51-3b9f0d2e7c11";
        let device = "0a6b7c8d-1111-4222-8333-944455566677";
        assert_eq!(
            relay_url("https://mobile-api.cmux.dev/", session, device).as_deref(),
            Some(
                "wss://mobile-api.cmux.dev/v1/relay/6f1c2a8e-1b7d-4c2e-9a51-3b9f0d2e7c11?deviceId=0a6b7c8d-1111-4222-8333-944455566677"
            )
        );
        assert_eq!(
            relay_url("http://127.0.0.1:9000", session, device).as_deref(),
            Some(&*format!("ws://127.0.0.1:9000/v1/relay/{session}?deviceId={device}"))
        );
        assert_eq!(relay_url("ftp://x", session, device), None);
        // Ids go into the path and query as they are: nothing but hex and dashes.
        assert_eq!(relay_url("https://x", "../../v1/ice", device), None);
        assert_eq!(relay_url("https://x", session, "a&b=c"), None);
    }

    #[test]
    fn the_endpoint_names_its_host_and_hides_its_token() {
        let endpoint =
            RelayEndpoint::with_token("https://mobile-api.cmux.dev/x", None, "dev", "secret-token");
        assert_eq!(endpoint.host(), "mobile-api.cmux.dev");
        assert!(!format!("{endpoint:?}").contains("secret-token"));
    }

    #[test]
    fn a_refusal_that_retrying_cannot_change_is_final() {
        let refused = |status, code: &str| RelayFailure::Refused { status, code: code.into() };
        assert!(refused(503, "relay_off").is_final());
        assert!(refused(404, "not_found").is_final());
        assert!(refused(403, "not_in_session").is_final());
        assert!(!refused(401, "unauthorized").is_final());
        assert!(!refused(502, "").is_final());
        assert!(!RelayFailure::Timeout.is_final());
        assert_eq!(refused(503, "relay_off").describe(), "refused (503 relay_off)");
    }

    /// The writer packs what is queued into frames of at most 16 KiB, by
    /// class, and the reader takes only frames from the expected peer.
    #[tokio::test]
    async fn datagrams_cross_in_packed_frames_and_only_from_the_peer() {
        let (client, server) = tokio::io::duplex(1 << 20);
        let (client, server) = tokio::join!(
            tokio_tungstenite::client_async("ws://relay.test/x", client),
            tokio_tungstenite::accept_async(server)
        );
        let (client, _) = client.unwrap();
        let mut server = server.unwrap();
        let peer = PeerId([7; 16]);
        let mut carrier = RelayCarrier::run(client, Some(peer));
        // Enough full-size datagrams to need two frames.
        for i in 0..20u8 {
            carrier.send(&[i; 1200], SendClass::Bulk);
        }
        carrier.send(&[0xaa; 32], SendClass::Control);
        let mut received = Vec::new();
        let mut frames = 0;
        while received.len() < 21 {
            let Some(Ok(Message::Binary(bytes))) = server.next().await else { panic!("no frame") };
            let frame = RelayFrame::decode(&bytes).unwrap();
            assert!(frame.payload.len() <= RELAY_FRAME_MAX_PAYLOAD);
            frames += 1;
            received.extend(frame.split_datagrams().unwrap().into_iter().map(<[u8]>::to_vec));
        }
        assert!((2..=4).contains(&frames), "{frames} frames");
        assert_eq!(received.iter().map(Vec::len).sum::<usize>(), 20 * 1200 + 32);
        // A frame from someone else is dropped; the peer's arrives.
        let stranger = RelayFrame::datagrams(PeerId([9; 16]), &[b"no"]).unwrap().encode().unwrap();
        let from_peer = RelayFrame::datagrams(peer, &[b"yes", b"too"]).unwrap().encode().unwrap();
        server.send(Message::Binary(stranger.into())).await.unwrap();
        server.send(Message::Text(r#"{"type":"peer","online":true}"#.into())).await.unwrap();
        server.send(Message::Binary(from_peer.into())).await.unwrap();
        assert_eq!(&carrier.inbound.recv().await.unwrap()[..], b"yes");
        assert_eq!(&carrier.inbound.recv().await.unwrap()[..], b"too");
        assert!(carrier.peer_online());
        assert!(!carrier.is_dead());
        // The service closes the socket: the carrier is dead.
        server.close(None).await.unwrap();
        let mut dead = carrier.dead();
        tokio::time::timeout(Duration::from_secs(5), dead.wait_for(|dead| *dead)).await.unwrap().unwrap();
    }
}
