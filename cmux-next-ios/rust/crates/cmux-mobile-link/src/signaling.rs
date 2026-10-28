//! The signaling WebSocket (PROTOCOL.md "Signaling WebSocket"): JSON text
//! frames for hello, presence, signal and error. (The binary WireGuard relay
//! frames are retired: a tunnel without a UDP path uses TURN over TLS.)
//! One task owns the socket; envelopes are routed to the dial or
//! answer that owns their `sessionId`. The first signal of a new session
//! (`webrtc-offer`, `wg-init`) opens that session's subscription atomically
//! and is handed to [`SignalingClient::next_session`] (a Mac answering
//! dials), so trickled signals that follow it are never lost. Other signals
//! for unknown sessions are dropped.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};

use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use tokio::sync::{broadcast, mpsc};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use crate::send_queue::{SendQueue, Signal};

/// A Mac as the backend reports it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MacPresence {
    pub device_id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub online: bool,
    #[serde(default)]
    pub last_seen_at: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_user_id: Option<String>,
}

/// `payload` of a `signal` message, tagged by `kind`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum SignalPayload {
    #[serde(rename = "webrtc-offer")]
    WebrtcOffer {
        sdp: String,
        /// Link lanes this side supports beyond the main stream (PROTOCOL.md
        /// "Lanes"); absent from older peers.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        lanes: Vec<String>,
        /// A media session for the WireGuard link with this session id
        /// (PROTOCOL.md "Media session"): a peer connection that carries
        /// only the media lane, beside that link. Absent: the offer starts a
        /// link of its own.
        #[serde(rename = "mediaFor", default, skip_serializing_if = "Option::is_none")]
        media_for: Option<String>,
    },
    #[serde(rename = "webrtc-answer")]
    WebrtcAnswer {
        sdp: String,
        /// Link lanes this side supports beyond the main stream (PROTOCOL.md
        /// "Lanes"); absent from older peers.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        lanes: Vec<String>,
    },
    #[serde(rename = "webrtc-ice")]
    WebrtcIce {
        candidate: String,
        #[serde(rename = "sdpMid", default)]
        sdp_mid: Option<String>,
        #[serde(rename = "sdpMLineIndex", default)]
        sdp_m_line_index: Option<u16>,
    },
    #[serde(rename = "wg-init")]
    WgInit {
        #[serde(rename = "publicKey")]
        public_key: String,
        endpoints: Vec<String>,
        #[serde(rename = "overlayIP")]
        overlay_ip: String,
        /// Link lanes this side supports beyond the main stream (PROTOCOL.md
        /// "Lanes"); absent from older peers.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        lanes: Vec<String>,
        /// Which of `endpoints` are the dialer's TURN relayed addresses. The
        /// Mac sends plain UDP to them like any endpoint, so only this tells
        /// it that such a route is TURN, not direct (its path label); absent
        /// from older phones.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        relayed: Vec<String>,
        /// Which of `relayed` reach their TURN server over TCP or TLS (the
        /// path label `turn-tls`); absent from older phones.
        #[serde(rename = "relayedTls", default, skip_serializing_if = "Vec::is_empty")]
        relayed_tls: Vec<String>,
        /// The WireGuard protocol version ([`WG_VERSION`]); absent (0) from
        /// older peers, which still send relay frames and their marker.
        #[serde(default, skip_serializing_if = "is_zero")]
        version: u32,
    },
    #[serde(rename = "wg-resp")]
    WgResp {
        #[serde(rename = "publicKey")]
        public_key: String,
        endpoints: Vec<String>,
        #[serde(rename = "overlayIP")]
        overlay_ip: String,
        /// Link lanes this side supports beyond the main stream (PROTOCOL.md
        /// "Lanes"); absent from older peers.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        lanes: Vec<String>,
        /// Which of `endpoints` are the Mac's own TURN relayed addresses (a
        /// Mac whose network blocks UDP allocates one); absent otherwise.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        relayed: Vec<String>,
        /// Which of `relayed` reach their TURN server over TCP or TLS.
        #[serde(rename = "relayedTls", default, skip_serializing_if = "Vec::is_empty")]
        relayed_tls: Vec<String>,
        /// The WireGuard protocol version ([`WG_VERSION`]); absent (0) from
        /// older Macs.
        #[serde(default, skip_serializing_if = "is_zero")]
        version: u32,
    },
    /// A WireGuard side's new endpoints after a roam (or a new TURN
    /// allocation), the same announcement it sends inside the tunnel
    /// (PROTOCOL.md "WireGuard roaming"), so it arrives even when the peer
    /// cannot receive from the new address yet (a NAT that filters by
    /// address). Older peers ignore it.
    #[serde(rename = "wg-endpoints")]
    WgEndpoints {
        generation: u64,
        endpoints: Vec<String>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        relayed: Vec<String>,
        #[serde(rename = "relayedTls", default, skip_serializing_if = "Vec::is_empty")]
        relayed_tls: Vec<String>,
    },
    #[serde(rename = "bye")]
    Bye {
        #[serde(default)]
        reason: String,
    },
}

/// One `signal` message.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SignalEnvelope {
    pub to: String,
    pub from: String,
    pub session_id: String,
    pub payload: SignalPayload,
    /// Stamped by the backend on forwarded signals: the Stack user id of the
    /// sender. Clients never set it (the backend overwrites it).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from_user_id: Option<String>,
}

/// One sealed reply the backend held for this Mac (PROTOCOL.md "Reply
/// mailbox"). `from` is the phone the backend verified as the sender.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MailboxItem {
    pub id: String,
    pub from: String,
    pub sealed: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub at: Option<u64>,
}

/// The Mac's answer for one mailbox item.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MailboxResult {
    pub id: String,
    pub applied: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// The Mac's identity signature over the outcome (`cmux-mobile-mailbox-ack-v1
    /// \0 mac \0 id \0 1|0 \0 reason`), so the phone can tell the backend did not
    /// make it up (API 0.14.0).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sig: Option<String>,
}

/// Every JSON message on the socket.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum SignalMessage {
    Hello {
        you: String,
        #[serde(default)]
        macs: Vec<MacPresence>,
    },
    Presence {
        mac: MacPresence,
    },
    Signal(SignalEnvelope),
    /// Backend → Mac: sealed replies held for it (API 0.13.0).
    Mailbox {
        items: Vec<MailboxItem>,
    },
    /// Mac → backend: what became of each mailbox item.
    #[serde(rename = "mailbox_ack")]
    MailboxAck {
        results: Vec<MailboxResult>,
    },
    Error {
        code: String,
        #[serde(default)]
        message: String,
        #[serde(default, rename = "sessionId")]
        session_id: Option<String>,
    },
}

/// The WireGuard protocol version this side speaks (`version` in `wg-init`
/// and `wg-resp`, PROTOCOL.md):
///
/// - 0 (absent): sends WireGuard datagrams through the backend relay frames
///   until the peer's relay marker confirms a direct route;
/// - 2: never sends relay frames; confirms routes with an in-tunnel `reach`
///   message, and may offer TURN relayed addresses reached over TCP or TLS.
///
/// A side treats a version-0 peer's authenticated datagrams as the
/// confirmation, since that peer's marker can no longer arrive.
pub const WG_VERSION: u32 = 2;

fn is_zero(value: &u32) -> bool {
    *value == 0
}

/// A session a peer started: its first signal and the subscription that
/// receives everything after it.
#[derive(Debug)]
pub struct IncomingSession {
    pub first: SignalEnvelope,
    pub events: mpsc::UnboundedReceiver<SessionEvent>,
}

/// What a session subscription receives.
#[derive(Debug, Clone)]
#[allow(clippy::large_enum_variant)] // rare events; boxing buys nothing
pub enum SessionEvent {
    Signal(SignalEnvelope),
    /// The signaling socket closed.
    Disconnected,
}

/// Events not owned by any session: hello, presence, errors, and signals of
/// sessions nobody subscribed to.
#[derive(Debug, Clone)]
pub enum SignalingEvent {
    Hello {
        you: String,
        macs: Vec<MacPresence>,
    },
    Presence(MacPresence),
    /// Sealed replies the backend held for this device (a Mac).
    Mailbox(Vec<MailboxItem>),
    /// A backend refusal; `session_id` names the session it concerns, when
    /// the backend says.
    Error {
        code: String,
        message: String,
        session_id: Option<String>,
    },
    Disconnected(String),
}

#[derive(Debug, thiserror::Error)]
pub enum SignalingError {
    #[error("bad signaling URL: {0}")]
    BadUrl(String),
    #[error("signaling connect failed: {0}")]
    Connect(String),
    #[error("signaling socket is closed")]
    Closed,
}

/// How often an idle socket is pinged, and how long it may stay silent
/// (no frame at all, pongs included) before it counts as dead. A socket
/// kept warm across dials must not be a half-open TCP connection (a phone
/// that slept, a NAT that forgot it), or the next dial would wait out its
/// whole timeout.
pub const KEEPALIVE_INTERVAL: std::time::Duration = std::time::Duration::from_secs(15);
pub const KEEPALIVE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(40);

struct Shared {
    device_id: String,
    /// Counts inbound frames (any kind); `probe` waits for it to move.
    inbound: tokio::sync::watch::Sender<u64>,
    opened: std::time::Instant,
    out: Arc<SendQueue>,
    sessions: Mutex<HashMap<String, mpsc::UnboundedSender<SessionEvent>>>,
    events: broadcast::Sender<SignalingEvent>,
    /// Mailbox frames, queued until read (`next_mailbox`): the backend sends
    /// them right after `hello`, before a caller could subscribe to `events`.
    mailbox: mpsc::UnboundedSender<Vec<MailboxItem>>,
    closed: Mutex<Option<String>>,
}

/// A connected signaling socket. Clone to share.
#[derive(Clone)]
pub struct SignalingClient {
    shared: Arc<Shared>,
    incoming: Arc<tokio::sync::Mutex<mpsc::UnboundedReceiver<IncomingSession>>>,
    mailbox: Arc<tokio::sync::Mutex<mpsc::UnboundedReceiver<Vec<MailboxItem>>>>,
}

impl std::fmt::Debug for SignalingClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SignalingClient").field("device_id", &self.shared.device_id).finish_non_exhaustive()
    }
}

/// `https://host` → `wss://host/v1/teams/<team>/signal?deviceId=<id>`.
pub fn signal_url(base_url: &str, team_id: &str, device_id: &str) -> Result<String, SignalingError> {
    let base = base_url.trim_end_matches('/');
    let ws = if let Some(rest) = base.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = base.strip_prefix("http://") {
        format!("ws://{rest}")
    } else if base.starts_with("ws://") || base.starts_with("wss://") {
        base.to_owned()
    } else {
        return Err(SignalingError::BadUrl(base_url.to_owned()));
    };
    Ok(format!("{ws}/v1/teams/{}/signal?deviceId={}", encode_segment(team_id), encode_segment(device_id)))
}

fn encode_segment(value: &str) -> String {
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

impl SignalingClient {
    /// Connect with `Authorization: Bearer <token>`.
    pub async fn connect(
        base_url: &str,
        token: &str,
        team_id: &str,
        device_id: &str,
    ) -> Result<Self, SignalingError> {
        crate::install_crypto_provider();
        let url = signal_url(base_url, team_id, device_id)?;
        let mut request = url.into_client_request().map_err(|e| SignalingError::BadUrl(e.to_string()))?;
        request.headers_mut().insert(
            "authorization",
            format!("Bearer {token}")
                .parse()
                .map_err(|_| SignalingError::BadUrl("token is not a header value".into()))?,
        );
        let (socket, _) = tokio_tungstenite::connect_async(request)
            .await
            .map_err(|e| SignalingError::Connect(e.to_string()))?;
        let (sink, mut source) = socket.split();
        let out = Arc::new(SendQueue::default());
        let (incoming_tx, incoming_rx) = mpsc::unbounded_channel();
        let (mailbox_tx, mailbox_rx) = mpsc::unbounded_channel();
        let shared = Arc::new(Shared {
            device_id: device_id.to_owned(),
            inbound: tokio::sync::watch::channel(0).0,
            opened: std::time::Instant::now(),
            out: Arc::clone(&out),
            sessions: Mutex::new(HashMap::new()),
            events: broadcast::channel(256).0,
            mailbox: mailbox_tx,
            closed: Mutex::new(None),
        });
        let pinger = Arc::clone(&out);
        tokio::spawn(async move { out.write_out(sink).await });
        let reader_shared = Arc::clone(&shared);
        tokio::spawn(async move {
            let shared = reader_shared;
            let mut keepalive = tokio::time::interval(KEEPALIVE_INTERVAL);
            keepalive.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            keepalive.tick().await;
            let mut last_inbound = tokio::time::Instant::now();
            let reason = loop {
                let next = tokio::select! {
                    next = source.next() => next,
                    _ = keepalive.tick() => {
                        if last_inbound.elapsed() >= KEEPALIVE_TIMEOUT {
                            pinger.close();
                            break "signaling keepalive timed out".to_owned();
                        }
                        let _ = pinger.push_signal(Signal::Ping);
                        continue;
                    }
                };
                let message = match next {
                    Some(Ok(message)) => message,
                    Some(Err(error)) => break format!("signaling read failed: {error}"),
                    None => break "signaling socket closed".to_owned(),
                };
                last_inbound = tokio::time::Instant::now();
                shared.inbound.send_modify(|count| *count += 1);
                match message {
                    Message::Text(text) => shared.dispatch_text(&text, &incoming_tx),
                    // Relay frames are retired; a peer never sends one here.
                    Message::Binary(bytes) => {
                        tracing::debug!(len = bytes.len(), "ignoring a binary signaling frame");
                    }
                    Message::Close(frame) => {
                        break format!(
                            "signaling closed by server{}",
                            frame.map(|f| format!(": {} {}", f.code, f.reason)).unwrap_or_default()
                        );
                    }
                    _ => {}
                }
            };
            // The writer waits on the queue, not on the socket: stop it, so
            // it releases the socket's write half.
            pinger.close();
            *shared.closed.lock().unwrap_or_else(PoisonError::into_inner) = Some(reason.clone());
            let sessions: Vec<_> = shared
                .sessions
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .drain()
                .map(|(_, tx)| tx)
                .collect();
            for tx in sessions {
                let _ = tx.send(SessionEvent::Disconnected);
            }
            let _ = shared.events.send(SignalingEvent::Disconnected(reason));
        });
        Ok(Self {
            shared,
            incoming: Arc::new(tokio::sync::Mutex::new(incoming_rx)),
            mailbox: Arc::new(tokio::sync::Mutex::new(mailbox_rx)),
        })
    }

    pub fn device_id(&self) -> &str {
        &self.shared.device_id
    }

    /// Whether `other` is a handle of this same socket.
    pub fn same_socket(&self, other: &SignalingClient) -> bool {
        Arc::ptr_eq(&self.shared, &other.shared)
    }

    /// When the socket opened.
    pub fn opened_at(&self) -> std::time::Instant {
        self.shared.opened
    }

    /// Whether the socket still answers: sends a WebSocket ping and waits
    /// up to `timeout` for any inbound frame. A socket that already closed
    /// is `false` at once.
    pub async fn probe(&self, timeout: std::time::Duration) -> bool {
        if self.closed_reason().is_some() {
            return false;
        }
        let mut inbound = self.shared.inbound.subscribe();
        inbound.borrow_and_update();
        if self.shared.out.push_signal(Signal::Ping).is_err() {
            return false;
        }
        matches!(tokio::time::timeout(timeout, inbound.changed()).await, Ok(Ok(())))
            && self.closed_reason().is_none()
    }

    /// `Some(reason)` once the socket closed.
    pub fn closed_reason(&self) -> Option<String> {
        self.shared.closed.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// Hello, presence, error and disconnect events.
    pub fn events(&self) -> broadcast::Receiver<SignalingEvent> {
        self.shared.events.subscribe()
    }

    /// The next mailbox frame the backend sent (never lost to a late
    /// subscriber); `None` once the socket is closed and the queue is empty.
    pub async fn next_mailbox(&self) -> Option<Vec<MailboxItem>> {
        let mut queue = self.mailbox.lock().await;
        if self.closed_reason().is_some() {
            return queue.try_recv().ok();
        }
        queue.recv().await
    }

    /// The next session a peer started (a Mac answering dials), already
    /// subscribed; `None` once the socket is closed. Drop or
    /// [`unsubscribe`](Self::unsubscribe) a session you refuse.
    pub async fn next_session(&self) -> Option<IncomingSession> {
        self.incoming.lock().await.recv().await
    }

    /// Route every later signal and relay frame of `session_id` to the
    /// returned receiver.
    pub fn subscribe(&self, session_id: &str) -> mpsc::UnboundedReceiver<SessionEvent> {
        let (tx, rx) = mpsc::unbounded_channel();
        if self.closed_reason().is_some() {
            let _ = tx.send(SessionEvent::Disconnected);
        }
        self.shared.sessions.lock().unwrap_or_else(PoisonError::into_inner).insert(session_id.to_owned(), tx);
        rx
    }

    pub fn unsubscribe(&self, session_id: &str) {
        self.shared.sessions.lock().unwrap_or_else(PoisonError::into_inner).remove(session_id);
    }

    /// Send `payload` to `to` in `session_id`.
    pub fn send_signal(
        &self,
        to: &str,
        session_id: &str,
        payload: SignalPayload,
    ) -> Result<(), SignalingError> {
        let message = SignalMessage::Signal(SignalEnvelope {
            to: to.to_owned(),
            from: self.shared.device_id.clone(),
            session_id: session_id.to_owned(),
            payload,
            from_user_id: None,
        });
        let text = serde_json::to_string(&message).expect("signal serializes");
        self.shared.out.push_signal(Signal::Text(text))
    }

    /// Tell the backend what became of mailbox items (`mailbox_ack`).
    pub fn send_mailbox_ack(&self, results: Vec<MailboxResult>) -> Result<(), SignalingError> {
        let text = serde_json::to_string(&SignalMessage::MailboxAck { results }).expect("ack serializes");
        self.shared.out.push_signal(Signal::Text(text))
    }

    /// Close the socket. Sessions see `Disconnected`.
    pub fn close(&self) {
        self.shared.out.close();
    }
}

impl Shared {
    fn dispatch_text(&self, text: &str, incoming: &mpsc::UnboundedSender<IncomingSession>) {
        let message = match serde_json::from_str::<SignalMessage>(text) {
            Ok(message) => message,
            Err(error) => {
                tracing::debug!(%error, "ignoring signaling message");
                return;
            }
        };
        match message {
            SignalMessage::Hello { you, macs } => {
                let _ = self.events.send(SignalingEvent::Hello { you, macs });
            }
            SignalMessage::Presence { mac } => {
                let _ = self.events.send(SignalingEvent::Presence(mac));
            }
            SignalMessage::Error { code, message, session_id } => {
                let _ = self.events.send(SignalingEvent::Error { code, message, session_id });
            }
            SignalMessage::Mailbox { items } => {
                let _ = self.mailbox.send(items.clone());
                let _ = self.events.send(SignalingEvent::Mailbox(items));
            }
            SignalMessage::MailboxAck { .. } => {}
            SignalMessage::Signal(envelope) => {
                let mut sessions = self.sessions.lock().unwrap_or_else(PoisonError::into_inner);
                if let Some(tx) = sessions.get(&envelope.session_id) {
                    if tx.send(SessionEvent::Signal(envelope.clone())).is_err() {
                        sessions.remove(&envelope.session_id);
                    }
                    return;
                }
                if !matches!(
                    envelope.payload,
                    SignalPayload::WebrtcOffer { .. } | SignalPayload::WgInit { .. }
                ) {
                    tracing::debug!(
                        session = envelope.session_id,
                        "dropping a signal for an unknown session"
                    );
                    return;
                }
                let (tx, rx) = mpsc::unbounded_channel();
                sessions.insert(envelope.session_id.clone(), tx);
                drop(sessions);
                let _ = incoming.send(IncomingSession { first: envelope, events: rx });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mailbox_frames_match_the_contract() {
        let frame: SignalMessage = serde_json::from_str(
            r#"{"type":"mailbox","items":[{"id":"r1","from":"p","sealed":"AQ","at":5},{"id":"r2","from":"p","sealed":"AQ"}]}"#,
        )
        .unwrap();
        let SignalMessage::Mailbox { items } = frame else { panic!("{frame:?}") };
        assert_eq!(
            items[0],
            MailboxItem { id: "r1".into(), from: "p".into(), sealed: "AQ".into(), at: Some(5) }
        );
        assert_eq!(items[1].at, None);
        let ack = SignalMessage::MailboxAck {
            results: vec![
                MailboxResult { id: "r1".into(), applied: true, reason: None, sig: Some("ab".into()) },
                MailboxResult { id: "r2".into(), applied: false, reason: Some("replayed".into()), sig: None },
            ],
        };
        assert_eq!(
            serde_json::to_value(&ack).unwrap(),
            serde_json::json!({"type":"mailbox_ack","results":[{"id":"r1","applied":true,"sig":"ab"},
                {"id":"r2","applied":false,"reason":"replayed"}]})
        );
    }

    #[test]
    fn wire_shapes_match_the_contract() {
        let offer = SignalMessage::Signal(SignalEnvelope {
            to: "mac".into(),
            from: "phone".into(),
            session_id: "s".into(),
            payload: SignalPayload::WebrtcIce {
                candidate: "c".into(),
                sdp_mid: Some("0".into()),
                sdp_m_line_index: Some(0),
            },
            from_user_id: None,
        });
        let json: serde_json::Value = serde_json::to_value(&offer).unwrap();
        assert_eq!(
            json,
            serde_json::json!({"type":"signal","to":"mac","from":"phone","sessionId":"s",
                "payload":{"kind":"webrtc-ice","candidate":"c","sdpMid":"0","sdpMLineIndex":0}})
        );
        let init: SignalPayload = serde_json::from_value(serde_json::json!(
            {"kind":"wg-init","publicKey":"k","endpoints":["1.2.3.4:5"],"overlayIP":"10.77.0.2"}))
        .unwrap();
        assert!(matches!(init, SignalPayload::WgInit { .. }));
        let with_relayed: SignalPayload = serde_json::from_value(serde_json::json!(
            {"kind":"wg-init","publicKey":"k","endpoints":["1.2.3.4:5","9.9.9.9:7"],"overlayIP":"10.77.0.2",
             "relayed":["9.9.9.9:7"]}))
        .unwrap();
        assert!(
            matches!(with_relayed, SignalPayload::WgInit { ref relayed, .. } if relayed == &["9.9.9.9:7"])
        );
        let hello: SignalMessage = serde_json::from_str(
            r#"{"type":"hello","you":"p","macs":[{"deviceId":"m","name":"Mac","online":true,"lastSeenAt":1}]}"#,
        )
        .unwrap();
        assert!(matches!(hello, SignalMessage::Hello { .. }));
    }

    #[test]
    fn wg_versions_and_tls_relayed_addresses() {
        let resp: SignalPayload = serde_json::from_value(serde_json::json!(
            {"kind":"wg-resp","publicKey":"k","endpoints":["9.9.9.9:7"],"overlayIP":"10.77.0.1",
             "relayed":["9.9.9.9:7"],"relayedTls":["9.9.9.9:7"],"version":2}))
        .unwrap();
        assert!(
            matches!(resp, SignalPayload::WgResp { version: 2, ref relayed_tls, .. } if relayed_tls == &["9.9.9.9:7"])
        );
        // An older Mac's wg-resp has neither: version 0.
        let old: SignalPayload = serde_json::from_value(serde_json::json!(
            {"kind":"wg-resp","publicKey":"k","endpoints":[],"overlayIP":"10.77.0.1"}))
        .unwrap();
        assert!(matches!(old, SignalPayload::WgResp { version: 0, .. }));
        let text = serde_json::to_string(&old).unwrap();
        assert!(!text.contains("version") && !text.contains("relayed"), "{text}");
    }

    #[test]
    fn signal_url_shapes() {
        assert_eq!(
            signal_url("https://api.example.dev/", "team 1", "dev").unwrap(),
            "wss://api.example.dev/v1/teams/team%201/signal?deviceId=dev"
        );
        assert!(signal_url("ftp://x", "t", "d").is_err());
    }
}
