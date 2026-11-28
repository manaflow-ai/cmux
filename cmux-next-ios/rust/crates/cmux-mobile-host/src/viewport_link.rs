//! Viewport sync on a `daemon` channel: the per-surface state machine between the daemon's
//! lines and [`viewport_sync::run_selected`], and the link's one overlay datagram port.
//!
//! On only when the phone asked (`"viewport_sync": 1` in the channel's args), this Mac's gate is
//! on ([`crate::config::ServiceConfig::viewport_sync`]) and the link rides a WireGuard overlay.
//! Per surface, in bytes mode:
//! - a `vt-state` goes on as it came; a host model primed from it starts, and the phone hears
//!   `{"event":"viewport-sync","surface":S,"epoch":E}`;
//! - its `output` lines feed the model instead of going on: [`StreamOut`] decides what the
//!   stream carries (`output`, `viewport-history`, `viewport-path`), the rest go as datagrams;
//! - any other line naming the surface ends the sync first (everything it emitted forwarded,
//!   then `viewport-sync-end`), goes on, and the sync starts again under a new epoch where the
//!   model can follow (not after `detached`, an exit, or an agent CLI line).
//!
//! A surface's emitted lines and its forwarded daemon lines keep their order. Hybrid attaches
//! (`hybrid_stream`, `hybrid_frame`) and surfaces with agent CLI lines never sync.

use std::borrow::Cow;
use std::collections::{HashMap, HashSet, VecDeque};
use std::future::Future;
use std::io;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use base64::Engine as _;
use cmux_mobile_link::dial::Overlay;
use cmux_mobile_link::viewport::render_screen;
use cmux_terminal_projection::sync::parse_ack_datagram;
use cmux_wg::WgDatagramSocket;
use serde::Deserialize;
use serde::de::IgnoredAny;
use tokio::sync::{OnceCell, mpsc};
use tokio::task::JoinHandle;

use crate::viewport_sync::{
    self, Config, DatagramIo, Path, SelectorConfig, SendError, SendErrors, StreamOut, ViewportSync,
};

/// A datagram and its peer (the source of one received, the destination of one to send).
type Addressed = (Vec<u8>, SocketAddr);
type Routes = Arc<Mutex<HashMap<u32, mpsc::Sender<Addressed>>>>;

/// Datagrams queued to the link's socket before a send counts as lost.
const SEND_QUEUE: usize = 1024;
/// Acks one surface's driver holds before new ones are dropped.
const SURFACE_INBOX: usize = 256;
/// PTY batches queued to one surface's model.
const OUTPUT_QUEUE: usize = 1024;

/// Where a surface's datagrams go: the link's port, shared by every channel and surface.
pub trait Datagrams: Send + Sync + 'static {
    type Io: DatagramIo + 'static;
    /// The largest payload and the phone's address, binding the port on first use; `None`
    /// when it cannot be bound (the sync stays off).
    fn open(&self) -> impl Future<Output = Option<(usize, SocketAddr)>> + Send;
    /// The acks of `epoch` and a way to send, once [`Datagrams::open`] succeeded.
    fn register(&self, epoch: u32) -> Option<Self::Io>;
}

/// The link's viewport sync port ([`viewport_sync::PORT`] on its WireGuard overlay), bound
/// lazily. One task sends every surface's datagrams and routes the phone's acks by epoch; it
/// ends when the last [`crate::services::Peer`] of the link (and every surface's handle) drops.
pub struct LinkHub {
    overlay: Overlay,
    bound: OnceCell<Option<Arc<Hub>>>,
}

impl std::fmt::Debug for LinkHub {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("LinkHub")
            .field("peer_ip", &self.overlay.peer_ip)
            .field("bound", &self.bound.get().map(Option::is_some))
            .finish()
    }
}

impl LinkHub {
    pub fn new(overlay: Overlay) -> Self {
        Self { overlay, bound: OnceCell::new() }
    }

    async fn hub(&self) -> Option<Arc<Hub>> {
        self.bound
            .get_or_init(|| async {
                let peer = SocketAddr::new(self.overlay.peer_ip, viewport_sync::PORT);
                match self.overlay.net.bind_datagram(viewport_sync::PORT).await {
                    Ok(socket) => Some(Arc::new(Hub::start(socket, peer))),
                    Err(error) => {
                        tracing::warn!(%error, "viewport sync: the overlay datagram port is unavailable");
                        None
                    }
                }
            })
            .await
            .clone()
    }
}

impl Datagrams for LinkHub {
    type Io = SurfaceIo;

    async fn open(&self) -> Option<(usize, SocketAddr)> {
        let hub = self.hub().await?;
        Some((hub.max_datagram, hub.peer))
    }

    fn register(&self, epoch: u32) -> Option<SurfaceIo> {
        let hub = self.bound.get()?.clone()?;
        let (inbox, inbound) = mpsc::channel(SURFACE_INBOX);
        hub.routes.lock().unwrap_or_else(PoisonError::into_inner).insert(epoch, inbox);
        Some(SurfaceIo { epoch, hub, inbound })
    }
}

struct Hub {
    max_datagram: usize,
    peer: SocketAddr,
    out: mpsc::Sender<Addressed>,
    routes: Routes,
    task: JoinHandle<()>,
}

impl Hub {
    fn start(socket: WgDatagramSocket, peer: SocketAddr) -> Self {
        let max_datagram = socket.max_datagram();
        let routes = Routes::default();
        let (out, outbound) = mpsc::channel(SEND_QUEUE);
        let task = tokio::spawn(serve_hub(socket, outbound, Arc::clone(&routes)));
        Self { max_datagram, peer, out, routes, task }
    }
}

impl Drop for Hub {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn serve_hub(mut socket: WgDatagramSocket, mut outbound: mpsc::Receiver<Addressed>, routes: Routes) {
    let mut errors = SendErrors::default();
    loop {
        tokio::select! {
            // Both are mpsc receives underneath: cancel-safe.
            received = socket.recv_from() => {
                let Some((datagram, from)) = received else { break };
                let Some((epoch, _)) = parse_ack_datagram(&datagram) else { continue };
                let route = routes.lock().unwrap_or_else(PoisonError::into_inner).get(&epoch).cloned();
                if let Some(route) = route {
                    // A driver behind on its acks loses the newest: the next one says as much.
                    let _ = route.try_send((datagram, from));
                }
            }
            next = outbound.recv() => {
                let Some((payload, to)) = next else { break };
                // A refused send is a lost datagram, counted by class; the driver's resend
                // covers it. A gone tunnel ends the hub (and so every surface's driver).
                if let Err(error) = DatagramIo::send_to(&socket, &payload, to).await
                    && errors.record(&error) == SendError::Fatal
                {
                    break;
                }
            }
        }
    }
    if errors.total() > 0 {
        tracing::info!(?errors, "viewport sync: overlay sends refused");
    }
    // The tunnel is gone: every surface's driver hears it and ends.
    routes.lock().unwrap_or_else(PoisonError::into_inner).clear();
}

/// One surface's view of the link's port: the acks of its epoch, and sends.
pub struct SurfaceIo {
    epoch: u32,
    hub: Arc<Hub>,
    inbound: mpsc::Receiver<Addressed>,
}

impl Drop for SurfaceIo {
    fn drop(&mut self) {
        self.hub.routes.lock().unwrap_or_else(PoisonError::into_inner).remove(&self.epoch);
    }
}

impl DatagramIo for SurfaceIo {
    fn max_datagram(&self) -> usize {
        self.hub.max_datagram
    }

    fn send_to(&self, payload: &[u8], peer: SocketAddr) -> impl Future<Output = io::Result<()>> + Send {
        // Never waits: a full queue is a lost datagram.
        let sent = self.hub.out.try_send((payload.to_vec(), peer));
        std::future::ready(
            sent.map_err(|_| {
                io::Error::new(io::ErrorKind::WouldBlock, "the viewport sync send queue is full")
            }),
        )
    }

    async fn recv_from(&mut self) -> io::Result<Addressed> {
        self.inbound
            .recv()
            .await
            .ok_or_else(|| io::Error::new(io::ErrorKind::BrokenPipe, "the link's viewport sync port closed"))
    }
}

/// The phone is gone (the channel's line queue closed).
#[derive(Debug)]
pub struct Closed;

/// Surfaces that never sync, from the phone's requests ([`HybridMarks::observe`]).
#[derive(Clone, Debug, Default)]
pub struct HybridMarks(Arc<Mutex<HashSet<u64>>>);

impl HybridMarks {
    /// A phone request line on its way to the daemon: an `attach-surface` asking for a hybrid
    /// stream (`hybrid_stream` or `hybrid_frame`) marks its surface.
    pub fn observe(&self, line: &[u8]) {
        if !line.windows(7).any(|w| w == b"hybrid_") {
            return;
        }
        let Ok(request) = serde_json::from_slice::<serde_json::Value>(line) else { return };
        let hybrid = !request["hybrid_stream"].is_null() || !request["hybrid_frame"].is_null();
        if request["cmd"] == "attach-surface"
            && hybrid
            && let Some(surface) = request["surface"].as_u64()
        {
            self.mark(surface);
        }
    }

    fn mark(&self, surface: u64) {
        self.0.lock().unwrap_or_else(PoisonError::into_inner).insert(surface);
    }

    fn contains(&self, surface: u64) -> bool {
        self.0.lock().unwrap_or_else(PoisonError::into_inner).contains(&surface)
    }
}

/// The fields of a daemon event line this module reads.
#[derive(Deserialize)]
struct DaemonEvent<'a> {
    #[serde(borrow)]
    event: Cow<'a, str>,
    #[serde(default)]
    surface: Option<serde_json::Value>,
    #[serde(borrow, default)]
    data: Option<Cow<'a, str>>,
    #[serde(borrow, default)]
    pending: Option<Cow<'a, str>>,
    #[serde(borrow, default)]
    replay: Option<Cow<'a, str>>,
    #[serde(default)]
    cols: Option<u16>,
    #[serde(default)]
    rows: Option<u16>,
    /// An `output` line that also changes the palette.
    #[serde(default)]
    colors: Option<IgnoredAny>,
}

fn decode(data: Option<&Cow<'_, str>>) -> Option<Vec<u8>> {
    base64::engine::general_purpose::STANDARD.decode(data?.as_bytes()).ok()
}

/// What a new sync's model starts from.
enum Prime {
    /// A fresh model at the grid, fed these (a replay and its pending sequence).
    Bytes { cols: u16, rows: u16, parts: Vec<Vec<u8>> },
    /// The model of the sync that just ended, then these bytes (forwarded on the stream).
    Model(Box<ViewportSync>, Vec<u8>),
}

struct Surface {
    output: mpsc::Sender<Vec<u8>>,
    task: JoinHandle<io::Result<ViewportSync>>,
}

/// A `daemon` channel's viewport sync: every daemon line for the phone goes through
/// [`ViewportLink::on_line`], and comes out on `lines`, stamped when the phone asked.
pub struct ViewportLink<D: Datagrams> {
    datagrams: Arc<D>,
    selector: SelectorConfig,
    pseq: bool,
    lines: mpsc::Sender<Vec<u8>>,
    surfaces: HashMap<u64, Surface>,
    excluded: HybridMarks,
}

impl<D: Datagrams> Drop for ViewportLink<D> {
    fn drop(&mut self) {
        for surface in self.surfaces.values() {
            surface.task.abort();
        }
    }
}

/// `line` with its paint-latency id when the phone asked for one (`"pseq": true`).
pub(crate) fn stamped(line: Vec<u8>, pseq: bool) -> Vec<u8> {
    if pseq { crate::paint_latency::stamp_line(line).0 } else { line }
}

fn output_line(surface: u64, bytes: &[u8]) -> Vec<u8> {
    let data = base64::engine::general_purpose::STANDARD.encode(bytes);
    format!("{{\"event\":\"output\",\"surface\":{surface},\"data\":\"{data}\"}}\n").into_bytes()
}

fn history_line(surface: u64, rows: &[u8]) -> Vec<u8> {
    let data = base64::engine::general_purpose::STANDARD.encode(rows);
    format!("{{\"event\":\"viewport-history\",\"surface\":{surface},\"data\":\"{data}\"}}\n").into_bytes()
}

fn path_line(surface: u64, path: Path) -> Vec<u8> {
    format!("{{\"event\":\"viewport-path\",\"surface\":{surface},\"path\":\"{}\"}}\n", path.name())
        .into_bytes()
}

fn sync_line(surface: u64, epoch: u32) -> Vec<u8> {
    format!("{{\"event\":\"viewport-sync\",\"surface\":{surface},\"epoch\":{epoch}}}\n").into_bytes()
}

fn end_line(surface: u64) -> Vec<u8> {
    format!("{{\"event\":\"viewport-sync-end\",\"surface\":{surface}}}\n").into_bytes()
}

/// A surface's [`StreamOut`] as the phone's lines, in order. With
/// [`viewport_sync::skip_superseded`] on, it looks ahead at what is queued: a switch to the
/// datagrams supersedes every stream batch and repaint before it (the phone repaints from the
/// datagrams on the switch), so those go as their scrolled-off rows only.
async fn forward(
    mut stream: mpsc::Receiver<StreamOut>,
    surface: u64,
    lines: mpsc::Sender<Vec<u8>>,
    pseq: bool,
) {
    let skip = viewport_sync::skip_superseded();
    let mut ahead: VecDeque<StreamOut> = VecDeque::new();
    loop {
        if ahead.is_empty() {
            let Some(out) = stream.recv().await else { return };
            ahead.push_back(out);
        }
        if skip {
            // Bounded: the driver still waits on this queue once it is full.
            while ahead.len() < OUTPUT_QUEUE
                && let Ok(out) = stream.try_recv()
            {
                ahead.push_back(out);
            }
            drop_superseded(&mut ahead);
        }
        let Some(out) = ahead.pop_front() else { continue };
        let line = match out {
            StreamOut::Output { bytes, .. } => output_line(surface, &bytes),
            StreamOut::History(rows) => history_line(surface, &rows),
            StreamOut::Switched(path) => path_line(surface, path),
            StreamOut::Repaint(screen) => output_line(surface, &render_screen(None, &screen)),
        };
        if lines.send(stamped(line, pseq)).await.is_err() {
            return;
        }
    }
}

/// Before the last switch to the datagrams queued: stream batches become their scrolled-off
/// rows (none: dropped) and repaints go; a batch without its rows stays as it is.
fn drop_superseded(ahead: &mut VecDeque<StreamOut>) {
    let Some(at) = ahead.iter().rposition(|out| matches!(out, StreamOut::Switched(Path::Datagram))) else {
        return;
    };
    let superseded =
        |out: &StreamOut| matches!(out, StreamOut::Output { rows: Some(_), .. } | StreamOut::Repaint(_));
    if !ahead.iter().take(at).any(superseded) {
        return;
    }
    let tail = ahead.split_off(at);
    let head = std::mem::take(ahead);
    ahead.extend(head.into_iter().filter_map(|out| match out {
        StreamOut::Output { rows: Some(rows), .. } => (!rows.is_empty()).then_some(StreamOut::History(rows)),
        StreamOut::Repaint(_) => None,
        other => Some(other),
    }));
    ahead.extend(tail);
}

impl<D: Datagrams> ViewportLink<D> {
    pub fn new(
        datagrams: Arc<D>,
        selector: SelectorConfig,
        pseq: bool,
        lines: mpsc::Sender<Vec<u8>>,
    ) -> Self {
        Self { datagrams, selector, pseq, lines, surfaces: HashMap::new(), excluded: HybridMarks::default() }
    }

    /// Where the phone-to-daemon side marks hybrid attaches.
    pub fn hybrid_marks(&self) -> HybridMarks {
        self.excluded.clone()
    }

    /// Whether `surface` is synced now.
    pub fn syncing(&self, surface: u64) -> bool {
        self.surfaces.contains_key(&surface)
    }

    async fn send(&self, line: Vec<u8>) -> Result<(), Closed> {
        self.lines.send(stamped(line, self.pseq)).await.map_err(|_| Closed)
    }

    /// One daemon line for the phone (with its newline).
    pub async fn on_line(&mut self, line: Vec<u8>) -> Result<(), Closed> {
        let parsed = (line.first() == Some(&b'{'))
            .then(|| serde_json::from_slice::<DaemonEvent<'_>>(&line).ok())
            .flatten()
            .and_then(|event| Some((event.surface.as_ref()?.as_u64()?, event)));
        let Some((surface, event)) = parsed else { return self.send(line).await };
        match event.event.as_ref() {
            "output" if event.colors.is_none() && self.syncing(surface) => {
                if let Some(bytes) = decode(event.data.as_ref())
                    && let Some(sync) = self.surfaces.get(&surface)
                    && sync.output.send(bytes).await.is_ok()
                {
                    return Ok(());
                }
                // Undecodable, or the sync ended on its own (the link's port closed).
                drop(event);
                self.end(surface).await?;
                self.send(line).await
            }
            "vt-state" => {
                let prime = decode(event.data.as_ref()).zip(event.cols.zip(event.rows)).map(
                    |(data, (cols, rows))| {
                        let parts = [Some(data), decode(event.pending.as_ref())].into_iter().flatten();
                        Prime::Bytes { cols, rows, parts: parts.collect() }
                    },
                );
                drop(event);
                self.end(surface).await?;
                self.send(line).await?;
                match prime {
                    Some(prime) if !self.excluded.contains(surface) => self.start(surface, prime).await,
                    _ => Ok(()),
                }
            }
            "resized" => {
                let prime = decode(event.replay.as_ref()).zip(event.cols.zip(event.rows)).map(
                    |(replay, (cols, rows))| {
                        let parts = [Some(replay), decode(event.pending.as_ref())].into_iter().flatten();
                        Prime::Bytes { cols, rows, parts: parts.collect() }
                    },
                );
                drop(event);
                let was = self.end(surface).await?.is_some();
                self.send(line).await?;
                match prime {
                    Some(prime) if was => self.start(surface, prime).await,
                    _ => Ok(()),
                }
            }
            kind => {
                let kind = kind.to_owned();
                let output = (kind == "output" && self.syncing(surface))
                    .then(|| decode(event.data.as_ref()))
                    .flatten();
                drop(event);
                if kind.starts_with("agent-cli") {
                    self.excluded.mark(surface);
                }
                let ended = self.end(surface).await?;
                self.send(line).await?;
                let follows = !kind.starts_with("agent-cli")
                    && !matches!(kind.as_str(), "detached" | "exited" | "surface-exited" | "closed");
                match ended {
                    // The line changed nothing the model holds, or the model takes its bytes too.
                    Some(sync) if follows && (kind != "output" || output.is_some()) => {
                        self.start(surface, Prime::Model(Box::new(sync), output.unwrap_or_default())).await
                    }
                    _ => Ok(()),
                }
            }
        }
    }

    /// Starts `surface`'s sync and announces its epoch. Without the link's port it stays off.
    async fn start(&mut self, surface: u64, prime: Prime) -> Result<(), Closed> {
        let Some((max_datagram, peer)) = self.datagrams.open().await else { return Ok(()) };
        let now = Instant::now();
        let mut sync = match prime {
            Prime::Bytes { cols, rows, parts } => {
                let mut sync = ViewportSync::new(cols, rows, max_datagram, Config::default(), now);
                for part in parts {
                    // The phone has these rows already (the replay carried them).
                    let _ = sync.feed(&part);
                }
                sync
            }
            Prime::Model(sync, bytes) => {
                let mut sync = sync.renewed(max_datagram, now);
                if !bytes.is_empty() {
                    let _ = sync.feed(&bytes);
                }
                sync
            }
        };
        sync.select_path(self.selector.clone());
        let epoch = sync.epoch();
        let Some(io) = self.datagrams.register(epoch) else { return Ok(()) };
        // Before anything the sync emits.
        self.send(sync_line(surface, epoch)).await?;
        let (output, batches) = mpsc::channel(OUTPUT_QUEUE);
        let (stream, stream_rx) = mpsc::channel(OUTPUT_QUEUE);
        let lines = self.lines.clone();
        let pseq = self.pseq;
        let task = tokio::spawn(async move {
            let run = viewport_sync::run_selected(sync, io, Some(peer), batches, stream, Duration::ZERO);
            let (result, ()) = tokio::join!(run, forward(stream_rx, surface, lines, pseq));
            result
        });
        self.surfaces.insert(surface, Surface { output, task });
        Ok(())
    }

    /// Ends `surface`'s sync: its model takes the batches already sent it, everything it
    /// emitted goes out, then (on the datagram path, whose last state the phone may not hold) a
    /// full repaint, then `viewport-sync-end`. The model, when it ended well.
    async fn end(&mut self, surface: u64) -> Result<Option<ViewportSync>, Closed> {
        let Some(Surface { output, task }) = self.surfaces.remove(&surface) else { return Ok(None) };
        drop(output);
        let sync = match task.await {
            Ok(Ok(sync)) => {
                let errors = sync.send_errors();
                if errors.total() > 0 {
                    tracing::info!(surface, ?errors, "viewport sync: sends refused");
                }
                Some(sync)
            }
            Ok(Err(error)) => {
                tracing::info!(surface, %error, "viewport sync ended");
                None
            }
            Err(_) => None,
        };
        if let Some(sync) = &sync
            && sync.path() == Path::Datagram
        {
            self.send(output_line(surface, &render_screen(None, &sync.capture()))).await?;
        }
        self.send(end_line(surface)).await?;
        Ok(sync)
    }

    /// The daemon closed: every sync ends in order.
    pub async fn finish(&mut self) -> Result<(), Closed> {
        let surfaces: Vec<u64> = self.surfaces.keys().copied().collect();
        for surface in surfaces {
            self.end(surface).await?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_terminal_projection::sync::{ScreenState, SyncReceiver, parse_diff_datagram};

    /// A fake link port: every datagram sent is kept; no ack ever comes.
    #[derive(Default)]
    struct FakeDatagrams {
        sent: Arc<Mutex<Vec<Vec<u8>>>>,
        held: Mutex<Vec<mpsc::Sender<Addressed>>>,
    }

    struct FakeIo {
        sent: Arc<Mutex<Vec<Vec<u8>>>>,
        inbound: mpsc::Receiver<Addressed>,
    }

    impl DatagramIo for FakeIo {
        fn max_datagram(&self) -> usize {
            viewport_sync::UDP_MAX_DATAGRAM
        }

        fn send_to(&self, payload: &[u8], _peer: SocketAddr) -> impl Future<Output = io::Result<()>> + Send {
            self.sent.lock().unwrap().push(payload.to_vec());
            std::future::ready(Ok(()))
        }

        async fn recv_from(&mut self) -> io::Result<Addressed> {
            self.inbound.recv().await.ok_or_else(|| io::Error::from(io::ErrorKind::BrokenPipe))
        }
    }

    impl Datagrams for FakeDatagrams {
        type Io = FakeIo;

        async fn open(&self) -> Option<(usize, SocketAddr)> {
            Some((viewport_sync::UDP_MAX_DATAGRAM, SocketAddr::from(([127, 0, 0, 1], viewport_sync::PORT))))
        }

        fn register(&self, _epoch: u32) -> Option<FakeIo> {
            let (inbox, inbound) = mpsc::channel(8);
            self.held.lock().unwrap().push(inbox);
            Some(FakeIo { sent: Arc::clone(&self.sent), inbound })
        }
    }

    #[test]
    fn a_switch_to_the_datagrams_drops_the_stream_batches_queued_before_it() {
        let batch = |n: u64, rows: Option<&[u8]>| StreamOut::Output {
            batch: n,
            bytes: vec![b'x'; 8],
            rows: rows.map(<[u8]>::to_vec),
        };
        let mut ahead: VecDeque<StreamOut> = VecDeque::from(vec![
            batch(1, Some(b"")),
            batch(2, Some(b"row\r\n")),
            batch(3, None),
            StreamOut::Switched(Path::Datagram),
            StreamOut::History(b"later\r\n".to_vec()),
        ]);
        drop_superseded(&mut ahead);
        assert_eq!(
            Vec::from(ahead),
            vec![
                StreamOut::History(b"row\r\n".to_vec()),
                batch(3, None),
                StreamOut::Switched(Path::Datagram),
                StreamOut::History(b"later\r\n".to_vec()),
            ]
        );
        // Batches after the last switch, or with no switch queued, stay.
        let mut ahead: VecDeque<StreamOut> =
            VecDeque::from(vec![StreamOut::Switched(Path::Stream), batch(4, Some(b""))]);
        drop_superseded(&mut ahead);
        assert_eq!(ahead.len(), 2);
    }

    fn b64(bytes: &[u8]) -> String {
        base64::engine::general_purpose::STANDARD.encode(bytes)
    }

    fn vt_state(surface: u64, cols: u16, rows: u16, data: &[u8], pending: &[u8]) -> Vec<u8> {
        let pending =
            if pending.is_empty() { String::new() } else { format!(",\"pending\":\"{}\"", b64(pending)) };
        format!(
            "{{\"event\":\"vt-state\",\"surface\":{surface},\"cols\":{cols},\"rows\":{rows},\"data\":\"{}\"{pending}}}\n",
            b64(data)
        )
        .into_bytes()
    }

    fn output(surface: u64, bytes: &[u8]) -> Vec<u8> {
        format!("{{\"event\":\"output\",\"surface\":{surface},\"data\":\"{}\"}}\n", b64(bytes)).into_bytes()
    }

    fn rig(
        selector: SelectorConfig,
        pseq: bool,
    ) -> (ViewportLink<FakeDatagrams>, Arc<FakeDatagrams>, mpsc::Receiver<Vec<u8>>) {
        let datagrams = Arc::new(FakeDatagrams::default());
        let (lines, received) = mpsc::channel(4096);
        (ViewportLink::new(Arc::clone(&datagrams), selector, pseq, lines), datagrams, received)
    }

    fn drain(received: &mut mpsc::Receiver<Vec<u8>>) -> Vec<serde_json::Value> {
        let mut out = Vec::new();
        while let Ok(line) = received.try_recv() {
            assert_eq!(line.last(), Some(&b'\n'), "a whole line");
            out.push(serde_json::from_slice(&line).unwrap());
        }
        out
    }

    fn events(lines: &[serde_json::Value]) -> Vec<String> {
        lines.iter().map(|line| line["event"].as_str().unwrap_or("-").to_owned()).collect()
    }

    fn decoded(line: &serde_json::Value) -> Vec<u8> {
        base64::engine::general_purpose::STANDARD.decode(line["data"].as_str().unwrap()).unwrap()
    }

    fn screen_text(screen: &ScreenState) -> String {
        (0..screen.rows)
            .map(|row| screen.row(row).iter().map(|cell| cell.text.as_str()).collect::<String>())
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// Gives the surface's driver time to take what was sent it and pace out its datagrams.
    async fn settle() {
        tokio::time::sleep(Duration::from_millis(200)).await;
    }

    #[tokio::test]
    async fn viewport_link_vt_state_primes_and_announces_the_epoch() {
        let (mut link, datagrams, mut received) = rig(SelectorConfig::datagram_first(), false);
        link.on_line(vt_state(3, 20, 4, b"hello", b" world")).await.unwrap();
        assert!(link.syncing(3));
        settle().await;
        let lines = drain(&mut received);
        assert_eq!(events(&lines)[..3], ["vt-state", "viewport-sync", "viewport-path"]);
        assert_eq!(lines[1]["surface"], 3);
        assert_eq!(lines[2]["path"], "datagram");
        let epoch = lines[1]["epoch"].as_u64().unwrap();
        let sent = datagrams.sent.lock().unwrap().clone();
        assert!(!sent.is_empty(), "the primed screen goes as datagrams");
        let (header, _) = parse_diff_datagram(&sent[0]).unwrap();
        assert_eq!(u64::from(header.epoch), epoch);
        // The phone's receiver rebuilds the primed screen from them: data, then pending.
        let mut phone = SyncReceiver::new();
        for datagram in &sent {
            let _ = phone.on_datagram(datagram);
        }
        assert!(screen_text(phone.screen().unwrap()).starts_with("hello world"));
    }

    #[tokio::test]
    async fn viewport_link_outputs_go_as_datagrams_and_rows_as_history() {
        let (mut link, datagrams, mut received) = rig(SelectorConfig::datagram_first(), false);
        link.on_line(vt_state(1, 20, 4, b"", b"")).await.unwrap();
        for i in 0..12 {
            link.on_line(output(1, format!("row {i}\r\n").as_bytes())).await.unwrap();
        }
        settle().await;
        let lines = drain(&mut received);
        let kinds = events(&lines);
        assert!(!kinds.contains(&"output".to_owned()), "no output line forwarded: {kinds:?}");
        let history: Vec<u8> =
            lines.iter().filter(|line| line["event"] == "viewport-history").flat_map(decoded).collect();
        let history = String::from_utf8_lossy(&history);
        assert!(history.contains("row 0") && history.contains("row 8"), "{history:?}");
        assert!(!history.contains("row 11"), "row 11 is still on the screen: {history:?}");
        let mut phone = SyncReceiver::new();
        for datagram in datagrams.sent.lock().unwrap().iter() {
            let _ = phone.on_datagram(datagram);
        }
        assert!(screen_text(phone.screen().unwrap()).contains("row 11"));
    }

    #[tokio::test]
    async fn viewport_link_a_resize_ends_then_restarts_in_order() {
        let (mut link, _datagrams, mut received) = rig(SelectorConfig::datagram_first(), false);
        link.on_line(vt_state(1, 20, 4, b"one", b"")).await.unwrap();
        link.on_line(output(1, b" two")).await.unwrap();
        let resized = format!(
            "{{\"event\":\"resized\",\"surface\":1,\"cols\":30,\"rows\":5,\"replay\":\"{}\"}}\n",
            b64(b"one two")
        );
        link.on_line(resized.into_bytes()).await.unwrap();
        assert!(link.syncing(1));
        settle().await;
        let lines = drain(&mut received);
        let kinds = events(&lines);
        let at = |name: &str, from: usize| kinds.iter().skip(from).position(|k| k == name).map(|i| i + from);
        let end = at("viewport-sync-end", 0).expect("an end");
        // The datagram path's last screen in full, then the end, the resize, the new epoch.
        assert_eq!(kinds[end - 1], "output");
        assert!(String::from_utf8_lossy(&decoded(&lines[end - 1])).contains("one two"));
        assert_eq!(kinds[end + 1], "resized");
        assert_eq!(kinds[end + 2], "viewport-sync");
        assert_ne!(lines[end + 2]["epoch"], lines[1]["epoch"], "a new epoch");
        // A line without a replay ends it for good.
        link.on_line(b"{\"event\":\"resized\",\"surface\":1,\"cols\":30,\"rows\":6}\n".to_vec())
            .await
            .unwrap();
        assert!(!link.syncing(1));
    }

    #[tokio::test]
    async fn viewport_link_colors_end_and_restart_from_the_model() {
        let (mut link, _datagrams, mut received) = rig(SelectorConfig::datagram_first(), false);
        link.on_line(vt_state(1, 20, 4, b"abc", b"")).await.unwrap();
        link.on_line(b"{\"event\":\"colors-changed\",\"surface\":1,\"foreground\":\"#ffffff\"}\n".to_vec())
            .await
            .unwrap();
        assert!(link.syncing(1));
        settle().await;
        let kinds = events(&drain(&mut received));
        let end = kinds.iter().position(|k| k == "viewport-sync-end").unwrap();
        assert_eq!(kinds[end + 1..end + 3], ["colors-changed", "viewport-sync"]);
        // Detached: ended, not restarted.
        link.on_line(b"{\"event\":\"detached\",\"surface\":1}\n".to_vec()).await.unwrap();
        assert!(!link.syncing(1));
    }

    #[tokio::test]
    async fn viewport_link_agent_cli_and_hybrid_surfaces_never_sync() {
        let (mut link, datagrams, mut received) = rig(SelectorConfig::datagram_first(), false);
        link.on_line(b"{\"event\":\"agent-cli-frame\",\"surface\":5,\"frame\":1}\n".to_vec()).await.unwrap();
        link.on_line(vt_state(5, 20, 4, b"x", b"")).await.unwrap();
        link.hybrid_marks().observe(br#"{"cmd":"attach-surface","id":1,"surface":6,"hybrid_stream":"s"}"#);
        link.on_line(vt_state(6, 20, 4, b"y", b"")).await.unwrap();
        link.on_line(output(5, b"plain")).await.unwrap();
        assert!(!link.syncing(5) && !link.syncing(6));
        let kinds = events(&drain(&mut received));
        assert_eq!(kinds, ["agent-cli-frame", "vt-state", "vt-state", "output"]);
        assert!(datagrams.sent.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn viewport_link_stream_path_forwards_batches_and_stamps_only_when_asked() {
        // The default selector starts on the stream: every batch goes on, in order.
        for pseq in [false, true] {
            let (mut link, _datagrams, mut received) = rig(SelectorConfig::default(), pseq);
            link.on_line(vt_state(2, 20, 4, b"", b"")).await.unwrap();
            link.on_line(output(2, b"a")).await.unwrap();
            link.on_line(output(2, b"b")).await.unwrap();
            link.on_line(b"{\"id\":1,\"ok\":true}\n".to_vec()).await.unwrap();
            link.finish().await.unwrap();
            let lines = drain(&mut received);
            let outputs: Vec<&serde_json::Value> = lines.iter().filter(|l| l["event"] == "output").collect();
            assert_eq!(
                outputs.iter().map(|l| decoded(l)).collect::<Vec<_>>(),
                [b"a".to_vec(), b"b".to_vec()]
            );
            assert!(outputs.iter().all(|l| l.get("pseq").is_some() == pseq), "{outputs:?}");
            assert_eq!(events(&lines).last().map(String::as_str), Some("viewport-sync-end"));
        }
    }

    #[test]
    fn viewport_link_hybrid_marks_read_only_hybrid_attaches() {
        let marks = HybridMarks::default();
        marks.observe(br#"{"cmd":"attach-surface","id":1,"surface":7}"#);
        marks.observe(br#"{"cmd":"send","id":2,"surface":8,"bytes":"aHlicmlkXw=="}"#);
        marks.observe(br#"{"cmd":"attach-surface","id":3,"surface":9,"hybrid_frame":4}"#);
        assert!(!marks.contains(7) && !marks.contains(8) && marks.contains(9));
    }
}
