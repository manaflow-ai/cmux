//! The iPhone's screen viewer for `cmux.rd/1` hosts (the Linux desktop host today; the
//! Windows and Mac rd hosts the same way): the phone half of what `cmux-rd view` does in
//! one process (cmux-tui/crates/cmux-rd-host/src/view/).
//!
//! Swift keeps the hub side (the session request, the viewer ticket, the signaling socket
//! and the `fpSig` signatures, which need the device key); this module does the rest:
//!
//! 1. [`screen_offer`] makes a session key and the signed-to-be `cmux.rd/1` offer text.
//! 2. Swift signs it (`fingerprint_message(session, "viewer", fingerprint)`, the bytes
//!    [`ScreenOffer::signed_bytes`] returns), sends it, checks the host's signed answer, and
//!    hands the answer text to [`ScreenOffer::answer`].
//! 3. `answer` opens the secure link (cmux-rd-link: Noise_XX over one UDP socket, STUN and
//!    TURN from the ticket's ICE servers) as the initiator, sends `hello` (service `desktop`)
//!    and `start` (`view` or `control`) once it is up, and runs the shared rd viewer core
//!    (`cmux-rd-ffi`, datagram carrier: reassembly, NACK and loss feedback, clock probes,
//!    exactly-once input) on the library runtime.
//! 4. Whole H.264 access units go to Swift ([`ScreenObserver::on_frame`], the same
//!    [`BrowserFrame`] a streamed browser tab hands out), to decode with VideoToolbox. The
//!    link's candidates and path go to Swift for the signaling socket
//!    ([`ScreenObserver::on_candidate`], [`ScreenObserver::on_path`]); the host's
//!    candidates come back through [`ScreenStream::add_candidate`].
//!
//! Desktop input ([`ScreenStream::send_input`]) is JSON naming one rd input event, the
//! events the Linux host's XTest path and the Mac host's CGEvent path apply:
//!
//! - `{"e":"pointer","x":10,"y":20}`: absolute position in stream pixels;
//! - `{"e":"button","button":1,"down":true}`: 1 left, 2 middle, 3 right (X numbering);
//! - `{"e":"scroll","dx":0,"dy":-300,"precise":true}`: hundredths of a line, or of a point
//!   with `precise`;
//! - `{"e":"key","usage":458756,"down":true}`: a USB HID usage, `page << 16 | id`
//!   (`0x0007_0004` is A), so the meaning does not depend on the phone's layout;
//! - `{"e":"text","text":"é"}`: committed text (IME, dictation), as the host takes it;
//! - `{"e":"keysym","k":65,"down":true}`: an X11 keysym, the key that types it on a US layout
//!   (with Shift around it when the key needs one), or the character as text when no key
//!   does (CmuxScreenKit's keyboard bar and hardware keys speak keysyms);
//! - `{"e":"type","text":"Hi"}`: typed text as key presses, character by character (the
//!   Linux host applies no committed text); runs no US key types go as text.

use std::net::SocketAddr;
use std::os::fd::{AsRawFd, RawFd};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use cmux_rd_ffi::{Carrier, InputChannel, Session};
use cmux_rd_link::doc::{self, RdDocument};
use cmux_rd_link::net::{Candidate, Net, NetConfig, NetEvent, TurnServer};
use cmux_rd_link::{EndpointEvent, Event, KeyPair, Role};
use cmux_rd_proto::control::Control;
use cmux_rd_proto::{InputEvent, MAX_DATAGRAM_VPC, SERVICE_DESKTOP, STREAM_CONTROL, flags};
use serde_json::Value;
use tokio::io::unix::AsyncFd;
use tokio::sync::mpsc;

use crate::browser::BrowserFrame;
use crate::screen_keys;
use crate::{CmuxMobileError, on_runtime};

/// How long a frame may wait for missing shards (`cmux-rd view`'s value), and when its
/// gaps are NACKed (past Wi-Fi reordering, well under a frame at 60 fps).
const FRAME_DEADLINE_US: u64 = 200_000;
const NACK_AFTER_US: u64 = 10_000;
/// When an unacknowledged input event is sent again.
const INPUT_RESEND_US: u64 = 50_000;
/// The rd cap for clock probes (each frame's age); offered, used when the host accepts it.
const CAP_CLOCK: &str = "clock";
/// The viewer's datagram size: what `cmux-rd view` asks, which fits every path's MTU.
const MAX_DATAGRAM: usize = MAX_DATAGRAM_VPC;
/// The most characters one `type` input event takes (a paste of a few pages).
const MAX_TYPED_CHARS: usize = 8_192;
/// The close reason when the app closed the stream.
pub const CLOSED_BY_APP: &str = "closed by the app";

/// A session key and its `cmux.rd/1` offer, waiting for the host's answer.
#[derive(uniffi::Object)]
pub struct ScreenOffer {
    text: String,
    keys: Mutex<Option<KeyPair>>,
}

/// A new session key and the offer that carries it. `max_width` is the widest stream the
/// phone wants (the host scales down to it), `max_fps` its frame rate, `display` the host
/// display to show (the host's first when `None`).
#[uniffi::export]
pub fn screen_offer(
    max_width: Option<u32>,
    max_fps: Option<u32>,
    display: Option<i64>,
) -> Result<Arc<ScreenOffer>, CmuxMobileError> {
    let keys = KeyPair::generate()
        .map_err(|e| CmuxMobileError::Transport { message: format!("session key: {e}") })?;
    let text =
        RdDocument { key: doc::hex(&keys.public), max_width, max_fps, display, ..RdDocument::default() }
            .text();
    Ok(Arc::new(ScreenOffer { text, keys: Mutex::new(Some(keys)) }))
}

/// The link's current path, for the signaling socket's `path` report and the overlay.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ScreenPath {
    /// The path class's wire name (`direct_lan`, `direct_wan`, `turn_relay`, ...).
    pub kind: String,
    /// Through a relay: the hub's `path` report says `relay`, else `direct`.
    pub relayed: bool,
    pub rtt_us: Option<u64>,
}

/// Counters for the overlay and the logs.
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct ScreenStats {
    /// The secure link's handshake finished.
    pub connected: bool,
    /// The host's `welcome` arrived: its stream size.
    pub width: u32,
    pub height: u32,
    pub encoder: String,
    pub frames: u64,
    pub keyframes: u64,
    pub bytes: u64,
    pub frames_lost: u64,
    /// Frames Swift showed ([`ScreenStream::note_presented`]).
    pub presented: u64,
    /// `host = viewer + offset`, and the best probe's round trip.
    pub clock_offset_us: Option<i64>,
    pub clock_rtt_us: Option<u32>,
    /// The newest frame's age when it was complete (network, reassembly, host encode).
    pub last_age_us: Option<i64>,
    pub path: Option<ScreenPath>,
}

/// Receives a screen stream's frames and events on a library thread. Implementations
/// should hand off quickly (a decode queue).
#[uniffi::export(with_foreign)]
pub trait ScreenObserver: Send + Sync {
    /// One complete frame: an Annex-B access unit (SPS and PPS before each IDR).
    fn on_frame(&self, frame: BrowserFrame);
    /// A local link candidate (`"<kind> <addr>"`) to send on the signaling socket as
    /// `{"type":"candidate","candidate":..,"sdpMid":"cmux-rd","sdpMLineIndex":0}`.
    fn on_candidate(&self, candidate: String);
    /// The link's path changed (send `{"type":"path","path":"relay"|"direct"}`).
    fn on_path(&self, path: ScreenPath);
    /// An rd control message from the host, JSON with `t` (`welcome`, `started`, `stats`,
    /// `refused`, `ended`, ...).
    fn on_message(&self, json: String);
    /// The stream ended; `reason` is for the person and the logs.
    fn on_closed(&self, reason: String);
}

#[uniffi::export]
impl ScreenOffer {
    /// The offer, the `sdp` of the signaling socket's `offer` frame.
    pub fn text(&self) -> String {
        self.text.clone()
    }

    /// The bytes the offer's `fpSig` signs with the device key for `session_id`.
    pub fn signed_bytes(&self, session_id: String) -> Vec<u8> {
        let fingerprint = doc::fingerprint_of(&self.text).unwrap_or_default();
        doc::fingerprint_message(&session_id, "viewer", &fingerprint)
    }

    /// Opens the stream on the host's answer. The caller has checked the answer's `fpSig`
    /// against the host's device key. `ice_servers_json` is the ticket's ICE servers
    /// (`[{urls, username?, credential?}]`); `relay_only` uses only TURN; `control` asks to
    /// control the screen (else view it); `viewer_id` is this phone's hub device id.
    /// An offer opens one stream: a second call is refused.
    #[allow(clippy::too_many_arguments)]
    pub async fn answer(
        &self,
        answer: String,
        session_id: String,
        viewer_id: String,
        ice_servers_json: String,
        relay_only: bool,
        control: bool,
        observer: Arc<dyn ScreenObserver>,
    ) -> Result<Arc<ScreenStream>, CmuxMobileError> {
        let bind = SocketAddr::from(([0, 0, 0, 0], 0));
        self.answer_bound(
            answer,
            session_id,
            viewer_id,
            ice_servers_json,
            relay_only,
            control,
            observer,
            bind,
        )
        .await
    }
}

impl ScreenOffer {
    #[allow(clippy::too_many_arguments)]
    async fn answer_bound(
        &self,
        answer: String,
        session_id: String,
        viewer_id: String,
        ice_servers_json: String,
        relay_only: bool,
        control: bool,
        observer: Arc<dyn ScreenObserver>,
        bind: SocketAddr,
    ) -> Result<Arc<ScreenStream>, CmuxMobileError> {
        let invalid = |message: String| CmuxMobileError::InvalidArgument { message };
        let answer = RdDocument::parse(&answer)
            .ok_or_else(|| invalid("the host's answer is not a cmux.rd/1 document".into()))?;
        let peer = answer.key_bytes().ok_or_else(|| invalid("the host's session key is malformed".into()))?;
        let ice: Value = if ice_servers_json.trim().is_empty() {
            Value::Array(Vec::new())
        } else {
            serde_json::from_str(&ice_servers_json).map_err(|e| invalid(format!("ice_servers_json: {e}")))?
        };
        if session_id.is_empty() {
            return Err(invalid("no session id".into()));
        }
        let keys = self
            .keys
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()
            .ok_or_else(|| invalid("this offer already opened a stream".into()))?;
        let setup = Setup { session_id, viewer_id, ice, relay_only, control, peer, bind, keys };
        let candidates: Vec<Candidate> =
            answer.candidates.iter().filter_map(|c| Candidate::from_wire(c)).collect();
        on_runtime(async move {
            // Name lookups and the socket's bind block: off the runtime's workers.
            let net = tokio::task::spawn_blocking(move || setup.start())
                .await
                .map_err(|e| CmuxMobileError::Transport { message: format!("link start: {e}") })??;
            for candidate in candidates {
                net.0.add_remote_candidate(candidate);
            }
            Ok(start(net, observer))
        })
        .await
    }
}

struct Setup {
    session_id: String,
    viewer_id: String,
    ice: Value,
    relay_only: bool,
    control: bool,
    peer: [u8; 32],
    bind: SocketAddr,
    keys: KeyPair,
}

/// The started link and what the viewer loop needs from the setup.
struct Started(Net, String, bool);

impl Setup {
    fn start(self) -> Result<Started, CmuxMobileError> {
        let (stun, turn) = doc::servers(&self.ice);
        let stun: Vec<SocketAddr> = stun
            .iter()
            .filter_map(|s| std::net::ToSocketAddrs::to_socket_addrs(s).ok()?.find(SocketAddr::is_ipv4))
            .collect();
        let turn: Vec<TurnServer> = cmux_rd_link::net::turn_servers(&turn);
        let net = Net::start(NetConfig {
            role: Role::Initiator,
            session: self.session_id.into_bytes(),
            local: self.keys,
            expected_remote: self.peer,
            stun,
            bind: self.bind,
            turn,
            relay_only: self.relay_only,
        })
        .map_err(|e| CmuxMobileError::Transport { message: e.to_string() })?;
        Ok(Started(net, self.viewer_id, self.control))
    }
}

enum Command {
    Candidate(Candidate),
    Input(InputEvent),
    Keyframe,
    Decoded(u32),
    NetworkChanged,
    Close,
}

/// One open screen stream.
#[derive(uniffi::Object)]
pub struct ScreenStream {
    commands: mpsc::UnboundedSender<Command>,
    stats: Arc<Mutex<ScreenStats>>,
    epoch: Instant,
    control: bool,
    #[cfg_attr(not(test), allow(dead_code))]
    local_addr: SocketAddr,
}

#[uniffi::export]
impl ScreenStream {
    /// A host candidate from the signaling socket (`"<kind> <addr>"`).
    pub fn add_candidate(&self, candidate: String) -> Result<(), CmuxMobileError> {
        let candidate = Candidate::from_wire(&candidate).ok_or_else(|| CmuxMobileError::InvalidArgument {
            message: format!("not a cmux-rd candidate: {candidate}"),
        })?;
        self.commands.send(Command::Candidate(candidate)).map_err(|_| closed())
    }

    /// Sends one desktop input event (the JSON forms in this module's documentation).
    /// Refused on a view-only stream.
    pub fn send_input(&self, json: String) -> Result<(), CmuxMobileError> {
        if !self.control {
            return Err(CmuxMobileError::InvalidArgument {
                message: "this stream only views the screen".into(),
            });
        }
        let events = input_events(&json).map_err(|message| CmuxMobileError::InvalidArgument { message })?;
        for event in events {
            self.commands.send(Command::Input(event)).map_err(|_| closed())?;
        }
        Ok(())
    }

    /// Asks the host for a keyframe (the decoder lost its state).
    pub fn request_keyframe(&self) {
        let _ = self.commands.send(Command::Keyframe);
    }

    /// Reports how long the last frame took to decode (feeds the host's rate control).
    pub fn note_decode(&self, decode_us: u32) {
        let _ = self.commands.send(Command::Decoded(decode_us));
    }

    /// Counts one frame shown on screen.
    pub fn note_presented(&self) {
        self.stats.lock().unwrap_or_else(PoisonError::into_inner).presented += 1;
    }

    /// The phone's network changed (Wi-Fi to cellular, an address): the link probes again.
    pub fn network_changed(&self) {
        let _ = self.commands.send(Command::NetworkChanged);
    }

    pub fn stats(&self) -> ScreenStats {
        self.stats.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// Microseconds on the clock `BrowserFrame.received_us` uses.
    pub fn now_us(&self) -> u64 {
        u64::try_from(self.epoch.elapsed().as_micros()).unwrap_or(u64::MAX)
    }

    /// Ends the stream: the host gets `stop`, the observer `on_closed`.
    pub fn close(&self) {
        let _ = self.commands.send(Command::Close);
    }
}

impl Drop for ScreenStream {
    fn drop(&mut self) {
        let _ = self.commands.send(Command::Close);
    }
}

fn closed() -> CmuxMobileError {
    CmuxMobileError::Closed { message: "the screen stream is closed".into() }
}

/// The desktop input events of one JSON form (a keysym or typed text can be several).
fn input_events(json: &str) -> Result<Vec<InputEvent>, String> {
    let v: Value = serde_json::from_str(json).map_err(|e| format!("input: {e}"))?;
    let int = |name: &str| -> Result<i32, String> {
        v.get(name)
            .and_then(Value::as_i64)
            .and_then(|n| i32::try_from(n).ok())
            .ok_or_else(|| format!("input needs an integer {name}"))
    };
    let down =
        || v.get("down").and_then(Value::as_bool).ok_or_else(|| "input needs a boolean down".to_owned());
    match v.get("e").and_then(Value::as_str) {
        Some("pointer") => Ok(vec![InputEvent::Pointer { x: int("x")?, y: int("y")? }]),
        Some("button") => {
            let button = u8::try_from(int("button")?)
                .ok()
                .filter(|b| (1..=9).contains(b))
                .ok_or("button is 1 to 9 (1 left, 2 middle, 3 right)")?;
            Ok(vec![InputEvent::Button { button, down: down()? }])
        }
        Some("scroll") => Ok(vec![InputEvent::Scroll {
            dx: int("dx").unwrap_or(0),
            dy: int("dy").unwrap_or(0),
            precise: v.get("precise").and_then(Value::as_bool).unwrap_or(false),
        }]),
        Some("key") => {
            let usage = v
                .get("usage")
                .and_then(Value::as_u64)
                .and_then(|n| u32::try_from(n).ok())
                .ok_or("input needs a HID usage (page << 16 | id)")?;
            Ok(vec![InputEvent::Key { usage, down: down()? }])
        }
        Some("text") => {
            let text = v.get("text").and_then(Value::as_str).ok_or("input needs text")?;
            if text.len() > cmux_rd_proto::MAX_TEXT_BYTES {
                return Err(format!("text is at most {} bytes", cmux_rd_proto::MAX_TEXT_BYTES));
            }
            Ok(vec![InputEvent::Text(text.to_owned())])
        }
        Some("keysym") => {
            let keysym = v
                .get("k")
                .and_then(Value::as_u64)
                .and_then(|n| u32::try_from(n).ok())
                .ok_or("input needs an X11 keysym k")?;
            screen_keys::keysym_events(keysym, down()?)
        }
        Some("type") => {
            let text = v.get("text").and_then(Value::as_str).ok_or("input needs text")?;
            if text.chars().count() > MAX_TYPED_CHARS {
                return Err(format!("typed text is at most {MAX_TYPED_CHARS} characters"));
            }
            Ok(screen_keys::typed_events(text))
        }
        other => {
            Err(format!("unknown input event {other:?} (pointer, button, scroll, key, text, keysym, type)"))
        }
    }
}

/// Starts the viewer loop on the library runtime.
fn start(started: Started, observer: Arc<dyn ScreenObserver>) -> Arc<ScreenStream> {
    let Started(net, viewer_id, control) = started;
    let (commands, rx) = mpsc::unbounded_channel();
    let stats = Arc::new(Mutex::new(ScreenStats::default()));
    let epoch = Instant::now();
    let local_addr = net.local_addr();
    let viewer = Viewer {
        session: Session::new(Carrier::Datagram, FRAME_DEADLINE_US, NACK_AFTER_US),
        input: InputChannel::new(Carrier::Datagram, INPUT_RESEND_US),
        observer,
        stats: Arc::clone(&stats),
        epoch,
        viewer_id,
        control,
        connected: false,
        started: false,
    };
    tokio::spawn(viewer.run(net, rx));
    Arc::new(ScreenStream { commands, stats, epoch, control, local_addr })
}

/// The link driver's event pipe, for the runtime's reactor (the driver owns the descriptor
/// and outlives this registration).
struct EventFd(RawFd);

impl AsRawFd for EventFd {
    fn as_raw_fd(&self) -> RawFd {
        self.0
    }
}

struct Viewer {
    session: Session,
    input: InputChannel,
    observer: Arc<dyn ScreenObserver>,
    stats: Arc<Mutex<ScreenStats>>,
    epoch: Instant,
    viewer_id: String,
    control: bool,
    /// The handshake finished.
    connected: bool,
    /// `hello` and `start` went out.
    started: bool,
}

impl Viewer {
    fn now(&self) -> u64 {
        u64::try_from(self.epoch.elapsed().as_micros()).unwrap_or(u64::MAX)
    }

    async fn run(mut self, net: Net, mut commands: mpsc::UnboundedReceiver<Command>) {
        // The driver is not `Sync` (its event queue): the loop owns it across its awaits.
        let (reason, net) = self.serve(net, &mut commands).await;
        if self.started {
            // Sent before the driver's close, on the same ordered queue.
            net.send_control(serde_json::to_vec(&Control::Stop).unwrap_or_default());
        }
        // Dropping the driver joins its thread: not on a runtime worker.
        let _ = tokio::task::spawn_blocking(move || drop(net)).await;
        self.observer.on_closed(reason);
    }

    async fn serve(&mut self, net: Net, commands: &mut mpsc::UnboundedReceiver<Command>) -> (String, Net) {
        let events = match AsyncFd::new(EventFd(net.event_fd())) {
            Ok(fd) => fd,
            Err(e) => return (format!("the link's events cannot be watched: {e}"), net),
        };
        let reason = 'run: loop {
            let wait = Duration::from_micros(self.deadline().saturating_sub(self.now()));
            let mut first = None;
            tokio::select! {
                ready = events.readable() => match ready {
                    Ok(mut guard) => guard.clear_ready(),
                    Err(e) => break 'run format!("the link's events cannot be watched: {e}"),
                },
                command = commands.recv() => first = Some(command),
                () = tokio::time::sleep(wait) => {}
            }
            if let Some(command) = first {
                if let Some(reason) = self.command(&net, command) {
                    break 'run reason;
                }
                while let Ok(command) = commands.try_recv() {
                    if let Some(reason) = self.command(&net, Some(command)) {
                        break 'run reason;
                    }
                }
            }
            for event in net.events() {
                if let Some(reason) = self.on_event(&net, event) {
                    break 'run reason;
                }
            }
            let now = self.now();
            self.session.tick(now);
            self.drain(now);
            if self.connected {
                while let Some(datagram) = self.session.feedback(now) {
                    net.send_datagram(datagram);
                }
            }
            if self.started {
                while let Some(datagram) = self.input.packet(now) {
                    net.send_datagram(datagram);
                }
            }
        };
        // Off the reactor before the driver closes the descriptor.
        drop(events);
        (reason, net)
    }

    /// One command from the app; `Some` ends the stream with that reason.
    fn command(&mut self, net: &Net, command: Option<Command>) -> Option<String> {
        match command {
            Some(Command::Candidate(c)) => net.add_remote_candidate(c),
            Some(Command::Input(event)) => {
                self.input.push(event);
            }
            Some(Command::Keyframe) => {
                let _ = self.session.request_keyframe(0);
            }
            Some(Command::Decoded(us)) => {
                let _ = self.session.note_decode(0, us);
            }
            Some(Command::NetworkChanged) => net.network_changed(),
            Some(Command::Close) | None => return Some(CLOSED_BY_APP.to_owned()),
        }
        None
    }

    fn deadline(&self) -> u64 {
        let session = if self.connected { self.session.next_deadline_us() } else { u64::MAX };
        let input = if self.started { self.input.next_deadline_us().unwrap_or(u64::MAX) } else { u64::MAX };
        // At least every 100 ms (clock probes, stats).
        session.min(input).min(self.now() + 100_000)
    }

    /// One event of the link; `Some` ends the stream with that reason.
    fn on_event(&mut self, net: &Net, event: NetEvent) -> Option<String> {
        match event {
            NetEvent::Candidate(c) => self.observer.on_candidate(c.to_wire()),
            NetEvent::Endpoint(EndpointEvent::Link(Event::Established)) => {
                self.connected = true;
                self.stats.lock().unwrap_or_else(PoisonError::into_inner).connected = true;
                if !self.started {
                    self.started = true;
                    self.say_hello(net);
                }
            }
            NetEvent::Endpoint(EndpointEvent::PathChanged { kind: Some(kind), rtt_us, .. }) => {
                let kind = kind.wire_name().to_owned();
                let path = ScreenPath { relayed: doc::is_relayed(&kind), kind, rtt_us };
                self.stats.lock().unwrap_or_else(PoisonError::into_inner).path = Some(path.clone());
                self.observer.on_path(path);
            }
            NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(d))) => {
                // One bad datagram does not end the stream.
                let _ = self.session.push_datagram(&d, self.now());
            }
            NetEvent::Endpoint(EndpointEvent::Link(Event::Control(record))) => {
                return self.on_control(&record);
            }
            NetEvent::Endpoint(EndpointEvent::Link(Event::Closed)) => {
                return Some("the host closed the link".into());
            }
            NetEvent::Failed(reason) => return Some(format!("the link failed: {reason}")),
            _ => {}
        }
        None
    }

    /// `hello` (the desktop service) and `start`.
    fn say_hello(&self, net: &Net) {
        let hello = Control::Hello {
            user: self.viewer_id.clone(),
            install: self.viewer_id.clone(),
            class: "user".into(),
            interactive: true,
            udp_port: None,
            max_datagram: MAX_DATAGRAM,
            token: None,
            service: SERVICE_DESKTOP.into(),
            caps: vec![CAP_CLOCK.into()],
        };
        let start = Control::Start {
            key: format!("phone-{}", uuid::Uuid::new_v4()),
            mode: if self.control { "control" } else { "view" }.into(),
        };
        for control in [hello, start] {
            net.send_control(serde_json::to_vec(&control).unwrap_or_default());
        }
    }

    fn on_control(&mut self, record: &[u8]) -> Option<String> {
        let Ok(control) = serde_json::from_slice::<Value>(record) else { return None };
        let field = |name: &str| control.get(name).and_then(Value::as_str).unwrap_or_default().to_owned();
        let ended = match control.get("t").and_then(Value::as_str) {
            Some("welcome") => {
                if control
                    .get("caps")
                    .and_then(Value::as_array)
                    .is_some_and(|caps| caps.iter().any(|c| c == CAP_CLOCK))
                {
                    self.session.enable_clock();
                }
                let size = |name: &str| {
                    control.get(name).and_then(Value::as_u64).and_then(|n| u32::try_from(n).ok()).unwrap_or(0)
                };
                let mut stats = self.stats.lock().unwrap_or_else(PoisonError::into_inner);
                (stats.width, stats.height, stats.encoder) =
                    (size("width"), size("height"), field("encoder"));
                None
            }
            Some("refused" | "ended") => Some(format!("the host ended the stream: {}", field("reason"))),
            _ => None,
        };
        self.observer.on_message(control.to_string());
        ended
    }

    fn drain(&mut self, now: u64) {
        while let Some(message) = self.session.pop_message() {
            if message.kind != STREAM_CONTROL {
                let _ = self.input.on_ack(&message.bytes);
            }
        }
        let clock = self.session.clock();
        while let Some((stream, complete)) = self.session.pop_frame() {
            let keyframe = complete.flags & flags::KEYFRAME != 0;
            let capture_us = complete.body.t_capture_us;
            let age_us = clock.map(|c| {
                let host_now = i128::from(now) + i128::from(c.offset_us);
                i64::try_from(host_now - i128::from(capture_us)).unwrap_or(i64::MAX)
            });
            {
                let mut stats = self.stats.lock().unwrap_or_else(PoisonError::into_inner);
                stats.frames += 1;
                stats.keyframes += u64::from(keyframe);
                stats.bytes += complete.body.access_unit.len() as u64;
                stats.clock_offset_us = clock.map(|c| c.offset_us);
                stats.clock_rtt_us = clock.map(|c| c.rtt_us);
                stats.last_age_us = age_us;
                if let Ok(s) = self.session.stats(stream) {
                    stats.frames_lost = s.frames_lost;
                }
            }
            self.observer.on_frame(BrowserFrame {
                stream,
                frame: complete.frame,
                keyframe,
                access_unit: complete.body.access_unit,
                capture_us,
                received_us: now,
                age_us,
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_rd_core::packetize::Packetizer;
    use cmux_rd_link::net::CandidateKind;
    use cmux_rd_proto::{DatagramHeader, DatagramKind, FrameBody, InputPacket, REF_NONE};
    use std::sync::mpsc as std_mpsc;

    #[derive(Debug)]
    enum Seen {
        Frame(BrowserFrame),
        Candidate(String),
        Path(ScreenPath),
        Message(String),
        Closed(String),
    }

    struct Recorder(Mutex<std_mpsc::Sender<Seen>>);

    impl Recorder {
        fn send(&self, seen: Seen) {
            let _ = self.0.lock().unwrap().send(seen);
        }
    }

    impl ScreenObserver for Recorder {
        fn on_frame(&self, frame: BrowserFrame) {
            self.send(Seen::Frame(frame));
        }
        fn on_candidate(&self, candidate: String) {
            self.send(Seen::Candidate(candidate));
        }
        fn on_path(&self, path: ScreenPath) {
            self.send(Seen::Path(path));
        }
        fn on_message(&self, json: String) {
            self.send(Seen::Message(json));
        }
        fn on_closed(&self, reason: String) {
            self.send(Seen::Closed(reason));
        }
    }

    /// The fake rd host: its link and the events it read but has not looked at yet
    /// (one `Net::events` batch can hold hello and start together).
    struct FakeHost {
        net: Net,
        backlog: std::collections::VecDeque<NetEvent>,
    }

    /// Reads the fake host's events until `pick` returns something, for at most 5 s;
    /// a timeout names what it waited for and the kinds of event it saw instead.
    fn host_wait<T>(host: &mut FakeHost, what: &str, mut pick: impl FnMut(NetEvent) -> Option<T>) -> T {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut other = Vec::new();
        while Instant::now() < deadline {
            host.backlog.extend(host.net.events());
            while let Some(event) = host.backlog.pop_front() {
                let kind = match &event {
                    NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(_))) => "datagram".to_owned(),
                    NetEvent::Endpoint(EndpointEvent::Link(Event::Control(_))) => "control".to_owned(),
                    e => format!("{e:?}").chars().take(60).collect(),
                };
                if let Some(found) = pick(event) {
                    return found;
                }
                other.push(kind);
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        panic!("the fake host waited 5 s for {what}; it saw {other:?}");
    }

    fn host_control(host: &mut FakeHost, what: &str) -> Control {
        host_wait(host, what, |event| match event {
            NetEvent::Endpoint(EndpointEvent::Link(Event::Control(record))) => {
                Some(serde_json::from_slice::<Control>(&record).expect("a typed control record"))
            }
            _ => None,
        })
    }

    fn host_input(host: &mut FakeHost) -> InputPacket {
        host_wait(host, "an input datagram", |event| match event {
            NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(d))) => {
                let (h, payload) = DatagramHeader::decode(&d).ok()?;
                (h.kind == DatagramKind::Input)
                    .then(|| InputPacket::decode(payload).expect("an input packet"))
            }
            _ => None,
        })
    }

    #[test]
    fn screen_offer_parses_with_the_hub_document_parser() {
        let offer = screen_offer(Some(1170), Some(60), Some(1)).unwrap();
        let text = offer.text();
        // cmux_hub_host::rd_doc re-exports this parser: the Linux host reads the offer so.
        let doc = RdDocument::parse(&text).expect("a cmux.rd/1 offer");
        assert_eq!((doc.max_width, doc.max_fps, doc.display), (Some(1170), Some(60), Some(1)));
        assert!(doc.key_bytes().is_some());
        let fingerprint = doc::fingerprint_of(&text).unwrap();
        assert_eq!(fingerprint, format!("cmux-rd-key {}", doc.key));
        assert_eq!(offer.signed_bytes("sid-9".into()), format!("sid-9|viewer|{fingerprint}").into_bytes());
        // Each offer has its own session key.
        let other = RdDocument::parse(&screen_offer(None, None, None).unwrap().text()).unwrap();
        assert_ne!(other.key, doc.key);
        assert_eq!((other.max_width, other.display), (None, None));
    }

    #[test]
    fn screen_input_json_becomes_rd_input_events() {
        let cases = [
            (r#"{"e":"pointer","x":10,"y":-2}"#, InputEvent::Pointer { x: 10, y: -2 }),
            (r#"{"e":"button","button":3,"down":true}"#, InputEvent::Button { button: 3, down: true }),
            (
                r#"{"e":"scroll","dy":-300,"precise":true}"#,
                InputEvent::Scroll { dx: 0, dy: -300, precise: true },
            ),
            (
                r#"{"e":"key","usage":458756,"down":false}"#,
                InputEvent::Key { usage: 0x0007_0004, down: false },
            ),
            (r#"{"e":"text","text":"é"}"#, InputEvent::Text("é".into())),
        ];
        for (json, event) in cases {
            assert_eq!(input_events(json), Ok(vec![event]), "{json}");
        }
        // A keysym is its US-layout key, with Shift when the key needs it; typed text is key presses.
        let shift = |down| InputEvent::Key { usage: 0x0007_00E1, down };
        let a = |down| InputEvent::Key { usage: 0x0007_0004, down };
        assert_eq!(input_events(r#"{"e":"keysym","k":65,"down":true}"#), Ok(vec![shift(true), a(true)]));
        assert_eq!(input_events(r#"{"e":"keysym","k":97,"down":false}"#), Ok(vec![a(false)]));
        assert_eq!(input_events(r#"{"e":"type","text":"a"}"#), Ok(vec![a(true), a(false)]));
        for bad in [
            "nope",
            r#"{"e":"wiggle"}"#,
            r#"{"e":"button","button":0,"down":true}"#,
            r#"{"e":"key","usage":4}"#,
            r#"{"e":"pointer","x":1}"#,
            r#"{"e":"keysym","k":65}"#,
            r#"{"e":"keysym","k":65104,"down":true}"#,
        ] {
            assert!(input_events(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn screen_answer_refuses_a_webrtc_answer() {
        let offer = screen_offer(None, None, None).unwrap();
        let (tx, _rx) = std_mpsc::channel();
        let observer: Arc<dyn ScreenObserver> = Arc::new(Recorder(Mutex::new(tx)));
        let webrtc = "v=0\r\na=fingerprint:sha-256 AB:CD\r\n".to_owned();
        let refused = crate::runtime().block_on(offer.answer(
            webrtc,
            "sid".into(),
            "phone".into(),
            String::new(),
            false,
            false,
            Arc::clone(&observer),
        ));
        assert!(
            matches!(refused, Err(CmuxMobileError::InvalidArgument { .. })),
            "{:?}",
            refused.as_ref().err()
        );
    }

    /// A fake rd host in this process (the secure link on loopback UDP) answers the offer,
    /// reads hello and start, sends welcome and three access units, and reads input.
    #[test]
    fn screen_stream_against_a_fake_host_on_loopback() {
        let offer = screen_offer(Some(1280), Some(30), None).unwrap();
        let offer_doc = RdDocument::parse(&offer.text()).unwrap();
        let session = "sid-loopback";
        let host_keys = KeyPair::generate().unwrap();
        let net = Net::start(NetConfig {
            role: Role::Responder,
            session: session.as_bytes().to_vec(),
            local: host_keys.clone(),
            expected_remote: offer_doc.key_bytes().unwrap(),
            stun: Vec::new(),
            bind: "127.0.0.1:0".parse().unwrap(),
            turn: Vec::new(),
            relay_only: false,
        })
        .unwrap();
        let mut host = FakeHost { net, backlog: Default::default() };
        let answer = RdDocument {
            key: doc::hex(&host_keys.public),
            candidates: vec![Candidate { kind: CandidateKind::Host, addr: host.net.local_addr() }.to_wire()],
            ..RdDocument::default()
        };

        let (tx, seen) = std_mpsc::channel();
        let observer: Arc<dyn ScreenObserver> = Arc::new(Recorder(Mutex::new(tx)));
        let open = |observer: Arc<dyn ScreenObserver>| {
            crate::runtime().block_on(offer.answer_bound(
                answer.text(),
                session.into(),
                "phone-1".into(),
                "[]".into(),
                false,
                true,
                observer,
                "127.0.0.1:0".parse().unwrap(),
            ))
        };
        let stream = open(Arc::clone(&observer)).expect("the stream opens");
        // An offer's key opens one stream.
        assert!(matches!(open(observer), Err(CmuxMobileError::InvalidArgument { .. })));
        // Signaling would carry the phone's candidate; on loopback its bound address is it.
        host.net.add_remote_candidate(Candidate { kind: CandidateKind::Host, addr: stream.local_addr });

        // hello names the desktop service and start asks for control.
        match host_control(&mut host, "hello") {
            Control::Hello { service, user, max_datagram, caps, .. } => {
                assert_eq!(
                    (service.as_str(), user.as_str(), max_datagram),
                    (SERVICE_DESKTOP, "phone-1", MAX_DATAGRAM)
                );
                assert!(caps.iter().any(|c| c == CAP_CLOCK));
            }
            other => panic!("expected hello, got {other:?}"),
        }
        match host_control(&mut host, "start") {
            Control::Start { mode, .. } => assert_eq!(mode, "control"),
            other => panic!("expected start, got {other:?}"),
        }
        let welcome = Control::Welcome {
            encoder: "fake".into(),
            width: 1280,
            height: 800,
            max_datagram: MAX_DATAGRAM,
            carrier: "link".into(),
            service: SERVICE_DESKTOP.into(),
            caps: Vec::new(),
        };
        host.net.send_control(serde_json::to_vec(&welcome).unwrap());

        // Three access units, the first a keyframe; the third spans several datagrams.
        let mut packetizer = Packetizer::new(0, MAX_DATAGRAM);
        let units: Vec<Vec<u8>> = vec![vec![0, 0, 0, 1, 0x65, 1], vec![0, 0, 0, 1, 0x41, 2], vec![7; 3000]];
        for (i, unit) in units.iter().enumerate() {
            let frame = i as u32 + 1;
            let body = FrameBody {
                t_capture_us: 1_000 * u64::from(frame),
                ref_frame: if frame == 1 { REF_NONE } else { frame - 1 },
                access_unit: unit.clone(),
            };
            let fl = if frame == 1 { flags::KEYFRAME } else { 0 };
            for datagram in packetizer.packetize(frame, fl, &body, 0).unwrap().datagrams {
                host.net.send_datagram(datagram);
            }
        }

        let (mut frames, mut messages, mut paths) = (Vec::new(), Vec::new(), Vec::new());
        let deadline = Instant::now() + Duration::from_secs(5);
        // welcome is a control record and the frames are datagrams: either may come first.
        while (frames.len() < 3 || messages.is_empty()) && Instant::now() < deadline {
            match seen.recv_timeout(Duration::from_millis(100)) {
                Ok(Seen::Frame(f)) => frames.push(f),
                Ok(Seen::Message(m)) => messages.push(m),
                Ok(Seen::Path(p)) => paths.push(p),
                // What Swift sends on the signaling socket: a candidate the host can read.
                Ok(Seen::Candidate(c)) => assert!(Candidate::from_wire(&c).is_some(), "{c}"),
                Err(_) => {}
                Ok(Seen::Closed(reason)) => panic!("closed early: {reason}"),
            }
        }
        let numbers: Vec<(u32, u64, bool)> =
            frames.iter().map(|f| (f.frame, f.capture_us, f.keyframe)).collect();
        assert_eq!(numbers, vec![(1, 1_000, true), (2, 2_000, false), (3, 3_000, false)]);
        let got: Vec<&Vec<u8>> = frames.iter().map(|f| &f.access_unit).collect();
        assert_eq!(got, units.iter().collect::<Vec<_>>());
        assert!(frames.iter().all(|f| f.stream == 0 && f.age_us.is_none()), "no clock cap, no age");
        let welcome: Value = serde_json::from_str(messages.first().expect("welcome reaches Swift")).unwrap();
        assert_eq!((welcome["t"].as_str(), welcome["width"].as_u64()), (Some("welcome"), Some(1280)));
        let stats = stream.stats();
        assert!(stats.connected);
        assert_eq!((stats.width, stats.height, stats.frames, stats.keyframes), (1280, 800, 3, 1));
        assert!(!paths.is_empty() || stats.path.is_some(), "the link reports its path");

        // Input crosses the link to the host's input path, in order.
        stream.send_input(r#"{"e":"pointer","x":10,"y":20}"#.into()).unwrap();
        stream.send_input(r#"{"e":"button","button":1,"down":true}"#.into()).unwrap();
        let (mut events, mut next_seq) = (Vec::new(), None::<u32>);
        while events.len() < 2 {
            let packet = host_input(&mut host);
            // Repeats until acknowledged: keep each sequence number once, in order.
            for (i, event) in packet.events.into_iter().enumerate() {
                let seq = packet.first_seq.wrapping_add(i as u32);
                if next_seq.is_none_or(|next| seq == next) {
                    events.push(event);
                    next_seq = Some(seq.wrapping_add(1));
                }
            }
        }
        assert_eq!(
            events,
            vec![InputEvent::Pointer { x: 10, y: 20 }, InputEvent::Button { button: 1, down: true }]
        );

        // Close sends stop and reports the app's close.
        stream.close();
        loop {
            match host_control(&mut host, "stop") {
                Control::Stop => break,
                _ => continue,
            }
        }
        let closed = loop {
            match seen.recv_timeout(Duration::from_secs(5)).expect("on_closed arrives") {
                Seen::Closed(reason) => break reason,
                _ => continue,
            }
        };
        assert_eq!(closed, CLOSED_BY_APP);
        assert!(matches!(
            stream.add_candidate("host 127.0.0.1:1".into()),
            Err(CmuxMobileError::Closed { .. })
        ));
    }
}
