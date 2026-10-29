//! uniffi bindings of cmux-mobile-link for the cmux-next-ios app (Swift).
//!
//! Every async function runs on one shared Tokio runtime owned by this
//! library, so Swift may await them from any executor.

use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::Duration;

use cmux_mobile_link::api::ApiClient;
use cmux_mobile_link::api::{HttpClient, IceCache, IceServer};
use cmux_mobile_link::link::{ChannelReceiver, ChannelSender};
use cmux_mobile_link::{ChannelEvent, DialError, DialOptions, LinkConfig, SignalingClient, Timeline};
use tokio::runtime::Runtime;

mod browser;

pub use browser::{BrowserFrame, BrowserObserver, BrowserStats, BrowserStream};

uniffi::setup_scaffolding!();

fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        init_logging();
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("cmux-mobile-link-ffi")
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

/// The library's own log, for rigs and measurement: off unless the app runs
/// with `CMUX_MOBILE_LOG` (a `tracing` filter such as
/// `info,cmux_mobile_link::dial=debug`; a simulator gets it as
/// `SIMCTL_CHILD_CMUX_MOBILE_LOG`), to stderr (`simctl launch --stderr`).
/// Without it nothing the link logs (its route, roams, TURN allocations)
/// reaches anyone on the phone side.
fn init_logging() {
    let Ok(filter) = tracing_subscriber::EnvFilter::try_from_env("CMUX_MOBILE_LOG") else { return };
    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_ansi(false)
        .with_writer(std::io::stderr)
        .try_init();
}

/// Run `future` on the library runtime and await it from any executor.
async fn on_runtime<F, T>(future: F) -> T
where
    F: std::future::Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    match runtime().spawn(future).await {
        Ok(value) => value,
        Err(error) => std::panic::resume_unwind(error.into_panic()),
    }
}

/// Settings → Connection → Transport.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Transport {
    WebRtc,
    WireGuard,
}

impl From<Transport> for cmux_mobile_link::TransportKind {
    fn from(value: Transport) -> Self {
        match value {
            Transport::WebRtc => Self::WebRtc,
            Transport::WireGuard => Self::WireGuard,
        }
    }
}

/// How the link's bytes travel.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LinkPath {
    Direct,
    /// Through a TURN server over UDP.
    Turn,
    /// Through a TURN server reached over TLS (UDP blocked).
    TurnTls,
    /// No working route at the moment.
    NoPath,
}

impl From<cmux_mobile_link::LinkPath> for LinkPath {
    fn from(value: cmux_mobile_link::LinkPath) -> Self {
        match value {
            cmux_mobile_link::LinkPath::Direct => Self::Direct,
            cmux_mobile_link::LinkPath::Turn => Self::Turn,
            cmux_mobile_link::LinkPath::TurnTls => Self::TurnTls,
            cmux_mobile_link::LinkPath::NoPath => Self::NoPath,
        }
    }
}

/// The WebRTC media session beside a WireGuard link (browser video).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum MediaState {
    /// No session: nothing shows a browser tab, or this link has none
    /// (WebRTC transport, or a Mac without media sessions).
    Off,
    Connecting,
    /// Connected over `path`; `rtt_millis` is its ICE pair's round trip.
    Up {
        path: LinkPath,
        rtt_millis: Option<u32>,
    },
    /// The last attempt failed or the session dropped: browser video rides
    /// the WireGuard tunnel until a retry in `retry_in_millis` works.
    Failed {
        reason: String,
        retry_in_millis: u32,
    },
}

impl From<cmux_mobile_link::hybrid::MediaStatus> for MediaState {
    fn from(value: cmux_mobile_link::hybrid::MediaStatus) -> Self {
        let millis = |d: Duration| u32::try_from(d.as_millis()).unwrap_or(u32::MAX);
        match value {
            cmux_mobile_link::hybrid::MediaStatus::Off => Self::Off,
            cmux_mobile_link::hybrid::MediaStatus::Connecting => Self::Connecting,
            cmux_mobile_link::hybrid::MediaStatus::Up { path, rtt } => {
                Self::Up { path: path.into(), rtt_millis: rtt.map(millis) }
            }
            cmux_mobile_link::hybrid::MediaStatus::Failed { reason, retry_in } => {
                Self::Failed { reason, retry_in_millis: millis(retry_in) }
            }
        }
    }
}

/// Link state events, in order: `Connecting`, then `Connected` (or
/// `Disconnected` when the dial fails), then any number of `PathChanged`,
/// `Rtt` and `Media`, then one `Disconnected`.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum LinkEvent {
    Connecting {
        transport: Transport,
    },
    Connected {
        transport: Transport,
        path: LinkPath,
    },
    PathChanged {
        path: LinkPath,
    },
    Rtt {
        millis: u32,
    },
    /// The WebRTC media session beside a WireGuard link changed.
    Media {
        state: MediaState,
    },
    Disconnected {
        reason: String,
    },
}

/// Receives link state events on a library thread.
#[uniffi::export(with_foreign)]
pub trait LinkObserver: Send + Sync {
    fn on_event(&self, event: LinkEvent);
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum CmuxMobileError {
    #[error("invalid argument: {message}")]
    InvalidArgument { message: String },
    #[error("signaling: {message}")]
    Signaling { message: String },
    #[error("refused: {code}: {message}")]
    Refused { code: String, message: String },
    #[error("timed out")]
    Timeout,
    #[error("transport: {message}")]
    Transport { message: String },
    #[error("closed: {message}")]
    Closed { message: String },
}

impl From<DialError> for CmuxMobileError {
    fn from(error: DialError) -> Self {
        match error {
            DialError::Signaling(message) => Self::Signaling { message },
            DialError::Refused { code, message } => Self::Refused { code, message },
            DialError::Bye(reason) => Self::Refused { code: "bye".into(), message: reason },
            DialError::Timeout => Self::Timeout,
            DialError::Transport(message) | DialError::Unexpected(message) => Self::Transport { message },
        }
    }
}

impl From<cmux_mobile_link::LinkError> for CmuxMobileError {
    fn from(error: cmux_mobile_link::LinkError) -> Self {
        Self::Closed { message: error.to_string() }
    }
}

/// One message from a channel.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ChannelMessage {
    Data {
        bytes: Vec<u8>,
    },
    /// The channel is closed; every later `recv` returns this again.
    Closed {
        code: String,
        reason: String,
    },
}

/// One step of a dial, `millis` after `connect` was called.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TimingMark {
    pub name: String,
    pub millis: f64,
}

fn timing_marks(timeline: &Timeline) -> Vec<TimingMark> {
    timeline
        .marks()
        .into_iter()
        .map(|(name, at)| TimingMark { name, millis: (at.as_secs_f64() * 10_000.0).round() / 10.0 })
        .collect()
}

/// A connected link to one Mac.
#[derive(uniffi::Object)]
pub struct LinkHandle {
    link: cmux_mobile_link::Link,
    /// The (shared, warm) signaling socket this link was dialed on; it
    /// stays open for the next dial while the warm pool holds it.
    _signaling: Arc<WarmSocket>,
    transport: Transport,
    path: tokio::sync::watch::Receiver<cmux_mobile_link::LinkPath>,
    watcher: Mutex<Option<tokio::task::JoinHandle<()>>>,
    timeline: Timeline,
    session_id: String,
    /// The WebRTC media session beside a WireGuard link, when both sides
    /// support one (cmux_mobile_link::hybrid).
    media: Option<cmux_mobile_link::hybrid::MediaManager>,
}

impl Drop for LinkHandle {
    fn drop(&mut self) {
        self.link.close("handle dropped");
        if let Some(task) = self.watcher.lock().unwrap_or_else(PoisonError::into_inner).take() {
            task.abort();
        }
    }
}

impl LinkHandle {
    /// A remote surface's video stream: `browser` or `surface`.
    async fn open_remote_surface(
        &self,
        service: &'static str,
        args_json: String,
        observer: Arc<dyn BrowserObserver>,
    ) -> Result<Arc<BrowserStream>, CmuxMobileError> {
        let args: serde_json::Value = serde_json::from_str(&args_json)
            .map_err(|e| CmuxMobileError::InvalidArgument { message: format!("args_json: {e}") })?;
        if !args.is_object() {
            return Err(CmuxMobileError::InvalidArgument {
                message: "args_json must be a JSON object".into(),
            });
        }
        let mut args = args;
        let link = self.link.clone();
        let media = self.media.clone();
        on_runtime(async move {
            // With a media lane the page's video rides it (`video: "track"`:
            // a WebRTC track or RTP in the WireGuard tunnel); an older hostd
            // ignores the field and streams on the channel, which the viewer
            // reads either way.
            let lane = match link.media() {
                Some(cmux_mobile_link::media::MediaLane::In(lane)) if args.get("video").is_none() => {
                    Some(lane)
                }
                _ => None,
            };
            // This tab's frames carry `video_tag` (media/tag.rs): the lane
            // switches tabs without telling the phone when, and a refused
            // `open` never switches it, so each viewer keeps its own frames
            // beside the others instead of taking them from the tab before.
            let tag = u32::from_le_bytes(uuid::Uuid::new_v4().as_bytes()[..4].try_into().unwrap_or_default());
            if lane.is_some() {
                args["video"] = serde_json::Value::from("track");
                args["video_tag"] = serde_json::Value::from(tag);
            }
            let channel = link.open(service, args).await?;
            let track = match lane {
                Some(lane) => {
                    let frames = lane.subscribe_shared().await;
                    Some(browser::Track { lane, frames, tag })
                }
                None => None,
            };
            let (sender, receiver) = channel.split();
            // A shown browser tab wants the WebRTC media session (if this
            // link has one); it lets go when hidden or closed.
            Ok(browser::start(Arc::new(sender), receiver, observer, track, media))
        })
        .await
    }

    async fn open(
        &self,
        service: String,
        args_json: String,
        lane: cmux_mobile_link::Lane,
    ) -> Result<Arc<ChannelHandle>, CmuxMobileError> {
        let args: serde_json::Value = if args_json.trim().is_empty() {
            serde_json::json!({})
        } else {
            serde_json::from_str(&args_json)
                .map_err(|e| CmuxMobileError::InvalidArgument { message: format!("args_json: {e}") })?
        };
        if !args.is_object() {
            return Err(CmuxMobileError::InvalidArgument {
                message: "args_json must be a JSON object".into(),
            });
        }
        let link = self.link.clone();
        let channel = on_runtime(async move { link.open_on(&service, args, lane).await }).await?;
        let id = channel.id();
        let (sender, receiver) = channel.split();
        Ok(Arc::new(ChannelHandle {
            id,
            sender: Arc::new(sender),
            receiver: Arc::new(tokio::sync::Mutex::new(receiver)),
            closed: Arc::new(Mutex::new(None)),
        }))
    }
}

#[uniffi::export]
impl LinkHandle {
    /// Open a channel to `service` (`echo`, `daemon`, `acpmux`, `file`) with
    /// `args_json`, a JSON object (empty string means `{}`). A refusal
    /// arrives as the first `recv`: `Closed { code: "unknown_service" … }`.
    pub async fn open_channel(
        &self,
        service: String,
        args_json: String,
    ) -> Result<Arc<ChannelHandle>, CmuxMobileError> {
        self.open(service, args_json, cmux_mobile_link::Lane::Bulk).await
    }

    /// `open_channel` on the input lane (PROTOCOL.md "Lanes"): for terminal
    /// keystrokes, resizes and their replies, which then never wait behind
    /// bulk output. With a Mac that has no input lane the channel rides the
    /// main stream at input priority.
    pub async fn open_input_channel(
        &self,
        service: String,
        args_json: String,
    ) -> Result<Arc<ChannelHandle>, CmuxMobileError> {
        self.open(service, args_json, cmux_mobile_link::Lane::Input).await
    }

    /// Whether the link has its own input-lane stream now.
    pub fn has_input_lane(&self) -> bool {
        self.link.input_lane() == cmux_mobile_link::LaneState::Ready
    }

    /// Open a streamed Mac browser tab (`browser` service, args JSON
    /// `{"tab", "url"}`): frames and host messages go to `observer`.
    pub async fn open_browser(
        &self,
        args_json: String,
        observer: Arc<dyn BrowserObserver>,
    ) -> Result<Arc<BrowserStream>, CmuxMobileError> {
        self.open_remote_surface("browser", args_json, observer).await
    }

    /// Open a streamed Mac simulator surface (a phone tab: `surface` service,
    /// args JSON `{"tab"}`). The stream is a browser tab's (the same viewer,
    /// media lane and lane ownership); only the Mac's source differs.
    pub async fn open_surface(
        &self,
        args_json: String,
        observer: Arc<dyn BrowserObserver>,
    ) -> Result<Arc<BrowserStream>, CmuxMobileError> {
        self.open_remote_surface("surface", args_json, observer).await
    }

    /// The shown workspace has browser tabs: open the WebRTC media session
    /// beside this WireGuard link ahead of the first tab (no-op without one).
    pub fn warm_media(&self) {
        if let Some(media) = &self.media {
            let media = media.clone();
            runtime().spawn(async move { media.warm() });
        }
    }

    /// The WebRTC media session's state (`Off` on links without one).
    pub fn media_state(&self) -> MediaState {
        self.media.as_ref().map_or(MediaState::Off, |m| m.status().borrow().clone().into())
    }

    /// Debug: close the media session's peer connection at once, as a dead
    /// path would; video falls back to the tunnel and the session is dialed
    /// again.
    pub fn kill_media(&self) {
        if let Some(media) = &self.media {
            media.kill();
        }
    }

    /// Round-trip one ping; milliseconds.
    pub async fn ping(&self) -> Result<u32, CmuxMobileError> {
        let link = self.link.clone();
        let rtt = on_runtime(async move { link.ping().await }).await?;
        Ok(u32::try_from(rtt.as_millis()).unwrap_or(u32::MAX))
    }

    /// Whether the link is alive within `timeout_ms`: the round trip in
    /// milliseconds on the pong, `None` when other frames from the Mac came
    /// first (a slow relay's queue; the link is alive), an error only when
    /// nothing came back at all or the link closed. The app's heartbeat,
    /// foreground and presence checks use it, so a busy link is never
    /// closed for a late pong (link-reliability-20261023.md).
    pub async fn probe(&self, timeout_ms: u32) -> Result<Option<u32>, CmuxMobileError> {
        let link = self.link.clone();
        let timeout = Duration::from_millis(u64::from(timeout_ms));
        let rtt = on_runtime(async move { link.probe(timeout).await }).await?;
        Ok(rtt.map(|rtt| u32::try_from(rtt.as_millis()).unwrap_or(u32::MAX)))
    }

    pub fn transport(&self) -> Transport {
        self.transport
    }

    pub fn path(&self) -> LinkPath {
        (*self.path.borrow()).into()
    }

    pub fn is_closed(&self) -> bool {
        self.link.is_closed()
    }

    /// Close the link and its transport. The signaling socket stays warm
    /// for the next dial (`reset_warm_state` closes it).
    pub fn close(&self) {
        self.link.close("closed by the app");
    }

    /// The dial's steps (`signaling_open`, `ice_connected`, `channel_open`,
    /// `link_ready`, ...), each in milliseconds since `connect` was called.
    /// Marks recorded later (the first ping, `first_pong`) appear as they come.
    pub fn timings(&self) -> Vec<TimingMark> {
        timing_marks(&self.timeline)
    }

    /// The latest WireGuard roam of this link (`network_changed`,
    /// `roam_reasserted`, `roam_first_packet`, `roam_direct` or `roam_turn`,
    /// ...), in milliseconds since the network changed; empty before any.
    pub fn roam_timings(&self) -> Vec<TimingMark> {
        cmux_mobile_link::dial::wireguard::roam_timeline(&self.session_id)
            .map(|timeline| timing_marks(&timeline))
            .unwrap_or_default()
    }

    /// Debug: measure a network change. Pings back to back for 1 s, then
    /// takes this device's network away (every WireGuard session's socket
    /// and TURN allocation go dead) and, when `roam`, roams at once; keeps
    /// pinging for `window_ms`. Returns JSON: `stall_ms` (the longest wait
    /// for a pong from the change on), `pongs`, `path` at the end, and the
    /// roam marks.
    pub async fn debug_network_change_probe(&self, roam: bool, window_ms: u32) -> String {
        let link = self.link.clone();
        let path = self.path.clone();
        let session_id = self.session_id.clone();
        on_runtime(async move {
            let pinging = async |until: std::time::Instant, gaps: &mut Vec<Duration>| {
                let mut last = std::time::Instant::now();
                while std::time::Instant::now() < until {
                    if link.ping().await.is_err() {
                        break;
                    }
                    let now = std::time::Instant::now();
                    gaps.push(now - last);
                    last = now;
                }
            };
            let mut warmup = Vec::new();
            pinging(std::time::Instant::now() + Duration::from_secs(1), &mut warmup).await;
            let changed = std::time::Instant::now();
            let hit = cmux_mobile_link::dial::wireguard::simulate_network_loss(None, true);
            let roam_task = roam.then(|| tokio::spawn(cmux_mobile_link::dial::wireguard::network_changed()));
            let mut gaps = Vec::new();
            pinging(changed + Duration::from_millis(u64::from(window_ms)), &mut gaps).await;
            if let Some(task) = roam_task {
                let _ = task.await;
            }
            let stall = gaps.iter().max().copied().unwrap_or_default();
            let marks: Vec<serde_json::Value> = cmux_mobile_link::dial::wireguard::roam_timeline(&session_id)
                .map(|timeline| timing_marks(&timeline))
                .unwrap_or_default()
                .into_iter()
                .map(|mark| serde_json::json!({ "name": mark.name, "ms": mark.millis }))
                .collect();
            let path = match *path.borrow() {
                cmux_mobile_link::LinkPath::Direct => "direct",
                cmux_mobile_link::LinkPath::Turn => "turn",
                cmux_mobile_link::LinkPath::TurnTls => "turn-tls",
                cmux_mobile_link::LinkPath::NoPath => "none",
            };
            serde_json::json!({
                "roam": roam,
                "sessions": hit,
                "stall_ms": (stall.as_secs_f64() * 10_000.0).round() / 10.0,
                "pongs": gaps.len(),
                "warmup_max_ms": warmup.iter().max().map_or(0.0, |gap| gap.as_secs_f64() * 1000.0),
                "path": path,
                "marks": marks,
                "link_closed": link.is_closed(),
            })
            .to_string()
        })
        .await
    }
}

/// One multiplexed channel.
#[derive(uniffi::Object)]
pub struct ChannelHandle {
    id: u32,
    sender: Arc<ChannelSender>,
    receiver: Arc<tokio::sync::Mutex<ChannelReceiver>>,
    closed: Arc<Mutex<Option<(String, String)>>>,
}

#[uniffi::export]
impl ChannelHandle {
    pub fn id(&self) -> u32 {
        self.id
    }

    pub async fn send(&self, data: Vec<u8>) -> Result<(), CmuxMobileError> {
        let sender = Arc::clone(&self.sender);
        on_runtime(async move { sender.send(data.into()).await }).await?;
        Ok(())
    }

    /// The next message. Calls are serialized; after `Closed` every call
    /// returns the same `Closed`.
    pub async fn recv(&self) -> ChannelMessage {
        if let Some((code, reason)) = self.closed.lock().unwrap_or_else(PoisonError::into_inner).clone() {
            return ChannelMessage::Closed { code, reason };
        }
        let receiver = Arc::clone(&self.receiver);
        let closed = Arc::clone(&self.closed);
        on_runtime(async move {
            let event = receiver.lock().await.recv().await;
            match event {
                Some(ChannelEvent::Data(bytes)) => ChannelMessage::Data { bytes: bytes.to_vec() },
                Some(ChannelEvent::Closed(info)) => {
                    *closed.lock().unwrap_or_else(PoisonError::into_inner) =
                        Some((info.code.clone(), info.reason.clone()));
                    ChannelMessage::Closed { code: info.code, reason: info.reason }
                }
                None => {
                    let stored = closed.lock().unwrap_or_else(PoisonError::into_inner).clone();
                    let (code, reason) = stored.unwrap_or_else(|| ("closed".into(), String::new()));
                    ChannelMessage::Closed { code, reason }
                }
            }
        })
        .await
    }

    pub async fn close(&self, code: String, reason: String) {
        let sender = Arc::clone(&self.sender);
        on_runtime(async move { sender.close(&code, &reason).await }).await;
    }
}

/// Dial options beyond the transport. Every field has a default, so
/// `ConnectOptions()` in Swift is the plain dial.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct ConnectOptions {
    /// Debug "simulate distant network": skip every direct path. WebRTC
    /// uses ICE transport policy `relay` with the service's TURN servers,
    /// WireGuard only its TURN allocation (path `Turn`, or `TurnTls` when
    /// the allocation had to use TLS). No TURN server fails the dial.
    #[uniffi(default = false)]
    pub relay_only: bool,
    /// Debug "simulate a network that blocks UDP": WireGuard sends and
    /// accepts no plain UDP and skips TURN over UDP, so it rides TURN over
    /// TLS on 443 (path `TurnTls`). WebRTC ignores it.
    #[uniffi(default = false)]
    pub block_udp: bool,
    /// Debug: do not offer the media lane, so browser video rides its
    /// reliable channel on either transport (the comparison baseline).
    #[uniffi(default = false)]
    pub no_video_lane: bool,
    /// WireGuard: no WebRTC media session beside the link, so browser video
    /// rides RTP inside the tunnel (the "WireGuard only" comparison).
    #[uniffi(default = false)]
    pub no_webrtc_media: bool,
}

/// Dial `mac_device_id` from this phone (`device_id`) over `transport`.
/// `base_url` is the backend (`https://cmux-mobile-api-…workers.dev`), `token`
/// a Stack access token, `team_id` the team whose signaling hub to use.
/// Same as `connect_with_options` with default options.
#[uniffi::export]
pub async fn connect(
    base_url: String,
    token: String,
    team_id: String,
    device_id: String,
    mac_device_id: String,
    transport: Transport,
    observer: Option<Arc<dyn LinkObserver>>,
) -> Result<Arc<LinkHandle>, CmuxMobileError> {
    connect_with_options(
        base_url,
        token,
        team_id,
        device_id,
        mac_device_id,
        transport,
        ConnectOptions::default(),
        observer,
    )
    .await
}

/// `connect` with `options` (relay only).
#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub async fn connect_with_options(
    base_url: String,
    token: String,
    team_id: String,
    device_id: String,
    mac_device_id: String,
    transport: Transport,
    options: ConnectOptions,
    observer: Option<Arc<dyn LinkObserver>>,
) -> Result<Arc<LinkHandle>, CmuxMobileError> {
    let request = ConnectRequest {
        base_url,
        token,
        team_id,
        device_id,
        mac_device_id,
        transport,
        include_loopback: false,
        relay_only: options.relay_only,
        block_udp: options.block_udp,
        video_lane: !options.no_video_lane,
        webrtc_media: !options.no_webrtc_media
            && std::env::var_os("CMUX_MOBILE_DEV_NO_WEBRTC_MEDIA").is_none(),
    };
    on_runtime(connect_inner(request, observer)).await
}

/// The library version.
#[uniffi::export]
pub fn cmux_mobile_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}

#[doc(hidden)]
pub struct ConnectRequest {
    pub base_url: String,
    pub token: String,
    pub team_id: String,
    pub device_id: String,
    pub mac_device_id: String,
    pub transport: Transport,
    pub include_loopback: bool,
    pub relay_only: bool,
    pub block_udp: bool,
    /// Offer the media lane (browser video as RTP: a WebRTC track, or UDP inside the WireGuard tunnel).
    pub video_lane: bool,
    /// WireGuard: offer a WebRTC media session beside the link for browser
    /// video (cmux_mobile_link::hybrid).
    pub webrtc_media: bool,
}

fn emit(observer: &Option<Arc<dyn LinkObserver>>, event: LinkEvent) {
    if let Some(observer) = observer {
        observer.on_event(event);
    }
}

#[doc(hidden)]
pub async fn connect_inner(
    request: ConnectRequest,
    observer: Option<Arc<dyn LinkObserver>>,
) -> Result<Arc<LinkHandle>, CmuxMobileError> {
    let timeline = Timeline::new();
    let transport = request.transport;
    emit(&observer, LinkEvent::Connecting { transport });
    let result = dial(&request, &timeline).await;
    let (connected, signaling) = match result {
        Ok(ok) => ok,
        Err(error) => {
            emit(&observer, LinkEvent::Disconnected { reason: error.to_string() });
            return Err(error);
        }
    };
    let mut path = connected.path.clone();
    emit(&observer, LinkEvent::Connected { transport, path: (*path.borrow()).into() });
    let media = connected.webrtc_media.then(|| media_manager(&request, &connected, &signaling));
    let mut media_status = media.as_ref().map(cmux_mobile_link::hybrid::MediaManager::status);
    let link = connected.link.clone();
    let watcher = tokio::spawn(async move {
        let mut rtt = link.rtt();
        let mut closed = link.closed_state();
        loop {
            let media_changed = async {
                match media_status.as_mut() {
                    Some(status) => status.changed().await.is_ok(),
                    None => std::future::pending().await,
                }
            };
            tokio::select! {
                changed = media_changed => {
                    if !changed {
                        media_status = None;
                        continue;
                    }
                    if let Some(status) = media_status.as_mut() {
                        let state = status.borrow_and_update().clone().into();
                        emit(&observer, LinkEvent::Media { state });
                    }
                }
                changed = path.changed() => {
                    if changed.is_err() { break; }
                    emit(&observer, LinkEvent::PathChanged { path: (*path.borrow_and_update()).into() });
                }
                changed = rtt.changed() => {
                    if changed.is_err() { break; }
                    let value = *rtt.borrow_and_update();
                    if let Some(value) = value {
                        emit(&observer, LinkEvent::Rtt { millis: u32::try_from(value.as_millis()).unwrap_or(u32::MAX) });
                    }
                }
                reason = closed.wait_for(Option::is_some) => {
                    let reason = reason.map(|r| r.clone().unwrap_or_default()).unwrap_or_default();
                    emit(&observer, LinkEvent::Disconnected { reason });
                    return;
                }
            }
        }
        let reason = link.closed().await;
        emit(&observer, LinkEvent::Disconnected { reason });
    });
    // Measure once right away so the app shows an RTT immediately.
    let first_ping = connected.link.clone();
    let ping_timeline = timeline.clone();
    tokio::spawn(async move {
        if first_ping.ping().await.is_ok() {
            ping_timeline.mark("first_pong");
        }
    });
    Ok(Arc::new(LinkHandle {
        link: connected.link,
        _signaling: signaling,
        transport,
        path: connected.path,
        watcher: Mutex::new(Some(watcher)),
        timeline,
        session_id: connected.session_id,
        media,
    }))
}

/// The phone's media session manager for a WireGuard link both sides
/// agreed to pair with a WebRTC media session. It dials on the warm pool's
/// current socket for this team and device (the link's may have been
/// replaced since) with fresh ICE servers.
fn media_manager(
    request: &ConnectRequest,
    connected: &cmux_mobile_link::Connected,
    socket: &Arc<WarmSocket>,
) -> cmux_mobile_link::hybrid::MediaManager {
    let key = socket.key.clone();
    let fallback = socket.client.clone();
    let signaling: cmux_mobile_link::hybrid::SignalingSource = Arc::new(move || {
        let key = key.clone();
        let fallback = fallback.clone();
        Box::pin(async move {
            match warm().pooled(&key).await {
                Some(socket) => Some(socket.client.clone()),
                None => (fallback.closed_reason().is_none()).then_some(fallback),
            }
        })
    });
    let base_url = request.base_url.clone();
    let token = request.token.clone();
    // Cached servers while fresh; else fetched with the dial's token (best
    // effort: an expired token leaves host candidates only).
    let ice: cmux_mobile_link::hybrid::IceSource = Arc::new(move || {
        let (base_url, token) = (base_url.clone(), token.clone());
        Box::pin(async move {
            without_turn_if_asked(warm().ice_servers(&base_url, &token, &Timeline::new()).await)
        })
    });
    cmux_mobile_link::hybrid::MediaManager::start(cmux_mobile_link::hybrid::MediaConfig {
        link: connected.link.clone(),
        mac: request.mac_device_id.clone(),
        link_session: connected.session_id.clone(),
        signaling,
        ice,
        options: DialOptions {
            include_loopback: request.include_loopback,
            relay_only: request.relay_only || std::env::var_os("CMUX_MOBILE_DEV_RELAY_ONLY").is_some(),
            block_udp: request.block_udp || std::env::var_os("CMUX_MOBILE_DEV_BLOCK_UDP").is_some(),
            ..DialOptions::default()
        },
        linger: cmux_mobile_link::hybrid::LINGER,
    })
}

// MARK: Warm state

/// What identifies a signaling socket: one per (service, team, device).
#[derive(Debug, Clone, PartialEq, Eq)]
struct SocketKey {
    base_url: String,
    team_id: String,
    device_id: String,
}

/// A signaling socket shared by the warm pool and the links dialed on it;
/// it closes when the last of them lets go.
#[doc(hidden)]
pub struct WarmSocket {
    key: SocketKey,
    client: SignalingClient,
}

impl Drop for WarmSocket {
    fn drop(&mut self) {
        self.client.close();
    }
}

/// Process-wide state kept between dials so a dial does not pay for work
/// an earlier dial or `prewarm` already did: one HTTP connection pool (a
/// warm TLS connection to the service), `GET /v1/ice` results per service
/// (TTL-aware), and the link device's signaling socket.
struct Warm {
    http: HttpClient,
    ice: Mutex<Vec<(String, Arc<IceCache>)>>,
    /// Warm sockets, newest last (a few: one per team and device in use).
    sockets: tokio::sync::Mutex<Vec<Arc<WarmSocket>>>,
    /// Held while a socket opens, so a dial that starts while `prewarm` is
    /// opening one waits for it instead of opening a second (the service
    /// keeps one socket per device and would close the first).
    opening: tokio::sync::Mutex<()>,
}

/// How many warm sockets are kept (the oldest goes first).
const MAX_WARM_SOCKETS: usize = 8;

fn warm() -> &'static Warm {
    static WARM: OnceLock<Warm> = OnceLock::new();
    WARM.get_or_init(|| Warm {
        http: ApiClient::http_client(),
        ice: Mutex::new(Vec::new()),
        sockets: tokio::sync::Mutex::new(Vec::new()),
        opening: tokio::sync::Mutex::new(()),
    })
}

/// How long `GET /v1/ice` may take before a dial goes on with host candidates only.
const ICE_BUDGET: Duration = Duration::from_secs(8);
/// How long a reused socket may stay silent after a ping before the dial
/// gives up on it and opens a fresh one.
const STALE_PROBE: Duration = Duration::from_millis(2500);

impl Warm {
    fn ice_cache(&self, base_url: &str) -> Arc<IceCache> {
        let mut caches = self.ice.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some((_, cache)) = caches.iter().find(|(url, _)| url == base_url) {
            return Arc::clone(cache);
        }
        let cache = Arc::new(IceCache::new());
        caches.push((base_url.to_owned(), Arc::clone(&cache)));
        cache
    }

    async fn ice_servers(&self, base_url: &str, token: &str, timeline: &Timeline) -> Vec<IceServer> {
        let api = ApiClient::with_http(base_url, token, self.http.clone());
        let (servers, cached) = self.ice_cache(base_url).get(&api, ICE_BUDGET).await;
        timeline.mark(if cached { "ice_servers_cached" } else { "ice_servers_fetched" });
        servers
    }

    /// The pooled socket for `key` while open (no probe).
    async fn pooled(&self, key: &SocketKey) -> Option<Arc<WarmSocket>> {
        let pool = self.sockets.lock().await;
        pool.iter().rev().find(|s| s.key == *key && s.client.closed_reason().is_none()).cloned()
    }

    /// The pooled socket for `key` (true), else a new one (false), waiting
    /// for one already opening.
    async fn pooled_or_open(
        &self,
        key: &SocketKey,
        token: &str,
        timeline: &Timeline,
    ) -> Result<(Arc<WarmSocket>, bool), CmuxMobileError> {
        if let Some(socket) = self.pooled(key).await {
            return Ok((socket, true));
        }
        let _opening = self.opening.lock().await;
        if let Some(socket) = self.pooled(key).await {
            timeline.mark("signaling_joined");
            return Ok((socket, true));
        }
        Ok((self.open_locked(key, token, timeline).await?, false))
    }

    /// A new socket for `key`, now the pooled one.
    async fn open(
        &self,
        key: &SocketKey,
        token: &str,
        timeline: &Timeline,
    ) -> Result<Arc<WarmSocket>, CmuxMobileError> {
        let _opening = self.opening.lock().await;
        self.open_locked(key, token, timeline).await
    }

    async fn open_locked(
        &self,
        key: &SocketKey,
        token: &str,
        timeline: &Timeline,
    ) -> Result<Arc<WarmSocket>, CmuxMobileError> {
        let client = SignalingClient::connect(&key.base_url, token, &key.team_id, &key.device_id)
            .await
            .map_err(|e| CmuxMobileError::Signaling { message: e.to_string() })?;
        timeline.mark("signaling_open");
        let socket = Arc::new(WarmSocket { key: key.clone(), client });
        let mut pool = self.sockets.lock().await;
        pool.retain(|s| s.key != *key && s.client.closed_reason().is_none());
        pool.push(Arc::clone(&socket));
        if pool.len() > MAX_WARM_SOCKETS {
            pool.remove(0);
        }
        drop(pool);
        // The service keeps one socket per device: this one replaced any other, so
        // every live WireGuard session of this device (one per Mac) moves onto it
        // now. A dial to a second Mac that found the shared socket dead left the
        // first Mac's session on the dead one until the next network change.
        if cmux_mobile_link::dial::wireguard::rehome(&socket.client) > 0 {
            timeline.mark("rehomed");
        }
        Ok(socket)
    }

    /// Forget `socket` if it is the pooled one.
    async fn evict(&self, socket: &Arc<WarmSocket>) {
        self.sockets.lock().await.retain(|s| !Arc::ptr_eq(s, socket));
    }
}

/// Warm what the next `connect` to this service, team and device needs:
/// fetch the ICE servers (unless cached) and open the signaling socket
/// (or, when one is open, check that it still answers). Call at launch,
/// on foreground and after sign-in, before the user asks for a Mac. Never
/// fails: the dial redoes whatever could not be warmed. Returns the steps.
#[uniffi::export]
pub async fn prewarm(base_url: String, token: String, team_id: String, device_id: String) -> Vec<TimingMark> {
    on_runtime(async move {
        let timeline = Timeline::new();
        let key = SocketKey { base_url: base_url.clone(), team_id, device_id };
        let socket = async {
            if let Some(socket) = warm().pooled(&key).await {
                if socket.client.probe(STALE_PROBE).await {
                    timeline.mark("signaling_alive");
                    return;
                }
                timeline.mark("signaling_stale");
                warm().evict(&socket).await;
            }
            if warm().pooled_or_open(&key, &token, &timeline).await.is_err() {
                timeline.mark("signaling_failed");
            }
        };
        tokio::join!(warm().ice_servers(&base_url, &token, &timeline), socket);
        timing_marks(&timeline)
    })
    .await
}

/// How long the signaling socket may take to answer after a network
/// change before a new one is opened (the old network's socket is usually
/// dead, and `bye` and new dials need a live one).
const NETWORK_PROBE: Duration = Duration::from_millis(1000);

/// The device's network changed or came back (iOS `NWPathMonitor`): every
/// WireGuard link moves onto the new network at once without a redial, and
/// the signaling socket is checked (and replaced when dead) so signaling
/// works again. Returns the steps: the first link's roam marks, then the
/// signaling ones prefixed `signaling:`.
#[uniffi::export]
pub async fn network_changed(
    base_url: String,
    token: String,
    team_id: String,
    device_id: String,
) -> Vec<TimingMark> {
    on_runtime(async move {
        let roam = tokio::spawn(cmux_mobile_link::dial::wireguard::network_changed());
        let timeline = Timeline::new();
        let key = SocketKey { base_url, team_id, device_id };
        if let Some(socket) = warm().pooled(&key).await {
            if socket.client.probe(NETWORK_PROBE).await {
                timeline.mark("alive");
            } else {
                timeline.mark("stale");
                warm().evict(&socket).await;
            }
        }
        match warm().pooled_or_open(&key, &token, &timeline).await {
            Ok((socket, _)) => {
                if cmux_mobile_link::dial::wireguard::rehome(&socket.client) > 0 {
                    timeline.mark("rehomed");
                }
            }
            Err(_) => timeline.mark("failed"),
        }
        let roamed = roam.await.unwrap_or_default();
        let mut marks = roamed.first().map(|(_, timeline)| timing_marks(timeline)).unwrap_or_default();
        marks.extend(
            timing_marks(&timeline)
                .into_iter()
                .map(|mark| TimingMark { name: format!("signaling:{}", mark.name), millis: mark.millis }),
        );
        marks
    })
    .await
}

/// Forget every warm socket and cached ICE server (sign-out, account switch).
#[uniffi::export]
pub async fn reset_warm_state() {
    on_runtime(async move {
        warm().sockets.lock().await.clear();
        for (_, cache) in warm().ice.lock().unwrap_or_else(PoisonError::into_inner).iter() {
            cache.clear();
        }
    })
    .await;
}

async fn dial(
    request: &ConnectRequest,
    timeline: &Timeline,
) -> Result<(cmux_mobile_link::Connected, Arc<WarmSocket>), CmuxMobileError> {
    for (name, value) in [
        ("base_url", &request.base_url),
        ("team_id", &request.team_id),
        ("device_id", &request.device_id),
        ("mac_device_id", &request.mac_device_id),
    ] {
        if value.trim().is_empty() {
            return Err(CmuxMobileError::InvalidArgument { message: format!("{name} is empty") });
        }
    }
    let key = SocketKey {
        base_url: request.base_url.clone(),
        team_id: request.team_id.clone(),
        device_id: request.device_id.clone(),
    };
    // ICE servers and the signaling socket are independent: get both at once.
    let socket = async {
        let (socket, reused) = warm().pooled_or_open(&key, &request.token, timeline).await?;
        if reused {
            timeline.mark("signaling_reused");
        }
        Ok::<_, CmuxMobileError>((socket, reused))
    };
    let (ice_servers, socket) =
        tokio::join!(warm().ice_servers(&request.base_url, &request.token, timeline), socket);
    let (socket, reused) = socket?;
    let ice_servers = without_turn_if_asked(ice_servers);
    let options = DialOptions {
        ice_servers,
        include_loopback: request.include_loopback,
        // The rig's relay-only and UDP-blocked runs (simulator:
        // SIMCTL_CHILD_CMUX_MOBILE_DEV_RELAY_ONLY=1, a phone on another network).
        relay_only: request.relay_only || std::env::var_os("CMUX_MOBILE_DEV_RELAY_ONLY").is_some(),
        // The rig's UDP-blocked runs (simulator:
        // SIMCTL_CHILD_CMUX_MOBILE_DEV_BLOCK_UDP=1) without touching app settings.
        block_udp: request.block_udp || std::env::var_os("CMUX_MOBILE_DEV_BLOCK_UDP").is_some(),
        video_lane: request.video_lane,
        webrtc_media: request.webrtc_media,
        timeline: timeline.clone(),
        ..DialOptions::default()
    };
    let attempt = dial_on(&socket, request, &options, reused).await;
    match attempt {
        Ok(connected) => Ok((connected, socket)),
        Err(Attempt::Stale) => {
            // The reused socket stopped answering (a phone that slept, a NAT
            // that forgot it): redial on a fresh one, once.
            timeline.mark("signaling_stale");
            warm().evict(&socket).await;
            let socket = warm().open(&key, &request.token, timeline).await?;
            match dial_on(&socket, request, &options, false).await {
                Ok(connected) => Ok((connected, socket)),
                Err(Attempt::Stale) => unreachable!("only a reused socket is probed"),
                Err(Attempt::Failed(error)) => Err(fail(&socket, error).await),
            }
        }
        Err(Attempt::Failed(error)) => Err(fail(&socket, error).await),
    }
}

/// Measurement support (simulator: SIMCTL_CHILD_CMUX_MOBILE_DEV_NO_TURN=1): no
/// TURN server, so WireGuard has only direct paths (and a relay-only or
/// UDP-blocked dial fails at once: there is no backend relay).
fn without_turn_if_asked(mut ice_servers: Vec<IceServer>) -> Vec<IceServer> {
    if std::env::var_os("CMUX_MOBILE_DEV_NO_TURN").is_some() {
        for server in &mut ice_servers {
            server.urls.retain(|url| !url.starts_with("turn:") && !url.starts_with("turns:"));
        }
        ice_servers.retain(|server| !server.urls.is_empty());
    }
    ice_servers
}

enum Attempt {
    Stale,
    Failed(DialError),
}

/// A failed dial on a socket the backend dropped evicts it, so the retry
/// opens a new one.
async fn fail(socket: &Arc<WarmSocket>, error: DialError) -> CmuxMobileError {
    if socket.client.closed_reason().is_some() || matches!(error, DialError::Signaling(_)) {
        warm().evict(socket).await;
    }
    error.into()
}

/// Dial on `socket`. A reused socket is probed while the dial runs: when it
/// does not answer within `STALE_PROBE`, the dial is abandoned as stale
/// instead of waiting out its whole timeout.
async fn dial_on(
    socket: &Arc<WarmSocket>,
    request: &ConnectRequest,
    options: &DialOptions,
    probe: bool,
) -> Result<cmux_mobile_link::Connected, Attempt> {
    let dial = cmux_mobile_link::dial::connect(
        &socket.client,
        &request.mac_device_id,
        request.transport.into(),
        options,
        LinkConfig::default(),
    );
    if !probe {
        return dial.await.map_err(Attempt::Failed);
    }
    tokio::pin!(dial);
    tokio::select! {
        result = &mut dial => result.map_err(Attempt::Failed),
        false = socket.client.probe(STALE_PROBE) => {
            // The probe failing may race a dial that just succeeded.
            match tokio::time::timeout(Duration::from_millis(1), &mut dial).await {
                Ok(result) => result.map_err(Attempt::Failed),
                Err(_) => Err(Attempt::Stale),
            }
        }
    }
}
