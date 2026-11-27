//! The WebRTC carrier: a video track on the link's own peer connection, so
//! video shares the link's ICE pair (direct or TURN), DTLS keys and
//! congestion of the path, with no second session.
//!
//! The phone's offer has one `recvonly` H.264 transceiver and lists
//! [`super::VIDEO_LANE`]; a Mac that streams browser video adds a
//! `sendonly` track before it applies the offer, so the answer's m-line
//! sends, and lists the lane back. An older Mac answers without the lane
//! (its empty media engine rejects the m-line) and the phone keeps the
//! reliable path.
//!
//! From webrtc-rs as is: SRTP, the RTP and RTCP routing per SSRC, the NACK
//! generator (phone) and responder with its history (Mac), TWCC feedback
//! (phone), sender and receiver reports.

use std::sync::Arc;
use std::time::Duration;

use futures_util::future::BoxFuture;
use tokio::sync::{Mutex, mpsc};
use webrtc::api::APIBuilder;
use webrtc::api::interceptor_registry::configure_rtcp_reports;
use webrtc::api::media_engine::{MIME_TYPE_H264, MediaEngine};
use webrtc::interceptor::nack::generator::Generator;
use webrtc::interceptor::nack::responder::Responder;
use webrtc::interceptor::registry::Registry;
use webrtc::interceptor::twcc::receiver::Receiver as TwccReceiver;
use webrtc::peer_connection::RTCPeerConnection;
use webrtc::rtp_transceiver::rtp_codec::{
    RTCRtpCodecCapability, RTCRtpCodecParameters, RTCRtpHeaderExtensionCapability, RTPCodecType,
};
use webrtc::rtp_transceiver::rtp_sender::RTCRtpSender;
use webrtc::rtp_transceiver::rtp_transceiver_direction::RTCRtpTransceiverDirection;
use webrtc::rtp_transceiver::{RTCPFeedback, RTCRtpTransceiverInit};
use webrtc::track::track_local::TrackLocalWriter;
use webrtc::track::track_local::track_local_static_rtp::TrackLocalStaticRTP;
use webrtc::track::track_remote::TrackRemote;

use super::{CarrierKind, MediaCarrier, MediaError, RtcpPackets, TWCC_URI, rtp};

/// The NACK generator's interval: a lost packet is asked for again this
/// often while it is missing.
pub const NACK_INTERVAL: Duration = Duration::from_millis(20);
/// TWCC feedback interval (webrtc-rs's default is 100 ms; the delay-based
/// controller wants fresher samples).
pub const TWCC_INTERVAL: Duration = Duration::from_millis(25);

pub(super) fn h264() -> RTCRtpCodecCapability {
    RTCRtpCodecCapability {
        mime_type: MIME_TYPE_H264.to_owned(),
        clock_rate: super::CLOCK_RATE,
        channels: 0,
        sdp_fmtp_line: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640034".to_owned(),
        rtcp_feedback: vec![
            RTCPFeedback { typ: "nack".to_owned(), parameter: String::new() },
            RTCPFeedback { typ: "nack".to_owned(), parameter: "pli".to_owned() },
            RTCPFeedback { typ: "ccm".to_owned(), parameter: "fir".to_owned() },
            RTCPFeedback { typ: "transport-cc".to_owned(), parameter: String::new() },
        ],
    }
}

/// An API with H.264 video, TWCC and the interceptors the media lane uses.
/// `drop_permille` (test and measurement support) drops that share of
/// outgoing RTP below the NACK responder, as a lossy path would.
pub(crate) fn api_builder(
    settings: webrtc::api::setting_engine::SettingEngine,
    drop_permille: u32,
) -> Result<APIBuilder, MediaError> {
    let error = |e: webrtc::Error| MediaError::Other(e.to_string());
    let mut media = MediaEngine::default();
    media
        .register_codec(
            RTCRtpCodecParameters {
                capability: h264(),
                payload_type: super::DEFAULT_PAYLOAD_TYPE,
                ..Default::default()
            },
            RTPCodecType::Video,
        )
        .map_err(error)?;
    media
        .register_header_extension(
            RTCRtpHeaderExtensionCapability { uri: TWCC_URI.to_owned() },
            RTPCodecType::Video,
            None,
        )
        .map_err(error)?;
    Ok(APIBuilder::new()
        .with_setting_engine(settings)
        .with_media_engine(media)
        .with_interceptor_registry(interceptor_registry(drop_permille)))
}

/// The media lane's interceptors, the same on every carrier: the NACK
/// responder and its history with a bound on resends (sender), the NACK generator (receiver),
/// sender and receiver reports, and TWCC feedback (receiver). Each binds
/// only to the streams it serves. `drop_permille` (test and measurement
/// support) drops that share of outgoing RTP below the responder.
pub(super) fn interceptor_registry(drop_permille: u32) -> Registry {
    let mut registry = Registry::new();
    // Interceptors added first sit closest to the network.
    if drop_permille > 0 {
        registry.add(Box::new(LossBuilder { permille: drop_permille }));
    }
    // Bounds the responder's resends (resend.rs).
    registry.add(Box::new(super::resend::ResendGuardBuilder));
    registry.add(Box::new(Responder::builder()));
    // 512 packets (2^(3+6)): a gap older than that is not asked for again.
    registry.add(Box::new(Generator::builder().with_interval(NACK_INTERVAL).with_log2_size_minus_6(3)));
    registry = configure_rtcp_reports(registry);
    registry.add(Box::new(TwccReceiver::builder().with_interval(TWCC_INTERVAL)));
    registry
}

/// Phone side, before the offer: the receiving transceiver. The track
/// arrives through `on_track` once media flows.
pub(crate) async fn add_receiver(pc: &RTCPeerConnection) -> Result<Arc<ReceiveCarrier>, MediaError> {
    pc.add_transceiver_from_kind(
        RTPCodecType::Video,
        Some(RTCRtpTransceiverInit {
            direction: RTCRtpTransceiverDirection::Recvonly,
            send_encodings: Vec::new(),
        }),
    )
    .await
    .map_err(|e| MediaError::Other(e.to_string()))?;
    // A task reads each video track into a queue: `recv_rtp` is polled in a
    // `select!` that drops it often, and a read dropped half way through the
    // interceptor chain (the TWCC receiver awaits its own queue after the
    // NACK generator already counted the packet as arrived) would lose the
    // packet without a NACK.
    let (rtp_tx, rtp_rx) = mpsc::channel(1024);
    pc.on_track(Box::new(move |track: Arc<TrackRemote>, _, _| {
        if track.kind() == RTPCodecType::Video {
            let rtp_tx = rtp_tx.clone();
            tokio::spawn(async move {
                while let Ok((packet, _)) = track.read_rtp().await {
                    if rtp_tx.send(packet).await.is_err() {
                        return;
                    }
                }
            });
        }
        Box::pin(async {})
    }));
    Ok(Arc::new(ReceiveCarrier { pc: Mutex::new(None), rtp: Mutex::new(rtp_rx) }))
}

/// Mac side, before applying an offer with the lane: the sending track.
pub(crate) async fn add_sender(
    pc: &RTCPeerConnection,
) -> Result<(Arc<TrackLocalStaticRTP>, Arc<RTCRtpSender>), MediaError> {
    let track =
        Arc::new(TrackLocalStaticRTP::new(h264(), "browser".to_owned(), "cmux-mobile-video".to_owned()));
    let transceiver = pc
        .add_transceiver_from_track(
            Arc::clone(&track) as Arc<dyn webrtc::track::track_local::TrackLocal + Send + Sync>,
            Some(RTCRtpTransceiverInit {
                direction: RTCRtpTransceiverDirection::Sendonly,
                send_encodings: Vec::new(),
            }),
        )
        .await
        .map_err(|e| MediaError::Other(e.to_string()))?;
    Ok((track, transceiver.sender().await))
}

/// The Mac's carrier: RTP out on the track, RTCP in from its sender.
pub struct SendCarrier {
    track: Arc<TrackLocalStaticRTP>,
    sender: Arc<RTCRtpSender>,
    ext_id: u8,
}

impl SendCarrier {
    /// After the local description is set (the extension ids are agreed).
    pub(crate) async fn new(track: Arc<TrackLocalStaticRTP>, sender: Arc<RTCRtpSender>) -> Arc<Self> {
        let params = sender.get_parameters().await;
        let ext_id = params
            .rtp_parameters
            .header_extensions
            .iter()
            .find(|e| e.uri == TWCC_URI)
            .and_then(|e| u8::try_from(e.id).ok())
            .unwrap_or(super::DEFAULT_TWCC_EXT_ID);
        Arc::new(Self { track, sender, ext_id })
    }
}

/// Test and measurement support (Mac side): while set, every WebRTC track
/// drops its outgoing RTP and the RTCP it receives, as a path that died
/// under a connected peer connection would. The media lane's route then
/// stalls and video moves to the WireGuard tunnel (media/routes.rs).
static BLACKHOLE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[doc(hidden)]
pub fn set_blackhole(on: bool) {
    BLACKHOLE.store(on, std::sync::atomic::Ordering::Relaxed);
}

#[doc(hidden)]
pub fn blackhole() -> bool {
    BLACKHOLE.load(std::sync::atomic::Ordering::Relaxed)
}

impl MediaCarrier for SendCarrier {
    fn kind(&self) -> CarrierKind {
        CarrierKind::WebRtcTrack
    }

    fn twcc_ext_id(&self) -> u8 {
        self.ext_id
    }

    fn send_rtp<'a>(&'a self, packet: &'a rtp::packet::Packet) -> BoxFuture<'a, Result<(), MediaError>> {
        Box::pin(async move {
            if blackhole() {
                return Ok(());
            }
            match self.track.write_rtp(packet).await {
                Ok(_) => Ok(()),
                Err(webrtc::Error::ErrClosedPipe) => Err(MediaError::Closed),
                // No binding yet (DTLS still finishing) or a full buffer:
                // the frame is lost like a dropped packet.
                Err(_) => Ok(()),
            }
        })
    }

    fn send_rtcp(&self, _packets: RtcpPackets) -> BoxFuture<'_, Result<(), MediaError>> {
        Box::pin(async { Ok(()) })
    }

    fn recv_rtp(&self) -> BoxFuture<'_, Option<rtp::packet::Packet>> {
        Box::pin(std::future::pending())
    }

    fn recv_rtcp(&self) -> BoxFuture<'_, Option<RtcpPackets>> {
        Box::pin(async move {
            loop {
                let packets = self.sender.read_rtcp().await.ok().map(|(packets, _)| packets)?;
                if !blackhole() {
                    return Some(packets);
                }
            }
        })
    }
}

/// Drops a share of outgoing RTP (test and measurement support).
struct LossBuilder {
    permille: u32,
}

impl webrtc::interceptor::InterceptorBuilder for LossBuilder {
    fn build(
        &self,
        _id: &str,
    ) -> Result<Arc<dyn webrtc::interceptor::Interceptor + Send + Sync>, webrtc::interceptor::Error> {
        Ok(Arc::new(Loss { permille: self.permille }))
    }
}

struct Loss {
    permille: u32,
}

struct LossWriter {
    permille: u32,
    next: Arc<dyn webrtc::interceptor::RTPWriter + Send + Sync>,
    count: std::sync::atomic::AtomicU64,
}

#[async_trait::async_trait]
impl webrtc::interceptor::RTPWriter for LossWriter {
    async fn write(
        &self,
        packet: &rtp::packet::Packet,
        attributes: &webrtc::interceptor::Attributes,
    ) -> Result<usize, webrtc::interceptor::Error> {
        let n = self.count.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        if drop_this(n, self.permille) {
            return Ok(0);
        }
        self.next.write(packet, attributes).await
    }
}

#[async_trait::async_trait]
impl webrtc::interceptor::Interceptor for Loss {
    async fn bind_rtcp_reader(
        &self,
        reader: Arc<dyn webrtc::interceptor::RTCPReader + Send + Sync>,
    ) -> Arc<dyn webrtc::interceptor::RTCPReader + Send + Sync> {
        reader
    }

    async fn bind_rtcp_writer(
        &self,
        writer: Arc<dyn webrtc::interceptor::RTCPWriter + Send + Sync>,
    ) -> Arc<dyn webrtc::interceptor::RTCPWriter + Send + Sync> {
        writer
    }

    async fn bind_local_stream(
        &self,
        _info: &webrtc::interceptor::stream_info::StreamInfo,
        writer: Arc<dyn webrtc::interceptor::RTPWriter + Send + Sync>,
    ) -> Arc<dyn webrtc::interceptor::RTPWriter + Send + Sync> {
        Arc::new(LossWriter {
            permille: self.permille,
            next: writer,
            count: std::sync::atomic::AtomicU64::new(0),
        })
    }

    async fn unbind_local_stream(&self, _info: &webrtc::interceptor::stream_info::StreamInfo) {}

    async fn bind_remote_stream(
        &self,
        _info: &webrtc::interceptor::stream_info::StreamInfo,
        reader: Arc<dyn webrtc::interceptor::RTPReader + Send + Sync>,
    ) -> Arc<dyn webrtc::interceptor::RTPReader + Send + Sync> {
        reader
    }

    async fn unbind_remote_stream(&self, _info: &webrtc::interceptor::stream_info::StreamInfo) {}

    async fn close(&self) -> Result<(), webrtc::interceptor::Error> {
        Ok(())
    }
}

/// Deterministic spread of `permille` drops over packet numbers.
fn drop_this(n: u64, permille: u32) -> bool {
    let hashed = n.wrapping_mul(0x9e37_79b9_7f4a_7c15) >> 54; // 0..1023
    hashed * 1000 / 1024 < u64::from(permille)
}

/// The phone's carrier: RTP in from the remote track, RTCP out on the
/// peer connection.
pub struct ReceiveCarrier {
    pc: Mutex<Option<Arc<RTCPeerConnection>>>,
    rtp: Mutex<mpsc::Receiver<rtp::packet::Packet>>,
}

impl ReceiveCarrier {
    pub(crate) async fn bind(&self, pc: Arc<RTCPeerConnection>) {
        *self.pc.lock().await = Some(pc);
    }
}

impl MediaCarrier for ReceiveCarrier {
    fn kind(&self) -> CarrierKind {
        CarrierKind::WebRtcTrack
    }

    fn twcc_ext_id(&self) -> u8 {
        super::DEFAULT_TWCC_EXT_ID
    }

    fn send_rtp<'a>(&'a self, _packet: &'a rtp::packet::Packet) -> BoxFuture<'a, Result<(), MediaError>> {
        Box::pin(async { Err(MediaError::Unsupported) })
    }

    fn send_rtcp(&self, packets: RtcpPackets) -> BoxFuture<'_, Result<(), MediaError>> {
        Box::pin(async move {
            let pc = self.pc.lock().await.clone().ok_or(MediaError::Closed)?;
            match pc.write_rtcp(&packets).await {
                Ok(_) => Ok(()),
                Err(webrtc::Error::ErrConnectionClosed) => Err(MediaError::Closed),
                Err(_) => Ok(()),
            }
        })
    }

    fn recv_rtp(&self) -> BoxFuture<'_, Option<rtp::packet::Packet>> {
        Box::pin(async move { self.rtp.lock().await.recv().await })
    }

    fn recv_rtcp(&self) -> BoxFuture<'_, Option<RtcpPackets>> {
        Box::pin(std::future::pending())
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn drops_spread_near_the_requested_share() {
        let dropped = (0..100_000u64).filter(|n| super::drop_this(*n, 50)).count();
        assert!((4_000..6_000).contains(&dropped), "{dropped}");
        assert_eq!((0..1000u64).filter(|n| super::drop_this(*n, 0)).count(), 0);
    }
}
