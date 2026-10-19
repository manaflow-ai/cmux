//! One host: takes viewers from its signaling sources (the tailnet listener,
//! and the Worker room as the fallback), answers each viewer with a WebRTC
//! session (one viewer at a time), and keeps a connected session running
//! through signaling drops on either side. Only WebRTC itself (the peer
//! connection failing or closing, or the input channel closing) ends a
//! session once its input channel is open.
//!
//! A viewer identified on the tailnet is never displaced by a Worker room
//! offer: the room secret is a weaker credential than a tailnet identity.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};
use cmux_screen_proto::{
    DisplaySize, INPUT_CHANNEL, Input, Pairing, Quality, SCREEN_TRACK, ScreenHostMessage, ScreenInput, SignalMessage,
};
use libwebrtc::data_channel::{DataChannel, DataChannelState};
use libwebrtc::ice_candidate::IceCandidate;
use libwebrtc::media_stream_track::MediaStreamTrack;
use libwebrtc::peer_connection::{AnswerOptions, BitrateSettings, PeerConnection, PeerConnectionState};
use libwebrtc::peer_connection_factory::native::PeerConnectionFactoryExt;
use libwebrtc::peer_connection_factory::{IceServer, PeerConnectionFactory, RtcConfiguration};
use libwebrtc::rtp_parameters::DegradationPreference;
use libwebrtc::rtp_sender::RtpSender;
use libwebrtc::session_description::{SdpType, SessionDescription};
use libwebrtc::video_source::VideoResolution;
use libwebrtc::video_source::native::NativeVideoSource;
use tokio::sync::mpsc;

use crate::backend::{Backend, BackendKind};
use crate::tailnet_signal::{self, Incoming, Source, TailnetSignal};
use crate::{log, signal};

/// What libwebrtc's callbacks report back to the host loop.
enum Event {
    /// A local ICE candidate of session `id`.
    Candidate(u64, SignalMessage),
    /// The viewer created a data channel (kept so `end_session` can drop its handlers).
    Channel(u64, DataChannel),
    /// A data channel opened (session id, label).
    Opened(u64, String),
    /// A control message from the viewer (display or quality).
    Control(u64, Input),
    /// The peer connection or the input channel ended.
    Ended(u64, String),
}

struct Session {
    id: u64,
    /// Where this session's viewer signals (answers and candidates go back there).
    source: Source,
    peer: PeerConnection,
    video: NativeVideoSource,
    sender: RtpSender,
    backend: Arc<dyn Backend>,
    input: Mutex<Option<DataChannel>>,
    /// Every channel the viewer created. Their handlers hold the backend, so
    /// they are cleared when the session ends (or the channel and backend leak).
    channels: Mutex<Vec<DataChannel>>,
    /// The input channel opened: from here on only WebRTC ends the session.
    opened: AtomicBool,
    quality: Mutex<Quality>,
    displays: Arc<Mutex<(Vec<DisplaySize>, usize)>>,
}

pub struct Host {
    name: String,
    /// The Worker room (fallback signaling and TURN), if this host keeps one.
    pairing: Option<Pairing>,
    tailnet: Option<TailnetSignal>,
    backend: BackendKind,
    factory: PeerConnectionFactory,
    session: Option<Arc<Session>>,
    next_id: AtomicU64,
    /// The current room connection's outbox (candidates go out on whichever is open).
    outbox: Arc<Mutex<Option<mpsc::UnboundedSender<SignalMessage>>>>,
    events: mpsc::UnboundedSender<Event>,
    event_inbox: Option<mpsc::UnboundedReceiver<Event>>,
}

impl Host {
    pub fn new(name: String, pairing: Option<Pairing>, tailnet: Option<TailnetSignal>, backend: BackendKind) -> Self {
        let (events, event_inbox) = mpsc::unbounded_channel();
        Self {
            name,
            pairing,
            tailnet,
            backend,
            factory: PeerConnectionFactory::default(),
            session: None,
            next_id: AtomicU64::new(1),
            outbox: Arc::new(Mutex::new(None)),
            events,
            event_inbox: Some(event_inbox),
        }
    }

    /// Serves viewers until the process ends.
    pub async fn run(mut self) {
        let mut events = self.event_inbox.take().expect("run once");
        let (incoming, mut inbox) = mpsc::unbounded_channel::<Incoming>();
        if let Some(tailnet) = self.tailnet.take() {
            let port = tailnet.port;
            match tailnet_signal::serve(tailnet, incoming.clone()) {
                Ok(()) => log(format!("serving viewers on tailnet port {port}")),
                Err(error) => log(format!("tailnet signaling failed: {error:#}")),
            }
        }
        if let Some(pairing) = self.pairing.clone() {
            tokio::spawn(worker_room(pairing, self.outbox.clone(), incoming.clone()));
        }
        drop(incoming);
        loop {
            tokio::select! {
                Some(incoming) = inbox.recv() => self.on_signal(incoming).await,
                Some(event) = events.recv() => self.on_event(event),
                else => break,
            }
        }
    }

    /// Sends to a viewer on whichever signaling link it uses.
    fn send(&self, source: &Source, message: SignalMessage) {
        match source {
            Source::Worker => {
                if let Some(outbox) = self.outbox.lock().unwrap().as_ref() {
                    let _ = outbox.send(message);
                }
            }
            Source::Tailnet { reply, .. } => {
                let _ = reply.send(message);
            }
        }
    }

    async fn on_signal(&mut self, incoming: Incoming) {
        let Incoming { source, message } = incoming;
        let ours = self.session.as_ref().is_some_and(|session| session.source.same(&source));
        match message.kind.as_str() {
            "hello" => {
                if let Some(pairing) = &self.pairing {
                    log(format!("waiting for a viewer in room {}…", pairing.room.get(..8).unwrap_or("?")));
                }
            }
            "offer" => {
                let Some(sdp) = message.sdp else { return };
                if let Some(session) = &self.session
                    && matches!(session.source, Source::Tailnet { .. })
                    && matches!(source, Source::Worker)
                {
                    log("room offer refused: a tailnet viewer is connected");
                    return;
                }
                if let Err(error) = self.accept(&sdp, source).await {
                    log(format!("could not answer the viewer: {error:#}"));
                    self.end_session(None);
                }
            }
            "candidate" => {
                if !ours {
                    return;
                }
                let (Some(session), Some(candidate)) = (self.session.clone(), message.candidate) else { return };
                let mid = message.sdp_mid.unwrap_or_default();
                let index = message.sdp_mline_index.unwrap_or(0);
                match IceCandidate::parse(&mid, index, &candidate) {
                    Ok(candidate) => {
                        if let Err(error) = session.peer.add_ice_candidate(candidate).await {
                            log(format!("candidate: {error:?}"));
                        }
                    }
                    Err(error) => log(format!("candidate: {error:?}")),
                }
            }
            "peer-left" => {
                if !ours {
                    return;
                }
                // The viewer's signaling link dropped. A connected session
                // lives on (WebRTC reports its own end); a half-open one ends.
                match &self.session {
                    Some(session) if session.opened.load(Ordering::SeqCst) => {
                        log(format!("viewer's {} link dropped; the stream continues", source.describe()));
                    }
                    _ => {
                        log("viewer left");
                        self.end_session(None);
                    }
                }
            }
            _ => {}
        }
    }

    async fn accept(&mut self, sdp: &str, source: Source) -> Result<()> {
        self.end_session(None);
        // ICE tries direct candidates first (on a tailnet these are the
        // tailnet addresses); the room's STUN and TURN are the fallback.
        let ice = match (&self.pairing, &source) {
            (Some(pairing), Source::Worker) => signal::ice_servers(pairing).await?,
            (Some(pairing), Source::Tailnet { .. }) => signal::ice_servers(pairing).await.unwrap_or_else(|error| {
                log(format!("room ICE servers unavailable ({error:#}); direct paths only"));
                vec![]
            }),
            (None, _) => vec![],
        };
        let mut configuration = RtcConfiguration::default();
        configuration.ice_servers = ice
            .into_iter()
            .map(|server| IceServer {
                urls: server.urls,
                username: server.username.unwrap_or_default(),
                password: server.credential.unwrap_or_default(),
            })
            .collect();
        let peer = self.factory.create_peer_connection(configuration).context("peer connection")?;
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);

        let events = self.events.clone();
        peer.on_ice_candidate(Some(Box::new(move |candidate: IceCandidate| {
            let message = SignalMessage {
                kind: "candidate".into(),
                candidate: Some(candidate.candidate()),
                sdp_mid: Some(candidate.sdp_mid()),
                sdp_mline_index: Some(candidate.sdp_mline_index()),
                ..SignalMessage::default()
            };
            let _ = events.send(Event::Candidate(id, message));
        })));
        let events = self.events.clone();
        peer.on_connection_state_change(Some(Box::new(move |state| {
            log(format!("connection: {state:?}"));
            if matches!(state, PeerConnectionState::Failed | PeerConnectionState::Closed) {
                let _ = events.send(Event::Ended(id, format!("connection {state:?}")));
            }
        })));
        let events = self.events.clone();
        let backend_slot: Arc<Mutex<Option<Arc<dyn Backend>>>> = Arc::new(Mutex::new(None));
        let backend_for_channels = backend_slot.clone();
        peer.on_data_channel(Some(Box::new(move |channel: DataChannel| {
            // Handlers capture the label, never the channel: a channel's own
            // handler holding it would keep it (and the backend) alive.
            let label = channel.label();
            let _ = events.send(Event::Channel(id, channel.clone()));
            let events_state = events.clone();
            let state_label = label.clone();
            channel.on_state_change(Some(Box::new(move |state| match state {
                DataChannelState::Open => {
                    let _ = events_state.send(Event::Opened(id, state_label.clone()));
                }
                DataChannelState::Closed if state_label == INPUT_CHANNEL => {
                    let _ = events_state.send(Event::Ended(id, "input channel closed".into()));
                }
                _ => {}
            })));
            let (events_message, backend) = (events.clone(), backend_for_channels.clone());
            channel.on_message(Some(Box::new(move |buffer| {
                let Ok(input) = serde_json::from_slice::<ScreenInput>(buffer.data) else { return };
                let Some(input) = input.decode() else { return };
                match input {
                    Input::SelectDisplay(_) | Input::Quality(_) => {
                        let _ = events_message.send(Event::Control(id, input));
                    }
                    input => {
                        if let Some(backend) = backend.lock().unwrap().as_ref() {
                            backend.handle(input);
                        }
                    }
                }
            })));
            if channel.state() == DataChannelState::Open {
                let _ = events.send(Event::Opened(id, label));
            }
        })));

        peer.set_remote_description(SessionDescription::parse(sdp, SdpType::Offer).map_err(|e| anyhow::anyhow!("offer: {e:?}"))?)
            .await
            .map_err(|e| anyhow::anyhow!("offer: {e:?}"))?;
        let video = NativeVideoSource::new(VideoResolution { width: 1920, height: 1080 }, true);
        let track = self.factory.create_video_track(SCREEN_TRACK, video.clone());
        let sender = peer
            .add_track(MediaStreamTrack::Video(track), &[SCREEN_TRACK])
            .map_err(|e| anyhow::anyhow!("screen track: {e:?}"))?;
        let backend: Arc<dyn Backend> = Arc::from(crate::backend::make(self.backend));
        *backend_slot.lock().unwrap() = Some(backend.clone());
        let session = Arc::new(Session {
            id,
            source: source.clone(),
            peer,
            video,
            sender,
            backend,
            input: Mutex::new(None),
            channels: Mutex::new(vec![]),
            opened: AtomicBool::new(false),
            quality: Mutex::new(Quality::Auto),
            displays: Arc::new(Mutex::new((vec![], 0))),
        });
        apply_quality(&session);
        let answer = session.peer.create_answer(AnswerOptions::default()).await.map_err(|e| anyhow::anyhow!("answer: {e:?}"))?;
        session.peer.set_local_description(answer.clone()).await.map_err(|e| anyhow::anyhow!("answer: {e:?}"))?;
        let answer = answer.to_string();
        log(format!("answer: {}", describe_video(&answer)));
        self.send(&source, SignalMessage::with_sdp("answer", answer));
        self.session = Some(session);
        log(format!("{} viewer offered; streaming answer sent", source.describe()));
        Ok(())
    }

    fn on_event(&mut self, event: Event) {
        match event {
            Event::Candidate(id, message) => {
                // A previous session's late candidates must not reach the next viewer.
                let Some(session) = self.current(id) else { return };
                self.send(&session.source, message);
            }
            Event::Channel(id, channel) => match self.current(id) {
                Some(session) => session.channels.lock().unwrap().push(channel),
                None => clear_handlers(&channel),
            },
            Event::Opened(id, label) => {
                let Some(session) = self.current(id) else { return };
                if label != INPUT_CHANNEL {
                    return;
                }
                let input = session.channels.lock().unwrap().iter().find(|c| c.label() == INPUT_CHANNEL).cloned();
                *session.input.lock().unwrap() = input;
                if session.opened.swap(true, Ordering::SeqCst) {
                    return;
                }
                log("channel open; starting capture");
                let stats = Arc::downgrade(&session);
                tokio::spawn(async move {
                    // Every 3 s: what the encoder is doing (codec, hardware, fps, limits).
                    let mut tick = tokio::time::interval(Duration::from_secs(3));
                    tick.tick().await;
                    loop {
                        tick.tick().await;
                        let Some(session) = stats.upgrade() else { return };
                        log(format!("video: {}", outbound_summary(&session.sender).await));
                    }
                });
                let weak = Arc::downgrade(&session);
                let name = self.name.clone();
                let (backend, video) = (session.backend.clone(), session.video.clone());
                // Capture setup blocks (ScreenCaptureKit): off the host loop.
                tokio::task::spawn_blocking(move || {
                    let started = backend.start(
                        video,
                        Arc::new(move |sizes, current| {
                            let Some(session) = weak.upgrade() else { return };
                            *session.displays.lock().unwrap() = (sizes.clone(), current);
                            send_displays(&session, &name);
                            apply_quality(&session);
                        }),
                    );
                    if let Err(error) = started {
                        log(format!("screen source failed: {error:#}"));
                    }
                });
            }
            Event::Control(id, input) => {
                let Some(session) = self.current(id) else { return };
                match input {
                    Input::SelectDisplay(index) => {
                        let backend = session.backend.clone();
                        tokio::task::spawn_blocking(move || backend.select(index));
                    }
                    Input::Quality(quality) => {
                        *session.quality.lock().unwrap() = quality;
                        log(format!("quality: {}", quality.name()));
                        apply_quality(&session);
                    }
                    _ => {}
                }
            }
            Event::Ended(id, reason) => {
                if self.current(id).is_some() {
                    log(format!("session ended: {reason}"));
                    self.end_session(Some(id));
                }
            }
        }
    }

    fn current(&self, id: u64) -> Option<Arc<Session>> {
        self.session.clone().filter(|session| session.id == id)
    }

    fn end_session(&mut self, id: Option<u64>) {
        let Some(session) = self.session.take_if(|session| id.is_none_or(|id| session.id == id)) else { return };
        for channel in session.channels.lock().unwrap().drain(..) {
            clear_handlers(&channel);
        }
        session.input.lock().unwrap().take();
        session.peer.close();
        let backend = session.backend.clone();
        tokio::task::spawn_blocking(move || backend.stop());
        log("session ended");
    }
}

fn clear_handlers(channel: &DataChannel) {
    channel.on_state_change(None);
    channel.on_message(None);
    channel.on_buffered_amount_change(None);
}

fn send_displays(session: &Session, name: &str) {
    let (sizes, current) = session.displays.lock().unwrap().clone();
    let message = ScreenHostMessage::displays(&sizes, current, name);
    if let (Some(channel), Ok(text)) = (session.input.lock().unwrap().as_ref(), serde_json::to_vec(&message)) {
        let _ = channel.send(&text, false);
    }
}

/// The session's quality as WebRTC sender parameters (its congestion control keeps running).
fn apply_quality(session: &Session) {
    let quality = *session.quality.lock().unwrap();
    let height = {
        let (sizes, current) = &*session.displays.lock().unwrap();
        sizes.get(*current).map(|size| size.h).unwrap_or(0)
    };
    let settings = quality.settings(height);
    let mut parameters = session.sender.parameters();
    parameters.set_degradation_preference(match settings.degradation {
        cmux_screen_proto::Degradation::MaintainResolution => DegradationPreference::MaintainResolution,
        cmux_screen_proto::Degradation::MaintainFramerate => DegradationPreference::MaintainFramerate,
        cmux_screen_proto::Degradation::Disabled => DegradationPreference::MaintainFramerateAndResolution,
    });
    for encoding in &mut parameters.encodings {
        encoding.max_bitrate = Some(settings.max_bitrate);
        encoding.max_framerate = Some(settings.max_framerate);
        encoding.scale_resolution_down_by = Some(settings.scale_down);
    }
    if let Err(error) = session.sender.set_parameters(parameters) {
        log(format!("quality {}: {error:?}", quality.name()));
    }
    // Encodings carry no minimum in this API; the connection's bitrate floor
    // is where a fixed preset asks congestion control to hold its rate.
    // Adaptive presets go back to libwebrtc's own floor (30 kbps).
    let floor = BitrateSettings {
        min_bitrate_bps: Some(settings.min_bitrate.unwrap_or(30_000)),
        start_bitrate_bps: None,
        max_bitrate_bps: Some(settings.max_bitrate),
    };
    if let Err(error) = session.peer.set_bitrate(floor) {
        log(format!("quality {} bitrate: {error:?}", quality.name()));
    }
}

/// The answer's video section in one line: direction and offered codecs.
fn describe_video(sdp: &str) -> String {
    let mut in_video = false;
    let mut parts = vec![];
    for line in sdp.lines() {
        if line.starts_with("m=") {
            in_video = line.starts_with("m=video");
            if in_video {
                parts.push(line.split(' ').take(2).collect::<Vec<_>>().join(" "));
            }
        } else if in_video {
            if matches!(line, "a=sendonly" | "a=recvonly" | "a=sendrecv" | "a=inactive") {
                parts.push(line[2..].to_owned());
            } else if let Some(map) = line.strip_prefix("a=rtpmap:")
                && parts.len() < 6 {
                    parts.push(map.split(' ').nth(1).unwrap_or("").to_owned());
                }
        }
    }
    parts.join(" ")
}

/// libwebrtc's outbound video numbers, like the Swift host's log line.
async fn outbound_summary(sender: &RtpSender) -> String {
    let Ok(stats) = sender.get_stats().await else { return "no stats".into() };
    for stat in stats {
        if let libwebrtc::stats::RtcStats::OutboundRtp(rtp) = stat {
            let out = &rtp.outbound;
            return format!(
                "encoder {} {}x{} fps {:.0} encoded {} keyframes {} limited-by {:?} target {:.0} bps",
                out.encoder_implementation,
                out.frame_width,
                out.frame_height,
                out.frames_per_second,
                out.frames_encoded,
                out.key_frames_encoded,
                out.quality_limitation_reason,
                out.target_bitrate
            );
        }
    }
    "no outbound video".into()
}

/// Keeps the Worker room open (fallback signaling), reconnecting with backoff.
async fn worker_room(
    pairing: Pairing,
    outbox: Arc<Mutex<Option<mpsc::UnboundedSender<SignalMessage>>>>,
    incoming: mpsc::UnboundedSender<Incoming>,
) {
    let mut delay = Duration::from_secs(1);
    loop {
        match signal::connect(&pairing, "host").await {
            Ok(mut room) => {
                *outbox.lock().unwrap() = Some(room.outbox.clone());
                delay = Duration::from_secs(1);
                while let Some(message) = room.inbox.recv().await {
                    if incoming.send(Incoming { source: Source::Worker, message }).is_err() {
                        return;
                    }
                }
                *outbox.lock().unwrap() = None;
                log("room connection lost; reconnecting");
            }
            Err(error) => log(format!("room connection failed: {error:#}; retrying in {} s", delay.as_secs())),
        }
        tokio::time::sleep(delay).await; // reconnect backoff, not synchronization
        delay = (delay * 2).min(Duration::from_secs(30));
    }
}
