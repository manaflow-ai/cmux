//! WireGuard for the link, a WebRTC media session for browser video
//! (verify/hybrid-link.md): in-process boringtun peers over loopback UDP,
//! real webrtc-rs peer connections, and the fake signaling server.
//!
//! - The phone opens the media session only when video is wanted, video
//!   moves onto it at a keyframe, and the session closes after the linger.
//! - When the session dies, video falls back into the tunnel with no gap
//!   longer than a keyframe round trip, starting at a keyframe; when the
//!   phone's next session is up, video moves back, again at a keyframe.
//! - Block UDP: the session fails and video stays in the tunnel.
//! - A Mac without media sessions leaves the lane out.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::hybrid::{MediaConfig, MediaManager, MediaStatus};
use cmux_mobile_link::media::{CarrierKind, MediaLane, OutgoingFrame, ReceivedFrame, VideoIn, VideoOut};
use cmux_mobile_link::media::{MediaCarrier, MediaError, RtcpPackets, rtp};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link::{DialOptions, Link, LinkConfig, SignalingClient, TransportKind};
use futures_util::future::BoxFuture;
use tokio::sync::{mpsc, watch};

fn options(webrtc_media: bool) -> DialOptions {
    DialOptions {
        include_loopback: true,
        timeout: Duration::from_secs(20),
        video_lane: true,
        webrtc_media,
        ..DialOptions::default()
    }
}

fn access_unit(keyframe: bool, slice: usize, fill: u8) -> Bytes {
    let mut au = Vec::new();
    if keyframe {
        au.extend_from_slice(&[0, 0, 0, 1, 0x67, 0x42, 0xc0, 0x1f, 0xda, 0x01]);
        au.extend_from_slice(&[0, 0, 0, 1, 0x68, 0xce, 0x3c, 0x80]);
        au.extend_from_slice(&[0, 0, 0, 1, 0x65]);
    } else {
        au.extend_from_slice(&[0, 0, 0, 1, 0x41]);
    }
    au.extend(std::iter::repeat_n(fill.max(2), slice));
    Bytes::from(au)
}

struct Hybrid {
    phone: Link,
    mac: Link,
    phone_client: SignalingClient,
    mac_id: String,
    link_session: String,
    webrtc_media: bool,
    /// The Mac's media sessions, as they come up (the test may kill one).
    sessions: mpsc::UnboundedReceiver<Arc<dial::webrtc::MediaSession>>,
    /// While set, the Mac's media session tracks lose every RTP and RTCP
    /// packet under a connected peer connection.
    silent: Arc<AtomicBool>,
    _server: FakeSignaling,
}

/// A carrier whose packets vanish while `silent` is set.
struct Silenced {
    inner: Arc<dyn MediaCarrier>,
    silent: Arc<AtomicBool>,
}

impl MediaCarrier for Silenced {
    fn kind(&self) -> CarrierKind {
        self.inner.kind()
    }
    fn twcc_ext_id(&self) -> u8 {
        self.inner.twcc_ext_id()
    }
    fn max_payload(&self) -> usize {
        self.inner.max_payload()
    }
    fn send_rtp<'a>(&'a self, packet: &'a rtp::packet::Packet) -> BoxFuture<'a, Result<(), MediaError>> {
        if self.silent.load(Ordering::Relaxed) {
            return Box::pin(async { Ok(()) });
        }
        self.inner.send_rtp(packet)
    }
    fn send_rtcp(&self, packets: RtcpPackets) -> BoxFuture<'_, Result<(), MediaError>> {
        self.inner.send_rtcp(packets)
    }
    fn recv_rtp(&self) -> BoxFuture<'_, Option<rtp::packet::Packet>> {
        self.inner.recv_rtp()
    }
    fn recv_rtcp(&self) -> BoxFuture<'_, Option<RtcpPackets>> {
        Box::pin(async move {
            loop {
                let packets = self.inner.recv_rtcp().await?;
                if !self.silent.load(Ordering::Relaxed) {
                    return Some(packets);
                }
            }
        })
    }
}

/// A WireGuard link; the Mac answers media sessions for it the way
/// cmux-mobile-host does (its track becomes a route of the link's lane).
async fn hybrid(phone: DialOptions, mac: DialOptions) -> Hybrid {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let phone_id = uuid::Uuid::new_v4().to_string();
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac_client = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let (links_tx, mut links_rx) = mpsc::channel(1);
    let (sessions_tx, sessions) = mpsc::unbounded_channel();
    let lane: Arc<std::sync::Mutex<Option<VideoOut>>> = Arc::default();
    let silent = Arc::new(AtomicBool::new(false));
    let mac_silent = Arc::clone(&silent);
    tokio::spawn(async move {
        while let Some(session) = mac_client.next_session().await {
            let first = session.first;
            let events = SessionEvents {
                backend: mac_client.events(),
                session_id: first.session_id.clone(),
                session: session.events,
            };
            if dial::media_session_for(&first.payload).is_some() {
                let Some(video) = lane.lock().unwrap().clone() else { continue };
                let client = mac_client.clone();
                let options = DialOptions { timeout: Duration::from_secs(15), ..mac.clone() };
                let sessions_tx = sessions_tx.clone();
                let silent = Arc::clone(&mac_silent);
                tokio::spawn(async move {
                    let Ok(session) = dial::webrtc::answer_media(&client, first, events, &options).await
                    else {
                        return;
                    };
                    let session = Arc::new(session);
                    let carrier = Arc::new(Silenced { inner: Arc::clone(&session.carrier), silent });
                    let route = video.add_route(carrier, session.up.clone());
                    let _ = sessions_tx.send(Arc::clone(&session));
                    session.wait_ended().await;
                    drop(route);
                });
                continue;
            }
            let connected =
                dial::answer(&mac_client, first, events, &mac, LinkConfig::default()).await.expect("answer");
            if let Some(MediaLane::Out(video)) = connected.link.media() {
                *lane.lock().unwrap() = Some(video);
            }
            let _ = links_tx.send((connected.link, connected.webrtc_media)).await;
        }
    });
    let phone_client =
        SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let connected =
        dial::connect(&phone_client, &mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
            .await
            .expect("dial");
    let (mac, mac_agreed) = links_rx.recv().await.unwrap();
    assert_eq!(connected.webrtc_media, mac_agreed, "both sides agree on the media session lane");
    Hybrid {
        phone: connected.link,
        mac,
        phone_client,
        mac_id,
        link_session: connected.session_id,
        webrtc_media: connected.webrtc_media,
        sessions,
        silent,
        _server: server,
    }
}

fn manager(pair: &Hybrid, options: DialOptions, linger: Duration) -> MediaManager {
    let client = pair.phone_client.clone();
    MediaManager::start(MediaConfig {
        link: pair.phone.clone(),
        mac: pair.mac_id.clone(),
        link_session: pair.link_session.clone(),
        signaling: Arc::new(move || {
            let client = client.clone();
            Box::pin(async move { Some(client) })
        }),
        ice: Arc::new(|| Box::pin(async { Vec::new() })),
        options,
        linger,
    })
}

fn out(link: &Link) -> VideoOut {
    match link.media() {
        Some(MediaLane::Out(out)) => out,
        other => panic!("expected the Mac's sender, got {other:?}"),
    }
}

fn input(link: &Link) -> VideoIn {
    match link.media() {
        Some(MediaLane::In(input)) => input,
        other => panic!("expected the phone's receiver, got {other:?}"),
    }
}

/// A 60 fps source on the Mac that answers keyframe requests, as the
/// browser host does, until `stop` is set.
fn source(out: VideoOut, stop: watch::Receiver<bool>) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut claim = out.claim();
        let mut ticker = tokio::time::interval(Duration::from_micros(16_667));
        let mut keyframe_next = true;
        let mut i = 0u64;
        while !*stop.borrow() {
            ticker.tick().await;
            while claim.keyframes.try_recv().is_ok() {
                keyframe_next = true;
            }
            let keyframe = std::mem::take(&mut keyframe_next);
            let size = if keyframe { 20_000 } else { 2_000 + (i as usize % 5) * 300 };
            let au = access_unit(keyframe, size, (i % 200) as u8 + 3);
            if claim.send(OutgoingFrame { access_unit: au, capture_us: i * 16_667 }).await.is_err() {
                return;
            }
            i += 1;
        }
    })
}

/// Frames as the phone got them, with when.
struct Seen {
    frames: Vec<(Instant, ReceivedFrame)>,
}

impl Seen {
    fn carriers(&self) -> Vec<Option<CarrierKind>> {
        let mut runs: Vec<Option<CarrierKind>> = Vec::new();
        for (_, frame) in &self.frames {
            if runs.last() != Some(&frame.carrier) {
                runs.push(frame.carrier);
            }
        }
        runs
    }

    /// Every change of carrier starts with a keyframe (the decoder never
    /// gets a frame whose reference went the other way).
    fn assert_switches_at_keyframes(&self) {
        for pair in self.frames.windows(2) {
            if pair[0].1.carrier != pair[1].1.carrier {
                assert!(pair[1].1.keyframe, "switched to {:?} on a P frame", pair[1].1.carrier);
            }
        }
    }

    /// The longest time without a frame.
    fn longest_gap(&self) -> Duration {
        self.frames.windows(2).map(|w| w[1].0.duration_since(w[0].0)).max().unwrap_or_default()
    }
}

/// Drains the phone's frames as they come (a test that waits on something
/// else must not hold them back), stamped on arrival.
type Arrivals = mpsc::UnboundedReceiver<(Instant, ReceivedFrame)>;

fn collector(mut frames: cmux_mobile_link::media::VideoFrames) -> Arrivals {
    let (tx, rx) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        while let Some(frame) = frames.frames.recv().await {
            if tx.send((Instant::now(), frame)).is_err() {
                return;
            }
        }
    });
    rx
}

async fn collect_until(
    frames: &mut Arrivals,
    seen: &mut Seen,
    deadline: Duration,
    mut done: impl FnMut(&Seen) -> bool,
) -> bool {
    let end = tokio::time::Instant::now() + deadline;
    while let Ok(Some(frame)) = tokio::time::timeout_at(end, frames.recv()).await {
        seen.frames.push(frame);
        if done(seen) {
            return true;
        }
    }
    false
}

async fn status_until(
    status: &mut watch::Receiver<MediaStatus>,
    want: impl Fn(&MediaStatus) -> bool,
) -> MediaStatus {
    let result = tokio::time::timeout(Duration::from_secs(20), status.wait_for(|s| want(s))).await;
    result.expect("media status in time").expect("manager alive").clone()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn video_moves_onto_the_media_session_falls_back_into_the_tunnel_and_returns() {
    let mut pair = hybrid(options(true), options(true)).await;
    assert!(pair.webrtc_media);
    let input = input(&pair.phone);
    let mut frames = collector(input.subscribe().await);
    let (stop_tx, stop) = watch::channel(false);
    let _source = source(out(&pair.mac), stop);
    let mut seen = Seen { frames: Vec::new() };
    // Before anything wants it, video rides the tunnel and no session opens.
    let manager = manager(&pair, options(true), Duration::from_secs(1));
    assert!(collect_until(&mut frames, &mut seen, Duration::from_secs(5), |s| s.frames.len() >= 30).await);
    assert!(seen.frames.iter().all(|(_, f)| f.carrier == Some(CarrierKind::WireGuardUdp)));
    assert_eq!(*manager.status().borrow(), MediaStatus::Off);
    assert!(pair.sessions.try_recv().is_err(), "no media session before a tab wants video");

    // A shown tab: the session opens and video moves onto it at a keyframe.
    let demand = manager.acquire();
    let mut status = manager.status();
    status_until(&mut status, |s| matches!(s, MediaStatus::Up { .. })).await;
    let session = pair.sessions.recv().await.expect("the Mac answered");
    assert!(
        collect_until(&mut frames, &mut seen, Duration::from_secs(10), |s| {
            s.frames.last().is_some_and(|(_, f)| f.carrier == Some(CarrierKind::WebRtcTrack))
        })
        .await,
        "video moved onto the media session: {:?}",
        seen.carriers()
    );
    // The link itself still works beside it.
    assert!(pair.phone.ping().await.is_ok());

    // The session dies: video falls back into the tunnel at a keyframe with
    // no long gap, and the phone dials a new session.
    let before = seen.frames.len();
    session.kill().await;
    assert!(
        collect_until(&mut frames, &mut seen, Duration::from_secs(10), |s| {
            s.frames.last().is_some_and(|(_, f)| f.carrier == Some(CarrierKind::WireGuardUdp))
        })
        .await,
        "video fell back into the tunnel: {:?}",
        seen.carriers()
    );
    status_until(&mut status, |s| matches!(s, MediaStatus::Failed { .. } | MediaStatus::Connecting)).await;
    // And returns once the next session is up.
    let _next = tokio::time::timeout(Duration::from_secs(20), pair.sessions.recv()).await.expect("redialed");
    assert!(
        collect_until(&mut frames, &mut seen, Duration::from_secs(15), |s| {
            s.frames[before..].iter().any(|(_, f)| f.carrier == Some(CarrierKind::WireGuardUdp))
                && s.frames.last().is_some_and(|(_, f)| f.carrier == Some(CarrierKind::WebRtcTrack))
        })
        .await,
        "video came back: {:?}",
        seen.carriers()
    );
    seen.assert_switches_at_keyframes();
    let gap = seen.longest_gap();
    assert!(gap < Duration::from_millis(1500), "longest gap without a frame {gap:?}");

    // Hidden: after the linger the session closes and video stays in the tunnel.
    drop(demand);
    status_until(&mut status, |s| *s == MediaStatus::Off).await;
    assert!(
        collect_until(&mut frames, &mut seen, Duration::from_secs(10), |s| {
            s.frames.last().is_some_and(|(_, f)| f.carrier == Some(CarrierKind::WireGuardUdp))
        })
        .await
    );
    seen.assert_switches_at_keyframes();
    stop_tx.send_replace(true);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn with_udp_blocked_the_media_session_fails_and_video_stays_in_the_tunnel() {
    let mut pair = hybrid(options(true), options(true)).await;
    let input = input(&pair.phone);
    let mut frames = collector(input.subscribe().await);
    let (stop_tx, stop) = watch::channel(false);
    let _source = source(out(&pair.mac), stop);
    // The phone's dial policy as on a network that passes only TCP.
    let blocked = DialOptions { block_udp: true, ..options(true) };
    let manager = manager(&pair, blocked, Duration::from_secs(1));
    let _demand = manager.acquire();
    let mut status = manager.status();
    let failed = status_until(&mut status, |s| matches!(s, MediaStatus::Failed { .. })).await;
    let mut seen = Seen { frames: Vec::new() };
    assert!(collect_until(&mut frames, &mut seen, Duration::from_secs(5), |s| s.frames.len() >= 60).await);
    assert!(seen.frames.iter().all(|(_, f)| f.carrier == Some(CarrierKind::WireGuardUdp)), "{failed:?}");
    assert!(pair.sessions.try_recv().is_err(), "no media session came up");
    assert!(seen.longest_gap() < Duration::from_millis(500));
    stop_tx.send_replace(true);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_mac_without_media_sessions_leaves_the_lane_out() {
    let pair = hybrid(options(true), options(false)).await;
    assert!(!pair.webrtc_media);
    // The tunnel's media lane still works.
    assert!(pair.phone.media().is_some() && pair.mac.media().is_some());
    let pair = hybrid(options(false), options(true)).await;
    assert!(!pair.webrtc_media, "an older phone never asks");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_silent_media_session_stalls_video_falls_back_and_the_session_is_tried_again() {
    let mut pair = hybrid(options(true), options(true)).await;
    let input = input(&pair.phone);
    let mut frames = collector(input.subscribe().await);
    let (stop_tx, stop) = watch::channel(false);
    let _source = source(out(&pair.mac), stop);
    let manager = manager(&pair, options(true), Duration::from_secs(30));
    let _demand = manager.acquire();
    let mut status = manager.status();
    status_until(&mut status, |s| matches!(s, MediaStatus::Up { .. })).await;
    let _session = pair.sessions.recv().await.unwrap();
    let mut seen = Seen { frames: Vec::new() };
    let on = |kind| {
        move |s: &Seen| {
            s.frames.last().is_some_and(|(_, f): &(Instant, ReceivedFrame)| f.carrier == Some(kind))
        }
    };
    assert!(
        collect_until(&mut frames, &mut seen, Duration::from_secs(10), on(CarrierKind::WebRtcTrack)).await
    );
    // The path dies under a connected peer connection: no feedback, so the
    // Mac moves video into the tunnel within the stall time.
    let silenced = Instant::now();
    pair.silent.store(true, Ordering::Relaxed);
    assert!(
        collect_until(&mut frames, &mut seen, Duration::from_secs(5), on(CarrierKind::WireGuardUdp)).await
    );
    let fell_back = silenced.elapsed();
    assert!(fell_back < Duration::from_millis(1500), "fell back after {fell_back:?}");
    // The session itself stays up; once the path works again a retry moves
    // video back.
    pair.silent.store(false, Ordering::Relaxed);
    assert!(
        collect_until(&mut frames, &mut seen, Duration::from_secs(20), on(CarrierKind::WebRtcTrack)).await,
        "{:?}",
        seen.carriers()
    );
    assert!(matches!(*manager.status().borrow(), MediaStatus::Up { .. }));
    seen.assert_switches_at_keyframes();
    let gap = seen.longest_gap();
    assert!(gap < Duration::from_millis(1500), "longest gap without a frame {gap:?}");
    stop_tx.send_replace(true);
}
