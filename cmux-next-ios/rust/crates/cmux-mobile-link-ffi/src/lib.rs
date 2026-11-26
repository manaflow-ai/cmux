//! uniffi bindings of cmux-mobile-link for the cmux-next-ios app (Swift).
//!
//! Every async function runs on one shared Tokio runtime owned by this
//! library, so Swift may await them from any executor.

use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::Duration;

use cmux_mobile_link::api::ApiClient;
use cmux_mobile_link::api::{HttpClient, IceCache, IceServer};
use cmux_mobile_link::link::{ChannelReceiver, ChannelSender};
use cmux_mobile_link::signaling::{AfterNetworkChange, after_network_change};
use cmux_mobile_link::viewport::{PhoneViewport, ViewportReceiver};
use cmux_mobile_link::{
    BuildSpace, ChannelEvent, DialError, DialOptions, LinkConfig, SignalingClient, Timeline,
};
use tokio::runtime::Runtime;

mod auto_chats;
mod browser;
#[doc(hidden)]
pub mod bundle;
mod catch_up;
mod chat_prompt_outbox;
mod classic_leftovers;
mod cloud_wake;
mod composer_outbox;
mod feed_list_edit;
mod follow_camera;
mod lan;
mod last_place;
mod link_progress;
mod link_side;
pub mod local_link;
mod mac_screen;
mod mailbox_client;
mod pair_requests;
mod pane_filter;
mod read_store;
mod relay_hold;
mod row_layout;
mod screen;
mod share_approval;
mod tabs;
mod task_composer;
mod terminal_chat;
mod terminal_fit;
mod terminal_prediction;
mod terminal_projection;
mod vnc;
mod window_layout;
mod workspace_groups;

pub use auto_chats::{
    AutoChat, AutoChatError, AutoChats, AutoHttp, AutoHttpError, AutoHttpReply, AutoHttpRequest,
};
pub use browser::{BrowserFrame, BrowserObserver, BrowserStats, BrowserStream};
pub use catch_up::{
    CatchUpAnswer, CatchUpAsk, CatchUpChatAsk, CatchUpChatPage, CatchUpCut, CatchUpError, CatchUpTree,
    PhoneCatchUp, catch_up_falls_back, catch_up_service,
};
pub use chat_prompt_outbox::{
    ChatAttachment, ChatCancelStep, ChatEditStep, ChatPromptDone, ChatPromptLook, ChatPromptOutbox,
    ChatPromptOutcome, ChatPromptRequest, ChatPromptTaken, ChatUploadState, ChatUploadedAttachment,
};
pub use classic_leftovers::{ClassicCleanupPlan, KeychainDelete, KeychainLeftover};
pub use cloud_wake::{
    CloudWakeAnswer, CloudWakeHint, CloudWakeIdle, CloudWakeOutcome, cloud_wake_hint, cloud_wake_idle,
    cloud_wake_input, cloud_wake_resumed, cloud_wake_version,
};
pub use composer_outbox::{
    ComposerOutbox, ComposerSendAnswer, ComposerSendDone, ComposerSendOutcome, ComposerSendRequest,
};
pub use follow_camera::{FollowCamera, FollowCameraMode, FollowRect};
pub use last_place::{LastPlaceAnchor, LastPlaceRecord, LastPlaceScreen, LastPlaceStore};
pub use link_progress::{HeldKeysExpiryReason, LinkProgressClock, held_keys_expiry};
pub use link_side::{LinkOpenSide, link_open_side};
pub use mac_screen::{MacScreenAnswer, MacScreenDisplay, MacScreenIceServer, MacScreenObserver, MacScreenRd};
pub use pane_filter::{
    PaneFilter, PaneFilterResult, PaneKind, PaneScope, pane_filter_apply, pane_filter_decode,
    pane_filter_default, pane_filter_encode, pane_filter_shows,
};
pub use read_store::{PhoneReadKey, PhoneReadStore, PhoneReadStoreError};
pub use share_approval::{ShareApprovalDraft, ShareAsk, share_approval_draft, share_approval_signed};
pub use tabs::{TabsEvent, TabsMirror, TabsRow, TabsViewport};
pub use task_composer::{
    TaskPickChange, TaskPickToggle, TaskTerminalLaunch, task_image_mime_type, task_pick_toggle,
    task_terminal_line,
};
pub use terminal_chat::{
    TabFace, TerminalChatCandidate, TerminalChatFaces, TerminalChatFacts, TerminalChatSwap,
};
pub use terminal_fit::{
    TerminalFitDecision, TerminalFitPolicy, TerminalFitReason, TerminalZoomGeometry, TerminalZoomState,
};
pub use terminal_prediction::{PredictedGlyph, PredictionLayout, TerminalPrediction};
pub use terminal_projection::{ProjectionSegment, ProjectionStats, TerminalProjection};
pub use vnc::{VncJsonError, vnc_json};
pub use window_layout::{WindowLayout, overview_columns, window_layout};
pub use workspace_groups::{
    GROUP_EDIT_CONFIRM_WINDOW, GROUP_EDIT_UNANSWERED_WINDOW, GroupEditStep, PendingGroupEdit,
    PhoneSidebarRow, PhoneWorkspaceGroup, WorkspaceGroupSlot, pending_group_edit_step, workspace_group_slots,
};

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
    /// Through cmux's own WebSocket relay over HTTPS (neither UDP nor TURN
    /// gets through: a network that allows only cmux's hosts, or only HTTPS).
    HttpsRelay,
    /// No working route at the moment.
    NoPath,
}

impl From<cmux_mobile_link::LinkPath> for LinkPath {
    fn from(value: cmux_mobile_link::LinkPath) -> Self {
        match value {
            cmux_mobile_link::LinkPath::Direct => Self::Direct,
            cmux_mobile_link::LinkPath::Turn => Self::Turn,
            cmux_mobile_link::LinkPath::TurnTls => Self::TurnTls,
            cmux_mobile_link::LinkPath::HttpsRelay => Self::HttpsRelay,
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
/// `Rtt`, `Media` and `Suspect`, then one `Disconnected`.
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
    /// The link heard nothing for `silent_millis` after a ping
    /// (`Link::suspect_state`): a dead or silent Mac, a dead network, a
    /// blackout. The link stays open and probes every second; the next
    /// `Rtt` says it answered again, and it closes (`Disconnected`) only
    /// after its keepalive timeout (45 s), so a blackout it survives keeps
    /// the session. Last in the enum so the other variants keep their
    /// numbers in the bindings.
    Suspect {
        silent_millis: u32,
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

/// The code of [`CmuxMobileError::Refused`] when no way to the Mac worked
/// and each one's failure is known (PROTOCOL.md "When no path works"): the
/// network blocks the link. Its message is the failures as one JSON object
/// (`cmux_mobile_link::dial::diagnosis::PathFailures`), which the app turns
/// into the person's sentence and the IT details.
pub const NETWORK_BLOCKED: &str = "network_blocked";

/// The code of [`CmuxMobileError::Refused`] when the cmux service refused the
/// access token (HTTP 401). The app refreshes the token once; a refused fresh
/// token is a revoked session (it stops redialing and asks to sign in).
pub const UNAUTHORIZED: &str = "unauthorized";

impl From<cmux_mobile_link::signaling::SignalingError> for CmuxMobileError {
    fn from(error: cmux_mobile_link::signaling::SignalingError) -> Self {
        match error {
            cmux_mobile_link::signaling::SignalingError::Unauthorized => {
                Self::Refused { code: UNAUTHORIZED.into(), message: error.to_string() }
            }
            other => Self::Signaling { message: other.to_string() },
        }
    }
}

impl From<DialError> for CmuxMobileError {
    fn from(error: DialError) -> Self {
        match error {
            DialError::Signaling(message) => Self::Signaling { message },
            DialError::Refused { code, message } => Self::Refused { code, message },
            DialError::Bye(reason) => Self::Refused { code: "bye".into(), message: reason },
            DialError::Timeout => Self::Timeout,
            DialError::Transport(message) | DialError::Unexpected(message) => Self::Transport { message },
            DialError::Blocked(failures) => {
                Self::Refused { code: NETWORK_BLOCKED.into(), message: failures.to_json() }
            }
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
    /// stays open for the next dial while the warm pool holds it. `None` for a
    /// link resumed on a dormant tunnel (no signaling ran) or one that came up
    /// directly on the LAN (`lan.rs`).
    _signaling: Option<Arc<WarmSocket>>,
    transport: Transport,
    path: tokio::sync::watch::Receiver<cmux_mobile_link::LinkPath>,
    /// A direct path's peer address (`peer_scope`).
    peer: cmux_mobile_link::dial::PeerAddr,
    watcher: Mutex<Option<tokio::task::JoinHandle<()>>>,
    timeline: Timeline,
    session_id: String,
    /// The WireGuard keys this link's tunnel handshook with (`None` on WebRTC).
    tunnel_keys: Option<cmux_mobile_link::dial::TunnelKeys>,
    /// The WebRTC media session beside a WireGuard link, when both sides
    /// support one (cmux_mobile_link::hybrid).
    media: Option<cmux_mobile_link::hybrid::MediaManager>,
    /// The phone end of viewport sync (cmux_mobile_link::viewport): what
    /// daemon channels ask for, and the link's datagram receivers.
    viewport: PhoneViewport,
    /// The Mac refused `bundle` (`unknown_service`, an older hostd): files go the old way on this link.
    bundle_refused: std::sync::atomic::AtomicBool,
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
        let mut args: serde_json::Value = if args_json.trim().is_empty() {
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
        // A daemon channel asks for pseq stamps and, with the gate on and an
        // overlay, viewport sync; its receiver turns synced screens into
        // `output` lines.
        let daemon = service == "daemon";
        if daemon {
            self.viewport.merge_daemon_args(&mut args);
        }
        let hub = (daemon && self.viewport.requests_sync()).then(|| self.viewport.clone());
        let link = self.link.clone();
        let channel = on_runtime(async move { link.open_on(&service, args, lane).await }).await?;
        let id = channel.id();
        let (sender, receiver) = channel.split();
        Ok(Arc::new(ChannelHandle {
            id,
            sender: Arc::new(sender),
            receiver: Arc::new(tokio::sync::Mutex::new(ViewportReceiver::new(receiver, hub))),
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

    /// Wake the radio before a keystroke (the terminal's keyboard took focus
    /// or a finger touched it): one datagram ping on a link quiet for a
    /// second. Free when the link is busy, parked or closed. `true` when sent.
    pub fn prewake(&self) -> bool {
        self.link.prewake()
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

    /// Before the OS suspends the app: ask the Mac to hold this link for up
    /// to `hold_ms` (at most 10 minutes) while the phone is silent, waiting
    /// at most `timeout_ms` for the answer (PROTOCOL.md "Parked link").
    /// `true`: parked, and nothing on the link wakes the phone until
    /// `resume`. `false`: an older Mac, no answer in time, or a WebRTC link,
    /// which cannot be held; the link closes on silence as before.
    pub async fn park(&self, hold_ms: u32, timeout_ms: u32) -> Result<bool, CmuxMobileError> {
        if self.transport != Transport::WireGuard {
            return Ok(false);
        }
        let link = self.link.clone();
        let hold = Duration::from_millis(u64::from(hold_ms));
        let timeout = Duration::from_millis(u64::from(timeout_ms));
        Ok(on_runtime(async move { link.park(hold, timeout).await }).await?)
    }

    /// Back from the background: the link expects the Mac again. `true` when
    /// it was parked and its hold has not passed. The tunnel then moves onto
    /// a fresh socket (as on a network change) and the caller probes; the
    /// first frame back ends the park on both sides.
    /// This link's relay-held send route (RFD 0142 R8), or `None` while [`relay_hold::set_relay_hold_enabled`]
    /// is off or the link is not a WireGuard session. One per link: keep it while the link lives.
    pub fn relay_hold(&self) -> Option<Arc<relay_hold::RelayHoldRoute>> {
        if !relay_hold::enabled() {
            return None;
        }
        let _runtime = runtime().enter();
        let ports = cmux_mobile_link::dial::wireguard::relay_hold_port(&self.session_id, true)?;
        Some(Arc::new(relay_hold::RelayHoldRoute::new(cmux_mobile_link::hold_route::HoldRoute::start(ports))))
    }

    pub fn resume(&self) -> bool {
        if !self.link.resume() {
            return false;
        }
        let _runtime = runtime().enter();
        cmux_mobile_link::dial::wireguard::resume_session(&self.session_id);
        true
    }

    /// How long a probe may wait for its pong on this link: `floor_ms`, or
    /// three smoothed round trips when longer (at most 5 s). The standby loop
    /// uses it, so a 1 s round trip does not time out every probe.
    pub fn probe_timeout_ms(&self, floor_ms: u32) -> u32 {
        let timeout = self.link.probe_timeout(Duration::from_millis(u64::from(floor_ms)));
        u32::try_from(timeout.as_millis()).unwrap_or(u32::MAX)
    }

    /// How long a resumed parked link may stay silent before the app races a
    /// fresh dial against it: three smoothed round trips plus 100 ms, within
    /// 250 ms and 1.5 s (500 ms before any round trip was measured).
    pub fn resume_hedge_ms(&self) -> u32 {
        u32::try_from(self.link.resume_hedge_after().as_millis()).unwrap_or(u32::MAX)
    }

    /// The app is in the foreground with a terminal or chat on screen
    /// (`true`), or not. While it is and the link's pings travel as
    /// WireGuard datagrams, the link probes every 3 s and is suspect after
    /// two unanswered probes; otherwise it pings on its 15 s keepalive alone.
    pub fn set_foreground_probe(&self, on: bool) {
        self.link.set_foreground_probe(on);
    }

    pub fn transport(&self) -> Transport {
        self.transport
    }

    pub fn path(&self) -> LinkPath {
        (*self.path.borrow()).into()
    }

    /// Where the direct path's peer address is: `lan`, `tailnet` (100.64.0.0/10 or Tailscale's
    /// IPv6 range), `wan`, or empty on a relayed path or before a route
    /// (`cmux_mobile_link::dial::peer_scope`). The app's DEBUG hand-off receipt names it, so a dev
    /// link over Tailscale says so.
    pub fn peer_scope(&self) -> String {
        cmux_mobile_link::dial::peer_scope(*self.peer.borrow()).to_owned()
    }

    pub fn is_closed(&self) -> bool {
        self.link.is_closed()
    }

    /// The WireGuard static public keys this link's tunnel handshook with, as `[dialer,
    /// answerer]` (base64), or empty on a link that is not a tunnel. The phone's `auth` signs
    /// them and checks the Mac's identity proof over them (cmux-mobile-host `pairing.rs`, v2).
    pub fn tunnel_keys(&self) -> Vec<String> {
        self.tunnel_keys
            .as_ref()
            .map(|keys| vec![keys.dialer.clone(), keys.answerer.clone()])
            .unwrap_or_default()
    }

    /// Milliseconds since the link last received any frame from the Mac.
    /// Any frame proves the link alive as a probe's pong would, so the app's
    /// heartbeat probes only a link quiet for a whole beat.
    pub fn received_ago_ms(&self) -> u64 {
        u64::try_from(self.link.received_ago().as_millis()).unwrap_or(u64::MAX)
    }

    /// Milliseconds since the link last received a frame other than a ping
    /// or a pong. With Align Keepalives on, the heartbeat probes a link with
    /// no traffic for a whole beat on the keepalive beat.
    pub fn traffic_ago_ms(&self) -> u64 {
        u64::try_from(self.link.traffic_ago().as_millis()).unwrap_or(u64::MAX)
    }

    /// Milliseconds since the link last made progress: anything heard from
    /// the Mac, or a write other than a keepalive taken by the transport
    /// (`Link::progress_ago`). The one progress clock a send's hold reads:
    /// `ChatPromptOutbox.progressed(nowMs - progressAgoMs())` is the adapter.
    pub fn progress_ago_ms(&self) -> u64 {
        u64::try_from(self.link.progress_ago().as_millis()).unwrap_or(u64::MAX)
    }

    /// How many times the link made progress; monotonic, so a change since
    /// the last read means it moved in between (`Link::progress_count`).
    pub fn progress_count(&self) -> u64 {
        self.link.progress_count()
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
            let path = path.borrow().as_str();
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
    receiver: Arc<tokio::sync::Mutex<ViewportReceiver>>,
    closed: Arc<Mutex<Option<(String, String)>>>,
}

#[uniffi::export]
impl ChannelHandle {
    pub fn id(&self) -> u32 {
        self.id
    }

    /// Payload bytes this channel has queued for the transport so far. It moves while a long
    /// write is taken by the link and stops when the link stalls: a request's deadline reads it
    /// as progress, not a wall clock (`DaemonClient` on iOS).
    pub fn sent_bytes(&self) -> u64 {
        self.sender.sent_bytes()
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
    /// Debug "simulate a network whose only way out is its proxy": like
    /// `block_udp`, and TURN over TLS must leave through the system's proxy
    /// (Settings > Wi-Fi > HTTP Proxy, PAC, an MDM profile); with none for the
    /// TURN server the dial fails at once and says so. WebRTC ignores it.
    #[uniffi(default = false)]
    pub proxy_only: bool,
    /// Debug "simulate a firewall that drops WireGuard": STUN and TURN's own
    /// requests pass, every UDP datagram carrying WireGuard (plain, or inside
    /// TURN over UDP) is dropped both ways, so WireGuard falls through to TURN
    /// over TLS (path `TurnTls`). WebRTC ignores it.
    #[uniffi(default = false)]
    pub drop_wireguard: bool,
    /// Debug "Relay via cmux (HTTPS) only": WireGuard sends no plain UDP and
    /// takes no TURN allocation; it joins cmux's WebSocket relay at once and
    /// rides it (path `HttpsRelay`). WebRTC ignores it.
    #[uniffi(default = false)]
    pub force_relay: bool,
    /// Debug: do not offer the media lane, so browser video rides its
    /// reliable channel on either transport (the comparison baseline).
    #[uniffi(default = false)]
    pub no_video_lane: bool,
    /// WireGuard: no WebRTC media session beside the link, so browser video
    /// rides RTP inside the tunnel (the "WireGuard only" comparison).
    #[uniffi(default = false)]
    pub no_webrtc_media: bool,
    /// WireGuard: the person's Settings > Transport > Ultra Mode, as the app
    /// stores it: `"off"`, `"auto"` (the default: no extra data on a clean
    /// link, repair data once packets are lost, capped while
    /// `set_cellular_path` says cellular) or `"always"` (repair data on
    /// every datagram, about 2-3x the bytes).
    #[uniffi(default = "auto")]
    pub ultra: String,
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
        proxy_only: options.proxy_only,
        drop_wireguard: options.drop_wireguard,
        force_relay: options.force_relay,
        video_lane: !options.no_video_lane,
        webrtc_media: !options.no_webrtc_media
            && std::env::var_os("CMUX_MOBILE_DEV_NO_WEBRTC_MEDIA").is_none(),
        ultra: cmux_mobile_link::UltraSetting::parse(&options.ultra),
    };
    on_runtime(connect_inner(request, observer)).await
}

/// The library version.
#[uniffi::export]
pub fn cmux_mobile_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}

/// What the phone's terminal declares in `set-client-info` for the lean stream
/// (`cmux_mobile_link::names::TERMINAL_LEAN_STREAM`).
#[uniffi::export]
pub fn terminal_lean_stream_capabilities() -> Vec<String> {
    cmux_mobile_link::names::TERMINAL_LEAN_STREAM.iter().map(|name| (*name).to_owned()).collect()
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
    /// `ConnectOptions::proxy_only`.
    pub proxy_only: bool,
    /// `ConnectOptions::drop_wireguard`.
    pub drop_wireguard: bool,
    /// Debug: ride cmux's WebSocket relay only (`ConnectOptions::force_relay`).
    pub force_relay: bool,
    /// Offer the media lane (browser video as RTP: a WebRTC track, or UDP inside the WireGuard tunnel).
    pub video_lane: bool,
    /// WireGuard: offer a WebRTC media session beside the link for browser
    /// video (cmux_mobile_link::hybrid).
    pub webrtc_media: bool,
    /// WireGuard: Settings > Transport > Ultra Mode (`ConnectOptions::ultra`).
    pub ultra: cmux_mobile_link::UltraSetting,
}

fn emit(observer: &Option<Arc<dyn LinkObserver>>, event: LinkEvent) {
    if let Some(observer) = observer {
        observer.on_event(event);
    }
}

/// `connect` on the process's warm pool, on the caller's runtime.
#[doc(hidden)]
pub async fn connect_inner(
    request: ConnectRequest,
    observer: Option<Arc<dyn LinkObserver>>,
) -> Result<Arc<LinkHandle>, CmuxMobileError> {
    WarmPool::shared().connect(request, observer).await
}

async fn connect_on(
    pool: &Arc<Warm>,
    request: ConnectRequest,
    observer: Option<Arc<dyn LinkObserver>>,
) -> Result<Arc<LinkHandle>, CmuxMobileError> {
    let timeline = Timeline::new();
    let transport = request.transport;
    emit(&observer, LinkEvent::Connecting { transport });
    // The relay dial may itself come back without a socket (a dormant resume), so the race's
    // "no socket" and the dial's fold into one.
    let result = lan::race(&request.mac_device_id, &timeline, dial(pool, &request, &timeline))
        .await
        .map(|(connected, signaling)| (connected, signaling.flatten()));
    let (connected, signaling) = match result {
        Ok(ok) => ok,
        Err(error) => {
            emit(&observer, LinkEvent::Disconnected { reason: error.to_string() });
            return Err(error);
        }
    };
    finish_link(pool, &request, connected, signaling, timeline, observer).await
}

/// A dialed link's handle: its watcher, first ping and path report.
async fn finish_link(
    pool: &Arc<Warm>,
    request: &ConnectRequest,
    connected: cmux_mobile_link::Connected,
    signaling: Option<Arc<WarmSocket>>,
    timeline: Timeline,
    observer: Option<Arc<dyn LinkObserver>>,
) -> Result<Arc<LinkHandle>, CmuxMobileError> {
    let transport = request.transport;
    let viewport = PhoneViewport::new(connected.overlay.as_ref(), cmux_mobile_link::viewport::enabled());
    let mut path = connected.path.clone();
    emit(&observer, LinkEvent::Connected { transport, path: (*path.borrow()).into() });
    let media = match &signaling {
        Some(socket) if connected.webrtc_media => Some(media_manager(pool, request, &connected, socket)),
        _ => None,
    };
    lan::enroll_later(connected.link.clone(), request.mac_device_id.clone());
    let mut media_status = media.as_ref().map(cmux_mobile_link::hybrid::MediaManager::status);
    let link = connected.link.clone();
    let watcher = tokio::spawn(async move {
        let mut rtt = link.rtt();
        let mut closed = link.closed_state();
        let mut suspect = link.suspect_state();
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
                changed = suspect.changed() => {
                    if changed.is_err() { break; }
                    if *suspect.borrow_and_update() {
                        let silent_millis = u32::try_from(link.received_ago().as_millis()).unwrap_or(u32::MAX);
                        emit(&observer, LinkEvent::Suspect { silent_millis });
                    }
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
    // The path report (PROTOCOL.md "Link stats"): on the pool's current socket for this team and
    // device, so a replaced socket still carries it; it ends with the link.
    cmux_mobile_link::link_stat::spawn(
        connected.link.clone(),
        connected.transport,
        connected.path.clone(),
        timeline.clone(),
        match &signaling {
            Some(socket) => current_signaling(pool, socket),
            // A LAN direct link (lan.rs) has no socket of its own: the pool's, when one is open.
            None => pooled_signaling(pool, request),
        },
        connected.session_id.clone(),
    );
    Ok(Arc::new(LinkHandle {
        link: connected.link,
        _signaling: signaling,
        transport,
        path: connected.path,
        peer: connected.peer,
        watcher: Mutex::new(Some(watcher)),
        timeline,
        session_id: connected.session_id,
        tunnel_keys: connected.tunnel_keys,
        media,
        viewport,
        bundle_refused: std::sync::atomic::AtomicBool::new(false),
    }))
}

/// The pool's current signaling socket for `request`'s team and device (a
/// resumed link's: it was dialed on none).
fn pooled_signaling(pool: &Arc<Warm>, request: &ConnectRequest) -> cmux_mobile_link::hybrid::SignalingSource {
    let key = SocketKey {
        base_url: request.base_url.clone(),
        team_id: request.team_id.clone(),
        device_id: request.device_id.clone(),
        build_space: build_space(),
    };
    let pool = Arc::clone(pool);
    Arc::new(move || {
        let key = key.clone();
        let pool = Arc::clone(&pool);
        Box::pin(async move { pool.pooled(&key).await.map(|socket| socket.client.clone()) })
    })
}

/// The pool's current signaling socket for `socket`'s team and device, else `socket` itself while
/// it is open (the media session and the path report send on it).
fn current_signaling(
    pool: &Arc<Warm>,
    socket: &Arc<WarmSocket>,
) -> cmux_mobile_link::hybrid::SignalingSource {
    let key = socket.key.clone();
    let fallback = socket.client.clone();
    let local = socket.local;
    let pool = Arc::clone(pool);
    Arc::new(move || {
        let key = key.clone();
        let fallback = fallback.clone();
        let pool = Arc::clone(&pool);
        Box::pin(async move {
            // A local link signals through its own hub, not the service's socket.
            let pooled = if local { None } else { pool.pooled(&key).await };
            match pooled {
                Some(socket) => Some(socket.client.clone()),
                None => (fallback.closed_reason().is_none()).then_some(fallback),
            }
        })
    })
}

/// The phone's media session manager for a WireGuard link both sides
/// agreed to pair with a WebRTC media session. It dials on the warm pool's
/// current socket for this team and device (the link's may have been
/// replaced since) with fresh ICE servers.
fn media_manager(
    pool: &Arc<Warm>,
    request: &ConnectRequest,
    connected: &cmux_mobile_link::Connected,
    socket: &Arc<WarmSocket>,
) -> cmux_mobile_link::hybrid::MediaManager {
    let signaling = current_signaling(pool, socket);
    let base_url = request.base_url.clone();
    let token = request.token.clone();
    // Cached servers while fresh; else fetched with the dial's token (best
    // effort: an expired token leaves host candidates only).
    let ice_pool = Arc::clone(pool);
    let ice: cmux_mobile_link::hybrid::IceSource = Arc::new(move || {
        let (base_url, token) = (base_url.clone(), token.clone());
        let pool = Arc::clone(&ice_pool);
        Box::pin(
            async move { without_turn_if_asked(pool.ice_servers(&base_url, &token, &Timeline::new()).await) },
        )
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
    /// The build space the socket's upgrade carried (`set_build_space`): a
    /// change opens a new socket instead of reusing one in the old space.
    build_space: Option<BuildSpace>,
}

/// A signaling socket shared by the warm pool and the links dialed on it;
/// it closes when the last of them lets go.
#[doc(hidden)]
pub struct WarmSocket {
    key: SocketKey,
    client: SignalingClient,
    /// A socket to a Mac's local hub (`local_link`): never pooled, never replaced by the service's.
    local: bool,
}

impl Drop for WarmSocket {
    fn drop(&mut self) {
        self.client.close();
    }
}

/// State kept between dials so a dial does not pay for work an earlier
/// dial or `prewarm` already did: one HTTP connection pool (a
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

/// A warm pool. The exported functions (`connect`, `prewarm`,
/// `network_changed`, `reset_warm_state`) all use the process's shared one;
/// a test makes its own, so another test's `reset` or its sockets filling
/// the `MAX_WARM_SOCKETS` cap cannot empty it mid-test.
#[doc(hidden)]
#[derive(Clone)]
pub struct WarmPool(Arc<Warm>);

impl Default for WarmPool {
    fn default() -> Self {
        Self::new()
    }
}

impl WarmPool {
    /// An empty pool of its own.
    pub fn new() -> Self {
        Self(Arc::new(Warm {
            http: ApiClient::http_client(),
            ice: Mutex::new(Vec::new()),
            sockets: tokio::sync::Mutex::new(Vec::new()),
            opening: tokio::sync::Mutex::new(()),
        }))
    }

    /// The process's pool, the one the exported functions use.
    pub fn shared() -> &'static WarmPool {
        static WARM: OnceLock<WarmPool> = OnceLock::new();
        WARM.get_or_init(WarmPool::new)
    }

    /// `connect_inner` on this pool.
    pub async fn connect(
        &self,
        request: ConnectRequest,
        observer: Option<Arc<dyn LinkObserver>>,
    ) -> Result<Arc<LinkHandle>, CmuxMobileError> {
        connect_on(&self.0, request, observer).await
    }

    /// `prewarm` on this pool. Like every exported call it runs on the
    /// library's runtime, never the caller's: the sockets it opens and the
    /// tasks they spawn must outlive a caller's runtime (a test's ends with
    /// the test).
    pub async fn prewarm(
        &self,
        base_url: String,
        token: String,
        team_id: String,
        device_id: String,
    ) -> Vec<TimingMark> {
        let pool = Arc::clone(&self.0);
        on_runtime(async move { prewarm_on(&pool, base_url, token, team_id, device_id).await }).await
    }

    /// `network_changed` on this pool, on the library's runtime. It roams
    /// every live WireGuard session of the process, so the roam (its new
    /// UDP socket, its TURN allocation) must not run on a caller's runtime:
    /// a test's ends with the test, and a session another test still uses
    /// would be left on a socket whose reactor is gone (cmux#41791: a relay-only
    /// link stalled forever).
    pub async fn network_changed(
        &self,
        base_url: String,
        token: String,
        team_id: String,
        device_id: String,
    ) -> Vec<TimingMark> {
        let pool = Arc::clone(&self.0);
        on_runtime(async move { network_changed_on(&pool, base_url, token, team_id, device_id).await }).await
    }

    /// `reset_warm_state` on this pool.
    pub async fn reset(&self) {
        let pool = Arc::clone(&self.0);
        on_runtime(async move {
            pool.sockets.lock().await.clear();
            for (_, cache) in pool.ice.lock().unwrap_or_else(PoisonError::into_inner).iter() {
                cache.clear();
            }
        })
        .await;
    }
}

async fn prewarm_on(
    pool: &Warm,
    base_url: String,
    token: String,
    team_id: String,
    device_id: String,
) -> Vec<TimingMark> {
    let timeline = Timeline::new();
    let key = SocketKey { base_url: base_url.clone(), team_id, device_id, build_space: build_space() };
    let socket = async {
        if let Some(socket) = pool.reusable(&key, &timeline).await {
            if socket.client.probe(STALE_PROBE).await {
                timeline.mark("signaling_alive");
                return;
            }
            timeline.mark("signaling_stale");
            pool.evict(&socket).await;
        }
        if pool.pooled_or_open(&key, &token, &timeline).await.is_err() {
            timeline.mark("signaling_failed");
        }
    };
    tokio::join!(pool.ice_servers(&base_url, &token, &timeline), socket);
    timing_marks(&timeline)
}

async fn network_changed_on(
    pool: &Warm,
    base_url: String,
    token: String,
    team_id: String,
    device_id: String,
) -> Vec<TimingMark> {
    // The ads were seen on the old network: a dial now would wait on a dead hub.
    local_link::local_link_forget_all();
    let roam = tokio::spawn(cmux_mobile_link::dial::wireguard::network_changed());
    let timeline = Timeline::new();
    let key = SocketKey { base_url, team_id, device_id, build_space: build_space() };
    // The new socket opens at once, the old one probed beside it, never before it
    // (`after_network_change`); a new socket moves every session onto it (`open` rehomes them).
    let old = pool.pooled(&key).await;
    let open = pool.open_after_change(&key, &token, old.as_ref(), &timeline);
    let outcome = after_network_change(old.as_ref().map(|socket| &socket.client), open).await;
    if let AfterNetworkChange::OldAnswered { open_slow: true } = outcome {
        timeline.mark("open_slow");
    }
    if !matches!(outcome, AfterNetworkChange::Opened(_)) {
        pool.fall_back(&key, old.as_ref(), outcome.old_answered(), &timeline).await;
    }
    let roamed = roam.await.unwrap_or_default();
    let mut marks = roamed.first().map(|(_, timeline)| timing_marks(timeline)).unwrap_or_default();
    marks.extend(
        timing_marks(&timeline)
            .into_iter()
            .map(|mark| TimingMark { name: format!("signaling:{}", mark.name), millis: mark.millis }),
    );
    marks
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
        let api = ApiClient::with_http(base_url, token, self.http.clone()).with_build_space(build_space());
        let (servers, cached) = self.ice_cache(base_url).get(&api, ICE_BUDGET).await;
        timeline.mark(if cached { "ice_servers_cached" } else { "ice_servers_fetched" });
        servers
    }

    /// The pooled socket for `key` while open (no probe).
    async fn pooled(&self, key: &SocketKey) -> Option<Arc<WarmSocket>> {
        let pool = self.sockets.lock().await;
        pool.iter().rev().find(|s| s.key == *key && s.client.closed_reason().is_none()).cloned()
    }

    /// The pooled socket for `key` while it has heard from the service within one keepalive
    /// ([`SignalingClient::is_fresh`]). One that missed a pong (the phone slept, or the app was
    /// suspended past a keepalive) is dropped here instead of reused: a dial on it waited
    /// [`STALE_PROBE`] (2.5 s) for an answer a half-open socket never sends, and only then
    /// opened the socket it could have opened at once (ask-48f698fc26).
    async fn reusable(&self, key: &SocketKey, timeline: &Timeline) -> Option<Arc<WarmSocket>> {
        let socket = self.pooled(key).await?;
        if socket.client.is_fresh() {
            return Some(socket);
        }
        timeline.mark("signaling_quiet");
        self.evict(&socket).await;
        None
    }

    /// The pooled socket for `key` (true), else a new one (false), waiting
    /// for one already opening.
    async fn pooled_or_open(
        &self,
        key: &SocketKey,
        token: &str,
        timeline: &Timeline,
    ) -> Result<(Arc<WarmSocket>, bool), CmuxMobileError> {
        if let Some(socket) = self.reusable(key, timeline).await {
            return Ok((socket, true));
        }
        let _opening = self.opening.lock().await;
        if let Some(socket) = self.reusable(key, timeline).await {
            timeline.mark("signaling_joined");
            return Ok((socket, true));
        }
        Ok((self.open_locked(key, token, timeline).await?, false))
    }

    /// A new socket for `key`, now the pooled one (tests open one directly).
    #[cfg(test)]
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
        let client = SignalingClient::connect_in(
            &key.base_url,
            token,
            &key.team_id,
            &key.device_id,
            key.build_space.as_ref(),
        )
        .await
        .map_err(CmuxMobileError::from)?;
        timeline.mark("signaling_open");
        Ok(self.store_opened(key, client, timeline).await)
    }

    /// Add a signaling client to the pool as soon as its upgrade completes.
    /// The opening lock is held by the caller when this is part of a redial,
    /// so another redial cannot replace it before the dial takes the socket.
    async fn store_opened(
        &self,
        key: &SocketKey,
        client: SignalingClient,
        timeline: &Timeline,
    ) -> Arc<WarmSocket> {
        let socket = Arc::new(WarmSocket { key: key.clone(), client, local: false });
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
        socket
    }

    /// A new socket for `key` after a network change, unless one opened since `old` was the
    /// pooled one. Two changes in a burst both see `old`; the second waits here for the first's
    /// open and then uses its socket instead of opening another (the service keeps one socket
    /// per device, so a second open would replace the first).
    async fn open_after_change(
        &self,
        key: &SocketKey,
        token: &str,
        old: Option<&Arc<WarmSocket>>,
        timeline: &Timeline,
    ) -> Result<Arc<WarmSocket>, CmuxMobileError> {
        let _opening = self.opening.lock().await;
        if let Some(current) = self.pooled(key).await
            && !old.is_some_and(|old| Arc::ptr_eq(&current, old))
        {
            timeline.mark("signaling_joined");
            return Ok(current);
        }
        self.open_locked(key, token, timeline).await
    }

    /// After a network change whose new socket did not open: the socket another change opened
    /// meanwhile, else `old` if it answered and is still the pooled one, else none. A socket that
    /// was replaced since `old` was seen is never taken back, even if it still answers.
    async fn fall_back(
        &self,
        key: &SocketKey,
        old: Option<&Arc<WarmSocket>>,
        alive: bool,
        timeline: &Timeline,
    ) {
        let socket = match self.pooled(key).await {
            Some(current) if !old.is_some_and(|old| Arc::ptr_eq(&current, old)) => {
                timeline.mark("signaling_joined");
                current
            }
            Some(current) if alive => {
                timeline.mark("alive");
                current
            }
            Some(current) => {
                timeline.mark("failed");
                self.evict(&current).await;
                return;
            }
            None => {
                timeline.mark("failed");
                return;
            }
        };
        if cmux_mobile_link::dial::wireguard::rehome(&socket.client) > 0 {
            timeline.mark("rehomed");
        }
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
    WarmPool::shared().prewarm(base_url, token, team_id, device_id).await
}

/// The device's network is cellular now, or not (iOS `NWPathMonitor`,
/// `NWPath.usesInterfaceType(.cellular)`; every path update, the first one
/// too). Every WireGuard link in Auto (`ConnectOptions::ultra`) reads it
/// live: on cellular its repair data stays within its data bytes.
#[uniffi::export]
pub fn set_cellular_path(cellular: bool) {
    cmux_mobile_link::dial::wireguard::set_cellular_path(cellular);
}

/// Keep the IP literals every dialed host (TURN, STUN, signaling, API) last resolved to in the
/// file at `path` (an Application Support file of this build's own), so a dial after a relaunch
/// with DNS down still reaches them (`cmux_mobile_link::route_literals`). Without a call they
/// are kept for this process only. Returns how many hosts the file remembered.
#[uniffi::export]
pub fn set_route_literals_path(path: String) -> u32 {
    let loaded = cmux_mobile_link::route_literals::RouteLiterals::shared().set_file(path);
    u32::try_from(loaded).unwrap_or(u32::MAX)
}

/// The Mac answered a typed batch's `send` `ack_ms` after its first key's tap
/// (`DaemonTerminalSession`). The next `link_stat` carries it (PROTOCOL.md "Link stats").
#[uniffi::export]
pub fn record_key_ack(ack_ms: u32) {
    cmux_mobile_link::key_echo::record_ack(ack_ms);
}

/// The first terminal output after a typed batch came `echo_ms` after its first
/// key's tap; `ack_ms` when the Mac's answer to that batch had already come.
#[uniffi::export]
pub fn record_key_echo(echo_ms: u32, ack_ms: Option<u32>) {
    cmux_mobile_link::key_echo::record_echo(echo_ms, ack_ms);
}

/// A typed key's echo was painted `paint_ms` after its tap (the terminal's
/// first frame showing the Mac's echo of it, `TerminalViewController`).
/// Counted in the key-to-paint histogram under the current network and route.
#[uniffi::export]
pub fn record_key_paint(paint_ms: u32) {
    cmux_mobile_link::key_paint::record(paint_ms);
}

/// The device's network now, `wifi`, `lte` (any cellular), `wired` or
/// `other` (iOS `NWPathMonitor`, every path update): the key-to-paint tag.
#[uniffi::export]
pub fn set_network_kind(kind: String) {
    cmux_mobile_link::key_paint::set_network(&kind);
}

/// The key-to-paint histogram as JSON: per network and route p50/p95/p99,
/// max and bucket counts; the newest spikes, the gaps between them and the
/// period they share, if any (named by the link timer it matches).
#[uniffi::export]
pub fn key_paint_snapshot() -> String {
    cmux_mobile_link::key_paint::snapshot_json()
}

/// Empty the key-to-paint histogram.
#[uniffi::export]
pub fn reset_key_paint() {
    cmux_mobile_link::key_paint::reset();
}

/// This process's build space (`set_build_space`); nil: none (no header).
static BUILD_SPACE: Mutex<Option<BuildSpace>> = Mutex::new(None);

fn build_space() -> Option<BuildSpace> {
    BUILD_SPACE.lock().unwrap_or_else(PoisonError::into_inner).clone()
}

/// A dev build's cloud data space, `dev:<slug>` (Swift `CMUXBuildSpace`),
/// set once at launch by the app's composition root before any `connect`
/// or `prewarm`: every `GET /v1/ice` and signaling upgrade then carries
/// `x-cmux-build-space`. `None`, or a value that is not `dev:<slug>`, sends
/// no header (nightly, TestFlight and App Store builds never call it with a
/// value). A change takes effect for the next socket opened; a socket opened
/// in another space is not reused.
#[uniffi::export]
pub fn set_build_space(value: Option<String>) {
    let space = BuildSpace::parse_optional(value.as_deref());
    *BUILD_SPACE.lock().unwrap_or_else(PoisonError::into_inner) = space;
}

/// Settings → Transport → Align Keepalives (off by default): every
/// keepalive of the phone goes out on the same beats
/// (`cmux_mobile_link::keepalive`). Read by each dial and by the signaling
/// socket's next keepalive tick.
#[uniffi::export]
pub fn set_keepalive_alignment(on: bool) {
    cmux_mobile_link::keepalive::set_aligned(on);
}

/// Milliseconds from now until the next keepalive beat of `period_ms`, for
/// the app's own timers (presence, Cloud Chief, the link heartbeat), so
/// they share the Rust keepalives' instants.
#[uniffi::export]
pub fn keepalive_beat_delay_ms(period_ms: u64) -> u64 {
    let delay = cmux_mobile_link::keepalive::delay_to_beat(Duration::from_millis(period_ms.max(1)));
    u64::try_from(delay.as_millis()).unwrap_or(u64::MAX)
}

#[cfg(test)]
mod redial_tests {
    use super::*;
    use cmux_mobile_link::testing::{FakeOptions, FakeSignaling, TestTurn};

    fn request(base_url: &str, device_id: &str, mac_device_id: &str) -> ConnectRequest {
        ConnectRequest {
            base_url: base_url.into(),
            token: "user:alice".into(),
            team_id: "team".into(),
            device_id: device_id.into(),
            mac_device_id: mac_device_id.into(),
            transport: Transport::WireGuard,
            include_loopback: true,
            relay_only: true,
            force_relay: false,
            block_udp: false,
            proxy_only: false,
            drop_wireguard: false,
            video_lane: false,
            webrtc_media: false,
            ultra: cmux_mobile_link::UltraSetting::Off,
        }
    }

    fn key(request: &ConnectRequest) -> SocketKey {
        SocketKey {
            base_url: request.base_url.clone(),
            team_id: request.team_id.clone(),
            device_id: request.device_id.clone(),
            build_space: build_space(),
        }
    }

    fn options(turn: &TestTurn) -> DialOptions {
        DialOptions {
            ice_servers: vec![turn.udp_only()],
            include_loopback: true,
            relay_only: true,
            timeout: Duration::from_secs(10),
            timeline: Timeline::new(),
            ..DialOptions::default()
        }
    }

    async fn held(turn: &TestTurn, want: usize) -> bool {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        while turn.allocations() != want {
            if tokio::time::Instant::now() >= deadline {
                return false;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        true
    }

    async fn holding_mac(server: &FakeSignaling, mac_device_id: &str) -> SignalingClient {
        let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", mac_device_id)
            .await
            .expect("Mac signaling");
        let serving = mac.clone();
        tokio::spawn(async move { while serving.next_session().await.is_some() {} });
        mac
    }

    fn redial(
        pool: WarmPool,
        request: ConnectRequest,
        options: DialOptions,
    ) -> impl std::future::Future<Output = Result<(cmux_mobile_link::Connected, Arc<WarmSocket>), CmuxMobileError>>
    {
        let pool = Arc::clone(&pool.0);
        let key = key(&request);
        async move { redial_after(&pool, &key, &request, &options, &options.timeline).await }
    }

    /// Dropping the FFI pool's real replacement dial releases the early TURN
    /// allocation even while the Mac never answers the session.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn ffi_pool_redial_drop_releases_early_turn() {
        let turn = TestTurn::start().await;
        let server = FakeSignaling::start(FakeOptions {
            ice_servers: vec![turn.udp_only()],
            strip_direct_endpoints: true,
            ..FakeOptions::default()
        })
        .await;
        let pool = WarmPool::new();
        let mac_id = uuid::Uuid::new_v4().to_string();
        let _mac = holding_mac(&server, &mac_id).await;
        let request = request(&server.base_url, &uuid::Uuid::new_v4().to_string(), &mac_id);
        let options = options(&turn);
        let mut dial = tokio::spawn(redial(pool.clone(), request, options));
        tokio::select! {
            allocated = held(&turn, 1) => assert!(allocated, "the replacement redial never allocated TURN"),
            result = &mut dial => match result {
                Ok(Ok(_)) => panic!("replacement redial unexpectedly connected"),
                Ok(Err(error)) => panic!("replacement redial failed before allocation: {error:?}"),
                Err(error) => panic!("replacement redial task failed: {error}"),
            },
        }
        dial.abort();
        assert!(held(&turn, 0).await, "{} TURN allocations held after drop", turn.allocations());
        pool.reset().await;
    }

    /// A pool teardown during a replacement dial follows the app-background
    /// path and leaves no allocation held by the abandoned redial.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn ffi_pool_teardown_mid_redial_releases_early_turn() {
        let turn = TestTurn::start().await;
        let server = FakeSignaling::start(FakeOptions {
            ice_servers: vec![turn.udp_only()],
            strip_direct_endpoints: true,
            ..FakeOptions::default()
        })
        .await;
        let pool = WarmPool::new();
        let mac_id = uuid::Uuid::new_v4().to_string();
        let _mac = holding_mac(&server, &mac_id).await;
        let request = request(&server.base_url, &uuid::Uuid::new_v4().to_string(), &mac_id);
        let options = options(&turn);
        let dial = tokio::spawn(redial(pool.clone(), request, options));
        assert!(held(&turn, 1).await, "the replacement redial never allocated TURN");
        pool.reset().await;
        dial.abort();
        assert!(held(&turn, 0).await, "{} TURN allocations held after pool teardown", turn.allocations());
    }

    /// A flapping network makes the app redial one link ten times, each
    /// attempt cancelling the one before (Swift drops the connect future).
    /// Sampling the TURN server through the storm shows at most one held
    /// allocation, and none after it.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn ffi_pool_redial_storm_holds_at_most_one_turn_allocation() {
        let turn = Arc::new(TestTurn::start().await);
        let server = FakeSignaling::start(FakeOptions {
            ice_servers: vec![turn.udp_only()],
            strip_direct_endpoints: true,
            ..FakeOptions::default()
        })
        .await;
        let pool = WarmPool::new();
        let mac_id = uuid::Uuid::new_v4().to_string();
        let _mac = holding_mac(&server, &mac_id).await;
        let device_id = uuid::Uuid::new_v4().to_string();
        let maximum = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let sampling = {
            let turn = Arc::clone(&turn);
            let maximum = Arc::clone(&maximum);
            tokio::spawn(async move {
                loop {
                    maximum.fetch_max(turn.allocations(), std::sync::atomic::Ordering::Relaxed);
                    tokio::time::sleep(Duration::from_millis(1)).await;
                }
            })
        };
        let mut previous: Option<tokio::task::JoinHandle<_>> = None;
        for _ in 0..10 {
            if let Some(attempt) = previous.take() {
                attempt.abort();
                let _ = attempt.await;
                assert!(held(&turn, 0).await, "a cancelled redial kept its TURN allocation");
            }
            let attempt = tokio::spawn(redial(
                pool.clone(),
                request(&server.base_url, &device_id, &mac_id),
                options(&turn),
            ));
            assert!(held(&turn, 1).await, "a redial in the storm never allocated TURN");
            previous = Some(attempt);
        }
        if let Some(attempt) = previous.take() {
            attempt.abort();
            let _ = attempt.await;
        }
        assert!(held(&turn, 0).await, "{} TURN allocations held after storm", turn.allocations());
        sampling.abort();
        let maximum = maximum.load(std::sync::atomic::Ordering::Relaxed);
        assert!(maximum <= 1, "redial storm held {maximum} TURN allocations");
    }

    /// A redial waiting on the Mac does not hold the opening lock: a dial for
    /// another team opens its socket while the redial is still negotiating.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn ffi_pool_redial_lets_another_key_open_mid_dial() {
        let turn = Arc::new(TestTurn::start().await);
        let server = FakeSignaling::start(FakeOptions {
            ice_servers: vec![turn.udp_only()],
            strip_direct_endpoints: true,
            ..FakeOptions::default()
        })
        .await;
        let pool = WarmPool::new();
        let mac_id = uuid::Uuid::new_v4().to_string();
        let _mac = holding_mac(&server, &mac_id).await;
        let device_id = uuid::Uuid::new_v4().to_string();
        let dial = tokio::spawn(redial(
            pool.clone(),
            request(&server.base_url, &device_id, &mac_id),
            options(&turn),
        ));
        assert!(held(&turn, 1).await, "the redial never allocated TURN");
        let mut other = request(&server.base_url, &device_id, &mac_id);
        other.team_id = "other-team".into();
        let opened = tokio::time::timeout(
            Duration::from_secs(2),
            pool.0.open(&key(&other), &other.token, &Timeline::new()),
        )
        .await
        .map(|opened| opened.map(|_| ()));
        dial.abort();
        assert!(matches!(opened, Ok(Ok(()))), "another key's socket waited on the redial: {opened:?}");
        assert!(held(&turn, 0).await, "{} TURN allocations held after drop", turn.allocations());
        pool.reset().await;
    }

    /// A signaling upgrade failure does not leak an early allocation when the
    /// pool cannot establish its replacement socket.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn ffi_pool_signaling_failure_releases_early_turn() {
        let turn = TestTurn::start().await;
        let pool = WarmPool::new();
        let request = request("http://127.0.0.1:1", &uuid::Uuid::new_v4().to_string(), "missing-mac");
        let options = options(&turn);
        let result = redial(pool, request, options).await;
        assert!(result.is_err());
        assert!(held(&turn, 0).await, "{} TURN allocations held after signaling failure", turn.allocations());
    }
}

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
    WarmPool::shared().network_changed(base_url, token, team_id, device_id).await
}

/// Forget every warm socket and cached ICE server (sign-out, account switch).
#[uniffi::export]
pub async fn reset_warm_state() {
    WarmPool::shared().reset().await;
    cmux_mobile_link::dial::wireguard::dormant::forget_all();
}

/// The dial's options for `request` (the service's ICE servers; none for a hub dial).
fn dial_options(request: &ConnectRequest, ice_servers: Vec<IceServer>, timeline: &Timeline) -> DialOptions {
    DialOptions {
        ice_servers,
        // cmux's WebSocket relay, on the service the phone signs in and signals
        // through: the last way to the Mac (PROTOCOL.md "WebSocket relay").
        // CMUX_MOBILE_DEV_NO_RELAY=1 (simulator) dials without it.
        relay: std::env::var_os("CMUX_MOBILE_DEV_NO_RELAY").is_none().then(|| {
            cmux_mobile_link::dial::relay::RelayEndpoint::with_token(
                request.base_url.clone(),
                build_space(),
                request.device_id.clone(),
                request.token.clone(),
            )
        }),
        // Debug "Relay via cmux (HTTPS) only" (simulator:
        // SIMCTL_CHILD_CMUX_MOBILE_DEV_FORCE_RELAY=1).
        force_relay: request.force_relay || std::env::var_os("CMUX_MOBILE_DEV_FORCE_RELAY").is_some(),
        include_loopback: request.include_loopback,
        // The rig's relay-only and UDP-blocked runs (simulator:
        // SIMCTL_CHILD_CMUX_MOBILE_DEV_RELAY_ONLY=1, a phone on another network).
        relay_only: request.relay_only || std::env::var_os("CMUX_MOBILE_DEV_RELAY_ONLY").is_some(),
        // The rig's UDP-blocked runs (simulator:
        // SIMCTL_CHILD_CMUX_MOBILE_DEV_BLOCK_UDP=1) without touching app settings.
        // A proxy-only network blocks UDP too.
        block_udp: request.block_udp
            || std::env::var_os("CMUX_MOBILE_DEV_BLOCK_UDP").is_some()
            || proxy_only(request),
        // The corporate network simulations (PROTOCOL.md "Corporate networks";
        // simulator: SIMCTL_CHILD_CMUX_MOBILE_DEV_DROP_WIREGUARD=1,
        // SIMCTL_CHILD_CMUX_MOBILE_DEV_PROXY_ONLY=1, and
        // SIMCTL_CHILD_CMUX_MOBILE_DEV_PROXY=http://host:port for the proxy).
        drop_wireguard_udp: request.drop_wireguard
            || std::env::var_os("CMUX_MOBILE_DEV_DROP_WIREGUARD").is_some(),
        egress: cmux_mobile_link::egress::Egress { require_proxy: proxy_only(request), ..Default::default() },
        video_lane: request.video_lane,
        webrtc_media: request.webrtc_media,
        ultra: request.ultra,
        // Read once, so the tunnel and its link agree (`dial_on`).
        aligned_keepalives: cmux_mobile_link::keepalive::aligned(),
        timeline: timeline.clone(),
        ..DialOptions::default()
    }
}

/// A dial, or a redial of a Mac whose WireGuard tunnel this phone keeps
/// dormant (`dial::wireguard::dormant`): then the dormant tunnel resumes
/// beside the full dial, and the first link up wins. A resumed link has no
/// signaling socket of its own; the pool opens one behind it.
async fn dial(
    pool: &Arc<Warm>,
    request: &ConnectRequest,
    timeline: &Timeline,
) -> Result<(cmux_mobile_link::Connected, Option<Arc<WarmSocket>>), CmuxMobileError> {
    use cmux_mobile_link::dial::wireguard::dormant;
    let kind: cmux_mobile_link::TransportKind = request.transport.into();
    let ticket =
        if kind == cmux_mobile_link::TransportKind::WireGuard && !request.mac_device_id.trim().is_empty() {
            dormant::ticket(&request.mac_device_id)
        } else {
            None
        };
    let link_config =
        if cmux_mobile_link::keepalive::aligned() { LinkConfig::aligned() } else { LinkConfig::default() };
    match dormant::hedged(ticket, link_config, timeline, full_dial(pool, request, timeline)).await? {
        dormant::Hedged::Full((connected, socket)) => Ok((connected, Some(socket))),
        dormant::Hedged::Resumed(connected) => {
            // The next dial (and the path report) want a socket: open it
            // now, off the link's path.
            let (pool, token) = (Arc::clone(pool), request.token.clone());
            let key = SocketKey {
                base_url: request.base_url.clone(),
                team_id: request.team_id.clone(),
                device_id: request.device_id.clone(),
                build_space: build_space(),
            };
            tokio::spawn(async move {
                if let Err(error) = pool.pooled_or_open(&key, &token, &Timeline::new()).await {
                    tracing::info!(%error, "no signaling socket behind a resumed link");
                }
            });
            Ok((connected, None))
        }
    }
}

async fn full_dial(
    pool: &Arc<Warm>,
    request: &ConnectRequest,
    timeline: &Timeline,
) -> Result<(cmux_mobile_link::Connected, Arc<WarmSocket>), CmuxMobileError> {
    // A Mac found nearby (its ad matches the Mac the phone paired with) is also dialed through its
    // own hub: no service round trip, and a link even with no route out. The two race from the
    // same instant and the first link up wins (the loser is dropped), so an ad that outlived its
    // network (Wi-Fi gone, the Mac asleep) costs the service dial nothing.
    let local = local_link::dial_local(request, timeline);
    let service = dial_service(pool, request, timeline);
    tokio::pin!(local, service);
    let mut local_done = false;
    loop {
        tokio::select! {
            result = &mut local, if !local_done => {
                local_done = true;
                if let Some(ok) = result {
                    return Ok(ok);
                }
            }
            result = &mut service => {
                return match result {
                    Ok(ok) => Ok(ok),
                    Err(error) if local_done => Err(error),
                    // No service (no route out, no account): the hub is the only way left.
                    Err(error) => local.await.map(Ok).unwrap_or(Err(error)),
                };
            }
        }
    }
}

/// `dial` through the service: its signaling socket and ICE servers.
async fn dial_service(
    pool: &Arc<Warm>,
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
        build_space: build_space(),
    };
    // ICE servers and the signaling socket are independent: get both at once.
    let socket = async {
        let (socket, reused) = pool.pooled_or_open(&key, &request.token, timeline).await?;
        if reused {
            timeline.mark("signaling_reused");
        }
        Ok::<_, CmuxMobileError>((socket, reused))
    };
    // Once ICE answers, a WireGuard dial's TURN allocation starts
    // (`EarlyTurn`, as a redial's does beside its reconnect), beside the rest
    // of the socket's open, instead of after it inside the dial.
    let ice = async {
        let ice_servers =
            without_turn_if_asked(pool.ice_servers(&request.base_url, &request.token, timeline).await);
        let options = dial_options(request, ice_servers, timeline);
        let early = cmux_mobile_link::dial::EarlyTurn::for_dial(request.transport.into(), &options);
        (options, early)
    };
    let ((options, early), socket) = tokio::join!(ice, socket);
    let (socket, reused) = socket?;
    let attempt = dial_on(&socket, request, &options, reused, early).await;
    match attempt {
        Ok(connected) => Ok((connected, socket)),
        Err(Attempt::Stale) => {
            // The reused socket stopped answering (a phone that slept, a NAT
            // that forgot it): redial on a fresh one, once.
            timeline.mark("signaling_stale");
            pool.evict(&socket).await;
            redial_after(pool, &key, request, &options, timeline).await
        }
        Err(Attempt::Failed(error)) => Err(fail(pool, &socket, error).await),
    }
}

/// The debug "Proxy only" network, from the app or the rig's environment.
fn proxy_only(request: &ConnectRequest) -> bool {
    request.proxy_only || std::env::var_os("CMUX_MOBILE_DEV_PROXY_ONLY").is_some()
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

/// Open a replacement signaling socket and dial it as one redial operation.
/// `connect_after` starts a WireGuard TURN allocation before the WebSocket
/// upgrade finishes, so the two network handshakes overlap. The socket is
/// installed as soon as the upgrade completes, retaining the pool's existing
/// rehome behavior while the transport negotiation runs.
///
/// The opening lock is taken before the allocation starts and let go once
/// the socket is in the pool, as `Warm::open` holds it: a redial waiting on
/// another's upgrade holds no allocation, and a dial for another key waits
/// for an upgrade, never for a whole dial.
async fn redial_after(
    pool: &Arc<Warm>,
    key: &SocketKey,
    request: &ConnectRequest,
    options: &DialOptions,
    timeline: &Timeline,
) -> Result<(cmux_mobile_link::Connected, Arc<WarmSocket>), CmuxMobileError> {
    let opening = pool.opening.lock().await;
    let opened = Arc::new(tokio::sync::Mutex::new(None));
    let opened_by_signaling = Arc::clone(&opened);
    let pool_for_signaling = Arc::clone(pool);
    let key_for_signaling = key.clone();
    let timeline_for_signaling = timeline.clone();
    let signaling = async move {
        let client = SignalingClient::connect_in(
            &key_for_signaling.base_url,
            &request.token,
            &key_for_signaling.team_id,
            &key_for_signaling.device_id,
            key_for_signaling.build_space.as_ref(),
        )
        .await?;
        timeline_for_signaling.mark("signaling_open");
        let socket = pool_for_signaling
            .store_opened(&key_for_signaling, client.clone(), &timeline_for_signaling)
            .await;
        *opened_by_signaling.lock().await = Some(socket);
        drop(opening);
        Ok::<_, cmux_mobile_link::signaling::SignalingError>(client)
    };
    let result = cmux_mobile_link::dial::connect_after(
        signaling,
        &request.mac_device_id,
        request.transport.into(),
        options,
        if options.aligned_keepalives { LinkConfig::aligned() } else { LinkConfig::default() },
    )
    .await;
    let socket = opened.lock().await.take();
    match (result, socket) {
        (Ok((_signaling, connected)), Some(socket)) => Ok((connected, socket)),
        (Ok(_), None) => unreachable!("connect_after succeeded without opening a signaling socket"),
        (Err(error), Some(socket)) => Err(fail(pool, &socket, error).await),
        (Err(error), None) => Err(error.into()),
    }
}

/// A failed dial on a socket the backend dropped evicts it, so the retry
/// opens a new one.
async fn fail(pool: &Warm, socket: &Arc<WarmSocket>, error: DialError) -> CmuxMobileError {
    if socket.client.closed_reason().is_some() || matches!(error, DialError::Signaling(_)) {
        pool.evict(socket).await;
    }
    error.into()
}

/// Dial on `socket`, taking `early`, the TURN allocation started when ICE
/// answered. A reused socket is probed while the dial runs: when it does not
/// answer within `STALE_PROBE`, the dial is abandoned as stale instead of
/// waiting out its whole timeout.
async fn dial_on(
    socket: &Arc<WarmSocket>,
    request: &ConnectRequest,
    options: &DialOptions,
    probe: bool,
    early: Option<cmux_mobile_link::dial::EarlyTurn>,
) -> Result<cmux_mobile_link::Connected, Attempt> {
    let dial = cmux_mobile_link::dial::connect_with_early_turn(
        &socket.client,
        &request.mac_device_id,
        request.transport.into(),
        options,
        if options.aligned_keepalives { LinkConfig::aligned() } else { LinkConfig::default() },
        early,
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
