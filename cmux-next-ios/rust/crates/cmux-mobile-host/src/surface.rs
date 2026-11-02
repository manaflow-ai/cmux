//! `surface`: a streamed simulator surface (a Mac phone tab showing a booted
//! iOS simulator; cmux-next-ios/verify/simulator-surface.md).
//!
//! The phone opens `surface {tab, video?, video_tag?}` with the phone tab's
//! key (`s<surface>`). The stream is the same as a browser tab's: the
//! `cmux.rd/1` stream carrier of a `cmux.rb/1`-shaped session on the
//! channel, and the main stream's video on the link's media lane when the
//! phone asks for `video: "track"`. It goes through the browser service's
//! splice ([`crate::browser::splice`]): the same lane ownership (the tab
//! shown last owns the lane, `rb.visibility` true takes it back), the same
//! `video_tag`, keyframe switching, host limit and eviction.
//!
//! What differs is the host. A browser tab's host is a CEF process; a
//! surface's host runs inside hostd ([`host_session`]): the shared rd media
//! engine (`cmux-rd-engine`: frame gate, congestion control, packetizing,
//! FEC, recovery, exactly-once input) fed by the Mac app's frame source. The
//! app captures the simulator's own framebuffer (SimulatorKit's IOSurface,
//! never the screen), encodes H.264 with VideoToolbox when the engine asks,
//! and drives the simulator with the touches and keys hostd hands it. The
//! app's source speaks `sf/1` on loopback ([`SourceFrame`]).
//!
//! Trust is the browser tab's: only a paired phone of this Mac's owner gets a
//! channel at all (`services.rs`), and only a tab this Mac's daemon lists as
//! a phone page tab streams ([`SurfaceTabs`]); the app checks the tab again
//! before it starts a source. The phone's frames pass [`filter_frame`]: rd
//! datagrams (input, feedback, clock probes), `stop`, and only the rb
//! messages a surface viewer sends. The phone's input reaches the simulator
//! only as touches at 0...1 of its screen, text, a short list of keys and the
//! Home and Lock buttons ([`input_line`]).
//!
//! A Cloud desktop tab (`c~<machine_id>~<team_id>`, [`cloud_desktop_of`]) streams the
//! owner's own cmux Cloud machine screen through the same host, view only. hostd
//! serves it only when the app's current Cloud links list exactly one owned link
//! for that machine and team, and the machine is running ([`cloud_desktop_access`]);
//! its host forwards no phone input to the source and offers the phone no input cap.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use cmux_mobile_link::link::{ChannelReceiver, ChannelSender};
use cmux_rd_core::flow::Rect;
use cmux_rd_engine::{EncodeRequest, Encoded, EngineConfig, MediaEngine, Output};
use cmux_rd_proto::control::Control;
use cmux_rd_proto::{
    InputEvent, MAX_DATAGRAM_DEFAULT, SERVICE_REMOTE_BROWSER, STREAM_CONTROL, STREAM_DATAGRAM,
    StreamDeframer, encode_stream_frame,
};
use futures_util::future::BoxFuture;
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use crate::browser::{BrowserConfig, FrameVerdict, HostGuard, LaunchRequest, Launcher, RunningHost};
use crate::control::{CloudLink, request_cloud_links};
use crate::services::{Peer, Refusal, owned_cloud_link, valid_cloud_id};

/// rb messages a surface viewer may send. A surface has no page: no
/// navigation, history, menus, dialogs or find.
const VIEWER_MESSAGES: &[&str] = &["rb.open", "rb.close", "rb.visibility", "rb.screen", "rb.vsync"];
/// The surface's frame rate cap (the browser host's is 60 too).
const MAX_FPS: u32 = 60;
/// How long the phone's splice has to send the rd hello.
const HELLO_TIMEOUT: Duration = Duration::from_secs(3);
/// How long the app's source has to say its size.
const SOURCE_TIMEOUT: Duration = Duration::from_secs(10);
/// The largest `sf/1` frame either side sends (one 4K IDR fits easily).
pub const MAX_SOURCE_FRAME: usize = 8 * 1024 * 1024;
/// The longest text one input event types.
const MAX_TEXT_BYTES: usize = 4096;
/// Keys a phone may press on a simulator (DOM `code` names; the app maps
/// them to HID usages). Letters and symbols arrive as text.
const KEYS: &[&str] =
    &["Backspace", "Enter", "Tab", "Escape", "Delete", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"];
/// Hardware buttons a phone may press on a simulator.
const BUTTONS: &[&str] = &["home", "lock"];

/// The `surface` service's configuration: its hosts (one per tab, at most
/// `max_tabs`) live in a [`BrowserConfig`] of their own, so a surface and a
/// browser tab never evict each other's host, and they share the lane.
#[derive(Clone, Debug, Default)]
pub struct SurfaceConfig {
    hosts: BrowserConfig,
    /// Whether the app's source streams simulator phone tabs too (SimulatorKit loads); without
    /// it the source serves only Cloud desktops.
    no_simulators: bool,
}

impl SurfaceConfig {
    /// `source` starts the app's frame source for a tab (supervised: the
    /// app answers `need_surface`); None refuses every open.
    pub fn new(source: Option<Launcher>, max_tabs: usize) -> Self {
        Self { hosts: BrowserConfig::new(source.map(host_launcher), max_tabs), no_simulators: false }
    }

    /// The same source, but one that streams no simulator tabs (`CMUX_MOBILE_SURFACE_SIMULATORS=0`:
    /// SimulatorKit does not load); it still streams Cloud desktops.
    pub fn without_simulators(mut self) -> Self {
        self.no_simulators = true;
        self
    }

    /// Whether the app has a surface source at all (Cloud desktops, `cloud-desktop-v1`).
    pub fn available(&self) -> bool {
        self.hosts.available()
    }

    /// Whether this Mac streams simulator surfaces (`surface-stream-v1`).
    pub fn streams_simulators(&self) -> bool {
        self.available() && !self.no_simulators
    }

    /// Tabs with a running host (tests and diagnostics).
    pub async fn running_tabs(&self) -> Vec<String> {
        self.hosts.running_tabs().await
    }
}

/// Answers whether a tab key is a phone tab this Mac shows now.
pub trait SurfaceTabs: Send + Sync {
    /// Whether daemon surface `surface` is a phone page tab in one of this
    /// Mac's open workspaces.
    fn is_phone_tab(&self, surface: u64) -> BoxFuture<'_, bool>;
}

/// The daemon surface of a tab key `s<surface>`.
pub fn surface_of(tab: &str) -> Option<u64> {
    let digits = tab.strip_prefix('s')?;
    if digits.is_empty() || digits.len() > 19 || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    digits.parse().ok()
}

/// The Cloud machine and team of a Cloud desktop tab key `c~<machine_id>~<team_id>`.
/// Each id passes the `cloud-acpmux` id rules, which never allow `~`.
pub fn cloud_desktop_of(tab: &str) -> Option<(&str, &str)> {
    let (machine, team) = tab.strip_prefix("c~")?.split_once('~')?;
    (valid_cloud_id(machine) && valid_cloud_id(team)).then_some((machine, team))
}

/// Whether the phone may watch Cloud machine `machine_id` of `team_id` now: the
/// app lists exactly one owned link for it (else `forbidden`), and it is running
/// (else `asleep`).
pub fn cloud_desktop_access(links: Vec<CloudLink>, machine_id: &str, team_id: &str) -> Result<(), Refusal> {
    let link = owned_cloud_link(links, machine_id, team_id)?;
    if link.status != "running" {
        return Err(Refusal::new("asleep", "the Cloud machine is not running"));
    }
    Ok(())
}

/// Whether a `list-workspaces` reply lists daemon surface `surface` as a phone
/// page tab (`kind: conversation`, `conversation.page: "phone"`).
pub fn phone_tab_in(reply: &Value, surface: u64) -> bool {
    let data = reply.get("data").unwrap_or(reply);
    let list =
        |value: &Value, key: &str| value.get(key).and_then(Value::as_array).cloned().unwrap_or_default();
    list(data, "workspaces").iter().any(|workspace| {
        list(workspace, "screens").iter().any(|screen| {
            list(screen, "panes").iter().any(|pane| {
                list(pane, "tabs").iter().any(|tab| {
                    tab.get("surface").and_then(Value::as_u64) == Some(surface)
                        && tab.get("kind").and_then(Value::as_str) == Some("conversation")
                        && tab.pointer("/conversation/page").and_then(Value::as_str) == Some("phone")
                })
            })
        })
    })
}

/// Checks one stream frame the phone sent toward a surface's host.
pub fn filter_frame(kind: u8, payload: &[u8]) -> FrameVerdict {
    match kind {
        STREAM_DATAGRAM => FrameVerdict::Forward,
        STREAM_CONTROL => {
            let Ok(control) = serde_json::from_slice::<Value>(payload) else {
                return FrameVerdict::Drop("control is not JSON");
            };
            match control.get("t").and_then(Value::as_str) {
                Some("stop") => FrameVerdict::Forward,
                Some("service") => {
                    if control.get("service").and_then(Value::as_str) != Some(SERVICE_REMOTE_BROWSER) {
                        return FrameVerdict::Drop("not an rb message");
                    }
                    match control.pointer("/body/t").and_then(Value::as_str) {
                        Some(t) if VIEWER_MESSAGES.contains(&t) => FrameVerdict::Forward,
                        Some(_) => FrameVerdict::Drop("rb message a surface viewer may not send"),
                        None => FrameVerdict::Drop("rb message without t"),
                    }
                }
                Some("hello") => FrameVerdict::Drop("hostd sends the hello"),
                _ => FrameVerdict::Drop("rd control a viewer may not send"),
            }
        }
        _ => FrameVerdict::Drop("bulk transfers are not carried"),
    }
}

/// `surface {tab, video?, video_tag?}`: see the module docs.
pub async fn serve(
    config: &SurfaceConfig,
    tabs: &dyn SurfaceTabs,
    peer: &Peer,
    args: &Value,
    sender: &ChannelSender,
    receiver: ChannelReceiver,
) -> Result<(), Refusal> {
    let tab = args.get("tab").and_then(Value::as_str).unwrap_or_default();
    if let Some(surface) = surface_of(tab) {
        if !config.streams_simulators() {
            return Err(Refusal::new("no_surface_host", "this Mac does not stream simulator tabs"));
        }
        if !tabs.is_phone_tab(surface).await {
            return Err(Refusal::new("forbidden", "that tab is not a phone tab on this Mac"));
        }
    } else if let Some((machine_id, team_id)) = cloud_desktop_of(tab) {
        if !config.available() {
            return Err(Refusal::new("no_surface_host", "this Mac does not stream Cloud desktops"));
        }
        let snapshot =
            request_cloud_links().await.map_err(|message| Refusal::new("unavailable", message))?;
        cloud_desktop_access(snapshot.links, machine_id, team_id)?;
    } else {
        return Err(Refusal::new("bad_request", "invalid tab"));
    }
    let claim = config.hosts.claim(tab, "").await?;
    let viewer = claim.viewer;
    let track = (args.get("video").and_then(Value::as_str) == Some("track"))
        .then_some(peer.video.as_ref())
        .flatten()
        .filter(|video| !video.is_closed());
    let video_tag = args.get("video_tag").and_then(Value::as_u64).and_then(|tag| u32::try_from(tag).ok());
    let track = track.map(|video| (video, video_tag));
    let result = crate::browser::splice(claim, None, filter_frame, None, peer, sender, receiver, track).await;
    if cloud_desktop_of(tab).is_some() {
        // A Cloud desktop's source holds a VNC session to the machine: it ends with its viewer.
        config.hosts.release_and_stop(tab, viewer).await;
    } else {
        config.hosts.release(tab, viewer).await;
    }
    result
}

/// The clock frame capture times are in: monotonic and shared with the Mac app's
/// source (`CLOCK_UPTIME_RAW` on macOS, which it reads too), in microseconds.
pub fn surface_clock_us() -> u64 {
    #[cfg(target_os = "macos")]
    let clock = libc::CLOCK_UPTIME_RAW;
    #[cfg(not(target_os = "macos"))]
    let clock = libc::CLOCK_MONOTONIC;
    let mut now = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: `now` is a valid timespec to write, and `clock` a valid clock id.
    unsafe { libc::clock_gettime(clock, &mut now) };
    u64::try_from(now.tv_sec).unwrap_or(0) * 1_000_000 + u64::try_from(now.tv_nsec).unwrap_or(0) / 1000
}

// MARK: the app's frame source (`sf/1`)

/// One `sf/1` frame: `u8 kind | u32 BE length | payload`.
///
/// - kind 1, JSON, both ways. hostd to app: `{"t":"hello","secret"}` first,
///   then `encode {idr, kbps}`, `visible {visible}`, `touch {phase, x, y}`
///   (`began`, `moved`, `ended`; 0...1 of the screen, top-left origin, in the
///   orientation shown), `text {text}`, `key {key, down}`, `button {button}`.
///   App to hostd: `size {width, height}` (the frames' pixels; first, and on
///   every change), `damage` (the screen changed), `skip` (an `encode` with
///   no frame), `error {message}`.
/// - kind 2, an access unit, app to hostd: `u8 flags (bit 0: IDR) | u64 BE
///   capture time (`surface_clock_us`) | Annex B H.264`. Exactly one `skip`
///   or access unit answers each `encode`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SourceFrame {
    Json(Value),
    AccessUnit { idr: bool, capture_us: u64, annex_b: Vec<u8> },
}

impl SourceFrame {
    pub fn encode(&self) -> Vec<u8> {
        let (kind, payload) = match self {
            Self::Json(value) => (1u8, serde_json::to_vec(value).unwrap_or_default()),
            Self::AccessUnit { idr, capture_us, annex_b } => {
                let mut payload = Vec::with_capacity(9 + annex_b.len());
                payload.push(u8::from(*idr));
                payload.extend_from_slice(&capture_us.to_be_bytes());
                payload.extend_from_slice(annex_b);
                (2u8, payload)
            }
        };
        let mut out = Vec::with_capacity(5 + payload.len());
        out.push(kind);
        out.extend_from_slice(&u32::try_from(payload.len()).unwrap_or(u32::MAX).to_be_bytes());
        out.extend_from_slice(&payload);
        out
    }
}

/// Reads `sf/1` frames out of a byte stream.
#[derive(Default)]
pub struct SourceDeframer {
    buffer: Vec<u8>,
}

impl SourceDeframer {
    pub fn extend(&mut self, bytes: &[u8]) {
        self.buffer.extend_from_slice(bytes);
    }

    /// The next whole frame; an error for a frame no peer may send.
    pub fn next_frame(&mut self) -> Result<Option<SourceFrame>, &'static str> {
        if self.buffer.len() < 5 {
            return Ok(None);
        }
        let kind = self.buffer[0];
        let length =
            u32::from_be_bytes([self.buffer[1], self.buffer[2], self.buffer[3], self.buffer[4]]) as usize;
        if length > MAX_SOURCE_FRAME {
            return Err("an sf/1 frame over the limit");
        }
        if self.buffer.len() < 5 + length {
            return Ok(None);
        }
        let payload: Vec<u8> = self.buffer.drain(..5 + length).skip(5).collect();
        match kind {
            1 => {
                serde_json::from_slice(&payload).map(|v| Some(SourceFrame::Json(v))).map_err(|_| "sf/1 JSON")
            }
            2 if payload.len() >= 9 => {
                let mut stamp = [0u8; 8];
                stamp.copy_from_slice(&payload[1..9]);
                Ok(Some(SourceFrame::AccessUnit {
                    idr: payload[0] & 1 == 1,
                    capture_us: u64::from_be_bytes(stamp),
                    annex_b: payload[9..].to_vec(),
                }))
            }
            _ => Err("an unknown sf/1 frame"),
        }
    }
}

/// The app line for one phone input event (the JSON of an rd `service`
/// input), or None for an event a surface does not take. `touching` is
/// whether a finger is down (a mouse-style `move` with no button is no touch).
pub fn input_line(event: &Value, touching: &mut bool) -> Option<Value> {
    let unit = |v: Option<f64>| v.filter(|v| v.is_finite()).map(|v| v.clamp(0.0, 1.0));
    match event.get("e").and_then(Value::as_str)? {
        "pointer" => {
            let x = unit(event.get("x").and_then(Value::as_f64))?;
            let y = unit(event.get("y").and_then(Value::as_f64))?;
            let phase = match event.get("kind").and_then(Value::as_str)? {
                "down" => {
                    *touching = true;
                    "began"
                }
                "move" if *touching => "moved",
                "up" if *touching => {
                    *touching = false;
                    "ended"
                }
                _ => return None,
            };
            Some(json!({"t": "touch", "phase": phase, "x": x, "y": y}))
        }
        "ime_commit" => {
            let text = event.get("text").and_then(Value::as_str)?;
            if text.is_empty()
                || text.len() > MAX_TEXT_BYTES
                || text.chars().any(|c| c.is_control() && c != '\n' && c != '\t')
            {
                return None;
            }
            Some(json!({"t": "text", "text": text}))
        }
        "key" => {
            let code = event.get("code").and_then(Value::as_str)?;
            let down = event.get("down").and_then(Value::as_bool)?;
            KEYS.contains(&code).then(|| json!({"t": "key", "key": code, "down": down}))
        }
        "button" => {
            let button = event.get("button").and_then(Value::as_str)?;
            BUTTONS.contains(&button).then(|| json!({"t": "button", "button": button}))
        }
        _ => None,
    }
}

// MARK: the in-hostd host

/// Wraps the app's source launcher: each tab's host is an rd host task on
/// loopback in hostd, with its own per-launch secret, over the app's source.
fn host_launcher(source: Launcher) -> Launcher {
    Arc::new(move |request: LaunchRequest| {
        let source = Arc::clone(&source);
        Box::pin(async move {
            let app = source(request.clone()).await?;
            let listener =
                TcpListener::bind("127.0.0.1:0").await.map_err(|e| format!("surface host: {e}"))?;
            let addr = listener.local_addr().map_err(|e| format!("surface host: {e}"))?;
            let secret = format!("{}{}", uuid::Uuid::new_v4().simple(), uuid::Uuid::new_v4().simple());
            let (source_addr, source_secret, host_secret) = (app.addr, app.secret.clone(), secret.clone());
            let tab = request.tab;
            // A Cloud desktop is view only: its viewers' input never reaches the source.
            let view_only = cloud_desktop_of(&tab).is_some();
            let task = tokio::spawn(async move {
                while let Ok((stream, _)) = listener.accept().await {
                    let (host_secret, source_secret, tab) =
                        (host_secret.clone(), source_secret.clone(), tab.clone());
                    tokio::spawn(async move {
                        if let Err(reason) =
                            host_session(stream, &host_secret, source_addr, &source_secret, view_only).await
                        {
                            tracing::info!(tab, reason, "surface: session ended");
                        }
                    });
                }
            });
            Ok(RunningHost { addr, secret, guard: Box::new(SurfaceGuard { app: app.guard, task }) })
        })
    })
}

struct SurfaceGuard {
    app: Box<dyn HostGuard>,
    task: tokio::task::JoinHandle<()>,
}

impl HostGuard for SurfaceGuard {
    fn alive(&mut self) -> bool {
        self.app.alive() && !self.task.is_finished()
    }
}

impl Drop for SurfaceGuard {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn equal_secrets(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn rd_frame(kind: u8, payload: &[u8], out: &mut Vec<u8>) {
    let _ = encode_stream_frame(kind, payload, out);
}

fn rd_control(control: &Control, out: &mut Vec<u8>) {
    rd_frame(STREAM_CONTROL, &serde_json::to_vec(control).unwrap_or_default(), out);
}

fn rb(body: Value, out: &mut Vec<u8>) {
    rd_control(&Control::Service { service: SERVICE_REMOTE_BROWSER.into(), body }, out);
}

/// One viewer of a surface: the rd hello (with this host's secret), a fresh
/// connection to the app's source, then the media engine between them.
/// `view_only` (a Cloud desktop): no input cap, and no input reaches the source.
pub async fn host_session(
    mut stream: TcpStream,
    secret: &str,
    source: SocketAddr,
    source_secret: &str,
    view_only: bool,
) -> Result<(), String> {
    let _ = stream.set_nodelay(true);
    let mut deframer = StreamDeframer::default();
    let mut buffer = vec![0u8; 64 * 1024];
    // One deadline for the whole hello: a client that trickles bytes is closed too.
    let hello_by = tokio::time::Instant::now() + HELLO_TIMEOUT;
    let hello = loop {
        match deframer.next_frame() {
            Ok(Some((STREAM_CONTROL, payload))) => break serde_json::from_slice::<Control>(&payload).ok(),
            Ok(Some(_)) | Err(_) => break None,
            Ok(None) => {}
        }
        match tokio::time::timeout_at(hello_by, stream.read(&mut buffer)).await {
            Ok(Ok(n)) if n > 0 => deframer.extend(&buffer[..n]),
            _ => return Err("no hello".into()),
        }
    };
    let (max_datagram, caps) = match hello {
        Some(Control::Hello { token: Some(token), service, max_datagram, caps, .. })
            if equal_secrets(&token.0, secret) && service == SERVICE_REMOTE_BROWSER =>
        {
            (max_datagram.clamp(576, MAX_DATAGRAM_DEFAULT), caps)
        }
        _ => {
            let mut out = Vec::new();
            rd_control(&Control::Refused { reason: "unauthorized".into() }, &mut out);
            let _ = stream.write_all(&out).await;
            return Err("unauthorized".into());
        }
    };
    let mut app = TcpStream::connect(source).await.map_err(|e| format!("surface source: {e}"))?;
    let _ = app.set_nodelay(true);
    app.write_all(&SourceFrame::Json(json!({"t": "hello", "secret": source_secret})).encode())
        .await
        .map_err(|e| format!("surface source: {e}"))?;
    let mut source_frames = SourceDeframer::default();
    let mut app_buffer = vec![0u8; 256 * 1024];
    let (mut width, mut height) = loop {
        match source_frames.next_frame() {
            Ok(Some(SourceFrame::Json(value))) if value["t"] == "size" => {
                let size =
                    |key: &str| value.get(key).and_then(Value::as_u64).and_then(|v| u32::try_from(v).ok());
                match (size("width"), size("height")) {
                    (Some(w), Some(h)) if w > 0 && h > 0 && w <= 8192 && h <= 8192 => break (w, h),
                    _ => return Err("the source sent a bad size".into()),
                }
            }
            Ok(Some(SourceFrame::Json(value))) if value["t"] == "error" => {
                return Err(format!("surface source: {}", value["message"].as_str().unwrap_or("error")));
            }
            Ok(Some(_)) => {}
            Ok(None) => match tokio::time::timeout(SOURCE_TIMEOUT, app.read(&mut app_buffer)).await {
                Ok(Ok(n)) if n > 0 => source_frames.extend(&app_buffer[..n]),
                Ok(Ok(_)) => return Err("the source closed before it said its size".into()),
                Ok(Err(error)) => return Err(format!("the source: {error}")),
                Err(_) => return Err("the source said no size in time".into()),
            },
            Err(reason) => return Err(reason.into()),
        }
    };
    let input_caps: Vec<String> = caps.into_iter().filter(|c| !view_only && c == "input.service").collect();
    let mut out = Vec::new();
    rd_control(
        &Control::Welcome {
            encoder: "videotoolbox".into(),
            width,
            height,
            max_datagram,
            carrier: "stream".into(),
            service: SERVICE_REMOTE_BROWSER.into(),
            caps: input_caps,
        },
        &mut out,
    );
    rd_control(&Control::Started { session: 1 }, &mut out);
    stream.write_all(&out).await.map_err(|e| e.to_string())?;

    let mut engine = MediaEngine::new(
        EngineConfig { width, height, max_fps: MAX_FPS, max_datagram, ..EngineConfig::default() },
        surface_clock_us(),
    );
    let mut flow = Flow { pending: engine.start(surface_clock_us()), view_only, ..Flow::default() };
    let (mut phone_read, mut phone_write) = stream.into_split();
    let (mut app_read, mut app_write) = app.into_split();
    let result = loop {
        let mut to_phone = Vec::new();
        let mut to_app = Vec::new();
        let now = surface_clock_us();
        // An encode the source never answered (it lost the frame) counts as skipped.
        if flow.in_flight.as_ref().is_some_and(|(_, deadline)| now >= *deadline)
            && let Some((request, _)) = flow.in_flight.take()
            && let Ok(output) = engine.encoded(&request, None, now)
        {
            tracing::warn!("surface: the source did not answer an encode in time");
            // Its answer may still come: it belongs to no request now and is dropped. The
            // next frame is an IDR, so a P-frame the phone never got corrupts nothing.
            flow.late += 1;
            flow.force_idr = true;
            flow.take(output, &mut to_phone, &mut to_app);
        }
        if flow.in_flight.is_none()
            && let Some(request) = flow.pending.take()
        {
            let kbps = flow.kbps(request.target_kbps, now);
            let idr = request.force_idr || std::mem::take(&mut flow.force_idr);
            flow.sent_kbps = kbps;
            to_app.extend(SourceFrame::Json(json!({"t": "encode", "idr": idr, "kbps": kbps})).encode());
            flow.in_flight = Some((request, now + ENCODE_TIMEOUT_US));
        }
        if !to_app.is_empty() && app_write.write_all(&std::mem::take(&mut to_app)).await.is_err() {
            break Err("the source closed".to_owned());
        }
        let mut wake = engine.next_deadline_us().unwrap_or(now + 1_000_000).min(now + 1_000_000);
        if let Some((_, deadline)) = &flow.in_flight {
            wake = wake.min(*deadline);
        }
        let sleep = tokio::time::sleep(Duration::from_micros(wake.saturating_sub(now)));
        tokio::select! {
            read = phone_read.read(&mut buffer) => match read {
                Ok(0) | Err(_) => break Ok(()),
                Ok(n) => {
                    deframer.extend(&buffer[..n]);
                    let mut stop = false;
                    loop {
                        match deframer.next_frame() {
                            Ok(Some((STREAM_DATAGRAM, payload))) => {
                                let output = engine.on_datagram(&payload, true, surface_clock_us());
                                flow.take(output, &mut to_phone, &mut to_app);
                            }
                            Ok(Some((STREAM_CONTROL, payload))) => match serde_json::from_slice::<Control>(&payload) {
                                Ok(Control::Stop) => stop = true,
                                Ok(Control::Service { body, .. }) => match body.get("t").and_then(Value::as_str) {
                                    Some("rb.open") => {
                                        rb(json!({"t": "rb.opened", "session": 1, "main_stream": 0}), &mut to_phone);
                                        rb(json!({"t": "rb.screen_applied", "seq": 0, "pixel_width": width,
                                                  "pixel_height": height, "scale": 1.0}), &mut to_phone);
                                    }
                                    Some("rb.screen") => {
                                        rb(json!({"t": "rb.screen_applied", "seq": body["seq"].as_u64().unwrap_or(0),
                                                  "pixel_width": width, "pixel_height": height, "scale": 1.0}), &mut to_phone);
                                    }
                                    Some("rb.visibility") => {
                                        let visible = body["visible"].as_bool().unwrap_or(true);
                                        to_app.extend(SourceFrame::Json(json!({"t": "visible", "visible": visible})).encode());
                                    }
                                    Some("rb.close") => stop = true,
                                    _ => {}
                                },
                                _ => {}
                            },
                            Ok(Some(_)) => {}
                            Ok(None) => break,
                            Err(_) => {
                                stop = true;
                                break;
                            }
                        }
                    }
                    if stop {
                        break Ok(());
                    }
                }
            },
            read = app_read.read(&mut app_buffer) => match read {
                Ok(0) | Err(_) => break Err("the source closed".to_owned()),
                Ok(n) => {
                    source_frames.extend(&app_buffer[..n]);
                    let mut bad = None;
                    loop {
                        match source_frames.next_frame() {
                            Ok(Some(SourceFrame::AccessUnit { idr, capture_us, annex_b })) => {
                                if flow.late_answer() {
                                    continue;
                                }
                                let Some((request, _)) = flow.in_flight.take() else { continue };
                                let encoded = Encoded { access_unit: annex_b, idr, t_capture_us: capture_us };
                                match engine.encoded(&request, Some(encoded), surface_clock_us()) {
                                    Ok(output) => flow.take(output, &mut to_phone, &mut to_app),
                                    Err(error) => tracing::warn!(?error, "surface: a frame did not packetize"),
                                }
                            }
                            Ok(Some(SourceFrame::Json(value))) => match value.get("t").and_then(Value::as_str) {
                                Some("damage") => {
                                    let full = Rect { x: 0, y: 0, width, height };
                                    flow.newest(engine.damage(0, full, surface_clock_us()));
                                }
                                Some("skip") => {
                                    if !flow.late_answer()
                                        && let Some((request, _)) = flow.in_flight.take()
                                        && let Ok(output) = engine.encoded(&request, None, surface_clock_us())
                                    {
                                        flow.take(output, &mut to_phone, &mut to_app);
                                    }
                                }
                                Some("size") => {
                                    let size = |key: &str| value.get(key).and_then(Value::as_u64).and_then(|v| u32::try_from(v).ok());
                                    if let (Some(w), Some(h)) = (size("width"), size("height"))
                                        && w > 0 && h > 0 && w <= 8192 && h <= 8192 && (w, h) != (width, height)
                                    {
                                        // A rotation: the phone hears the new size (its touches map by the decoded frame).
                                        (width, height) = (w, h);
                                        rb(json!({"t": "rb.screen_applied", "seq": 0, "pixel_width": width,
                                                  "pixel_height": height, "scale": 1.0}), &mut to_phone);
                                    }
                                }
                                Some("error") => tracing::warn!(message = value["message"].as_str(), "surface: the source reported"),
                                _ => {}
                            },
                            Ok(None) => break,
                            Err(reason) => {
                                bad = Some(reason);
                                break;
                            }
                        }
                    }
                    if let Some(reason) = bad {
                        break Err(reason.into());
                    }
                }
            },
            () = sleep => {
                let now = surface_clock_us();
                let output = engine.tick(true, now);
                flow.take(output, &mut to_phone, &mut to_app);
                flow.newest(engine.poll(now));
            }
        }
        if !to_app.is_empty() && app_write.write_all(&to_app).await.is_err() {
            break Err("the source closed".to_owned());
        }
        if !to_phone.is_empty() && phone_write.write_all(&to_phone).await.is_err() {
            break Ok(());
        }
    };
    // A finger left down on the simulator is lifted where it was when its viewer goes.
    for line in flow.release() {
        let _ = app_write.write_all(&SourceFrame::Json(line).encode()).await;
    }
    result
}

/// How long the source has to answer one `encode` before it counts as skipped.
const ENCODE_TIMEOUT_US: u64 = 1_000_000;
/// How long a halved bitrate (a frame too large for the path) holds.
const HALVED_FOR_US: u64 = 2_000_000;

/// The engine's requests and the phone's finger between hostd and the source.
#[derive(Default)]
struct Flow {
    /// The next encode to ask for: always the newest request (the engine's frame
    /// gate counts a request as sent, so an older one dropped for it never stalls it).
    pending: Option<EncodeRequest>,
    /// The encode the source is working on, and when it counts as skipped.
    in_flight: Option<(EncodeRequest, u64)>,
    touching: bool,
    last_touch: (f64, f64),
    /// A bitrate cap after the engine asked to halve it, and until when.
    halved: Option<(u32, u64)>,
    /// The kbps of the last `encode` sent (what a halving halves).
    sent_kbps: u32,
    /// Answers still owed for encodes that timed out: the source answers in order,
    /// so the next this many answers belong to no request and are dropped.
    late: u32,
    /// The next encode asks for an IDR (a frame was lost to a timeout).
    force_idr: bool,
    /// Keys the phone holds down on the simulator (released with a finger).
    held_keys: Vec<String>,
    /// A view-only source (a Cloud desktop): the phone's input is dropped.
    view_only: bool,
}

impl Flow {
    /// Whether this answer belongs to an encode that already timed out.
    fn late_answer(&mut self) -> bool {
        if self.late == 0 {
            return false;
        }
        self.late -= 1;
        true
    }

    fn newest(&mut self, request: Option<EncodeRequest>) {
        if request.is_some() {
            self.pending = request;
        }
    }

    fn kbps(&mut self, target: u32, now: u64) -> u32 {
        match self.halved {
            Some((cap, until)) if now < until => target.min(cap),
            _ => {
                self.halved = None;
                target
            }
        }
    }

    /// One engine output: datagrams to the phone, input to the source, the next request.
    fn take(&mut self, output: Output, to_phone: &mut Vec<u8>, to_app: &mut Vec<u8>) {
        // A view-only source (a Cloud desktop) takes none of the phone's input.
        let inject = if self.view_only { &[][..] } else { &output.inject[..] };
        for event in inject {
            if let InputEvent::Service { bytes, .. } = event
                && let Ok(event) = serde_json::from_slice::<Value>(&bytes[..])
                && let Some(line) = input_line(&event, &mut self.touching)
            {
                if line["t"] == "touch" {
                    self.last_touch = (line["x"].as_f64().unwrap_or(0.5), line["y"].as_f64().unwrap_or(0.5));
                }
                if line["t"] == "key"
                    && let Some(key) = line["key"].as_str()
                {
                    self.held_keys.retain(|held| held != key);
                    if line["down"] == true {
                        self.held_keys.push(key.to_owned());
                    }
                }
                to_app.extend(SourceFrame::Json(line).encode());
            }
        }
        // The engine gave up on input it held behind a gap: a finger and keys still down are lifted.
        if output.release_all {
            for line in self.release() {
                to_app.extend(SourceFrame::Json(line).encode());
            }
        }
        if output.halve_bitrate && self.sent_kbps > 0 {
            let current = self.halved.map_or(self.sent_kbps, |(cap, _)| cap.min(self.sent_kbps));
            self.halved = Some(((current / 2).max(300), surface_clock_us() + HALVED_FOR_US));
        }
        self.newest(emit(to_phone, output));
    }

    /// The lines that lift a finger still down (at its last point) and release held keys.
    fn release(&mut self) -> Vec<Value> {
        let mut lines: Vec<Value> = std::mem::take(&mut self.held_keys)
            .into_iter()
            .map(|key| json!({"t": "key", "key": key, "down": false}))
            .collect();
        if self.touching {
            self.touching = false;
            let (x, y) = self.last_touch;
            lines.push(json!({"t": "touch", "phase": "ended", "x": x, "y": y}));
        }
        lines
    }
}

fn emit(out: &mut Vec<u8>, output: Output) -> Option<EncodeRequest> {
    for datagram in &output.datagrams {
        rd_frame(STREAM_DATAGRAM, datagram, out);
    }
    output.encode
}

#[cfg(test)]
mod tests {
    use super::*;

    fn control(value: Value) -> Vec<u8> {
        serde_json::to_vec(&value).unwrap()
    }

    #[test]
    fn a_surface_viewer_sends_no_navigation_or_page_messages() {
        let rb = |t: &str| {
            control(json!({"t": "service", "service": "rb/1", "body": {"t": t, "url": "https://x/"}}))
        };
        for t in VIEWER_MESSAGES {
            assert_eq!(filter_frame(STREAM_CONTROL, &rb(t)), FrameVerdict::Forward, "{t}");
        }
        for t in ["rb.navigate", "rb.history", "rb.menu.result", "rb.dialog.result", "rb.find", "rb.page"] {
            assert!(matches!(filter_frame(STREAM_CONTROL, &rb(t)), FrameVerdict::Drop(_)), "{t}");
        }
        assert!(matches!(
            filter_frame(STREAM_CONTROL, &control(json!({"t": "hello"}))),
            FrameVerdict::Drop(_)
        ));
        assert_eq!(filter_frame(STREAM_CONTROL, &control(json!({"t": "stop"}))), FrameVerdict::Forward);
        assert_eq!(filter_frame(STREAM_DATAGRAM, b"x"), FrameVerdict::Forward);
        assert!(matches!(filter_frame(3, b"x"), FrameVerdict::Drop(_)));
    }

    #[test]
    fn tab_keys_name_daemon_surfaces() {
        assert_eq!(surface_of("s12"), Some(12));
        for bad in ["", "s", "12", "s-1", "s1a", "S12", "s99999999999999999999"] {
            assert_eq!(surface_of(bad), None, "{bad}");
        }
    }

    #[test]
    fn cloud_desktop_keys_name_a_machine_and_its_team() {
        assert_eq!(cloud_desktop_of("c~m1~t1"), Some(("m1", "t1")));
        assert_eq!(cloud_desktop_of("c~vm.a-b_c~team.9"), Some(("vm.a-b_c", "team.9")));
        let malformed = ["", "c", "c~", "c~m1", "c~m1~", "c~~t1", "c~m1~t1~x", "c.m1.t1", "C~m1~t1", "s12"];
        let bad_ids = ["c~m 1~t1", "c~m1~t/1", "c~ m1~t1"];
        for bad in malformed.into_iter().chain(bad_ids) {
            assert_eq!(cloud_desktop_of(bad), None, "{bad}");
        }
        assert_eq!(cloud_desktop_of(&format!("c~{}~t", "m".repeat(161))), None);
        // A Cloud key is never a simulator surface, and the reverse.
        assert_eq!(surface_of("c~m1~t1"), None);
    }

    #[test]
    fn a_cloud_desktop_streams_only_the_owners_one_running_machine() {
        let link = |owner: bool, status: &str| CloudLink {
            machine_id: "m".into(),
            team_id: "t".into(),
            name: "Dev box".into(),
            socket: None,
            owner,
            status: status.into(),
            ran: true,
        };
        assert!(cloud_desktop_access(vec![link(true, "running")], "m", "t").is_ok());
        let code = |links, machine, team| cloud_desktop_access(links, machine, team).unwrap_err().code;
        // Not owned, ambiguous, or not listed: forbidden, whatever its state.
        assert_eq!(code(vec![link(false, "running")], "m", "t"), "forbidden");
        assert_eq!(code(vec![link(true, "running"), link(true, "running")], "m", "t"), "forbidden");
        assert_eq!(code(vec![link(true, "running")], "m", "other"), "forbidden");
        assert_eq!(code(vec![], "m", "t"), "forbidden");
        assert_eq!(code(vec![link(false, "paused")], "m", "t"), "forbidden");
        // Owned but not running: asleep.
        for status in ["paused", "pausing", "starting", "provisioning", "failed", "unknown"] {
            assert_eq!(code(vec![link(true, status)], "m", "t"), "asleep", "{status}");
        }
    }

    #[test]
    fn a_view_only_source_gets_no_phone_input() {
        let service = |event: Value| InputEvent::Service {
            must_deliver: true,
            bytes: serde_json::to_vec(&event).unwrap(),
        };
        let input = || Output {
            inject: vec![
                service(json!({"e": "pointer", "kind": "down", "x": 0.5, "y": 0.5})),
                service(json!({"e": "ime_commit", "text": "rm -rf ~"})),
                service(json!({"e": "key", "code": "Enter", "down": true})),
                service(json!({"e": "button", "button": "home"})),
            ],
            release_all: true,
            ..Output::default()
        };
        let mut view_only = Flow { view_only: true, ..Flow::default() };
        let mut to_app = Vec::new();
        view_only.take(input(), &mut Vec::new(), &mut to_app);
        assert!(to_app.is_empty(), "no input line reaches a Cloud desktop");
        assert!(!view_only.touching && view_only.held_keys.is_empty());
        // The same input reaches a simulator.
        let mut simulator = Flow::default();
        simulator.take(input(), &mut Vec::new(), &mut to_app);
        let mut lines = SourceDeframer::default();
        lines.extend(&to_app);
        let mut kinds = Vec::new();
        while let Ok(Some(SourceFrame::Json(line))) = lines.next_frame() {
            kinds.push(line["t"].as_str().unwrap().to_owned());
        }
        assert_eq!(kinds[..4], ["touch", "text", "key", "button"]);
    }

    #[test]
    fn only_phone_page_tabs_stream() {
        let reply = json!({"ok": true, "data": {"workspaces": [{"screens": [{"panes": [{"tabs": [
            {"surface": 9, "kind": "browser", "url": "https://x/"},
            {"surface": 12, "kind": "conversation", "conversation": {"page": "phone", "route": "sim:A"}},
            {"surface": 13, "kind": "conversation", "conversation": {"page": "settings"}},
        ]}]}]}]}});
        assert!(phone_tab_in(&reply, 12));
        assert!(!phone_tab_in(&reply, 9));
        assert!(!phone_tab_in(&reply, 13));
        assert!(!phone_tab_in(&reply, 14));
        assert!(!phone_tab_in(&json!({"ok": false}), 12));
    }

    #[test]
    fn phone_input_becomes_touches_text_keys_and_buttons_only() {
        let mut touching = false;
        let pointer = |kind: &str, x: f64, y: f64| json!({"e": "pointer", "kind": kind, "x": x, "y": y});
        // A hover move before any touch is nothing.
        assert_eq!(input_line(&pointer("move", 0.5, 0.5), &mut touching), None);
        assert_eq!(
            input_line(&pointer("down", 0.25, 0.75), &mut touching),
            Some(json!({"t": "touch", "phase": "began", "x": 0.25, "y": 0.75}))
        );
        // Points outside the screen are clamped to its edge.
        assert_eq!(
            input_line(&pointer("move", 1.5, -2.0), &mut touching),
            Some(json!({"t": "touch", "phase": "moved", "x": 1.0, "y": 0.0}))
        );
        assert_eq!(input_line(&pointer("up", 0.3, 0.3), &mut touching).unwrap()["phase"], "ended");
        assert!(!touching);
        assert_eq!(
            input_line(&json!({"e": "ime_commit", "text": "héllo"}), &mut touching),
            Some(json!({"t": "text", "text": "héllo"}))
        );
        assert_eq!(input_line(&json!({"e": "ime_commit", "text": "a\u{1b}b"}), &mut touching), None);
        assert_eq!(
            input_line(&json!({"e": "key", "code": "Backspace", "down": true}), &mut touching),
            Some(json!({"t": "key", "key": "Backspace", "down": true}))
        );
        assert_eq!(input_line(&json!({"e": "key", "code": "MetaLeft", "down": true}), &mut touching), None);
        assert_eq!(
            input_line(&json!({"e": "button", "button": "home"}), &mut touching),
            Some(json!({"t": "button", "button": "home"}))
        );
        assert_eq!(input_line(&json!({"e": "button", "button": "siri"}), &mut touching), None);
        assert_eq!(input_line(&json!({"e": "wheel", "x": 0.1, "y": 0.1}), &mut touching), None);
    }

    #[test]
    fn a_viewer_that_goes_releases_its_finger_and_keys_and_a_halving_halves_what_was_sent() {
        let mut flow = Flow {
            touching: true,
            last_touch: (0.2, 0.7),
            held_keys: vec!["Backspace".into()],
            ..Flow::default()
        };
        assert_eq!(
            flow.release(),
            vec![
                json!({"t": "key", "key": "Backspace", "down": false}),
                json!({"t": "touch", "phase": "ended", "x": 0.2, "y": 0.7}),
            ]
        );
        assert!(flow.release().is_empty());
        flow.sent_kbps = 4000;
        let output = Output { halve_bitrate: true, ..Output::default() };
        flow.take(output, &mut Vec::new(), &mut Vec::new());
        assert_eq!(flow.kbps(4000, surface_clock_us()), 2000);
        // Answers owed to timed-out encodes are dropped, in order.
        flow.late = 1;
        assert!(flow.late_answer());
        assert!(!flow.late_answer());
    }

    #[test]
    fn source_frames_round_trip() {
        let mut deframer = SourceDeframer::default();
        let au = SourceFrame::AccessUnit { idr: true, capture_us: 42, annex_b: vec![0, 0, 0, 1, 0x65, 1, 2] };
        let json = SourceFrame::Json(json!({"t": "size", "width": 10, "height": 20}));
        let mut bytes = au.encode();
        bytes.extend(json.encode());
        deframer.extend(&bytes[..3]);
        assert_eq!(deframer.next_frame(), Ok(None));
        deframer.extend(&bytes[3..]);
        assert_eq!(deframer.next_frame(), Ok(Some(au)));
        assert_eq!(deframer.next_frame(), Ok(Some(json)));
        assert_eq!(deframer.next_frame(), Ok(None));
        let mut huge = SourceDeframer::default();
        huge.extend(&[2, 0xff, 0xff, 0xff, 0xff]);
        assert!(huge.next_frame().is_err());
    }
}
