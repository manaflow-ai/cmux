//! The three-way hub's clients (RFD 0142 R6; PROTOCOL.md "Three-way hub").
//!
//! When an agent session has two sources, the Mac and its AutoCloud VM, each
//! source's link host joins the session's hub room as a [`HubSource`] and
//! publishes every event of the session's log, sealed end to end, at its log
//! position `(epoch, seq)`. The phone joins as a [`HubViewer`]: the relay
//! forwards the newest copy of each position once, and the viewer's
//! [`TruthTracker`] checks it, orders it and drops duplicates. When the Mac
//! sleeps mid-turn, the VM's copies are already flowing; the phone sees no
//! gap and dials nothing.
//!
//! Lockstep. A hub client offers the `cmux-hub.v1` subprotocol; anything but
//! an upgrade that echoes it is a [`HubFallback`] (an older Worker's 404, the
//! kill switch's 503, a refusal, an upgrade without the echo, or a relay that
//! answers kind-5 frames with `bad_frame:kind`), and the caller keeps today's
//! per-source path ([`hub_wanted`] says when to try at all). Old clients never
//! ask for the hub, so a new relay changes nothing for them.
//!
//! The relay holds no key: every client derives the session's
//! [`HubKey`] from a 32-byte secret the session's devices share (handed out
//! over their own end-to-end links, never through the relay) and the session
//! id.

use std::sync::Arc;
use std::time::Duration;

use cmux_transport::RelayFrame;
use cmux_transport::hub::{
    HUB_SUBPROTOCOL, HubFallback, HubHeader, HubJoin, HubKey, HubPos, HubRole, HubSealError, HubTo,
    hub_join_outcome, relay_error_means_no_hub, seal_frame,
};
use cmux_transport::hub_truth::{TruthConfig, TruthEvent, TruthReject, TruthTracker};
use futures_util::{SinkExt, StreamExt};
use tokio::sync::{mpsc, watch};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::error::{Error as WsError, ProtocolError, SubProtocolError};

/// How long a hub join may take before the caller falls back.
pub const HUB_JOIN_WAIT: Duration = Duration::from_secs(10);

/// Whether a session should try the hub: only with two sources (a session
/// with one source gains nothing from a room and keeps its direct link).
pub fn hub_wanted(mac: bool, vm: bool) -> bool {
    mac && vm
}

/// What a hub client needs to join one session's room.
#[derive(Clone)]
pub struct HubParams {
    /// The backend origin (`https://...`; `http://` in tests).
    pub base_url: String,
    /// The Stack token.
    pub token: String,
    pub build_space: Option<crate::BuildSpace>,
    /// The agent session's id.
    pub session: uuid::Uuid,
    /// This device's registered id.
    pub device_id: String,
    /// The secret the session's devices share; the relay never sees it.
    pub secret: [u8; 32],
}

impl HubParams {
    fn key(&self) -> HubKey {
        HubKey::derive(&self.secret, self.session.as_bytes())
    }
}

/// Which side of the room a client joins.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HubSide {
    Source(HubRole),
    Viewer,
}

impl HubSide {
    fn query(self) -> &'static str {
        match self {
            HubSide::Source(HubRole::Mac) => "mac",
            HubSide::Source(HubRole::Vm) => "vm",
            HubSide::Viewer => "viewer",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum HubError {
    /// No hub here: keep today's path.
    #[error("no hub: {0:?}")]
    Fallback(HubFallback),
    /// The join did not complete (network, timeout): retry or keep today's path.
    #[error("hub join failed: {0}")]
    Connect(String),
    #[error("bad hub url: {0}")]
    BadUrl(String),
}

/// `GET /v1/hub/:sessionId?deviceId=&role=` on `base_url`'s WebSocket origin.
pub fn hub_url(
    base_url: &str,
    session: &uuid::Uuid,
    device_id: &str,
    side: HubSide,
) -> Result<String, HubError> {
    let base = base_url.trim_end_matches('/');
    let ws = if let Some(rest) = base.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = base.strip_prefix("http://") {
        format!("ws://{rest}")
    } else if base.starts_with("ws://") || base.starts_with("wss://") {
        base.to_owned()
    } else {
        return Err(HubError::BadUrl(base_url.to_owned()));
    };
    let device =
        uuid::Uuid::parse_str(device_id).map_err(|_| HubError::BadUrl("device id is not a UUID".into()))?;
    Ok(format!("{ws}/v1/hub/{}?deviceId={}&role={}", session.hyphenated(), device.hyphenated(), side.query()))
}

/// The outcome of the upgrade, from tungstenite's answer.
fn join_error(error: &WsError) -> HubError {
    match error {
        WsError::Http(response) => match hub_join_outcome(response.status().as_u16(), None) {
            HubJoin::Fallback(fallback) => HubError::Fallback(fallback),
            HubJoin::Hub => HubError::Connect("upgrade refused".into()),
        },
        // We offered cmux-hub.v1 and the relay echoed nothing (or something else): not a hub.
        WsError::Protocol(ProtocolError::SecWebSocketSubProtocolError(
            SubProtocolError::NoSubProtocol | SubProtocolError::InvalidSubProtocol,
        )) => HubError::Fallback(HubFallback::NoSubprotocol),
        other => HubError::Connect(other.to_string()),
    }
}

type Socket = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn join(params: &HubParams, side: HubSide) -> Result<Socket, HubError> {
    crate::install_crypto_provider();
    let url = hub_url(&params.base_url, &params.session, &params.device_id, side)?;
    let mut request = url.into_client_request().map_err(|e| HubError::BadUrl(e.to_string()))?;
    let headers = request.headers_mut();
    let bearer = format!("Bearer {}", params.token).parse().map_err(|_| HubError::BadUrl("token".into()))?;
    headers.insert("authorization", bearer);
    headers.insert("sec-websocket-protocol", http_value(HUB_SUBPROTOCOL)?);
    if let Some(space) = &params.build_space {
        headers.insert(crate::build_space::HEADER, http_value(space.as_str())?);
    }
    let (socket, response) =
        tokio::time::timeout(HUB_JOIN_WAIT, cmux_egress::ws::connect_async(request, "cmux_mobile_link::hub"))
            .await
            .map_err(|_| HubError::Connect(format!("no answer within {}s", HUB_JOIN_WAIT.as_secs())))?
            .map_err(|e| join_error(&e))?;
    let selected = response.headers().get("sec-websocket-protocol").and_then(|v| v.to_str().ok());
    match hub_join_outcome(response.status().as_u16(), selected) {
        HubJoin::Hub => Ok(socket),
        HubJoin::Fallback(fallback) => Err(HubError::Fallback(fallback)),
    }
}

fn http_value(value: &str) -> Result<tokio_tungstenite::tungstenite::http::HeaderValue, HubError> {
    value.parse().map_err(|_| HubError::BadUrl(format!("{value} is not a header value")))
}

/// What the room said, besides frames.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HubNotice {
    /// A source came or went.
    Source { role: HubRole, online: bool },
    /// The relay does not carry hub frames after all (`bad_frame:kind`): fall back.
    Fallback(HubFallback),
    /// Any other refusal the relay named (`bad_hub:role`, ...).
    Error(String),
}

fn notice(text: &str) -> Option<HubNotice> {
    let value: serde_json::Value = serde_json::from_str(text).ok()?;
    match value["type"].as_str()? {
        "source" => {
            let role = match value["role"].as_str()? {
                "mac" => HubRole::Mac,
                "vm" => HubRole::Vm,
                _ => return None,
            };
            Some(HubNotice::Source { role, online: value["online"].as_bool()? })
        }
        "error" => {
            let code = value["code"].as_str()?;
            Some(if relay_error_means_no_hub(code) {
                HubNotice::Fallback(HubFallback::KindRefused)
            } else {
                HubNotice::Error(code.to_owned())
            })
        }
        _ => None,
    }
}

/// A source's socket in the room: publishes the session's events.
pub struct HubSource {
    role: HubRole,
    session: [u8; 16],
    key: HubKey,
    out: mpsc::UnboundedSender<Message>,
    notices: mpsc::UnboundedReceiver<HubNotice>,
    closed: watch::Receiver<bool>,
    task: tokio::task::JoinHandle<()>,
    /// Hub frames from the other source (`to` this one), opened.
    synced: Synced,
}

/// Events the other source sent this one, opened, until taken.
type Synced = Arc<std::sync::Mutex<Vec<(HubPos, Vec<u8>)>>>;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum HubSendError {
    #[error("event too large for one hub frame: {0}")]
    TooLarge(usize),
    #[error("the hub socket closed")]
    Closed,
}

impl HubSource {
    pub async fn join(params: &HubParams, role: HubRole) -> Result<Self, HubError> {
        let socket = join(params, HubSide::Source(role)).await?;
        let (mut sink, mut stream) = socket.split();
        let (out, mut out_rx) = mpsc::unbounded_channel::<Message>();
        let (notice_tx, notices) = mpsc::unbounded_channel();
        let (closed_tx, closed) = watch::channel(false);
        let key = params.key();
        let synced: Synced = Arc::new(std::sync::Mutex::new(Vec::new()));
        let (sync_key, sync_into) = (key.clone(), Arc::clone(&synced));
        let task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    message = out_rx.recv() => match message {
                        Some(message) => if sink.send(message).await.is_err() { break },
                        None => break,
                    },
                    incoming = stream.next() => match incoming {
                        Some(Ok(Message::Text(text))) => if let Some(n) = notice(&text) { let _ = notice_tx.send(n); },
                        Some(Ok(Message::Binary(bytes))) => {
                            if let Ok(frame) = RelayFrame::decode(&bytes)
                                && let Ok(opened) = cmux_transport::hub::open(&sync_key, &frame.payload)
                            {
                                sync_into.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push((opened.header.pos, opened.event));
                            }
                        }
                        Some(Ok(_)) => {}
                        Some(Err(_)) | None => break,
                    },
                }
            }
            let _ = sink.close().await;
            let _ = closed_tx.send(true);
        });
        Ok(Self { role, session: *params.session.as_bytes(), key, out, notices, closed, task, synced })
    }

    /// Publishes the event at `pos` of the session's log to the viewers.
    pub fn publish(&self, pos: HubPos, event: &[u8]) -> Result<usize, HubSendError> {
        self.send(HubTo::Viewers, pos, event)
    }

    /// Sends the event at `pos` to the other source only (Mac-to-VM sync with no direct path).
    pub fn sync_to_other(&self, pos: HubPos, event: &[u8]) -> Result<usize, HubSendError> {
        self.send(HubTo::Source(self.role.other()), pos, event)
    }

    fn send(&self, to: HubTo, pos: HubPos, event: &[u8]) -> Result<usize, HubSendError> {
        let header = HubHeader { session: self.session, pos, source: self.role, to };
        let frame = seal_frame(&self.key, &header, event).map_err(|e| match e {
            HubSealError::TooLarge(n) => HubSendError::TooLarge(n),
            HubSealError::Seal => HubSendError::TooLarge(event.len()),
        })?;
        let bytes = frame.encode().map_err(|_| HubSendError::TooLarge(event.len()))?;
        let len = bytes.len();
        self.out.send(Message::Binary(bytes.into())).map_err(|_| HubSendError::Closed)?;
        Ok(len)
    }

    /// The next notice from the room (`None` once the socket is gone).
    pub async fn notice(&mut self) -> Option<HubNotice> {
        self.notices.recv().await
    }

    /// Events the other source sent to this one, taken.
    pub fn take_synced(&self) -> Vec<(HubPos, Vec<u8>)> {
        std::mem::take(&mut *self.synced.lock().unwrap_or_else(std::sync::PoisonError::into_inner))
    }

    pub fn is_closed(&self) -> bool {
        *self.closed.borrow()
    }

    /// Leaves the room (a sleeping Mac's socket simply goes quiet; this closes it).
    pub fn close(&self) {
        let _ = self.out.send(Message::Close(None));
    }
}

impl Drop for HubSource {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// What a viewer gets, in order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ViewerEvent {
    /// From the viewer's [`TruthTracker`]: deliver, a gap to fill, a stale pick.
    Truth(TruthEvent),
    /// A frame the tracker refused (a duplicate, a header the relay edited, ...).
    Rejected(TruthReject),
    Notice(HubNotice),
    /// The socket ended.
    Closed,
}

/// The phone's socket in the room.
pub struct HubViewer {
    events: mpsc::UnboundedReceiver<ViewerEvent>,
    /// Bytes of hub frames received (what the phone downloaded).
    received: Arc<std::sync::atomic::AtomicU64>,
    task: tokio::task::JoinHandle<()>,
}

impl HubViewer {
    pub async fn join(params: &HubParams, config: TruthConfig) -> Result<Self, HubError> {
        let socket = join(params, HubSide::Viewer).await?;
        let (events_tx, events) = mpsc::unbounded_channel();
        let received = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let counted = Arc::clone(&received);
        let key = params.key();
        let mut tracker = TruthTracker::new(*params.session.as_bytes(), config);
        let task = tokio::spawn(async move {
            let (_sink, mut stream) = socket.split();
            while let Some(Ok(message)) = stream.next().await {
                match message {
                    Message::Binary(bytes) => {
                        counted.fetch_add(bytes.len() as u64, std::sync::atomic::Ordering::Relaxed);
                        let Ok(frame) = RelayFrame::decode(&bytes) else { continue };
                        match tracker.on_payload(&key, &frame.payload) {
                            Ok(out) => {
                                for event in out {
                                    let _ = events_tx.send(ViewerEvent::Truth(event));
                                }
                            }
                            Err(reject) => {
                                let _ = events_tx.send(ViewerEvent::Rejected(reject));
                            }
                        }
                    }
                    Message::Text(text) => {
                        if let Some(n) = notice(&text) {
                            let _ = events_tx.send(ViewerEvent::Notice(n));
                        }
                    }
                    Message::Close(_) => break,
                    _ => {}
                }
            }
            let _ = events_tx.send(ViewerEvent::Closed);
        });
        Ok(Self { events, received, task })
    }

    pub async fn next(&mut self) -> Option<ViewerEvent> {
        self.events.recv().await
    }

    pub fn bytes_received(&self) -> u64 {
        self.received.load(std::sync::atomic::Ordering::Relaxed)
    }
}

impl Drop for HubViewer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// The phone's choice for one session: the hub, or why today's path stays.
pub enum ViewPlan {
    Hub(HubViewer),
    /// One source, or no hub here: keep the per-source link.
    Direct(Option<HubError>),
}

/// Joins the hub as a viewer when the session has two sources; otherwise, or
/// when the relay is not a hub, keeps today's path.
pub async fn view(params: &HubParams, mac: bool, vm: bool, config: TruthConfig) -> ViewPlan {
    if !hub_wanted(mac, vm) {
        return ViewPlan::Direct(None);
    }
    match HubViewer::join(params, config).await {
        Ok(viewer) => ViewPlan::Hub(viewer),
        Err(error) => ViewPlan::Direct(Some(error)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hub_url_shapes() {
        let session = uuid::Uuid::from_u128(0x5e55_104e_0000_4000_8000_0000_0000_0001);
        let device = "00112233-4455-6677-8899-aabbccddeeff";
        assert_eq!(
            hub_url("https://api.example.dev/", &session, device, HubSide::Viewer).unwrap(),
            "wss://api.example.dev/v1/hub/5e55104e-0000-4000-8000-000000000001?deviceId=00112233-4455-6677-8899-aabbccddeeff&role=viewer"
        );
        assert!(
            hub_url("http://h", &session, device, HubSide::Source(HubRole::Vm)).unwrap().ends_with("role=vm")
        );
        assert!(hub_url("ftp://h", &session, device, HubSide::Viewer).is_err());
        assert!(hub_url("http://h", &session, "not-a-uuid", HubSide::Viewer).is_err());
    }

    #[test]
    fn the_hub_is_tried_only_with_two_sources() {
        assert!(hub_wanted(true, true));
        assert!(!hub_wanted(true, false));
        assert!(!hub_wanted(false, true));
    }

    #[test]
    fn notices_parse() {
        assert_eq!(
            notice(r#"{"type":"source","role":"mac","online":false}"#),
            Some(HubNotice::Source { role: HubRole::Mac, online: false })
        );
        assert_eq!(
            notice(r#"{"type":"error","code":"bad_frame:kind"}"#),
            Some(HubNotice::Fallback(HubFallback::KindRefused))
        );
        assert_eq!(
            notice(r#"{"type":"error","code":"bad_hub:role"}"#),
            Some(HubNotice::Error("bad_hub:role".into()))
        );
        assert_eq!(notice(r#"{"type":"joined","hub":1}"#), None);
    }
}
