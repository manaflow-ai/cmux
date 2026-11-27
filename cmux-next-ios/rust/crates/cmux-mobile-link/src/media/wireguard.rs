//! The WireGuard carrier: RTP and RTCP as plain datagrams on overlay UDP
//! inside the tunnel (verify/browser-video-track.md, option A).
//!
//! - **No SRTP, no ICE, no DTLS.** WireGuard already authenticates and
//!   encrypts every datagram, and only the tunnel's peer (its overlay
//!   address) can reach the port.
//! - **One port, both directions.** RTP and RTCP share [`MEDIA_PORT`] on
//!   both sides and are told apart by the payload type byte (RFC 5761).
//!   RTP goes in cmux-wg's `Priority::Media` class (dropped after 50 ms in
//!   the send queue, so a congested tunnel loses stale video instead of
//!   delaying the link's TCP streams); RTCP goes as `Interactive`.
//! - **No SDP.** The stream is fixed by [`StreamSpec`]: payload type 102,
//!   the TWCC extension at id 1, and the sender's SSRC. Both sides agree by
//!   listing the `video` lane in `wg-init` / `wg-resp`.
//! - **The same interceptors as the track.** webrtc-rs's `interceptor`
//!   crate is used as a library: the registry the peer connection uses
//!   ([`super::track::interceptor_registry`]: NACK generator and responder,
//!   sender and receiver reports, TWCC feedback) is built once per carrier
//!   and bound to the socket here, which is what `RTCRtpSender` and
//!   `TrackRemote` do inside a peer connection.
//! - **MTU.** The tunnel's inner MTU is 1280, so the datagram service takes
//!   at most 1232 bytes. [`max_payload`] sizes RTP payloads so that a packet
//!   with its header and extensions never exceeds that; the datagram service
//!   refuses anything larger rather than fragment it, and this carrier counts
//!   such refusals ([`WgCarrierStats::oversize`]).
//! - **Roaming.** The socket belongs to the session's `WgNet`, which a roam
//!   keeps (only the underlay's UDP socket changes). Nothing is negotiated
//!   again. The session reports each roam (its own or the peer's) through
//!   [`super::MediaCarrier::path_changes`]: the receiver then asks for a
//!   keyframe and the sender forgets the bytes it had in flight on the old
//!   path.
//!
//! Nothing here is specific to browser tabs: a later Mac screen surface can
//! open the same carrier with its own [`StreamSpec`] (another SSRC and
//! overlay port, say 7423, so each stream keeps its own interceptor chain).

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use bytes::Bytes;
use cmux_wg::{Priority, WgDatagramSocket, WgNet};
use futures_util::future::BoxFuture;
use tokio::sync::{Mutex, mpsc, watch};
use tokio::task::JoinHandle;
use tokio::time::Instant;
use webrtc::interceptor::stream_info::{RTCPFeedback, RTPHeaderExtension, StreamInfo};
use webrtc::interceptor::{Attributes, Interceptor, RTCPReader, RTCPWriter, RTPReader, RTPWriter};
use webrtc::util::{Marshal, Unmarshal};

use super::{CarrierKind, MediaCarrier, MediaError, RtcpPackets, TWCC_URI, rtcp, rtp};

/// Overlay UDP port of the media lane on both sides, next to the link's
/// TCP 7420 and the roaming messages' 7421.
pub const MEDIA_PORT: u16 = 7422;
/// RTP fixed header.
const RTP_HEADER: usize = 12;
/// Room for header extensions: the one-byte extension block (4) with the
/// transport-wide sequence number (1 + 2, padded to 4), and spare for two
/// more extensions (say abs-send-time and playout-delay) a later sender may
/// add.
const RTP_EXTENSIONS: usize = 8 + 16;
/// Queued outgoing datagrams before senders wait.
const OUT_QUEUE: usize = 512;
/// Packets a receiving side holds for its consumer before dropping.
const IN_QUEUE: usize = 1024;

/// The largest RTP payload that fits one datagram of a tunnel whose
/// datagram service takes `max_datagram` bytes.
pub fn max_payload(max_datagram: usize) -> usize {
    max_datagram.saturating_sub(RTP_HEADER + RTP_EXTENSIONS)
}

/// The one stream a carrier moves: what SDP would say on WebRTC.
#[derive(Debug, Clone)]
pub struct StreamSpec {
    /// Overlay UDP port of the stream on both sides.
    pub port: u16,
    pub ssrc: u32,
    pub payload_type: u8,
    pub mime_type: String,
    pub clock_rate: u32,
    pub sdp_fmtp_line: String,
    pub twcc_ext_id: u8,
}

impl StreamSpec {
    /// Browser video: H.264 as the track sends it, the Mac's default SSRC.
    pub fn h264_video() -> Self {
        let codec = super::track::h264();
        Self {
            port: MEDIA_PORT,
            ssrc: super::SenderConfig::default().ssrc,
            payload_type: super::DEFAULT_PAYLOAD_TYPE,
            mime_type: codec.mime_type,
            clock_rate: codec.clock_rate,
            sdp_fmtp_line: codec.sdp_fmtp_line,
            twcc_ext_id: super::DEFAULT_TWCC_EXT_ID,
        }
    }

    fn info(&self) -> StreamInfo {
        let feedback = |typ: &str, parameter: &str| RTCPFeedback {
            typ: typ.to_owned(),
            parameter: parameter.to_owned(),
        };
        StreamInfo {
            id: format!("cmux-mobile-wg-{:08x}", self.ssrc),
            ssrc: self.ssrc,
            payload_type: self.payload_type,
            rtp_header_extensions: vec![RTPHeaderExtension {
                uri: TWCC_URI.to_owned(),
                id: isize::from(self.twcc_ext_id),
            }],
            mime_type: self.mime_type.clone(),
            clock_rate: self.clock_rate,
            sdp_fmtp_line: self.sdp_fmtp_line.clone(),
            rtcp_feedback: vec![
                feedback("nack", ""),
                feedback("nack", "pli"),
                feedback("ccm", "fir"),
                feedback("transport-cc", ""),
            ],
            ..StreamInfo::default()
        }
    }
}

/// Which way the stream flows on this side.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    /// This side sends RTP and reads RTCP (the Mac).
    Send,
    /// This side reads RTP and sends RTCP (the phone).
    Receive,
}

/// Test and measurement support: what the path does to this side's
/// outgoing RTP, below the NACK responder (so resends meet it too).
#[derive(Debug, Clone, Copy, Default)]
pub struct Impairment {
    /// Drop this many of every 1000 RTP packets.
    pub drop_permille: u32,
    /// A bottleneck of this many bits per second with a 250 ms queue
    /// (packets that would wait longer are dropped); 0 means none.
    pub cap_bps: u64,
    /// Drop every RTP packet first sent from `.0` after the carrier's first
    /// RTP packet for `.1`, and every later resend of those: a loss no NACK
    /// recovers.
    pub blackout: Option<(Duration, Duration)>,
}

impl Impairment {
    pub fn is_none(&self) -> bool {
        self.drop_permille == 0 && self.cap_bps == 0 && self.blackout.is_none()
    }
}

/// Counters of a WireGuard carrier.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct WgCarrierStats {
    pub rtp_sent: u64,
    pub rtcp_sent: u64,
    pub rtp_received: u64,
    pub rtcp_received: u64,
    /// Datagrams that did not parse, or came from another SSRC or address.
    pub ignored: u64,
    /// Packets larger than the tunnel's datagram limit (never sent). Always
    /// 0 unless a sender ignores [`super::MediaCarrier::max_payload`].
    pub oversize: u64,
    /// RTP the test impairment dropped.
    pub impaired: u64,
}

#[derive(Default)]
struct Counters {
    rtp_sent: AtomicU64,
    rtcp_sent: AtomicU64,
    rtp_received: AtomicU64,
    rtcp_received: AtomicU64,
    ignored: AtomicU64,
    oversize: AtomicU64,
    impaired: AtomicU64,
}

impl Counters {
    fn add(counter: &AtomicU64) {
        counter.fetch_add(1, Ordering::Relaxed);
    }

    fn snapshot(&self) -> WgCarrierStats {
        let load = |c: &AtomicU64| c.load(Ordering::Relaxed);
        WgCarrierStats {
            rtp_sent: load(&self.rtp_sent),
            rtcp_sent: load(&self.rtcp_sent),
            rtp_received: load(&self.rtp_received),
            rtcp_received: load(&self.rtcp_received),
            ignored: load(&self.ignored),
            oversize: load(&self.oversize),
            impaired: load(&self.impaired),
        }
    }
}

/// One outgoing datagram for the socket task.
struct Outgoing {
    bytes: Bytes,
    priority: Priority,
}

/// RTP and RTCP on one overlay UDP port of a WireGuard tunnel.
pub struct WgCarrier {
    direction: Direction,
    spec: StreamSpec,
    max_payload: usize,
    /// Send side: the interceptor chain's writer for the local stream.
    rtp_out: Option<Arc<dyn RTPWriter + Send + Sync>>,
    /// The chain's RTCP writer (PLIs from the receiver core go here).
    rtcp_out: Arc<dyn RTCPWriter + Send + Sync>,
    /// What the chain let through, pumped by tasks so a reader that stops
    /// waiting never loses a packet half way through the chain.
    rtp_in: Mutex<mpsc::Receiver<rtp::packet::Packet>>,
    rtcp_in: Mutex<mpsc::Receiver<RtcpPackets>>,
    path: watch::Receiver<u64>,
    counters: Arc<Counters>,
    interceptor: Arc<dyn Interceptor + Send + Sync>,
    tasks: Vec<JoinHandle<()>>,
}

impl std::fmt::Debug for WgCarrier {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WgCarrier")
            .field("direction", &self.direction)
            .field("ssrc", &self.spec.ssrc)
            .field("max_payload", &self.max_payload)
            .finish_non_exhaustive()
    }
}

impl Drop for WgCarrier {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
        let interceptor = Arc::clone(&self.interceptor);
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                let _ = interceptor.close().await;
            });
        }
    }
}

fn other(error: impl std::fmt::Display) -> MediaError {
    MediaError::Other(error.to_string())
}

/// RTCP packet types are 192 to 223 in the second byte, which RTP's marker
/// plus payload type never uses for dynamic types (RFC 5761 §4).
fn is_rtcp(datagram: &[u8]) -> bool {
    datagram.len() >= 8 && (192..=223).contains(&datagram[1])
}

impl WgCarrier {
    /// Binds the stream's port on `net` and wires the interceptors for one
    /// stream toward `peer_ip`. `path` counts the session's roams.
    pub async fn open(
        net: &WgNet,
        peer_ip: IpAddr,
        direction: Direction,
        spec: StreamSpec,
        path: watch::Receiver<u64>,
        impairment: Impairment,
    ) -> Result<Arc<Self>, MediaError> {
        let socket = net.bind_datagram(spec.port).await.map_err(other)?;
        let max_datagram = socket.max_datagram();
        let max_payload = max_payload(max_datagram);
        let peer = SocketAddr::new(peer_ip, spec.port);
        let counters = Arc::new(Counters::default());
        let (out_tx, out_rx) = mpsc::channel::<Outgoing>(OUT_QUEUE);
        let (raw_rtp_tx, raw_rtp_rx) = mpsc::channel::<rtp::packet::Packet>(IN_QUEUE);
        let (raw_rtcp_tx, raw_rtcp_rx) = mpsc::channel::<RtcpPackets>(IN_QUEUE);
        let mut tasks = vec![tokio::spawn(socket_task(
            socket,
            peer,
            spec.ssrc,
            direction,
            out_rx,
            raw_rtp_tx,
            raw_rtcp_tx,
            Arc::clone(&counters),
        ))];

        // Impairment (tests and measurement) sits below the chain, as the
        // path does; the drop share is the same interceptor the track uses.
        let rtp_base: Arc<dyn RTPWriter + Send + Sync> =
            if impairment.cap_bps > 0 || impairment.blackout.is_some() {
                let (shaped_tx, shaped_rx) = mpsc::channel(OUT_QUEUE);
                tasks.push(tokio::spawn(shaper(shaped_rx, out_tx.clone())));
                Arc::new(ShapedRtpWriter {
                    shaper: std::sync::Mutex::new(Shaper::new(impairment)),
                    out: shaped_tx,
                    max_datagram,
                    counters: Arc::clone(&counters),
                })
            } else {
                Arc::new(RtpToSocket { out: out_tx.clone(), max_datagram, counters: Arc::clone(&counters) })
            };
        let rtcp_base: Arc<dyn RTCPWriter + Send + Sync> =
            Arc::new(RtcpToSocket { out: out_tx, max_datagram, counters: Arc::clone(&counters) });

        let interceptor =
            super::track::interceptor_registry(impairment.drop_permille).build("").map_err(other)?;
        // As a peer connection does: the RTCP writer first (the generator
        // and the TWCC receiver start their loops on it), then the reader,
        // then the stream.
        let rtcp_out = interceptor.bind_rtcp_writer(rtcp_base).await;
        let rtcp_chain =
            interceptor.bind_rtcp_reader(Arc::new(ChannelReader { rx: Mutex::new(raw_rtcp_rx) })).await;
        let info = spec.info();
        let (rtcp_tx, rtcp_rx) = mpsc::channel(IN_QUEUE);
        tasks.push(tokio::spawn(pump_rtcp(rtcp_chain, rtcp_tx, direction)));
        let (rtp_tx, rtp_rx) = mpsc::channel(IN_QUEUE);
        let rtp_out = match direction {
            Direction::Send => {
                drop(raw_rtp_rx);
                drop(rtp_tx);
                Some(interceptor.bind_local_stream(&info, rtp_base).await)
            }
            Direction::Receive => {
                let chain = interceptor
                    .bind_remote_stream(&info, Arc::new(ChannelReader { rx: Mutex::new(raw_rtp_rx) }))
                    .await;
                tasks.push(tokio::spawn(pump_rtp(chain, rtp_tx)));
                None
            }
        };
        Ok(Arc::new(Self {
            direction,
            spec,
            max_payload,
            rtp_out,
            rtcp_out,
            rtp_in: Mutex::new(rtp_rx),
            rtcp_in: Mutex::new(rtcp_rx),
            path,
            counters,
            interceptor,
            tasks,
        }))
    }

    pub fn stats(&self) -> WgCarrierStats {
        self.counters.snapshot()
    }

    pub fn direction(&self) -> Direction {
        self.direction
    }
}

impl MediaCarrier for WgCarrier {
    fn kind(&self) -> CarrierKind {
        CarrierKind::WireGuardUdp
    }

    fn twcc_ext_id(&self) -> u8 {
        self.spec.twcc_ext_id
    }

    fn max_payload(&self) -> usize {
        self.max_payload
    }

    fn path_changes(&self) -> Option<watch::Receiver<u64>> {
        Some(self.path.clone())
    }

    fn send_rtp<'a>(&'a self, packet: &'a rtp::packet::Packet) -> BoxFuture<'a, Result<(), MediaError>> {
        Box::pin(async move {
            let writer = self.rtp_out.as_ref().ok_or(MediaError::Unsupported)?;
            match writer.write(packet, &Attributes::new()).await {
                Ok(_) => Ok(()),
                Err(webrtc::interceptor::Error::ErrIoEOF) => Err(MediaError::Closed),
                // A packet that could not go is lost like a dropped one.
                Err(_) => Ok(()),
            }
        })
    }

    fn send_rtcp(&self, packets: RtcpPackets) -> BoxFuture<'_, Result<(), MediaError>> {
        Box::pin(async move {
            match self.rtcp_out.write(&packets, &Attributes::new()).await {
                Ok(_) => Ok(()),
                Err(webrtc::interceptor::Error::ErrIoEOF) => Err(MediaError::Closed),
                Err(_) => Ok(()),
            }
        })
    }

    fn recv_rtp(&self) -> BoxFuture<'_, Option<rtp::packet::Packet>> {
        Box::pin(async move { self.rtp_in.lock().await.recv().await })
    }

    fn recv_rtcp(&self) -> BoxFuture<'_, Option<RtcpPackets>> {
        Box::pin(async move { self.rtcp_in.lock().await.recv().await })
    }
}

/// Owns the socket: sends what the writers queue, and sorts what arrives
/// into RTP and RTCP.
#[allow(clippy::too_many_arguments)]
async fn socket_task(
    mut socket: WgDatagramSocket,
    peer: SocketAddr,
    ssrc: u32,
    direction: Direction,
    mut out: mpsc::Receiver<Outgoing>,
    rtp: mpsc::Sender<rtp::packet::Packet>,
    rtcp: mpsc::Sender<RtcpPackets>,
    counters: Arc<Counters>,
) {
    loop {
        tokio::select! {
            outgoing = out.recv() => {
                let Some(outgoing) = outgoing else { return };
                if let Err(error) = socket.send_to(&outgoing.bytes, peer, outgoing.priority).await {
                    match error {
                        cmux_wg::WgError::DatagramTooLarge { .. } => Counters::add(&counters.oversize),
                        cmux_wg::WgError::Shutdown => return,
                        _ => tracing::debug!(%error, "media datagram not sent"),
                    }
                }
            }
            received = socket.recv_from() => {
                // The tunnel is gone.
                let Some((payload, from)) = received else { return };
                if from.ip() != peer.ip() {
                    Counters::add(&counters.ignored);
                    continue;
                }
                if is_rtcp(&payload) {
                    let mut bytes = Bytes::from(payload);
                    match rtcp::packet::unmarshal(&mut bytes) {
                        Ok(packets) => {
                            Counters::add(&counters.rtcp_received);
                            // A full queue drops feedback; the next one covers it.
                            let _ = rtcp.try_send(packets);
                        }
                        Err(_) => Counters::add(&counters.ignored),
                    }
                    continue;
                }
                if direction != Direction::Receive {
                    Counters::add(&counters.ignored);
                    continue;
                }
                match rtp::packet::Packet::unmarshal(&mut payload.as_slice()) {
                    Ok(packet) if packet.header.ssrc == ssrc => {
                        Counters::add(&counters.rtp_received);
                        let _ = rtp.try_send(packet);
                    }
                    _ => Counters::add(&counters.ignored),
                }
            }
        }
    }
}

/// Reads one side of the interceptor chain until it ends. The receiving
/// side has no consumer of RTCP (its sender reports only feed the receiver
/// report interceptor), so it drains.
async fn pump_rtcp(
    chain: Arc<dyn RTCPReader + Send + Sync>,
    tx: mpsc::Sender<RtcpPackets>,
    direction: Direction,
) {
    let mut buf = vec![0u8; 1500];
    loop {
        match chain.read(&mut buf, &Attributes::new()).await {
            Ok((packets, _)) => {
                if direction == Direction::Send && tx.send(packets).await.is_err() {
                    return;
                }
            }
            Err(_) => return,
        }
    }
}

async fn pump_rtp(chain: Arc<dyn RTPReader + Send + Sync>, tx: mpsc::Sender<rtp::packet::Packet>) {
    let mut buf = vec![0u8; 1500];
    loop {
        match chain.read(&mut buf, &Attributes::new()).await {
            Ok((packet, _)) => {
                if tx.send(packet).await.is_err() {
                    return;
                }
            }
            Err(_) => return,
        }
    }
}

/// The bottom of an incoming chain: what the socket task sorted.
struct ChannelReader<T> {
    rx: Mutex<mpsc::Receiver<T>>,
}

#[async_trait::async_trait]
impl RTPReader for ChannelReader<rtp::packet::Packet> {
    async fn read(
        &self,
        _buf: &mut [u8],
        attributes: &Attributes,
    ) -> Result<(rtp::packet::Packet, Attributes), webrtc::interceptor::Error> {
        let packet = self.rx.lock().await.recv().await.ok_or(webrtc::interceptor::Error::ErrIoEOF)?;
        Ok((packet, attributes.clone()))
    }
}

#[async_trait::async_trait]
impl RTCPReader for ChannelReader<RtcpPackets> {
    async fn read(
        &self,
        _buf: &mut [u8],
        attributes: &Attributes,
    ) -> Result<(RtcpPackets, Attributes), webrtc::interceptor::Error> {
        let packets = self.rx.lock().await.recv().await.ok_or(webrtc::interceptor::Error::ErrIoEOF)?;
        Ok((packets, attributes.clone()))
    }
}

/// Serializes an RTP packet, refusing one the tunnel cannot carry whole.
fn rtp_datagram(
    packet: &rtp::packet::Packet,
    max_datagram: usize,
    counters: &Counters,
) -> Result<Option<Bytes>, webrtc::interceptor::Error> {
    let bytes = packet.marshal()?;
    if bytes.len() > max_datagram {
        Counters::add(&counters.oversize);
        tracing::warn!(len = bytes.len(), max_datagram, "RTP packet larger than the tunnel's datagram limit");
        return Ok(None);
    }
    Ok(Some(bytes))
}

/// The bottom of the outgoing RTP chain: the socket, as media.
struct RtpToSocket {
    out: mpsc::Sender<Outgoing>,
    max_datagram: usize,
    counters: Arc<Counters>,
}

#[async_trait::async_trait]
impl RTPWriter for RtpToSocket {
    async fn write(
        &self,
        packet: &rtp::packet::Packet,
        _attributes: &Attributes,
    ) -> Result<usize, webrtc::interceptor::Error> {
        let Some(bytes) = rtp_datagram(packet, self.max_datagram, &self.counters)? else { return Ok(0) };
        let len = bytes.len();
        self.out
            .send(Outgoing { bytes, priority: Priority::Media })
            .await
            .map_err(|_| webrtc::interceptor::Error::ErrIoEOF)?;
        Counters::add(&self.counters.rtp_sent);
        Ok(len)
    }
}

/// The bottom of the RTCP chain: the socket, ahead of media. A compound
/// too large for one datagram goes packet by packet.
struct RtcpToSocket {
    out: mpsc::Sender<Outgoing>,
    max_datagram: usize,
    counters: Arc<Counters>,
}

#[async_trait::async_trait]
impl RTCPWriter for RtcpToSocket {
    async fn write(
        &self,
        packets: &[Box<dyn rtcp::packet::Packet + Send + Sync>],
        _attributes: &Attributes,
    ) -> Result<usize, webrtc::interceptor::Error> {
        let whole = rtcp::packet::marshal(packets)?;
        let datagrams = if whole.len() <= self.max_datagram {
            vec![whole]
        } else {
            let mut parts = Vec::with_capacity(packets.len());
            for packet in packets {
                let bytes = packet.marshal()?;
                if bytes.len() <= self.max_datagram {
                    parts.push(bytes);
                } else {
                    Counters::add(&self.counters.oversize);
                }
            }
            parts
        };
        let mut len = 0;
        for bytes in datagrams {
            len += bytes.len();
            self.out
                .send(Outgoing { bytes, priority: Priority::Interactive })
                .await
                .map_err(|_| webrtc::interceptor::Error::ErrIoEOF)?;
            Counters::add(&self.counters.rtcp_sent);
        }
        Ok(len)
    }
}

/// A bottleneck and blackout in front of the socket (tests and measurement).
struct Shaper {
    impairment: Impairment,
    /// When the first packet went (the blackout's clock).
    first: Option<Instant>,
    next_free: Instant,
    /// Sequence numbers the blackout took (so their resends die too).
    blacked_out: std::collections::HashSet<u16>,
    /// The shaper task is gone.
    closed: bool,
}

/// Longest a packet waits in the emulated bottleneck's queue.
const SHAPER_QUEUE: Duration = Duration::from_millis(250);

impl Shaper {
    fn new(impairment: Impairment) -> Self {
        let now = Instant::now();
        Self {
            impairment,
            first: None,
            next_free: now,
            blacked_out: std::collections::HashSet::new(),
            closed: false,
        }
    }

    /// When packet `seq` of `len` bytes sent at `now` leaves the bottleneck,
    /// or `None` when the path drops it.
    fn depart(&mut self, seq: u16, len: usize, now: Instant) -> Option<Instant> {
        if let Some((start, length)) = self.impairment.blackout {
            let since = now.duration_since(*self.first.get_or_insert(now));
            if since >= start && since < start + length {
                self.blacked_out.insert(seq);
            }
            if self.blacked_out.contains(&seq) {
                return None;
            }
        }
        if self.impairment.cap_bps == 0 {
            return Some(now);
        }
        let start = self.next_free.max(now);
        if start.duration_since(now) > SHAPER_QUEUE {
            return None;
        }
        // The IPv4, UDP and WireGuard overhead rides the bottleneck too.
        let bits = (len + 20 + 8 + 32) as f64 * 8.0;
        self.next_free = start + Duration::from_secs_f64(bits / self.impairment.cap_bps as f64);
        Some(self.next_free)
    }
}

struct ShapedRtpWriter {
    shaper: std::sync::Mutex<Shaper>,
    out: mpsc::Sender<(Instant, Bytes)>,
    max_datagram: usize,
    counters: Arc<Counters>,
}

#[async_trait::async_trait]
impl RTPWriter for ShapedRtpWriter {
    async fn write(
        &self,
        packet: &rtp::packet::Packet,
        _attributes: &Attributes,
    ) -> Result<usize, webrtc::interceptor::Error> {
        let Some(bytes) = rtp_datagram(packet, self.max_datagram, &self.counters)? else { return Ok(0) };
        let len = bytes.len();
        // Queue under the lock, so concurrent writers (the sender and the
        // NACK responder's resends) leave in departure order. A full queue
        // drops, as the bottleneck's own queue would.
        let mut shaper = self.shaper.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let queued = match shaper.depart(packet.header.sequence_number, len, Instant::now()) {
            None => false,
            Some(depart) => match self.out.try_send((depart, bytes)) {
                Ok(()) => true,
                Err(mpsc::error::TrySendError::Full(_)) => false,
                Err(mpsc::error::TrySendError::Closed(_)) => {
                    shaper.closed = true;
                    false
                }
            },
        };
        let closed = shaper.closed;
        drop(shaper);
        if closed {
            return Err(webrtc::interceptor::Error::ErrIoEOF);
        }
        Counters::add(if queued { &self.counters.rtp_sent } else { &self.counters.impaired });
        Ok(len)
    }
}

/// Releases shaped packets at their departure times, in order.
async fn shaper(mut rx: mpsc::Receiver<(Instant, Bytes)>, out: mpsc::Sender<Outgoing>) {
    while let Some((depart, bytes)) = rx.recv().await {
        // The emulated link's serialization delay: an intentional, bounded wait.
        tokio::time::sleep_until(depart).await;
        if out.send(Outgoing { bytes, priority: Priority::Media }).await.is_err() {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rtp_and_rtcp_are_told_apart_by_the_payload_type_byte() {
        let pli = rtcp::payload_feedbacks::picture_loss_indication::PictureLossIndication {
            sender_ssrc: 1,
            media_ssrc: 2,
        };
        let packets: RtcpPackets = vec![Box::new(pli)];
        assert!(is_rtcp(&rtcp::packet::marshal(&packets).unwrap()));
        for marker in [false, true] {
            let rtp = rtp::packet::Packet {
                header: rtp::header::Header {
                    version: 2,
                    marker,
                    payload_type: super::super::DEFAULT_PAYLOAD_TYPE,
                    ..Default::default()
                },
                payload: Bytes::from_static(&[1, 2, 3]),
            };
            assert!(!is_rtcp(&rtp.marshal().unwrap()));
        }
    }

    /// The largest packet the sender makes fits the 1280-byte tunnel's
    /// datagram service (1232 bytes) with room for more extensions.
    #[test]
    fn a_full_rtp_packet_fits_one_tunnel_datagram() {
        let max_datagram = 1280 - 48;
        let payload = max_payload(max_datagram);
        assert!(payload >= 1100, "{payload}");
        let mut packet = rtp::packet::Packet {
            header: rtp::header::Header {
                version: 2,
                payload_type: super::super::DEFAULT_PAYLOAD_TYPE,
                ..Default::default()
            },
            payload: Bytes::from(vec![7u8; payload]),
        };
        packet.header.set_extension(1, Bytes::from_static(&[0, 1])).unwrap();
        packet.header.set_extension(2, Bytes::from_static(&[0, 1, 2])).unwrap();
        packet.header.set_extension(3, Bytes::from_static(&[0])).unwrap();
        assert!(packet.marshal().unwrap().len() <= max_datagram);
    }

    #[test]
    fn the_bottleneck_paces_and_drops_past_its_queue() {
        let mut shaper = Shaper::new(Impairment { cap_bps: 1_000_000, ..Impairment::default() });
        let now = shaper.next_free;
        // 1000 + 60 bytes at 1 Mbit/s: about 8.5 ms each.
        let first = shaper.depart(0, 1000, now).unwrap();
        let second = shaper.depart(0, 1000, now).unwrap();
        let gap = second.duration_since(first);
        assert!((8_000..9_000).contains(&gap.as_micros()), "{gap:?}");
        let mut dropped = 0;
        for _ in 0..100 {
            if shaper.depart(0, 1000, now).is_none() {
                dropped += 1;
            }
        }
        // About 250 ms of queue: 29 packets; the rest are dropped.
        assert!((60..=75).contains(&dropped), "{dropped}");
    }

    #[test]
    fn a_blackout_drops_its_window_and_the_resends_of_it() {
        let mut shaper = Shaper::new(Impairment {
            blackout: Some((Duration::from_millis(100), Duration::from_millis(50))),
            ..Impairment::default()
        });
        let t0 = Instant::now();
        let ms = |n| t0 + Duration::from_millis(n);
        // The clock starts at the first packet.
        assert!(shaper.depart(0, 100, ms(0)).is_some());
        assert!(shaper.depart(1, 100, ms(99)).is_some());
        assert!(shaper.depart(2, 100, ms(100)).is_none());
        assert!(shaper.depart(3, 100, ms(149)).is_none());
        assert!(shaper.depart(4, 100, ms(150)).is_some());
        // NACKed later: still lost. Packet 1 resent: goes.
        assert!(shaper.depart(2, 100, ms(300)).is_none());
        assert!(shaper.depart(3, 100, ms(300)).is_none());
        assert!(shaper.depart(1, 100, ms(300)).is_some());
    }
}
