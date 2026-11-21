//! A joined Mac's screen over the device hub's `cmux.rd/1` share: the phone's
//! side of what the Mac's own viewer runs through `cmux rd connect`
//! (cmux-tui/crates/cmux-rd-host/src/connect.rs). The share host (the Rust
//! `cmux-hub-host` session, or the Mac app's rd host) answers a `cmux.rd/1`
//! offer instead of a WebRTC SDP and streams one display over a
//! `cmux-rd-link` (Noise_XX bound to the hub session, UDP with STUN and TURN).
//!
//! Swift keeps the hub ticket and the Session DO socket (it signs the offer's
//! fingerprint with the device key); this crate makes the session key, writes
//! the offer (with the display the link names), reads the answer, runs the
//! link on its own thread, sends `hello` and `start` (`view` or `control`),
//! reassembles the video (`cmux-rd-ffi`: NACK, loss feedback, clock probes),
//! carries exactly-once input in a control session, and hands Swift whole
//! access units to decode with VideoToolbox.

use std::net::{SocketAddr, ToSocketAddrs};
use std::os::fd::RawFd;
use std::sync::mpsc;
use std::sync::{Arc, Mutex, PoisonError};
use std::thread;
use std::time::Instant;

use cmux_rd_ffi::{Carrier, InputChannel, Session};
use cmux_rd_link::net::{Candidate, Net, NetConfig, NetEvent, TurnServer};
use cmux_rd_link::{EndpointEvent, Event, KeyPair, Role};
use cmux_rd_proto::{Control, InputEvent, flags};
use serde_json::Value;

use crate::CmuxMobileError;
use crate::browser::{BrowserFrame, BrowserStats};

/// How long a frame may wait for missing shards, and when to NACK one.
const FRAME_DEADLINE_US: u64 = 500_000;
const NACK_AFTER_US: u64 = 50_000;
/// When an unacknowledged input event is sent again.
const INPUT_RESEND_US: u64 = 50_000;
/// The largest rd datagram this viewer takes inside a sealed link packet (the
/// Mac viewer's `maxDatagram`).
const MAX_DATAGRAM: usize = 1126;
/// Longest the loop sleeps without a deadline (a command wakes it sooner).
const IDLE_POLL_MS: i32 = 250;

pub const HEADER: &str = "cmux.rd/1";
const KEY_PREFIX: &str = "cmux-rd-key ";

/// One display of the host, as its answer lists it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MacScreenDisplay {
    pub width: u32,
    pub height: u32,
    /// The display's id on the host (`CGDirectDisplayID`), when the host names ids.
    pub id: Option<u32>,
}

/// What the host's answer says about its screen.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MacScreenAnswer {
    pub displays: Vec<MacScreenDisplay>,
    /// Index into `displays` of the one being streamed.
    pub current: Option<u32>,
}

/// One ICE server of the hub ticket (`{urls, username?, credential?}`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MacScreenIceServer {
    pub urls: Vec<String>,
    pub username: Option<String>,
    pub credential: Option<String>,
}

/// Receives a screen session's events on a library thread. Implementations
/// should hand off quickly (a decode queue, the main actor).
#[uniffi::export(with_foreign)]
pub trait MacScreenObserver: Send + Sync {
    /// A local route to send to the host as a signaling candidate (`sdpMid`
    /// `cmux-rd`), in the form `"<kind> <addr>"`.
    fn on_candidate(&self, candidate: String);
    /// The link's handshake finished.
    fn on_connected(&self);
    /// The current path changed: its wire kind (`direct_lan`, `turn_relay`, ...)
    /// and round trip.
    fn on_path(&self, kind: Option<String>, rtt_us: Option<u64>);
    fn on_frame(&self, frame: BrowserFrame);
    /// An rd control message from the host (`welcome`, `started`, `refused`,
    /// `ended`, `stats`, `cursor`, ...), JSON with `t`.
    fn on_message(&self, json: String);
    /// The session ended (`ended`, `refused`, `link_closed`, `link_failed`,
    /// `closed`), with the host's or the link's reason.
    fn on_closed(&self, code: String, reason: String);
}

enum Command {
    Candidate(String),
    Input(InputEvent),
    Keyframe,
    Decoded(u32),
    Close,
}

/// One screen session toward a share host.
#[derive(uniffi::Object)]
pub struct MacScreenRd {
    key: KeyPair,
    control: bool,
    commands: mpsc::Sender<Command>,
    receiver: Mutex<Option<mpsc::Receiver<Command>>>,
    wake: Arc<Pipe>,
    stats: Arc<Mutex<BrowserStats>>,
    epoch: Instant,
}

#[uniffi::export]
impl MacScreenRd {
    /// A session with a fresh session key. `control`: the ticket's scope
    /// allows input and the link asked for it; a view session sends none.
    #[uniffi::constructor]
    pub fn new(control: bool) -> Result<Arc<Self>, CmuxMobileError> {
        let key = KeyPair::generate()
            .map_err(|e| CmuxMobileError::Transport { message: format!("session key: {e:?}") })?;
        let wake =
            Pipe::new().map_err(|e| CmuxMobileError::Transport { message: format!("wake pipe: {e}") })?;
        let (commands, receiver) = mpsc::channel();
        Ok(Arc::new(Self {
            key,
            control,
            commands,
            receiver: Mutex::new(Some(receiver)),
            wake: Arc::new(wake),
            stats: Arc::new(Mutex::new(BrowserStats::default())),
            epoch: Instant::now(),
        }))
    }

    /// Whether this session asks the host for control.
    pub fn control(&self) -> bool {
        self.control
    }

    /// The offer document: this side's key, and the display, width and frame
    /// rate it wants. `display_id` (a `CGDirectDisplayID`) wins over
    /// `display` (an index) at a host that knows ids; an unknown id streams
    /// the main display.
    pub fn offer(
        &self,
        display: Option<i64>,
        display_id: Option<u32>,
        max_width: Option<u32>,
        max_fps: Option<u32>,
    ) -> String {
        let mut lines =
            vec![HEADER.to_owned(), format!("a=fingerprint:{KEY_PREFIX}{}", hex(&self.key.public))];
        if let Some(d) = display {
            lines.push(format!("a=cmux-rd-display:{d}"));
        }
        if let Some(id) = display_id {
            lines.push(format!("a=cmux-rd-display-id:{id}"));
        }
        if let Some(w) = max_width {
            lines.push(format!("a=cmux-rd-max-width:{w}"));
        }
        if let Some(f) = max_fps {
            lines.push(format!("a=cmux-rd-max-fps:{f}"));
        }
        lines.join("\r\n") + "\r\n"
    }

    /// Starts the link with the host's answer. `session_id` is the hub
    /// session (the Noise prologue); `ice` is the ticket's ICE servers.
    /// `relay_only` keeps this phone's addresses from the host.
    pub fn connect(
        &self,
        session_id: String,
        answer: String,
        ice: Vec<MacScreenIceServer>,
        relay_only: bool,
        observer: Arc<dyn MacScreenObserver>,
    ) -> Result<MacScreenAnswer, CmuxMobileError> {
        let doc = Document::parse(&answer).ok_or_else(|| CmuxMobileError::InvalidArgument {
            message: "the answer is not a cmux.rd/1 document".into(),
        })?;
        let remote = unhex32(&doc.key).ok_or_else(|| CmuxMobileError::InvalidArgument {
            message: "the answer's key is not 32 bytes of hex".into(),
        })?;
        let Some(commands) = self.receiver.lock().unwrap_or_else(PoisonError::into_inner).take() else {
            return Err(CmuxMobileError::InvalidArgument { message: "the session already connected".into() });
        };
        let summary = doc.summary();
        let (stun, turn) = servers(&ice);
        let run = Run {
            role_session: session_id.into_bytes(),
            local: self.key.clone(),
            remote,
            stun,
            turn,
            relay_only,
            candidates: doc.candidates,
            control: self.control,
            observer,
            commands,
            wake: Arc::clone(&self.wake),
            stats: Arc::clone(&self.stats),
            epoch: self.epoch,
        };
        thread::Builder::new()
            .name("cmux-mac-screen".into())
            .spawn(move || run.run())
            .map_err(|e| CmuxMobileError::Transport { message: format!("link thread: {e}") })?;
        Ok(summary)
    }

    /// A route the host sent later through signaling (`sdpMid` `cmux-rd`).
    pub fn add_remote_candidate(&self, candidate: String) {
        self.send(Command::Candidate(candidate));
    }

    /// Absolute pointer position in the stream's pixels (the welcome's size).
    pub fn pointer(&self, x: i32, y: i32) {
        self.input(InputEvent::Pointer { x, y });
    }

    /// 0 left, 1 right, 2 middle.
    pub fn button(&self, button: u8, down: bool) {
        self.input(InputEvent::Button { button, down });
    }

    /// Scroll in hundredths of a line, or of a point with `precise`.
    pub fn scroll(&self, dx: i32, dy: i32, precise: bool) {
        self.input(InputEvent::Scroll { dx, dy, precise });
    }

    /// A key by HID usage (page 7).
    pub fn key(&self, usage: u32, down: bool) {
        self.input(InputEvent::Key { usage, down });
    }

    pub fn text(&self, text: String) {
        self.input(InputEvent::Text(text));
    }

    /// Asks the host for a keyframe (the decoder lost its reference).
    pub fn request_keyframe(&self) {
        self.send(Command::Keyframe);
    }

    /// One frame's decode time, for the host's rate control.
    pub fn note_decode(&self, decode_us: u32) {
        self.send(Command::Decoded(decode_us));
    }

    pub fn stats(&self) -> BrowserStats {
        self.stats.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// Microseconds on the clock `BrowserFrame.received_us` uses.
    pub fn now_us(&self) -> u64 {
        u64::try_from(self.epoch.elapsed().as_micros()).unwrap_or(u64::MAX)
    }

    pub fn close(&self) {
        self.send(Command::Close);
    }
}

impl MacScreenRd {
    fn input(&self, event: InputEvent) {
        if self.control {
            self.send(Command::Input(event));
        }
    }

    fn send(&self, command: Command) {
        if self.commands.send(command).is_ok() {
            self.wake.wake();
        }
    }
}

impl Drop for MacScreenRd {
    fn drop(&mut self) {
        self.send(Command::Close);
    }
}

/// The parts of a `cmux.rd/1` answer this viewer reads.
#[derive(Debug, Clone, Default, PartialEq)]
struct Document {
    key: String,
    candidates: Vec<String>,
    displays: Vec<(u32, u32)>,
    display_ids: Vec<u32>,
    current: Option<u32>,
}

impl Document {
    fn parse(text: &str) -> Option<Self> {
        let mut lines = text.lines().map(str::trim);
        if lines.next()? != HEADER {
            return None;
        }
        let mut doc = Document::default();
        let mut key = None;
        for line in lines {
            let Some(rest) = line.strip_prefix("a=") else { continue };
            let Some((name, value)) = rest.split_once(':') else { continue };
            match name {
                "fingerprint" => key = value.strip_prefix(KEY_PREFIX).map(str::to_owned),
                "cmux-rd-candidate" => doc.candidates.push(value.to_owned()),
                "cmux-rd-current" => doc.current = value.parse().ok(),
                "cmux-rd-displays" => {
                    doc.displays = value
                        .split(',')
                        .filter_map(|s| {
                            let (w, h) = s.split_once('x')?;
                            Some((w.parse().ok()?, h.parse().ok()?))
                        })
                        .collect();
                }
                "cmux-rd-display-ids" => {
                    doc.display_ids = value.split(',').filter_map(|s| s.trim().parse().ok()).collect();
                }
                _ => {}
            }
        }
        let key = key?;
        if key.len() != 64 || !key.bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
        doc.key = key.to_ascii_lowercase();
        Some(doc)
    }

    fn summary(&self) -> MacScreenAnswer {
        // Ids name the displays in order only when the host listed one per display.
        let ids = (self.display_ids.len() == self.displays.len()).then_some(&self.display_ids);
        MacScreenAnswer {
            displays: self
                .displays
                .iter()
                .enumerate()
                .map(|(i, &(width, height))| MacScreenDisplay { width, height, id: ids.map(|ids| ids[i]) })
                .collect(),
            current: self.current,
        }
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex32(text: &str) -> Option<[u8; 32]> {
    if text.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(text.get(i * 2..i * 2 + 2)?, 16).ok()?;
    }
    Some(out)
}

/// A STUN server or a UDP TURN relay, as `host:port` before resolving.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Turn {
    addr: String,
    username: String,
    password: String,
}

/// The ticket's ICE servers as STUN addresses and UDP TURN relays (the Mac's
/// `MacScreenRdServers`, the hub host's `rd_doc::servers`; TCP TURN is not a
/// carrier of the link).
fn servers(ice: &[MacScreenIceServer]) -> (Vec<String>, Vec<Turn>) {
    let (mut stun, mut turn) = (Vec::new(), Vec::new());
    let address = |s: &str| {
        if s.is_empty() {
            String::new()
        } else if s.contains(':') {
            s.to_owned()
        } else {
            format!("{s}:3478")
        }
    };
    for server in ice {
        for url in &server.urls {
            let (base, query) = url.split_once('?').unwrap_or((url, ""));
            if let Some(host) = base.strip_prefix("stun:") {
                let a = address(host);
                if !a.is_empty() && !stun.contains(&a) {
                    stun.push(a);
                }
            } else if let Some(host) = base.strip_prefix("turn:") {
                let (Some(user), Some(pass)) = (&server.username, &server.credential) else { continue };
                if query.contains("transport=tcp") {
                    continue;
                }
                let relay = Turn { addr: address(host), username: user.clone(), password: pass.clone() };
                if !relay.addr.is_empty() && !turn.contains(&relay) {
                    turn.push(relay);
                }
            }
        }
    }
    (stun, turn)
}

/// The first IPv4 address of `host:port` (the link's socket is IPv4).
fn resolve(addr: &str) -> Option<SocketAddr> {
    addr.to_socket_addrs().ok()?.find(SocketAddr::is_ipv4)
}

/// The `hello` and `start` records this viewer opens a session with.
fn opening(control: bool, start_key: String) -> (Vec<u8>, Vec<u8>) {
    let hello = Control::Hello {
        // The hub's identity is the viewer; the host does not read these claims.
        user: "viewer".into(),
        install: "ios-screen".into(),
        class: "user".into(),
        interactive: true,
        udp_port: None,
        max_datagram: MAX_DATAGRAM,
        token: None,
        service: "desktop".into(),
        caps: Vec::new(),
    };
    let start = Control::Start { key: start_key, mode: if control { "control" } else { "view" }.into() };
    (serde_json::to_vec(&hello).unwrap_or_default(), serde_json::to_vec(&start).unwrap_or_default())
}

/// The link thread's state.
struct Run {
    role_session: Vec<u8>,
    local: KeyPair,
    remote: [u8; 32],
    stun: Vec<String>,
    turn: Vec<Turn>,
    relay_only: bool,
    candidates: Vec<String>,
    control: bool,
    observer: Arc<dyn MacScreenObserver>,
    commands: mpsc::Receiver<Command>,
    wake: Arc<Pipe>,
    stats: Arc<Mutex<BrowserStats>>,
    epoch: Instant,
}

impl Run {
    fn now(&self) -> u64 {
        u64::try_from(self.epoch.elapsed().as_micros()).unwrap_or(u64::MAX)
    }

    fn run(self) {
        let observer = Arc::clone(&self.observer);
        let (code, reason) = self.drive();
        observer.on_closed(code, reason);
    }

    fn drive(self) -> (String, String) {
        let stun: Vec<SocketAddr> = self.stun.iter().filter_map(|s| resolve(s)).collect();
        let turn: Vec<TurnServer> = self
            .turn
            .iter()
            .filter_map(|t| {
                Some(TurnServer {
                    addr: resolve(&t.addr)?,
                    username: t.username.clone(),
                    password: t.password.clone(),
                })
            })
            .collect();
        let net = match Net::start(NetConfig {
            role: Role::Initiator,
            session: self.role_session.clone(),
            local: self.local.clone(),
            expected_remote: self.remote,
            stun,
            bind: SocketAddr::from(([0, 0, 0, 0], 0)),
            turn,
            relay_only: self.relay_only,
        }) {
            Ok(net) => net,
            Err(e) => return ("link_failed".into(), format!("{e:?}")),
        };
        for candidate in &self.candidates {
            if let Some(c) = Candidate::from_wire(candidate) {
                net.add_remote_candidate(c);
            }
        }
        let mut viewer = Viewer {
            session: Session::new(Carrier::Datagram, FRAME_DEADLINE_US, NACK_AFTER_US),
            input: InputChannel::new(Carrier::Datagram, INPUT_RESEND_US),
            opened: false,
        };
        viewer.session.enable_clock();
        loop {
            let now = self.now();
            let due =
                viewer.session.next_deadline_us().min(viewer.input.next_deadline_us().unwrap_or(u64::MAX));
            let timeout = if due == u64::MAX {
                IDLE_POLL_MS
            } else {
                i32::try_from(due.saturating_sub(now).div_ceil(1000))
                    .unwrap_or(IDLE_POLL_MS)
                    .min(IDLE_POLL_MS)
            };
            let mut fds = [
                libc::pollfd { fd: net.event_fd(), events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: self.wake.read, events: libc::POLLIN, revents: 0 },
            ];
            // SAFETY: two valid pollfds we own.
            unsafe { libc::poll(fds.as_mut_ptr(), 2, timeout) };
            self.wake.drain();
            loop {
                match self.commands.try_recv() {
                    Ok(Command::Candidate(text)) => {
                        if let Some(c) = Candidate::from_wire(&text) {
                            net.add_remote_candidate(c);
                        }
                    }
                    Ok(Command::Input(event)) => {
                        if self.control {
                            viewer.input.push(event);
                        }
                    }
                    Ok(Command::Keyframe) => {
                        let _ = viewer.session.request_keyframe(0);
                    }
                    Ok(Command::Decoded(us)) => {
                        let _ = viewer.session.note_decode(0, us);
                    }
                    Ok(Command::Close) | Err(mpsc::TryRecvError::Disconnected) => {
                        return ("closed".into(), String::new());
                    }
                    Err(mpsc::TryRecvError::Empty) => break,
                }
            }
            let now = self.now();
            for event in net.events() {
                match event {
                    NetEvent::Candidate(c) => self.observer.on_candidate(c.to_wire()),
                    NetEvent::CandidatesDone | NetEvent::RelayFailed { .. } => {}
                    NetEvent::Failed(reason) => return ("link_failed".into(), reason),
                    NetEvent::Endpoint(EndpointEvent::PathChanged { kind, rtt_us, .. }) => {
                        self.observer.on_path(kind.map(|k| k.wire_name().to_owned()), rtt_us);
                    }
                    NetEvent::Endpoint(EndpointEvent::Link(link)) => match link {
                        Event::Established => {
                            if !viewer.opened {
                                viewer.opened = true;
                                let (hello, start) = opening(self.control, uuid::Uuid::new_v4().to_string());
                                net.send_control(hello);
                                net.send_control(start);
                            }
                            self.observer.on_connected();
                        }
                        Event::Datagram(bytes) => {
                            // An input ack is not video: the input channel takes it.
                            if viewer.input.on_ack(&bytes).is_err() {
                                let _ = viewer.session.push_datagram(&bytes, now);
                            }
                        }
                        Event::Control(record) => {
                            if let Some(end) = self.control_record(&record) {
                                return end;
                            }
                        }
                        Event::ProbeReply(_) => {}
                        Event::Closed => return ("link_closed".into(), "the host closed the link".into()),
                    },
                }
            }
            viewer.session.tick(now);
            self.drain(&mut viewer, now);
            while let Some(bytes) = viewer.session.feedback(now) {
                net.send_datagram(bytes);
            }
            while let Some(bytes) = viewer.input.packet(now) {
                net.send_datagram(bytes);
            }
        }
    }

    /// Hands a control record to Swift; `ended` and `refused` end the session.
    fn control_record(&self, record: &[u8]) -> Option<(String, String)> {
        let json: Value = serde_json::from_slice(record).ok()?;
        self.observer.on_message(json.to_string());
        match json.get("t").and_then(Value::as_str) {
            Some("ended") => Some(("ended".into(), text(&json, "reason"))),
            Some("refused") => {
                let reason = text(&json, "reason");
                Some(("refused".into(), if reason.is_empty() { text(&json, "code") } else { reason }))
            }
            _ => None,
        }
    }

    fn drain(&self, viewer: &mut Viewer, now: u64) {
        while viewer.session.pop_message().is_some() {}
        let clock = viewer.session.clock();
        while let Some((stream, complete)) = viewer.session.pop_frame() {
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
                stats.video_carrier = "rd-link".to_owned();
                if let Ok(s) = viewer.session.stats(stream) {
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

fn text(json: &Value, field: &str) -> String {
    json.get(field).and_then(Value::as_str).unwrap_or_default().to_owned()
}

struct Viewer {
    session: Session,
    input: InputChannel,
    opened: bool,
}

/// A non-blocking pipe used as a wake-up: a byte means "look at the queue".
struct Pipe {
    read: RawFd,
    write: RawFd,
}

impl Pipe {
    fn new() -> std::io::Result<Self> {
        let mut fds = [0; 2];
        // SAFETY: pipe(2) fills the two-element array we own.
        if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        for fd in fds {
            // SAFETY: fcntl on descriptors we just created.
            unsafe {
                libc::fcntl(fd, libc::F_SETFL, libc::fcntl(fd, libc::F_GETFL) | libc::O_NONBLOCK);
                libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
            }
        }
        Ok(Self { read: fds[0], write: fds[1] })
    }

    fn wake(&self) {
        // SAFETY: one byte from a local to our write end; a full pipe already holds a wake-up.
        unsafe { libc::write(self.write, [1u8].as_ptr().cast(), 1) };
    }

    fn drain(&self) {
        let mut scratch = [0u8; 64];
        // SAFETY: reads into a local buffer from our non-blocking read end.
        while unsafe { libc::read(self.read, scratch.as_mut_ptr().cast(), scratch.len()) } > 0 {}
    }
}

impl Drop for Pipe {
    fn drop(&mut self) {
        // SAFETY: closing the two descriptors this value owns, once.
        unsafe {
            libc::close(self.read);
            libc::close(self.write);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &str = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

    #[test]
    fn the_offer_names_the_display_id_and_the_key() {
        let rd = MacScreenRd::new(false).unwrap();
        let offer = rd.offer(None, Some(17), Some(1920), Some(60));
        assert!(offer.starts_with("cmux.rd/1\r\na=fingerprint:cmux-rd-key "));
        assert!(offer.contains("\r\na=cmux-rd-display-id:17\r\n"));
        assert!(offer.contains("\r\na=cmux-rd-max-width:1920\r\n"));
        assert!(offer.ends_with("a=cmux-rd-max-fps:60\r\n"));
        assert!(!offer.contains("a=cmux-rd-display:"));
        let doc = Document::parse(&offer).unwrap();
        assert_eq!(doc.key, hex(&rd.key.public));
        assert_eq!(unhex32(&doc.key), Some(rd.key.public));
    }

    #[test]
    fn answers_list_displays_with_their_ids() {
        let text = format!(
            "cmux.rd/1\r\na=fingerprint:cmux-rd-key {KEY}\r\na=cmux-rd-candidate:host 10.0.0.2:5000\r\n\
             a=cmux-rd-displays:2560x1440,1920x1080\r\na=cmux-rd-display-ids:1,17\r\na=cmux-rd-current:1\r\n"
        );
        let doc = Document::parse(&text).unwrap();
        assert_eq!(doc.candidates, vec!["host 10.0.0.2:5000"]);
        assert_eq!(
            doc.summary(),
            MacScreenAnswer {
                displays: vec![
                    MacScreenDisplay { width: 2560, height: 1440, id: Some(1) },
                    MacScreenDisplay { width: 1920, height: 1080, id: Some(17) },
                ],
                current: Some(1),
            }
        );
        // A host without ids (or with a list that does not match) names none.
        let old = text.replace("a=cmux-rd-display-ids:1,17\r\n", "");
        assert!(Document::parse(&old).unwrap().summary().displays.iter().all(|d| d.id.is_none()));
    }

    #[test]
    fn webrtc_answers_and_bad_keys_are_refused() {
        assert!(Document::parse("v=0\r\na=fingerprint:sha-256 AB:CD\r\n").is_none());
        assert!(Document::parse("cmux.rd/1\r\na=fingerprint:cmux-rd-key 1234\r\n").is_none());
        assert!(unhex32("zz112233445566778899aabbccddeeff00112233445566778899aabbccddeeff").is_none());
    }

    #[test]
    fn hello_and_start_are_rd_control_records() {
        let (hello, start) = opening(false, "k".into());
        match serde_json::from_slice::<Control>(&hello).unwrap() {
            Control::Hello { max_datagram, interactive, service, .. } => {
                assert_eq!(max_datagram, MAX_DATAGRAM);
                assert!(interactive);
                assert_eq!(service, "desktop");
            }
            other => panic!("not a hello: {other:?}"),
        }
        assert!(matches!(serde_json::from_slice::<Control>(&start).unwrap(),
            Control::Start { mode, .. } if mode == "view"));
        let (_, start) = opening(true, "k".into());
        assert!(matches!(serde_json::from_slice::<Control>(&start).unwrap(),
            Control::Start { mode, .. } if mode == "control"));
    }

    #[test]
    fn ice_servers_become_stun_and_udp_turn() {
        let ice = vec![
            MacScreenIceServer {
                urls: vec![
                    "stun:stun.example".into(),
                    "turn:turn.example:3478?transport=udp".into(),
                    "turn:turn.example:443?transport=tcp".into(),
                ],
                username: Some("u".into()),
                credential: Some("p".into()),
            },
            MacScreenIceServer {
                urls: vec!["stun:stun.example:3478".into()],
                username: None,
                credential: None,
            },
        ];
        let (stun, turn) = servers(&ice);
        assert_eq!(stun, vec!["stun.example:3478"]);
        assert_eq!(
            turn,
            vec![Turn { addr: "turn.example:3478".into(), username: "u".into(), password: "p".into() }]
        );
    }
}
