//! The media lane end to end, negotiated per side, with NACK recovery and
//! keyframe requests through webrtc-rs's interceptors:
//!
//! - WebRTC: browser video as a video track on the link's own peer
//!   connection.
//! - WireGuard: RTP on overlay UDP inside the in-process tunnel pair (real
//!   boringtun peers over loopback UDP and the fake signaling server), with
//!   loss, a capped link, an unrecoverable gap and a roam mid-stream.

use std::time::Duration;

use bytes::Bytes;
use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::media::{MediaLane, OutgoingFrame, VideoIn, VideoOut};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link::{DialOptions, Link, LinkConfig, SignalingClient, TransportKind};
use tokio::sync::mpsc;

fn options(video: bool) -> DialOptions {
    DialOptions {
        include_loopback: true,
        timeout: Duration::from_secs(20),
        video_lane: video,
        ..DialOptions::default()
    }
}

/// An Annex-B access unit: SPS, PPS and an IDR slice, or one P slice.
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

struct Pair {
    phone: Link,
    mac: Link,
    session_id: String,
    _server: FakeSignaling,
}

async fn pair(kind: TransportKind, phone: DialOptions, mac: DialOptions) -> Pair {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let phone_id = uuid::Uuid::new_v4().to_string();
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac_client = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let (links_tx, mut links_rx) = mpsc::channel(1);
    tokio::spawn(async move {
        while let Some(session) = mac_client.next_session().await {
            let first = session.first;
            let events = SessionEvents {
                backend: mac_client.events(),
                session_id: first.session_id.clone(),
                session: session.events,
            };
            let connected =
                dial::answer(&mac_client, first, events, &mac, LinkConfig::default()).await.expect("answer");
            let _ = links_tx.send(connected.link).await;
        }
    });
    let phone_client =
        SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let connected =
        dial::connect(&phone_client, &mac_id, kind, &phone, LinkConfig::default()).await.expect("dial");
    let mac = links_rx.recv().await.unwrap();
    Pair { phone: connected.link, mac, session_id: connected.session_id, _server: server }
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

/// How the test source behaves.
#[derive(Default)]
struct Source {
    /// A keyframe every this many frames besides the first and the
    /// requested ones (None: only those).
    periodic: Option<u64>,
    /// Size frames to the lane's target and skip one while the lane says
    /// it is congested, as the Mac's browser host does.
    adaptive: bool,
    /// Fire this at frame `.0`.
    signal_at: Option<(u64, tokio::sync::oneshot::Sender<()>)>,
}

/// What a stream run saw.
struct Streamed {
    frames: Vec<cmux_mobile_link::media::ReceivedFrame>,
    state: cmux_mobile_link::media::SenderState,
    /// The lane's target, sampled once per second of streaming.
    targets: Vec<u64>,
    skipped: u64,
}

/// Streams `n` frames at 60 fps (a keyframe every 60) and returns the
/// frames the phone decoded, with the Mac's last state.
async fn stream(
    pair: &Pair,
    n: u64,
) -> (Vec<cmux_mobile_link::media::ReceivedFrame>, cmux_mobile_link::media::SenderState) {
    let run = stream_with(pair, n, Source { periodic: Some(60), ..Source::default() }).await;
    (run.frames, run.state)
}

async fn stream_with(pair: &Pair, n: u64, mut source: Source) -> Streamed {
    let out = out(&pair.mac);
    let input = input(&pair.phone);
    let mut frames = input.subscribe().await;
    let mut claim = out.claim();
    let mut got = Vec::new();
    let mut targets = Vec::new();
    let mut skipped = 0;
    let mut ticker = tokio::time::interval(Duration::from_micros(16_667));
    let mut keyframe_next = true;
    for i in 0..n {
        ticker.tick().await;
        if source.signal_at.as_ref().is_some_and(|(at, _)| *at == i)
            && let Some((_, signal)) = source.signal_at.take()
        {
            let _ = signal.send(());
        }
        if i % 60 == 59 {
            targets.push(claim.state().target_bps);
        }
        if std::env::var_os("CMUX_MOBILE_MEDIA_TRACE").is_some() && i % 6 == 0 {
            let s = claim.state();
            eprintln!(
                "{i:4} target {:8} in_flight {:7} loss {:.3} delay {:6} kf {} nacks {}",
                s.target_bps,
                s.in_flight_bytes,
                s.loss,
                s.feedback_delay_us,
                s.keyframe_requests,
                s.nacks_received
            );
        }
        // The source answers keyframe requests (the receiver's PLI).
        while claim.keyframes.try_recv().is_ok() {
            keyframe_next = true;
        }
        let state = claim.state();
        if source.adaptive && state.congested && !keyframe_next {
            skipped += 1;
            continue;
        }
        let keyframe = keyframe_next || source.periodic.is_some_and(|every| i % every == 0);
        keyframe_next = false;
        let size = if source.adaptive {
            let per_frame = (state.target_bps / 8 / 60) as usize;
            if keyframe { per_frame * 3 } else { per_frame }
        } else if keyframe {
            30_000
        } else {
            3_000 + (i as usize % 5) * 400
        };
        let au = access_unit(keyframe, size, (i % 200) as u8 + 3);
        claim.send(OutgoingFrame { access_unit: au, capture_us: i * 16_667 }).await.unwrap();
        while let Ok(frame) = frames.frames.try_recv() {
            got.push(frame);
        }
    }
    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    while let Ok(Some(frame)) = tokio::time::timeout_at(deadline, frames.frames.recv()).await {
        got.push(frame);
    }
    Streamed { frames: got, state: claim.state(), targets, skipped }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn video_frames_ride_a_track_on_the_links_peer_connection() {
    let pair = pair(TransportKind::WebRtc, options(true), options(true)).await;
    assert_eq!(out(&pair.mac).kind().name(), "webrtc-track");
    let (got, state) = stream(&pair, 120).await;
    assert!(got.len() >= 110, "{} frames", got.len());
    assert!(got[0].keyframe, "decoding starts at a keyframe");
    // In order, by capture time.
    for w in got.windows(2) {
        assert!(w[1].rtp_timestamp.wrapping_sub(w[0].rtp_timestamp) < 1 << 31);
    }
    let p = got.iter().find(|f| !f.keyframe).unwrap();
    assert_eq!(&p.access_unit[..5], &[0, 0, 0, 1, 0x41]);
    assert!(state.packets_sent > 200);
    // TWCC feedback flows back.
    assert!(state.feedback_delay_us > 0, "{state:?}");
    // Channels still work beside the track.
    assert!(pair.phone.ping().await.is_ok());
    pair.phone.close("done");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn lost_packets_come_back_by_nack_and_frames_stay_decodable() {
    let mac = DialOptions { video_drop_permille: 30, ..options(true) };
    let pair = pair(TransportKind::WebRtc, options(true), mac).await;
    let (got, state) = stream(&pair, 240).await;
    let stats = input(&pair.phone).stats();
    assert!(state.nacks_received > 0, "{state:?}");
    assert!(stats.packets_recovered > 0, "{stats:?}");
    assert!(got.iter().any(|f| f.recovered));
    // Most frames survive 3% loss; any given up restart at a keyframe.
    assert!(got.len() >= 180, "{} frames of 240, {stats:?}", got.len());
    assert!(got[0].keyframe);
    pair.phone.close("done");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_older_mac_leaves_the_lane_out_and_the_link_works() {
    let pair = pair(TransportKind::WebRtc, options(true), options(false)).await;
    assert!(pair.phone.media().is_none());
    assert!(pair.mac.media().is_none());
    assert!(pair.phone.ping().await.is_ok());
    pair.phone.close("done");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_older_phone_gets_no_track() {
    let pair = pair(TransportKind::WebRtc, options(false), options(true)).await;
    assert!(pair.phone.media().is_none());
    assert!(pair.mac.media().is_none());
    assert!(pair.mac.ping().await.is_ok());
    pair.phone.close("done");
}

/// Frames in order, by capture time.
fn assert_in_order(frames: &[cmux_mobile_link::media::ReceivedFrame]) {
    for w in frames.windows(2) {
        assert!(w[1].rtp_timestamp.wrapping_sub(w[0].rtp_timestamp) < 1 << 31);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn video_frames_ride_rtp_inside_the_wireguard_tunnel() {
    let pair = pair(TransportKind::WireGuard, options(true), options(true)).await;
    assert_eq!(out(&pair.mac).kind().name(), "wireguard-udp");
    assert_eq!(input(&pair.phone).kind().name(), "wireguard-udp");
    let (got, state) = stream(&pair, 120).await;
    assert!(got.len() >= 110, "{} frames", got.len());
    assert!(got[0].keyframe, "decoding starts at a keyframe");
    assert_in_order(&got);
    let p = got.iter().find(|f| !f.keyframe).unwrap();
    assert_eq!(&p.access_unit[..5], &[0, 0, 0, 1, 0x41]);
    // Keyframes of 30 kB arrive whole: FU-A fragments sized for the tunnel.
    assert!(got.iter().filter(|f| f.keyframe).all(|f| f.access_unit.len() > 30_000));
    assert!(state.packets_sent > 200);
    // TWCC feedback flows back through the tunnel.
    assert!(state.feedback_delay_us > 0, "{state:?}");
    // The link's TCP streams still work beside the lane.
    assert!(pair.phone.ping().await.is_ok());
    pair.phone.close("done");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_lost_packets_come_back_by_nack() {
    let mac = DialOptions { video_drop_permille: 30, ..options(true) };
    let pair = pair(TransportKind::WireGuard, options(true), mac).await;
    let (got, state) = stream(&pair, 240).await;
    let stats = input(&pair.phone).stats();
    assert!(state.nacks_received > 0, "{state:?}");
    assert!(stats.packets_recovered > 0, "{stats:?}");
    assert!(got.iter().any(|f| f.recovered));
    // Most frames survive 3% loss; any given up restart at a keyframe.
    assert!(got.len() >= 200, "{} frames of 240, {stats:?}", got.len());
    assert!(got[0].keyframe);
    assert_in_order(&got);
    pair.phone.close("done");
}

/// A 1.5 Mbit/s bottleneck under a source that starts at the lane's
/// 2.5 Mbit/s: TWCC delay feedback brings the target under the cap, and
/// the source skips frames while the window is full instead of queueing.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_bitrate_adapts_to_a_capped_link() {
    let cap = 1_500_000;
    let mac = DialOptions { video_cap_bps: cap, ..options(true) };
    let pair = pair(TransportKind::WireGuard, options(true), mac).await;
    let run =
        stream_with(&pair, 600, Source { periodic: Some(120), adaptive: true, ..Source::default() }).await;
    let last = *run.targets.last().unwrap();
    eprintln!(
        "targets {:?}, skipped {}, frames {}, {:?}",
        run.targets,
        run.skipped,
        run.frames.len(),
        run.state
    );
    assert!(last <= cap * 115 / 100, "target {last} above the {cap} cap: {:?}", run.targets);
    // It never collapsed to the floor (NACK resends are bounded and the
    // controller cuts once per round trip), and it is growing back.
    let lowest = *run.targets.iter().min().unwrap();
    assert!(lowest >= cap / 5, "target collapsed to {lowest}: {:?}", run.targets);
    assert!(last > lowest, "{:?}", run.targets);
    // Below the cap the bottleneck's queue drained: no standing delay or loss.
    assert!(run.state.feedback_delay_us < 120_000, "{:?}", run.state);
    assert!(run.state.loss < 0.05, "{:?}", run.state);
    // The phone kept getting decodable video.
    assert!(run.frames.len() >= 300, "{} frames", run.frames.len());
    assert!(run.frames[0].keyframe);
    assert_in_order(&run.frames);
    pair.phone.close("done");
}

/// Every packet (resends too) is lost for 600 ms, longer than any NACK
/// can recover: the phone gives the gap up, sends a PLI, and decoding
/// resumes at the keyframe the Mac makes for it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_unrecoverable_loss_resumes_at_a_requested_keyframe() {
    let mac = DialOptions {
        // From the first RTP packet: frames 60 to 96 of 240.
        video_blackout: Some((Duration::from_millis(1000), Duration::from_millis(600))),
        ..options(true)
    };
    let pair = pair(TransportKind::WireGuard, options(true), mac).await;
    // Keyframes only when asked for (and the first).
    let run = stream_with(&pair, 240, Source::default()).await;
    let stats = input(&pair.phone).stats();
    assert!(stats.frames_dropped > 0, "{stats:?}");
    assert!(stats.plis_sent > 0, "{stats:?}");
    assert!(run.state.keyframe_requests > 0, "{:?}", run.state);
    let keyframes: Vec<_> = run.frames.iter().filter(|f| f.keyframe).collect();
    assert!(keyframes.len() >= 2, "{} keyframes, {stats:?}", keyframes.len());
    // The frames after the gap start at the requested keyframe and go on.
    let resumed = run.frames.iter().position(|f| f.keyframe && f.rtp_timestamp > keyframes[0].rtp_timestamp);
    let resumed = resumed.expect("a keyframe after the gap");
    assert!(run.frames.len() - resumed > 60, "{} frames after the gap", run.frames.len() - resumed);
    assert_in_order(&run.frames);
    pair.phone.close("done");
}

/// The phone roams in the middle of a stream: the lane keeps its port and
/// keys (no new negotiation), the phone asks for a keyframe, and frames go
/// on.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_roam_mid_stream_keeps_the_lane_and_asks_for_a_keyframe() {
    let pair = pair(TransportKind::WireGuard, options(true), options(true)).await;
    let input = input(&pair.phone);
    let (roam_tx, roam_rx) = tokio::sync::oneshot::channel();
    let session_id = pair.session_id.clone();
    let roamed = tokio::spawn(async move {
        roam_rx.await.unwrap();
        cmux_mobile_link::dial::wireguard::roam_session(&session_id, true).await.expect("a live session")
    });
    let roam_frame = 90;
    let run =
        stream_with(&pair, 300, Source { signal_at: Some((roam_frame, roam_tx)), ..Source::default() }).await;
    let timeline = roamed.await.unwrap();
    eprintln!("roam {}", timeline.summary());
    let stats = input.stats();
    assert!(stats.plis_sent > 0, "{stats:?}");
    assert!(run.state.keyframe_requests > 0, "{:?}", run.state);
    // A keyframe after the roam, though the source makes them only on request.
    let roam_ts = cmux_mobile_link::media::rtp_timestamp(roam_frame * 16_667);
    let after: Vec<_> = run.frames.iter().filter(|f| f.rtp_timestamp > roam_ts).collect();
    assert!(after.iter().any(|f| f.keyframe), "no keyframe after the roam: {stats:?}");
    assert!(after.len() >= 150, "{} frames after the roam, {stats:?}", after.len());
    assert_in_order(&run.frames);
    // The same lane and link: nothing was dialed again.
    assert!(matches!(pair.phone.media(), Some(MediaLane::In(_))));
    assert!(pair.phone.ping().await.is_ok());
    pair.phone.close("done");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_with_an_older_mac_stays_on_the_channel() {
    let pair = pair(TransportKind::WireGuard, options(true), options(false)).await;
    assert!(pair.phone.media().is_none());
    assert!(pair.mac.media().is_none());
    assert!(pair.phone.ping().await.is_ok());
    pair.phone.close("done");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_with_an_older_phone_stays_on_the_channel() {
    let pair = pair(TransportKind::WireGuard, options(false), options(true)).await;
    assert!(pair.phone.media().is_none());
    assert!(pair.mac.media().is_none());
    assert!(pair.mac.ping().await.is_ok());
    pair.phone.close("done");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_newer_claim_preempts_the_older_source() {
    let pair = pair(TransportKind::WebRtc, options(true), options(true)).await;
    let out = out(&pair.mac);
    let mut first = out.claim();
    assert!(first.owns());
    let second = out.claim();
    tokio::time::timeout(Duration::from_secs(1), first.preempted()).await.expect("preempted");
    assert!(!first.owns() && second.owns());
    assert!(
        first.send(OutgoingFrame { access_unit: access_unit(true, 10, 3), capture_us: 0 }).await.is_err()
    );
    pair.phone.close("done");
}
