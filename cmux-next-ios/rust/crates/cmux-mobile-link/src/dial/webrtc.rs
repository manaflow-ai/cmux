//! WebRTC transport: one ordered, reliable data channel `cmux-mobile-link`
//! (webrtc-rs), ICE servers from `GET /v1/ice`, trickle ICE through
//! signaling.

use std::io;
use std::pin::Pin;
use std::sync::{Arc, Mutex, PoisonError};
use std::task::{Context, Poll};
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::{oneshot, watch};
use webrtc::api::APIBuilder;
use webrtc::api::setting_engine::SettingEngine;
use webrtc::data::data_channel::PollDataChannel;
use webrtc::data_channel::RTCDataChannel;
use webrtc::data_channel::data_channel_init::RTCDataChannelInit;
use webrtc::ice::mdns::MulticastDnsMode;
use webrtc::ice_transport::ice_candidate::{RTCIceCandidate, RTCIceCandidateInit};
use webrtc::ice_transport::ice_candidate_type::RTCIceCandidateType;
use webrtc::ice_transport::ice_connection_state::RTCIceConnectionState;
use webrtc::ice_transport::ice_gatherer_state::RTCIceGathererState;
use webrtc::ice_transport::ice_server::RTCIceServer;
use webrtc::peer_connection::RTCPeerConnection;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::peer_connection_state::RTCPeerConnectionState;
use webrtc::peer_connection::policy::ice_transport_policy::RTCIceTransportPolicy;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;

use super::{DialError, DialFuture, Dialed, Dialer, LinkPath, SessionEvents, TransportKind};
use crate::signaling::{SessionEvent, SignalEnvelope, SignalPayload, SignalingClient};
use crate::timing::Timeline;

/// The data channel label (PROTOCOL.md).
pub const LABEL: &str = "cmux-mobile-link";
/// The input lane's data channel: ordered and reliable, its own SCTP stream
/// (PROTOCOL.md "Lanes").
pub const INPUT_LABEL: &str = "cmux-mobile-input";
/// How long a working relay pair waits for a direct pair to also work
/// before it is nominated (relay only: no wait).
const RELAY_HEAD_START: Duration = Duration::from_millis(300);
/// Largest message written to the data channel; the link is a byte stream,
/// so message boundaries carry no meaning.
const MAX_MESSAGE: usize = 16 * 1024;

pub struct WebRtcDialer;

fn transport_error(error: impl std::fmt::Display) -> DialError {
    DialError::Transport(error.to_string())
}

/// A peer connection and its connection state as it changes.
type NewPeerConnection = (Arc<RTCPeerConnection>, watch::Receiver<RTCPeerConnectionState>);

async fn new_peer_connection(
    options: &super::DialOptions,
    video: bool,
) -> Result<NewPeerConnection, DialError> {
    new_peer_connection_for(options, video, false).await
}

/// `media`: a media session's peer connection (PROTOCOL.md "Media session"):
/// it notices a dead path sooner, and under Block UDP it gets no candidate
/// at all, as on a network that passes only TCP (webrtc-rs has no TURN over
/// TCP or TLS), so it fails like it would there.
async fn new_peer_connection_for(
    options: &super::DialOptions,
    video: bool,
    media: bool,
) -> Result<NewPeerConnection, DialError> {
    let mut settings = SettingEngine::default();
    if media {
        settings.set_ice_timeouts(
            Some(MEDIA_ICE_DISCONNECTED),
            Some(MEDIA_ICE_FAILED),
            Some(MEDIA_ICE_KEEPALIVE),
        );
    }
    let udp_blocked = media && options.block_udp;
    if udp_blocked {
        settings.set_ip_filter(Box::new(|_| false));
    }
    settings.detach_data_channels();
    settings.set_ice_multicast_dns_mode(MulticastDnsMode::Disabled);
    if options.include_loopback {
        settings.set_include_loopback_candidate(true);
    }
    if options.exclude_cgnat && !udp_blocked {
        settings.set_ip_filter(Box::new(|ip| !super::is_cgnat(ip)));
    }
    // Nominate the first working pair. webrtc-rs holds a valid srflx pair
    // back 500 ms, prflx 1 s and relay 2 s after checks start, hoping a
    // better pair turns up; a link that works now beats one that might work
    // a little better later (the path watcher reports any later change).
    // Relay keeps a short head start so a LAN pair still wins when both work.
    if !options.stock_ice_waits {
        settings.set_host_acceptance_min_wait(Some(Duration::ZERO));
        settings.set_srflx_acceptance_min_wait(Some(Duration::ZERO));
        settings.set_prflx_acceptance_min_wait(Some(Duration::ZERO));
        settings.set_relay_acceptance_min_wait(Some(if options.relay_only {
            Duration::ZERO
        } else {
            RELAY_HEAD_START
        }));
    }
    // The media lane registers H.264, TWCC and its interceptors; without
    // it the media engine stays empty, as in every earlier build.
    let api = if video {
        crate::media::track::api_builder(settings, options.video_drop_permille)
            .map_err(transport_error)?
            .build()
    } else {
        APIBuilder::new().with_setting_engine(settings).build()
    };
    let ice_servers: &[crate::api::IceServer] = if udp_blocked { &[] } else { &options.ice_servers };
    let config = RTCConfiguration {
        ice_servers: ice_servers
            .iter()
            .map(|server| RTCIceServer {
                urls: server.urls.clone(),
                username: server.username.clone().unwrap_or_default(),
                credential: server.credential.clone().unwrap_or_default(),
            })
            .collect(),
        ice_transport_policy: if options.relay_only {
            RTCIceTransportPolicy::Relay
        } else {
            RTCIceTransportPolicy::All
        },
        ..Default::default()
    };
    let pc = Arc::new(api.new_peer_connection(config).await.map_err(transport_error)?);
    let state = instrument(&pc, &options.timeline);
    Ok((pc, state))
}

/// Record ICE, DTLS and candidate steps on `timeline`; returns the peer
/// connection's state as it changes.
fn instrument(pc: &RTCPeerConnection, timeline: &Timeline) -> watch::Receiver<RTCPeerConnectionState> {
    let (state_tx, state_rx) = watch::channel(RTCPeerConnectionState::New);
    timeline.mark("pc_created");
    let ice = timeline.clone();
    pc.on_ice_connection_state_change(Box::new(move |state: RTCIceConnectionState| {
        match state {
            RTCIceConnectionState::Checking => ice.mark("ice_checking"),
            RTCIceConnectionState::Connected => ice.mark("ice_connected"),
            RTCIceConnectionState::Failed => ice.mark("ice_failed"),
            _ => {}
        }
        Box::pin(async {})
    }));
    let peer = timeline.clone();
    pc.on_peer_connection_state_change(Box::new(move |state: RTCPeerConnectionState| {
        // Connected = ICE connected and the DTLS handshake done.
        if state == RTCPeerConnectionState::Connected {
            peer.mark("dtls_connected");
        }
        state_tx.send_replace(state);
        Box::pin(async {})
    }));
    let gathering = timeline.clone();
    pc.on_ice_gathering_state_change(Box::new(move |state: RTCIceGathererState| {
        if state == RTCIceGathererState::Complete {
            gathering.mark("gathering_complete");
        }
        Box::pin(async {})
    }));
    state_rx
}

fn candidate_kind(typ: RTCIceCandidateType) -> &'static str {
    match typ {
        RTCIceCandidateType::Host => "host",
        RTCIceCandidateType::Srflx => "srflx",
        RTCIceCandidateType::Prflx => "prflx",
        RTCIceCandidateType::Relay => "relay",
        RTCIceCandidateType::Unspecified => "unknown",
    }
}

/// Trickle local candidates to `peer`.
fn trickle(
    pc: &RTCPeerConnection,
    signaling: &SignalingClient,
    peer: &str,
    session_id: &str,
    timeline: &Timeline,
) {
    let signaling = signaling.clone();
    let peer = peer.to_owned();
    let session_id = session_id.to_owned();
    let timeline = timeline.clone();
    pc.on_ice_candidate(Box::new(move |candidate: Option<RTCIceCandidate>| {
        if let Some(candidate) = candidate
            && let Ok(init) = candidate.to_json()
        {
            timeline.mark(&format!("local_{}", candidate_kind(candidate.typ)));
            let _ = signaling.send_signal(
                &peer,
                &session_id,
                SignalPayload::WebrtcIce {
                    candidate: init.candidate,
                    sdp_mid: init.sdp_mid,
                    sdp_m_line_index: init.sdp_mline_index,
                },
            );
        }
        Box::pin(async {})
    }));
}

/// Remote candidates arrive before or after the remote description; hold
/// the early ones.
struct RemoteCandidates {
    timeline: Timeline,
    exclude_cgnat: bool,
    ready: bool,
    pending: Vec<RTCIceCandidateInit>,
}

impl RemoteCandidates {
    async fn add(&mut self, pc: &RTCPeerConnection, candidate: RTCIceCandidateInit) {
        // `candidate:<foundation> <component> <proto> <priority> <address> ...`
        let address = candidate.candidate.split_whitespace().nth(4).and_then(|a| a.parse().ok());
        if self.exclude_cgnat && address.is_some_and(super::is_cgnat) {
            return;
        }
        if let Some(kind) = candidate.candidate.split_whitespace().nth(7) {
            self.timeline.mark(&format!("remote_{kind}"));
        }
        if self.ready {
            if let Err(error) = pc.add_ice_candidate(candidate).await {
                tracing::debug!(%error, "remote candidate refused");
            }
        } else {
            self.pending.push(candidate);
        }
    }

    async fn ready(&mut self, pc: &RTCPeerConnection) {
        self.ready = true;
        for candidate in std::mem::take(&mut self.pending) {
            if let Err(error) = pc.add_ice_candidate(candidate).await {
                tracing::debug!(%error, "remote candidate refused");
            }
        }
    }
}

fn ice_init(payload: SignalPayload) -> Option<RTCIceCandidateInit> {
    match payload {
        SignalPayload::WebrtcIce { candidate, sdp_mid, sdp_m_line_index } => Some(RTCIceCandidateInit {
            candidate,
            sdp_mid,
            sdp_mline_index: sdp_m_line_index,
            username_fragment: None,
        }),
        _ => None,
    }
}

/// The data channel, once open, through `opened`.
fn on_open(channel: &Arc<RTCDataChannel>, opened: Arc<Mutex<Option<oneshot::Sender<Arc<RTCDataChannel>>>>>) {
    let handle = Arc::clone(channel);
    channel.on_open(Box::new(move || {
        if let Some(tx) = opened.lock().unwrap_or_else(PoisonError::into_inner).take() {
            let _ = tx.send(handle);
        }
        Box::pin(async {})
    }));
}

/// `host-srflx` style name of the selected pair (local, then remote).
async fn selected_pair_name(pc: &RTCPeerConnection) -> Option<String> {
    let pair = pc.sctp().transport().ice_transport().get_selected_candidate_pair().await?;
    Some(format!("{}-{}", candidate_kind(pair.local.typ), candidate_kind(pair.remote.typ)))
}

async fn selected_path(pc: &RTCPeerConnection) -> LinkPath {
    let pair = pc.sctp().transport().ice_transport().get_selected_candidate_pair().await;
    match pair {
        Some(pair)
            if pair.local.typ == RTCIceCandidateType::Relay
                || pair.remote.typ == RTCIceCandidateType::Relay =>
        {
            LinkPath::Turn
        }
        _ => LinkPath::Direct,
    }
}

/// Holds the peer connection and the post-connect signal task.
struct Guard {
    pc: Arc<RTCPeerConnection>,
    task: tokio::task::JoinHandle<()>,
    watcher: tokio::task::JoinHandle<()>,
    signaling: SignalingClient,
    session_id: String,
}

impl Drop for Guard {
    fn drop(&mut self) {
        self.task.abort();
        self.watcher.abort();
        self.signaling.unsubscribe(&self.session_id);
        let pc = Arc::clone(&self.pc);
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                let _ = pc.close().await;
            });
        }
    }
}

/// A signaling socket that drops mid-handshake (a Worker deploy resets
/// every socket) need not end the dial: once offer and answer crossed
/// (`described`), ICE and DTLS finish without it. `None` means the socket is
/// gone and the caller keeps waiting for the data channel (the dial's
/// timeout still bounds it). Before the answer, the loss fails the dial at
/// once so the app redials on a fresh socket; backend refusals always fail.
fn signaling_outage(
    event: Result<SessionEvent, DialError>,
    timeline: &Timeline,
    described: bool,
) -> Result<Option<SessionEvent>, DialError> {
    match event {
        Ok(SessionEvent::Disconnected) | Err(DialError::Signaling(_)) if !described => {
            Err(DialError::Signaling("signaling socket closed before the answer".into()))
        }
        Ok(SessionEvent::Disconnected) | Err(DialError::Signaling(_)) => {
            timeline.mark("signaling_lost");
            Ok(None)
        }
        Ok(event) => Ok(Some(event)),
        Err(error) => Err(error),
    }
}

/// After connecting: keep adding late candidates; close on `bye`.
fn follow(
    pc: Arc<RTCPeerConnection>,
    mut events: SessionEvents,
    mut remote: RemoteCandidates,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            match events.session.recv().await {
                Some(SessionEvent::Signal(envelope)) => match envelope.payload {
                    SignalPayload::Bye { .. } => break,
                    payload => {
                        if let Some(init) = ice_init(payload) {
                            remote.add(&pc, init).await;
                        }
                    }
                },
                // A signaling outage does not end an established link.
                Some(SessionEvent::Disconnected) | None => return,
            }
        }
        let _ = pc.close().await;
    })
}

/// The lane's stream once its data channel opens.
fn lane_stream(
    opened: oneshot::Receiver<Arc<RTCDataChannel>>,
) -> oneshot::Receiver<Box<dyn super::LinkStream>> {
    let (tx, rx) = oneshot::channel();
    tokio::spawn(async move {
        let Ok(channel) = opened.await else { return };
        match channel.detach().await {
            Ok(raw) => {
                let mut stream = PollDataChannel::new(raw);
                stream.set_read_buf_capacity(64 * 1024);
                let _ = tx.send(Box::new(DataChannelStream { inner: stream }) as Box<dyn super::LinkStream>);
            }
            Err(error) => tracing::info!(%error, "input lane data channel did not detach"),
        }
    });
    rx
}

#[allow(clippy::too_many_arguments)]
async fn finish(
    pc: Arc<RTCPeerConnection>,
    channel: Arc<RTCDataChannel>,
    lane: Option<oneshot::Receiver<Arc<RTCDataChannel>>>,
    media: Option<super::PendingMedia>,
    events: SessionEvents,
    remote: RemoteCandidates,
    signaling: &SignalingClient,
    session_id: &str,
    timeline: &Timeline,
) -> Result<Dialed, DialError> {
    timeline.mark("channel_open");
    if let Some(pair) = selected_pair_name(&pc).await {
        timeline.mark(&format!("pair_{pair}"));
    }
    let raw = channel.detach().await.map_err(transport_error)?;
    let mut stream = PollDataChannel::new(raw);
    stream.set_read_buf_capacity(64 * 1024);
    let path = selected_path(&pc).await;
    let (path_tx, path_rx) = watch::channel(path);
    // The selected pair can change (ICE restart is out of scope, but a
    // nominated pair may be replaced while checks finish).
    let watcher_pc = Arc::clone(&pc);
    let task = follow(Arc::clone(&pc), events, remote);
    let watcher = tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(5));
        loop {
            interval.tick().await;
            if path_tx.is_closed() {
                return;
            }
            let path = selected_path(&watcher_pc).await;
            path_tx.send_if_modified(|current| {
                if *current == path {
                    false
                } else {
                    *current = path;
                    true
                }
            });
        }
    });
    Ok(Dialed {
        stream: Box::new(DataChannelStream { inner: stream }),
        path: path_rx,
        guard: Box::new(Guard {
            pc,
            task,
            watcher,
            signaling: signaling.clone(),
            session_id: session_id.to_owned(),
        }),
        lane: lane.map(lane_stream),
        media,
        webrtc_media: false,
    })
}

impl Dialer for WebRtcDialer {
    fn kind(&self) -> TransportKind {
        TransportKind::WebRtc
    }

    fn dial<'a>(
        &'a self,
        signaling: &'a SignalingClient,
        mac: &'a str,
        session_id: &'a str,
        mut events: SessionEvents,
        options: &'a super::DialOptions,
    ) -> DialFuture<'a> {
        Box::pin(async move {
            let (pc, _) = new_peer_connection(options, options.video_lane).await?;
            let init = RTCDataChannelInit { ordered: Some(true), ..Default::default() };
            let channel = pc.create_data_channel(LABEL, Some(init)).await.map_err(transport_error)?;
            // The media lane's receiving transceiver goes into the offer; an
            // older Mac rejects its m-line and leaves the lane out.
            let receiver = if options.video_lane {
                Some(crate::media::track::add_receiver(&pc).await.map_err(transport_error)?)
            } else {
                None
            };
            let mut video_agreed = false;
            let (open_tx, mut open_rx) = oneshot::channel();
            on_open(&channel, Arc::new(Mutex::new(Some(open_tx))));
            // The input lane's channel opens with the main one; it carries
            // frames only when the Mac's answer lists the lane.
            let mut lane = None;
            if options.input_lane {
                let init = RTCDataChannelInit { ordered: Some(true), ..Default::default() };
                let input = pc.create_data_channel(INPUT_LABEL, Some(init)).await.map_err(transport_error)?;
                let (lane_tx, lane_rx) = oneshot::channel();
                on_open(&input, Arc::new(Mutex::new(Some(lane_tx))));
                lane = Some(lane_rx);
            }
            let mut agreed = false;
            let timeline = &options.timeline;
            trickle(&pc, signaling, mac, session_id, timeline);
            let offer = pc.create_offer(None).await.map_err(transport_error)?;
            pc.set_local_description(offer.clone()).await.map_err(transport_error)?;
            signaling
                .send_signal(
                    mac,
                    session_id,
                    SignalPayload::WebrtcOffer {
                        sdp: offer.sdp,
                        lanes: super::offered_lanes(options, receiver.is_some(), false),
                        media_for: None,
                    },
                )
                .map_err(|e| DialError::Signaling(e.to_string()))?;
            timeline.mark("offer_sent");
            let mut remote = RemoteCandidates {
                timeline: timeline.clone(),
                exclude_cgnat: options.exclude_cgnat,
                ready: false,
                pending: Vec::new(),
            };
            let mut signaling_up = true;
            // An offer sent while the Mac's host was down or restarting is never
            // answered: give up at the answer deadline (termfix r13 D2b).
            let answer_deadline = tokio::time::sleep(options.answer_timeout);
            tokio::pin!(answer_deadline);
            let mut answered = false;
            let opened = loop {
                tokio::select! {
                    opened = &mut open_rx => break opened.map_err(|_| DialError::Transport("data channel never opened".into()))?,
                    () = &mut answer_deadline, if !answered => {
                        timeline.mark("answer_timeout");
                        let _ = pc.close().await;
                        return Err(DialError::Timeout);
                    }
                    event = events.next(), if signaling_up => {
                        let Some(event) = signaling_outage(event, timeline, remote.ready)? else {
                            signaling_up = false;
                            continue;
                        };
                        match event {
                        SessionEvent::Signal(envelope) => match envelope.payload {
                            SignalPayload::WebrtcAnswer { sdp, lanes } => {
                                agreed = super::input_lane_agreed(options, &lanes);
                                video_agreed = super::video_lane_listed(&lanes);
                                answered = true;
                                timeline.mark("answer_received");
                                let answer = RTCSessionDescription::answer(sdp).map_err(transport_error)?;
                                pc.set_remote_description(answer).await.map_err(transport_error)?;
                                remote.ready(&pc).await;
                            }
                            SignalPayload::Bye { reason } => return Err(DialError::Bye(reason)),
                            payload => {
                                if let Some(init) = ice_init(payload) {
                                    remote.add(&pc, init).await;
                                }
                            }
                        },
                        SessionEvent::Disconnected => {}
                    }},
                }
            };
            let lane = lane.filter(|_| agreed);
            let mut media = None;
            if let Some(receiver) = receiver.filter(|_| video_agreed) {
                receiver.bind(Arc::clone(&pc)).await;
                timeline.mark("video_lane");
                media = Some(super::PendingMedia::Receive(receiver));
            }
            finish(pc, opened, lane, media, events, remote, signaling, session_id, timeline).await
        })
    }

    fn answer<'a>(
        &'a self,
        signaling: &'a SignalingClient,
        first: SignalEnvelope,
        mut events: SessionEvents,
        options: &'a super::DialOptions,
    ) -> DialFuture<'a> {
        Box::pin(async move {
            let SignalPayload::WebrtcOffer { sdp, lanes, .. } = first.payload else {
                return Err(DialError::Unexpected("expected webrtc-offer".into()));
            };
            let agreed = super::input_lane_agreed(options, &lanes);
            // The media lane: the phone offered it and its SDP has the video
            // m-line. The sending track must exist before the offer applies.
            let video = options.video_lane && super::video_lane_listed(&lanes) && sdp.contains("m=video");
            let (pc, _) = new_peer_connection(options, video).await?;
            let sending = if video {
                match crate::media::track::add_sender(&pc).await {
                    Ok(sending) => Some(sending),
                    Err(error) => {
                        tracing::warn!(%error, "media lane: no video track");
                        None
                    }
                }
            } else {
                None
            };
            let (open_tx, mut open_rx) = oneshot::channel();
            let opened_slot = Arc::new(Mutex::new(Some(open_tx)));
            let (lane_tx, lane_rx) = oneshot::channel();
            let lane_slot = Arc::new(Mutex::new(Some(lane_tx)));
            pc.on_data_channel(Box::new(move |channel: Arc<RTCDataChannel>| {
                match channel.label() {
                    LABEL => on_open(&channel, Arc::clone(&opened_slot)),
                    INPUT_LABEL => on_open(&channel, Arc::clone(&lane_slot)),
                    _ => {}
                }
                Box::pin(async {})
            }));
            let timeline = &options.timeline;
            trickle(&pc, signaling, &first.from, &first.session_id, timeline);
            let offer = RTCSessionDescription::offer(sdp).map_err(transport_error)?;
            pc.set_remote_description(offer).await.map_err(transport_error)?;
            let mut remote = RemoteCandidates {
                timeline: timeline.clone(),
                exclude_cgnat: options.exclude_cgnat,
                ready: true,
                pending: Vec::new(),
            };
            let answer = pc.create_answer(None).await.map_err(transport_error)?;
            pc.set_local_description(answer.clone()).await.map_err(transport_error)?;
            signaling
                .send_signal(
                    &first.from,
                    &first.session_id,
                    SignalPayload::WebrtcAnswer {
                        sdp: answer.sdp,
                        lanes: super::offered_lanes(options, sending.is_some(), false),
                    },
                )
                .map_err(|e| DialError::Signaling(e.to_string()))?;
            timeline.mark("answer_sent");
            let mut signaling_up = true;
            let opened = loop {
                tokio::select! {
                    opened = &mut open_rx => break opened.map_err(|_| DialError::Transport("data channel never opened".into()))?,
                    event = events.next(), if signaling_up => {
                        let Some(event) = signaling_outage(event, timeline, true)? else {
                            signaling_up = false;
                            continue;
                        };
                        match event {
                        SessionEvent::Signal(envelope) => match envelope.payload {
                            SignalPayload::Bye { reason } => return Err(DialError::Bye(reason)),
                            payload => {
                                if let Some(init) = ice_init(payload) {
                                    remote.add(&pc, init).await;
                                }
                            }
                        },
                        SessionEvent::Disconnected => {}
                    }},
                }
            };
            let lane = agreed.then_some(lane_rx);
            let mut media = None;
            if let Some((track, sender)) = sending {
                timeline.mark("video_lane");
                let carrier = crate::media::track::SendCarrier::new(track, sender).await;
                media = Some(super::PendingMedia::Send(carrier));
            }
            finish(pc, opened, lane, media, events, remote, signaling, &first.session_id, timeline).await
        })
    }
}

// MARK: Media session (PROTOCOL.md "Media session")

/// A media session's peer connection reports Disconnected after this long
/// without an answer to its consent checks, and Failed after this; webrtc-rs
/// defaults to 5 and 25 s with a 2 s keepalive. Video moves to the tunnel on
/// Disconnected (or sooner, on missing feedback: media/routes.rs).
const MEDIA_ICE_DISCONNECTED: Duration = Duration::from_secs(3);
const MEDIA_ICE_FAILED: Duration = Duration::from_secs(8);
const MEDIA_ICE_KEEPALIVE: Duration = Duration::from_secs(1);

/// A WebRTC peer connection that carries only the media lane, beside a
/// WireGuard link to the same peer.
pub struct MediaSession {
    pub session_id: String,
    /// The phone's receiving or the Mac's sending carrier.
    pub carrier: Arc<dyn crate::media::MediaCarrier>,
    pub path: watch::Receiver<LinkPath>,
    /// True while the peer connection is connected (ICE consent holds).
    pub up: watch::Receiver<bool>,
    /// Some once the session ended (failed, closed, or the peer said `bye`).
    pub ended: watch::Receiver<Option<String>>,
    pc: Arc<RTCPeerConnection>,
    _guard: MediaGuard,
}

impl std::fmt::Debug for MediaSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MediaSession").field("session_id", &self.session_id).finish_non_exhaustive()
    }
}

impl MediaSession {
    /// The nominated candidate pair's round trip (ICE consent checks).
    pub async fn rtt(&self) -> Option<Duration> {
        let report = self.pc.get_stats().await;
        report.reports.values().find_map(|report| match report {
            webrtc::stats::StatsReportType::CandidatePair(pair)
                if pair.nominated && pair.current_round_trip_time > 0.0 =>
            {
                Some(Duration::from_secs_f64(pair.current_round_trip_time))
            }
            _ => None,
        })
    }

    /// Resolves once the session ended, with why.
    pub async fn wait_ended(&self) -> String {
        let mut ended = self.ended.clone();
        match ended.wait_for(Option::is_some).await {
            Ok(reason) => reason.clone().unwrap_or_default(),
            Err(_) => "closed".into(),
        }
    }

    /// Closes the peer connection at once without telling the peer (test and
    /// measurement support: the path died).
    #[doc(hidden)]
    pub async fn kill(&self) {
        let _ = self.pc.close().await;
    }
}

/// Closes the media session's peer connection and says `bye` once.
struct MediaGuard {
    pc: Arc<RTCPeerConnection>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
    signaling: SignalingClient,
    peer: String,
    session_id: String,
}

impl Drop for MediaGuard {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
        let _ = self.signaling.send_signal(
            &self.peer,
            &self.session_id,
            SignalPayload::Bye { reason: "closed".into() },
        );
        self.signaling.unsubscribe(&self.session_id);
        let pc = Arc::clone(&self.pc);
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                let _ = pc.close().await;
            });
        }
    }
}

/// Waits until the peer connection is connected, feeding it the peer's
/// trickled candidates (and, on the phone, its answer).
async fn media_connect(
    pc: &Arc<RTCPeerConnection>,
    state: &mut watch::Receiver<RTCPeerConnectionState>,
    events: &mut SessionEvents,
    remote: &mut RemoteCandidates,
    mut answered: Option<&mut Option<Vec<String>>>,
) -> Result<(), DialError> {
    let mut signaling_up = true;
    loop {
        if *state.borrow_and_update() == RTCPeerConnectionState::Connected {
            return Ok(());
        }
        if matches!(*state.borrow(), RTCPeerConnectionState::Failed | RTCPeerConnectionState::Closed) {
            return Err(DialError::Transport("the media session's peer connection failed".into()));
        }
        tokio::select! {
            changed = state.changed() => {
                if changed.is_err() {
                    return Err(DialError::Transport("the media session's peer connection went away".into()));
                }
            }
            event = events.next(), if signaling_up => {
                let described = answered.as_ref().is_none_or(|a| a.is_some());
                let Some(event) = signaling_outage(event, &remote.timeline, described)? else {
                    signaling_up = false;
                    continue;
                };
                let SessionEvent::Signal(envelope) = event else { continue };
                match envelope.payload {
                    SignalPayload::WebrtcAnswer { sdp, lanes } if answered.as_ref().is_some_and(|a| a.is_none()) => {
                        remote.timeline.mark("answer_received");
                        let answer = RTCSessionDescription::answer(sdp).map_err(transport_error)?;
                        pc.set_remote_description(answer).await.map_err(transport_error)?;
                        remote.ready(pc).await;
                        if let Some(slot) = answered.as_mut() {
                            **slot = Some(lanes);
                        }
                    }
                    SignalPayload::Bye { reason } => return Err(DialError::Bye(reason)),
                    payload => {
                        if let Some(init) = ice_init(payload) {
                            remote.add(pc, init).await;
                        }
                    }
                }
            }
        }
    }
}

/// A connected media session's watches and the tasks behind them.
struct Followed {
    path: watch::Receiver<LinkPath>,
    up: watch::Receiver<bool>,
    ended: watch::Receiver<Option<String>>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
}

/// After connecting: the session's path, health and end, and late candidates.
fn media_follow(
    pc: Arc<RTCPeerConnection>,
    mut state: watch::Receiver<RTCPeerConnectionState>,
    mut events: SessionEvents,
    mut remote: RemoteCandidates,
    path: LinkPath,
) -> Followed {
    let (path_tx, path_rx) = watch::channel(path);
    let (up_tx, up_rx) = watch::channel(true);
    let (ended_tx, ended_rx) = watch::channel(None);
    let ended = Arc::new(ended_tx);
    let signals_pc = Arc::clone(&pc);
    let signals_ended = Arc::clone(&ended);
    let signals = tokio::spawn(async move {
        loop {
            match events.session.recv().await {
                Some(SessionEvent::Signal(envelope)) => match envelope.payload {
                    SignalPayload::Bye { reason } => {
                        signals_ended.send_replace(Some(format!("bye: {reason}")));
                        let _ = signals_pc.close().await;
                        return;
                    }
                    payload => {
                        if let Some(init) = ice_init(payload) {
                            remote.add(&signals_pc, init).await;
                        }
                    }
                },
                // A signaling outage does not end an established session.
                Some(SessionEvent::Disconnected) | None => return,
            }
        }
    });
    let watcher_pc = Arc::clone(&pc);
    let watcher = tokio::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(2));
        loop {
            tokio::select! {
                changed = state.changed() => {
                    let current = if changed.is_ok() { *state.borrow_and_update() } else { RTCPeerConnectionState::Closed };
                    up_tx.send_replace(current == RTCPeerConnectionState::Connected);
                    if matches!(current, RTCPeerConnectionState::Failed | RTCPeerConnectionState::Closed) {
                        ended.send_if_modified(|reason| {
                            if reason.is_some() {
                                return false;
                            }
                            *reason = Some(format!("{current}"));
                            true
                        });
                        return;
                    }
                }
                _ = ticker.tick() => {
                    let path = selected_path(&watcher_pc).await;
                    path_tx.send_if_modified(|current| {
                        let changed = *current != path;
                        *current = path;
                        changed
                    });
                }
            }
        }
    });
    Followed { path: path_rx, up: up_rx, ended: ended_rx, tasks: vec![signals, watcher] }
}

/// Phone side: opens a media session to `mac` for the WireGuard link
/// `link_session` (which both sides agreed on with [`super::WEBRTC_MEDIA_LANE`])
/// and returns it once its peer connection is connected. Bounded by
/// `options.timeout`.
pub async fn dial_media(
    signaling: &SignalingClient,
    mac: &str,
    link_session: &str,
    options: &super::DialOptions,
) -> Result<MediaSession, DialError> {
    let session_id = uuid::Uuid::new_v4().to_string();
    let mut events = SessionEvents::subscribe(signaling, &session_id);
    // Made before the bound, so every way out closes it: webrtc-rs does not
    // close a dropped peer connection (its ICE agent and sockets would stay).
    let (pc, mut state) = match new_peer_connection_for(options, true, true).await {
        Ok(made) => made,
        Err(error) => {
            signaling.unsubscribe(&session_id);
            return Err(error);
        }
    };
    let timeline = &options.timeline;
    let result = tokio::time::timeout(options.timeout, async {
        let receiver = crate::media::track::add_receiver(&pc).await.map_err(transport_error)?;
        trickle(&pc, signaling, mac, &session_id, timeline);
        let offer = pc.create_offer(None).await.map_err(transport_error)?;
        pc.set_local_description(offer.clone()).await.map_err(transport_error)?;
        signaling
            .send_signal(
                mac,
                &session_id,
                SignalPayload::WebrtcOffer {
                    sdp: offer.sdp,
                    lanes: vec![crate::media::VIDEO_LANE.to_owned()],
                    media_for: Some(link_session.to_owned()),
                },
            )
            .map_err(|e| DialError::Signaling(e.to_string()))?;
        timeline.mark("media_offer_sent");
        let mut remote = RemoteCandidates {
            timeline: timeline.clone(),
            exclude_cgnat: options.exclude_cgnat,
            ready: false,
            pending: Vec::new(),
        };
        let mut answered = None;
        media_connect(&pc, &mut state, &mut events, &mut remote, Some(&mut answered)).await?;
        if !answered.as_deref().is_some_and(super::video_lane_listed) {
            return Err(DialError::Transport("the Mac attached no video track".into()));
        }
        receiver.bind(Arc::clone(&pc)).await;
        timeline.mark("media_connected");
        Ok((receiver, remote))
    })
    .await
    .unwrap_or(Err(DialError::Timeout));
    let (receiver, remote) = match result {
        Ok(parts) => parts,
        Err(error) => {
            let _ = pc.close().await;
            media_refused(signaling, mac, &session_id, &error);
            return Err(error);
        }
    };
    let path = selected_path(&pc).await;
    let Followed { path, up, ended, tasks } = media_follow(Arc::clone(&pc), state, events, remote, path);
    Ok(MediaSession {
        session_id: session_id.clone(),
        carrier: receiver,
        path,
        up,
        ended,
        pc: Arc::clone(&pc),
        _guard: MediaGuard { pc, tasks, signaling: signaling.clone(), peer: mac.to_owned(), session_id },
    })
}

/// A media session that did not come up: stop following it and tell the peer.
fn media_refused(signaling: &SignalingClient, peer: &str, session_id: &str, error: &DialError) {
    signaling.unsubscribe(session_id);
    let reason = if *error == DialError::Timeout { "timeout".to_owned() } else { error.to_string() };
    let _ = signaling.send_signal(peer, session_id, SignalPayload::Bye { reason });
}

/// Mac side: answers a media session's first signal (`webrtc-offer` with
/// `mediaFor`) with a sending video track and returns it once its peer
/// connection is connected. The caller checked that `mediaFor` names a live
/// WireGuard link of the same phone. Bounded by `options.timeout`.
pub async fn answer_media(
    signaling: &SignalingClient,
    first: SignalEnvelope,
    mut events: SessionEvents,
    options: &super::DialOptions,
) -> Result<MediaSession, DialError> {
    let session_id = first.session_id.clone();
    let peer = first.from.clone();
    let SignalPayload::WebrtcOffer { sdp, lanes, media_for: Some(_) } = first.payload else {
        let error = DialError::Unexpected("expected a media session's webrtc-offer".into());
        media_refused(signaling, &peer, &session_id, &error);
        return Err(error);
    };
    if !super::video_lane_listed(&lanes) || !sdp.contains("m=video") {
        let error = DialError::Unexpected("a media session without video".into());
        media_refused(signaling, &peer, &session_id, &error);
        return Err(error);
    }
    // Made before the bound, so every way out closes it (see dial_media).
    let (pc, mut state) = match new_peer_connection_for(options, true, true).await {
        Ok(made) => made,
        Err(error) => {
            media_refused(signaling, &peer, &session_id, &error);
            return Err(error);
        }
    };
    let timeline = &options.timeline;
    let result = tokio::time::timeout(options.timeout, async {
        let (track, sender) = crate::media::track::add_sender(&pc).await.map_err(transport_error)?;
        trickle(&pc, signaling, &peer, &session_id, timeline);
        let offer = RTCSessionDescription::offer(sdp).map_err(transport_error)?;
        pc.set_remote_description(offer).await.map_err(transport_error)?;
        let answer = pc.create_answer(None).await.map_err(transport_error)?;
        pc.set_local_description(answer.clone()).await.map_err(transport_error)?;
        signaling
            .send_signal(
                &peer,
                &session_id,
                SignalPayload::WebrtcAnswer {
                    sdp: answer.sdp,
                    lanes: vec![crate::media::VIDEO_LANE.to_owned()],
                },
            )
            .map_err(|e| DialError::Signaling(e.to_string()))?;
        timeline.mark("media_answer_sent");
        let mut remote = RemoteCandidates {
            timeline: timeline.clone(),
            exclude_cgnat: options.exclude_cgnat,
            ready: true,
            pending: Vec::new(),
        };
        media_connect(&pc, &mut state, &mut events, &mut remote, None).await?;
        let carrier = crate::media::track::SendCarrier::new(track, sender).await;
        timeline.mark("media_connected");
        Ok((carrier, remote))
    })
    .await
    .unwrap_or(Err(DialError::Timeout));
    let (carrier, remote) = match result {
        Ok(parts) => parts,
        Err(error) => {
            let _ = pc.close().await;
            media_refused(signaling, &peer, &session_id, &error);
            return Err(error);
        }
    };
    let path = selected_path(&pc).await;
    let Followed { path, up, ended, tasks } = media_follow(Arc::clone(&pc), state, events, remote, path);
    Ok(MediaSession {
        session_id: session_id.clone(),
        carrier,
        path,
        up,
        ended,
        pc: Arc::clone(&pc),
        _guard: MediaGuard { pc, tasks, signaling: signaling.clone(), peer, session_id },
    })
}

/// The detached data channel as a byte stream with bounded message size.
struct DataChannelStream {
    inner: PollDataChannel,
}

impl AsyncRead for DataChannelStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}

impl AsyncWrite for DataChannelStream {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        let len = buf.len().min(MAX_MESSAGE);
        Pin::new(&mut self.inner).poll_write(cx, &buf[..len])
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A socket lost mid-handshake keeps the dial waiting for the data
    /// channel; a backend refusal still ends it.
    #[test]
    fn a_signaling_outage_does_not_fail_the_handshake() {
        let timeline = Timeline::new();
        assert!(matches!(signaling_outage(Ok(SessionEvent::Disconnected), &timeline, true), Ok(None)));
        assert!(matches!(
            signaling_outage(Err(DialError::Signaling("reset".into())), &timeline, true),
            Ok(None)
        ));
        assert!(timeline.get("signaling_lost").is_some());
        // Before the answer arrived there is nothing to finish: fail fast.
        assert!(matches!(
            signaling_outage(Ok(SessionEvent::Disconnected), &timeline, false),
            Err(DialError::Signaling(_))
        ));
        let refused = Err(DialError::Refused { code: "offline".into(), message: String::new() });
        assert!(signaling_outage(refused, &timeline, true).is_err());
    }
}
