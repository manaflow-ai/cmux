//! The parked link end to end (PROTOCOL.md "Parked link", ask-48f698fc26): the exported API the
//! app calls, over a real WireGuard tunnel (cmux-wg) to an in-process Mac. The phone links up and
//! exchanges a frame, parks as the app does before the OS suspends it, stays silent past the
//! Mac's own keepalive timeout, resumes (the tunnel moves to a fresh socket), probes once, and its
//! first frame comes back on the channel it had before the park.
//!
//! Real time, about 40 s: `cargo test -p cmux-mobile-link-ffi --test park_resume -- --nocapture`.
//! It prints one `PARK_RESUME {json}` line with each step's milliseconds.

use std::time::{Duration, Instant};

use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link::{ChannelEvent, DialOptions, Link, LinkConfig, SignalingClient};
use cmux_mobile_link_ffi::{ChannelMessage, ConnectRequest, Transport, WarmPool};
use serde_json::json;

/// Longer than the Mac link's keepalive timeout (15 s pings, 20 s without an answer): unparked,
/// a phone silent this long is a dead link the Mac closes.
const SILENT: Duration = Duration::from_secs(36);

/// An echo Mac that hands each link it answers to the test.
fn spawn_echo_mac(mac: SignalingClient, links: tokio::sync::mpsc::UnboundedSender<Link>) {
    tokio::spawn(async move {
        while let Some(session) = mac.next_session().await {
            let first = session.first;
            let events = SessionEvents {
                backend: mac.events(),
                session_id: first.session_id.clone(),
                session: session.events,
            };
            let mac = mac.clone();
            let links = links.clone();
            tokio::spawn(async move {
                let options = DialOptions { include_loopback: true, ..DialOptions::default() };
                let Ok(connected) = dial::answer(&mac, first, events, &options, LinkConfig::default()).await
                else {
                    return;
                };
                let _ = links.send(connected.link.clone());
                while let Some(mut incoming) = connected.link.accept().await {
                    tokio::spawn(async move {
                        while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                            let _ = incoming.channel.send(bytes).await;
                        }
                    });
                }
            });
        }
    });
}

fn ms(duration: Duration) -> f64 {
    (duration.as_secs_f64() * 10_000.0).round() / 10.0
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_parked_wireguard_link_resumes_and_carries_its_first_frame() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let (links_tx, mut links) = tokio::sync::mpsc::unbounded_channel();
    spawn_echo_mac(
        SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap(),
        links_tx,
    );
    let pool = WarmPool::new();
    let request = ConnectRequest {
        base_url: server.base_url.clone(),
        token: "user:alice".into(),
        team_id: "team".into(),
        device_id: uuid::Uuid::new_v4().to_string(),
        mac_device_id: mac_id,
        transport: Transport::WireGuard,
        include_loopback: true,
        relay_only: false,
        block_udp: false,
        video_lane: false,
        webrtc_media: false,
        ultra: cmux_mobile_link::UltraSetting::Off,
    };
    let phone = pool.connect(request, None).await.expect("the phone links up");
    assert_eq!(phone.transport(), Transport::WireGuard);
    let mac = tokio::time::timeout(Duration::from_secs(5), links.recv())
        .await
        .expect("the Mac answered")
        .expect("the Mac's link");
    let channel = phone.open_channel("echo".into(), String::new()).await.expect("channel");
    channel.send(b"before".to_vec()).await.unwrap();
    assert_eq!(channel.recv().await, ChannelMessage::Data { bytes: b"before".to_vec() });

    // The app goes to the background: it parks the link, and both ends hold.
    let start = Instant::now();
    assert!(phone.park(600_000, 2_000).await.expect("park"), "the Mac refused the park");
    let parked_ms = ms(start.elapsed());
    assert!(mac.is_parked(), "the Mac is not holding the link");

    // Suspended: the phone sends nothing for longer than the Mac's keepalive timeout.
    tokio::time::sleep(SILENT).await;
    assert!(mac.is_parked(), "the Mac left its park while the phone was silent");
    assert!(!mac.is_closed(), "the Mac closed the parked link: {:?}", mac.closed_state().borrow().clone());
    assert!(!phone.is_closed(), "the phone's parked link closed");

    // Back in the foreground: resume (a fresh tunnel socket), probe once, then the first frame.
    let start = Instant::now();
    assert!(phone.resume(), "the park had already ended");
    phone.probe(5_000).await.expect("the resumed link answers its probe");
    let probed_ms = ms(start.elapsed());
    channel.send(b"after".to_vec()).await.unwrap();
    let first = tokio::time::timeout(Duration::from_secs(5), channel.recv()).await.expect("the first frame");
    let first_frame_ms = ms(start.elapsed());
    assert_eq!(first, ChannelMessage::Data { bytes: b"after".to_vec() });
    assert!(!mac.is_parked(), "the Mac still holds a link the phone came back to");

    // Unparked, the link carries on with its keepalives on.
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert!(!phone.is_closed() && !mac.is_closed(), "the resumed link closed");
    println!(
        "PARK_RESUME {}",
        json!({"parked_ms": parked_ms, "silent_s": SILENT.as_secs(), "probed_ms": probed_ms,
               "first_frame_ms": first_frame_ms})
    );
    phone.close();
}
