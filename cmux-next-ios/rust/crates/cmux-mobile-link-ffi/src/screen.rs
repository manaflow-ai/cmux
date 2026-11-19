//! Screen Sharing on cmux.rd/1 (docs/device-hub/PROTOCOL.md, Session flow): the iPhone as the
//! viewer of any Mac or Linux host, the protocol the Mac's own viewer speaks. Every host
//! serves it: the Mac app (`MacScreenRdHost`), a joined Mac's daemon and a Linux desktop
//! (`cmux-hub-host`), which serve no WebRTC viewer.
//!
//! The shared parts, nothing written twice:
//! - the offer and answer documents and the ticket's ICE servers: `cmux_rd_proto::offer`
//!   (the Linux host and viewer read the same code);
//! - the secure link (Noise, sealed datagrams, the ordered control channel, STUN, TURN):
//!   `cmux_rd_link::net`, the one `cmux-rd connect` holds for the Mac's viewer;
//! - reassembly, NACK and loss feedback, clock probes and exactly-once input:
//!   `cmux_rd_ffi::{Session, InputChannel}`, the core the Mac's `RemoteRdCore` wraps.
//!
//! Swift keeps the hub (request, approval, the ticket's signed signaling socket) and the
//! picture (VideoToolbox decode, the layer, touches). This object holds the session key from
//! before the offer, then runs the link on its own thread from the answer on: hello and start
//! once the link is up, whole access units to the observer, input from the person to the host.

use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::sync::mpsc;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Instant;

use cmux_rd_ffi::{Carrier, InputChannel, Session};
use cmux_rd_link::net::{Candidate, Net, NetConfig, NetEvent, TurnServer};
use cmux_rd_link::{EndpointEvent, Event, KeyPair, Role};
use cmux_rd_proto::control::Control;
use cmux_rd_proto::offer::{RdDocument, servers};
use cmux_rd_proto::{InputEvent, MAX_DATAGRAM_VPC, SERVICE_DESKTOP, flags};

use crate::CmuxMobileError;
use crate::browser::BrowserFrame;

/// How long a frame may wait for missing shards, and when to NACK one (the Mac pane's values).
const FRAME_DEADLINE_US: u64 = 200_000;
const NACK_AFTER_US: u64 = 30_000;
/// When an unacknowledged input event is sent again.
const INPUT_RESEND_US: u64 = 20_000;
/// The longest the link thread sleeps: clock probes, stats and the keepalive feedback.
const MAX_SLEEP_US: u64 = 50_000;
/// The clock cap (rd change C8): every frame gets its age, the latency the overlay shows.
const CAP_CLOCK: &str = "clock";

/// Hears one screen session, on the link thread. Hand off quickly.
#[uniffi::export(with_foreign)]
pub trait ScreenObserver: Send + Sync {
    /// A whole H.264 Annex-B access unit (SPS and PPS before each IDR).
    fn on_frame(&self, frame: BrowserFrame);
    /// A local route for the host, to send on the session's signaling (`sdpMid` `cmux-rd`).
    fn on_candidate(&self, candidate: String);
    /// The link came up (`connected`), or its path changed: `{"t":"path","kind":..,"rtt_ms":..}`,
    /// or an rd control message of the host (`welcome`, `started`, `refused`, `ended`) as JSON.
    fn on_message(&self, json: String);
    /// The session is over: `reason` is the host's own `ended` (`host: <reason>`), the link's
    /// failure (`link failed: <why>`), or this side's close.
    fn on_closed(&self, reason: String);
}

/// The answer's routes and the ticket's servers, everything the link needs to start.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ScreenAnswer {
    /// The hub session id (the link's Noise prologue).
    pub session: String,
    /// The host's answer as it came on the signaling (checked as signed by the host's device key
    /// before it gets here).
    pub answer: String,
    /// The ticket's ICE servers as JSON (`[{urls, username?, credential?}]`).
    pub ice_json: String,
    /// Full Control (input) or View Only.
    pub control: bool,
    /// Reach the host through TURN relays only.
    pub relay_only: bool,
}

/// The host's displays as its answer listed them.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ScreenDisplay {
    pub width: u32,
    pub height: u32,
}

/// Counters for the overlay and the latency harness.
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct ScreenStats {
    pub frames: u64,
    pub keyframes: u64,
    pub bytes: u64,
    pub frames_lost: u64,
    /// From `start` to the first whole frame (microseconds), once one came.
    pub first_frame_us: Option<u64>,
    /// From `start` to the link's handshake.
    pub connected_us: Option<u64>,
    pub clock_offset_us: Option<i64>,
    pub clock_rtt_us: Option<u32>,
    /// The path the link rides (`direct_lan`, `direct_wan`, `turn_relay`, ...).
    pub path: Option<String>,
    pub path_rtt_us: Option<u64>,
}

enum Command {
    Candidate(String),
    Input(InputEvent),
    Keyframe,
    Decoded(u32),
    Close,
}

/// One screen session from this phone. Make it when the ticket comes, offer its key, then
/// `start` with the host's answer. Dropping it closes the link.
#[derive(uniffi::Object)]
pub struct ScreenLink {
    keys: Mutex<Option<KeyPair>>,
    key: String,
    commands: Mutex<Option<(mpsc::Sender<Command>, UnixStream)>>,
    stats: Arc<Mutex<ScreenStats>>,
    epoch: Instant,
}

#[uniffi::export]
impl ScreenLink {
    /// A new session key for one session.
    #[uniffi::constructor]
    pub fn new() -> Result<Arc<Self>, CmuxMobileError> {
        let keys = KeyPair::generate().map_err(|e| CmuxMobileError::Transport { message: e.to_string() })?;
        let key = hex(&keys.public);
        Ok(Arc::new(Self {
            keys: Mutex::new(Some(keys)),
            key,
            commands: Mutex::new(None),
            stats: Arc::new(Mutex::new(ScreenStats::default())),
            epoch: Instant::now(),
        }))
    }

    /// This side's session key (64 hex), the offer's fingerprint.
    pub fn session_key(&self) -> String {
        self.key.clone()
    }

    /// The offer to send on the session's signaling: this side's key and the viewer's wishes.
    pub fn offer(&self, display: Option<i64>, max_width: Option<u32>, max_fps: Option<u32>) -> String {
        RdDocument { key: self.key.clone(), display, max_width, max_fps, ..RdDocument::default() }.text()
    }

    /// Starts the link with the host's answer. A second call is refused.
    pub fn start(
        &self,
        answer: ScreenAnswer,
        observer: Arc<dyn ScreenObserver>,
    ) -> Result<Vec<ScreenDisplay>, CmuxMobileError> {
        let doc = RdDocument::parse(&answer.answer).ok_or_else(|| CmuxMobileError::InvalidArgument {
            message: "the host's answer is not a cmux.rd/1 document".into(),
        })?;
        let peer = unhex32(&doc.key).ok_or_else(|| CmuxMobileError::InvalidArgument {
            message: "the host's key is not 64 hex".into(),
        })?;
        let keys = self.keys.lock().unwrap_or_else(PoisonError::into_inner).take().ok_or_else(|| {
            CmuxMobileError::InvalidArgument { message: "this session already started".into() }
        })?;
        let ice: serde_json::Value =
            serde_json::from_str(&answer.ice_json).unwrap_or(serde_json::Value::Null);
        let (stun, turn) = servers(&ice);
        let net = Net::start(NetConfig {
            role: Role::Initiator,
            session: answer.session.clone().into_bytes(),
            local: keys,
            expected_remote: peer,
            stun: stun.iter().filter_map(|s| resolve(s)).collect(),
            bind: std::net::SocketAddr::from(([0, 0, 0, 0], 0)),
            turn: turn
                .iter()
                .filter_map(|t| {
                    Some(TurnServer {
                        addr: resolve(&t.addr)?,
                        username: t.username.clone(),
                        password: t.password.clone(),
                    })
                })
                .collect(),
            relay_only: answer.relay_only,
        })
        .map_err(|e| CmuxMobileError::Transport { message: e.to_string() })?;
        for candidate in doc.candidates.iter().filter_map(|c| Candidate::from_wire(c)) {
            net.add_remote_candidate(candidate);
        }
        let (wake_tx, wake_rx) =
            UnixStream::pair().map_err(|e| CmuxMobileError::Transport { message: e.to_string() })?;
        let _ = wake_rx.set_nonblocking(true);
        let _ = wake_tx.set_nonblocking(true);
        let (tx, rx) = mpsc::channel();
        *self.commands.lock().unwrap_or_else(PoisonError::into_inner) = Some((tx, wake_tx));
        let viewer = Viewer {
            net,
            session: Session::new(Carrier::Datagram, FRAME_DEADLINE_US, NACK_AFTER_US),
            input: InputChannel::new(Carrier::Datagram, INPUT_RESEND_US),
            control: answer.control,
            input_granted: false,
            observer,
            stats: Arc::clone(&self.stats),
            epoch: self.epoch,
            started_us: u64::try_from(self.epoch.elapsed().as_micros()).unwrap_or(0),
            host_said: None,
        };
        std::thread::Builder::new()
            .name("cmux-screen-link".into())
            .spawn(move || viewer.run(&rx, &wake_rx))
            .map_err(|e| CmuxMobileError::Transport { message: e.to_string() })?;
        Ok(doc.displays.iter().map(|(w, h)| ScreenDisplay { width: *w, height: *h }).collect())
    }

    /// A route the host trickled on the signaling after its answer.
    pub fn add_candidate(&self, candidate: String) {
        self.send(Command::Candidate(candidate));
    }

    /// The pointer at `(x, y)` in the stream's pixels (welcome's `width` by `height`).
    pub fn pointer(&self, x: i32, y: i32) {
        self.send(Command::Input(InputEvent::Pointer { x, y }));
    }

    /// Button 1 left, 2 middle, 3 right (`RemoteMouseButton`).
    pub fn button(&self, button: u8, down: bool) {
        self.send(Command::Input(InputEvent::Button { button, down }));
    }

    /// Scroll in hundredths of a line, or of a point when `precise`.
    pub fn scroll(&self, dx: i32, dy: i32, precise: bool) {
        self.send(Command::Input(InputEvent::Scroll { dx, dy, precise }));
    }

    /// A USB HID usage (page 7) pressed or released.
    pub fn key_event(&self, usage: u32, down: bool) {
        self.send(Command::Input(InputEvent::Key { usage, down }));
    }

    /// Text the host types as is.
    pub fn text(&self, text: String) {
        if text.len() <= cmux_rd_proto::MAX_TEXT_BYTES {
            self.send(Command::Input(InputEvent::Text(text)));
        }
    }

    /// The decoder lost its state: ask the host for a keyframe.
    pub fn request_keyframe(&self) {
        self.send(Command::Keyframe);
    }

    /// How long the last frame took to decode (feeds the host's rate control).
    pub fn note_decode(&self, decode_us: u32) {
        self.send(Command::Decoded(decode_us));
    }

    pub fn stats(&self) -> ScreenStats {
        self.stats.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// Microseconds on the clock `BrowserFrame.received_us` uses.
    pub fn now_us(&self) -> u64 {
        u64::try_from(self.epoch.elapsed().as_micros()).unwrap_or(u64::MAX)
    }

    /// Ends the session (the host hears `stop`, then the link closes).
    pub fn close(&self) {
        self.send(Command::Close);
    }
}

impl ScreenLink {
    fn send(&self, command: Command) {
        if let Some((tx, wake)) = self.commands.lock().unwrap_or_else(PoisonError::into_inner).as_mut()
            && tx.send(command).is_ok()
        {
            let _ = wake.write(&[1]);
        }
    }
}

impl Drop for ScreenLink {
    fn drop(&mut self) {
        self.send(Command::Close);
    }
}

struct Viewer {
    net: Net,
    session: Session,
    input: InputChannel,
    control: bool,
    input_granted: bool,
    observer: Arc<dyn ScreenObserver>,
    stats: Arc<Mutex<ScreenStats>>,
    epoch: Instant,
    started_us: u64,
    /// The host's `ended` reason, once it said one (the link closes right after).
    host_said: Option<String>,
}

impl Viewer {
    fn now(&self) -> u64 {
        u64::try_from(self.epoch.elapsed().as_micros()).unwrap_or(u64::MAX)
    }

    fn run(mut self, commands: &mpsc::Receiver<Command>, wake: &UnixStream) {
        let reason = loop {
            let now = self.now();
            let deadline = self
                .session
                .next_deadline_us()
                .min(self.input.next_deadline_us().unwrap_or(u64::MAX))
                .min(now + MAX_SLEEP_US);
            wait(&[self.net.event_fd(), wake.as_raw_fd()], deadline.saturating_sub(now));
            let mut drained = [0u8; 64];
            while matches!((&*wake).read(&mut drained), Ok(n) if n > 0) {}
            if let Some(reason) = self.commands(commands) {
                break reason;
            }
            if let Some(reason) = self.net_events() {
                break reason;
            }
            let now = self.now();
            self.session.tick(now);
            self.drain(now);
            while let Some(bytes) = self.session.feedback(now) {
                self.net.send_datagram(bytes);
            }
            while let Some(bytes) = self.input.packet(now) {
                self.net.send_datagram(bytes);
            }
        };
        self.observer.on_closed(reason);
    }

    fn commands(&mut self, commands: &mpsc::Receiver<Command>) -> Option<String> {
        loop {
            match commands.try_recv() {
                Ok(Command::Candidate(text)) => {
                    if let Some(c) = Candidate::from_wire(&text) {
                        self.net.add_remote_candidate(c);
                    }
                }
                Ok(Command::Input(event)) => {
                    if self.input_granted {
                        self.input.push(event);
                    }
                }
                Ok(Command::Keyframe) => {
                    let _ = self.session.request_keyframe(0);
                }
                Ok(Command::Decoded(us)) => {
                    let _ = self.session.note_decode(0, us);
                }
                Ok(Command::Close) | Err(mpsc::TryRecvError::Disconnected) => {
                    self.send_control(&Control::Stop);
                    return Some("stopped by the viewer".into());
                }
                Err(mpsc::TryRecvError::Empty) => return None,
            }
        }
    }

    fn net_events(&mut self) -> Option<String> {
        for event in self.net.events() {
            match event {
                NetEvent::Candidate(c) => self.observer.on_candidate(c.to_wire()),
                NetEvent::Endpoint(EndpointEvent::Link(Event::Established)) => {
                    let at = self.now().saturating_sub(self.started_us);
                    self.stats.lock().unwrap_or_else(PoisonError::into_inner).connected_us.get_or_insert(at);
                    self.start_session();
                    self.observer.on_message(r#"{"t":"connected"}"#.into());
                }
                NetEvent::Endpoint(EndpointEvent::PathChanged { kind, rtt_us, .. }) => {
                    let kind = kind.map(|k| k.wire_name().to_owned());
                    {
                        let mut stats = self.stats.lock().unwrap_or_else(PoisonError::into_inner);
                        stats.path.clone_from(&kind);
                        stats.path_rtt_us = rtt_us;
                    }
                    let message = serde_json::json!({
                        "t": "path", "kind": kind, "rtt_ms": rtt_us.map(|us| us as f64 / 1000.0),
                    });
                    self.observer.on_message(message.to_string());
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Control(record))) => self.on_control(&record),
                NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(datagram))) => {
                    let now = self.now();
                    let _ = self.session.push_datagram(&datagram, now);
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Closed)) => {
                    return Some(ended(self.host_said.as_deref(), None));
                }
                NetEvent::Failed(why) => return Some(ended(self.host_said.as_deref(), Some(&why))),
                _ => {}
            }
        }
        None
    }

    /// `hello` and `start` once the link is up: the desktop service, Full Control or View Only.
    fn start_session(&mut self) {
        // The hello's viewer claims; the link already authenticated this device's session key.
        let viewer = format!("ios-{:x}", std::process::id());
        self.send_control(&Control::Hello {
            user: viewer.clone(),
            install: viewer,
            class: "user".into(),
            interactive: true,
            udp_port: None,
            max_datagram: MAX_DATAGRAM_VPC,
            token: None,
            service: SERVICE_DESKTOP.into(),
            caps: vec![CAP_CLOCK.into()],
        });
        self.send_control(&Control::Start {
            key: format!("ios-{}", self.now()),
            mode: if self.control { "control" } else { "view" }.into(),
        });
    }

    fn send_control(&self, control: &Control) {
        if let Ok(bytes) = serde_json::to_vec(control) {
            self.net.send_control(bytes);
        }
    }

    fn on_control(&mut self, record: &[u8]) {
        match serde_json::from_slice::<Control>(record) {
            Ok(Control::Welcome { caps, .. }) if caps.iter().any(|c| c == CAP_CLOCK) => {
                self.session.enable_clock();
            }
            Ok(Control::Started { .. }) => self.input_granted = self.control,
            Ok(Control::Ended { reason }) | Ok(Control::Refused { reason }) => self.host_said = Some(reason),
            _ => {}
        }
        if let Ok(text) = std::str::from_utf8(record) {
            self.observer.on_message(text.to_owned());
        }
    }

    fn drain(&mut self, now: u64) {
        while let Some(message) = self.session.pop_message() {
            let _ = self.input.on_ack(&message.bytes);
        }
        let clock = self.session.clock();
        while let Some((stream, complete)) = self.session.pop_frame() {
            if stream != 0 {
                continue;
            }
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
                stats.first_frame_us.get_or_insert(now.saturating_sub(self.started_us));
                if let Ok(s) = self.session.stats(0) {
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

/// Why the session ended: the host's own reason when it said one, else what this side saw.
fn ended(host_said: Option<&str>, link_failed: Option<&str>) -> String {
    match (host_said, link_failed) {
        (Some(reason), _) => format!("host: {reason}"),
        (None, Some(why)) => format!("link failed: {why}"),
        (None, None) => "the host ended the session".into(),
    }
}

/// Waits until one of `fds` is readable or `timeout_us` passes.
fn wait(fds: &[i32], timeout_us: u64) {
    let mut polls: Vec<libc::pollfd> =
        fds.iter().map(|fd| libc::pollfd { fd: *fd, events: libc::POLLIN, revents: 0 }).collect();
    let ms = i32::try_from(timeout_us.div_ceil(1000)).unwrap_or(i32::MAX);
    // SAFETY: `polls` is a live, correctly sized array of pollfd for the call's duration.
    unsafe {
        libc::poll(polls.as_mut_ptr(), polls.len() as libc::nfds_t, ms);
    }
}

fn resolve(address: &str) -> Option<std::net::SocketAddr> {
    std::net::ToSocketAddrs::to_socket_addrs(address).ok()?.find(std::net::SocketAddr::is_ipv4)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex32(text: &str) -> Option<[u8; 32]> {
    let text = text.trim();
    if text.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(text.get(2 * i..2 * i + 2)?, 16).ok()?;
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_offer_carries_this_sides_key_and_wishes() {
        let link = ScreenLink::new().unwrap();
        let offer = RdDocument::parse(&link.offer(Some(0), Some(1170), Some(60))).unwrap();
        assert_eq!(offer.key, link.session_key());
        assert_eq!((offer.display, offer.max_width, offer.max_fps), (Some(0), Some(1170), Some(60)));
        assert_eq!(unhex32(&link.session_key()).map(|k| hex(&k)), Some(link.session_key()));
    }

    #[test]
    fn the_hosts_own_reason_wins_over_the_close() {
        assert_eq!(ended(Some("failed: capture"), Some("timeout")), "host: failed: capture");
        assert_eq!(ended(None, Some("timeout")), "link failed: timeout");
        assert_eq!(ended(None, None), "the host ended the session");
    }
}
