//! The parked link end to end (PROTOCOL.md "Parked link", ask-48f698fc26): the exported API the
//! app calls, over a real WireGuard tunnel (cmux-wg) to an in-process Mac. The phone links up and
//! exchanges a frame, parks as the app does before the OS suspends it, stays silent past the
//! Mac's own keepalive timeout, resumes (the tunnel moves to a fresh socket), probes once, and its
//! first frame comes back on the channel it had before the park.
//!
//! The second test suspends the phone as iOS does: its network leg (here, the phone's TURN
//! allocation) is cut for the whole silence, so nothing reaches it and nothing leaves it, and the
//! datagrams either end sent across the cut are counted.
//!
//! Real time, about 40 s each: `cargo test -p cmux-mobile-link-ffi --test park_resume --
//! --nocapture`. Each prints one `PARK_RESUME {json}` line with each step's milliseconds.

use std::time::{Duration, Instant};

use cmux_mobile_link::api::IceServer;
use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling, TestTurn};
use cmux_mobile_link::{ChannelEvent, DialOptions, Link, LinkConfig, SignalingClient};
use cmux_mobile_link_ffi::{ChannelHandle, ChannelMessage, ConnectRequest, LinkHandle, Transport, WarmPool};
use serde_json::json;

/// Longer than the Mac link's keepalive timeout (15 s pings, 20 s without an answer): unparked,
/// a phone silent this long is a dead link the Mac closes.
const SILENT: Duration = Duration::from_secs(36);

/// The park exchange's own tail (its delayed ACKs), counted apart from the silence.
const TAIL: Duration = Duration::from_secs(1);

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

/// A linked phone with an echo channel that carried one frame, and the Mac's end of the link.
struct Linked {
    _server: FakeSignaling,
    phone: std::sync::Arc<LinkHandle>,
    mac: Link,
    channel: std::sync::Arc<ChannelHandle>,
}

async fn link_up(ice_servers: Vec<IceServer>, relay_only: bool) -> Linked {
    let server = FakeSignaling::start(FakeOptions { ice_servers, ..FakeOptions::default() }).await;
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
        relay_only,
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
    Linked { _server: server, phone, mac, channel }
}

/// The app goes to the background: it parks the link, and both ends hold. Returns the park's ms.
async fn park(linked: &Linked) -> f64 {
    let start = Instant::now();
    assert!(linked.phone.park(600_000, 2_000).await.expect("park"), "the Mac refused the park");
    let parked_ms = ms(start.elapsed());
    assert!(linked.mac.is_parked(), "the Mac is not holding the link");
    parked_ms
}

/// Back in the foreground: resume (a fresh tunnel socket), probe once, then the first frame.
/// Returns the probe's and the first frame's ms, both from the resume.
async fn resume(linked: &Linked) -> (f64, f64) {
    let start = Instant::now();
    assert!(linked.phone.resume(), "the park had already ended");
    linked.phone.probe(5_000).await.expect("the resumed link answers its probe");
    let probed_ms = ms(start.elapsed());
    linked.channel.send(b"after".to_vec()).await.unwrap();
    let first =
        tokio::time::timeout(Duration::from_secs(5), linked.channel.recv()).await.expect("the first frame");
    let first_frame_ms = ms(start.elapsed());
    assert_eq!(first, ChannelMessage::Data { bytes: b"after".to_vec() });
    assert!(!linked.mac.is_parked(), "the Mac still holds a link the phone came back to");

    // Unparked, the link carries on with its keepalives on.
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert!(!linked.phone.is_closed() && !linked.mac.is_closed(), "the resumed link closed");
    (probed_ms, first_frame_ms)
}

fn assert_held(linked: &Linked) {
    assert!(linked.mac.is_parked(), "the Mac left its park while the phone was silent");
    assert!(
        !linked.mac.is_closed(),
        "the Mac closed the parked link: {:?}",
        linked.mac.closed_state().borrow().clone()
    );
    assert!(!linked.phone.is_closed(), "the phone's parked link closed");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_parked_wireguard_link_resumes_and_carries_its_first_frame() {
    let linked = link_up(Vec::new(), false).await;
    let parked_ms = park(&linked).await;

    // Suspended: the phone sends nothing for longer than the Mac's keepalive timeout.
    tokio::time::sleep(SILENT).await;
    assert_held(&linked);

    let (probed_ms, first_frame_ms) = resume(&linked).await;
    println!(
        "PARK_RESUME {}",
        json!({"parked_ms": parked_ms, "silent_s": SILENT.as_secs(), "probed_ms": probed_ms,
               "first_frame_ms": first_frame_ms})
    );
    linked.phone.close();
}

/// Suspended as iOS suspends the app: the phone's only path (its TURN allocation, relay only) is
/// cut for longer than the Mac's keepalive timeout. Held, neither end sends the other anything
/// across the cut (counted at the TURN server: what the phone sent, what the Mac sent it); then
/// the phone is back, resumes over the same relay and its first frame comes back.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_suspended_phone_gets_nothing_and_resumes_with_its_first_frame() {
    let turn = TestTurn::start().await;
    let linked = link_up(vec![turn.udp_only()], true).await;
    let parked_ms = park(&linked).await;

    // Into the relay: either end's datagrams to the TURN server; out of it: what the relay would
    // have delivered from one end to the other. The first second after the park is its own tail
    // (the ACKs of the park exchange), counted apart; the rest of the silence must be empty.
    turn.set_udp_blocked(true);
    let cut = turn.udp_dropped();
    tokio::time::sleep(TAIL).await;
    let tail = turn.udp_dropped();
    tokio::time::sleep(SILENT - TAIL).await;
    let after = turn.udp_dropped();
    turn.set_udp_blocked(false);
    let (tail_in, tail_out) = (tail.0 - cut.0, tail.1 - cut.1);
    let (into_relay, out_of_relay) = (after.0 - tail.0, after.1 - tail.1);
    assert_held(&linked);
    println!(
        "suspended: first {} ms {tail_in} datagrams into the relay, {tail_out} out of it; next {} s \
         {into_relay} into the relay, {out_of_relay} out of it",
        TAIL.as_millis(),
        (SILENT - TAIL).as_secs()
    );
    assert_eq!(out_of_relay, 0, "the relay had {out_of_relay} datagrams for a suspended end");
    assert_eq!(into_relay, 0, "the held ends sent the relay {into_relay} datagrams");

    let (probed_ms, first_frame_ms) = resume(&linked).await;
    println!(
        "PARK_RESUME {}",
        json!({"path": "turn", "parked_ms": parked_ms, "silent_s": SILENT.as_secs(),
               "park_tail_datagrams": {"into_relay": tail_in, "out_of_relay": tail_out},
               "suspended_datagrams": {"into_relay": into_relay, "out_of_relay": out_of_relay},
               "probed_ms": probed_ms, "first_frame_ms": first_frame_ms})
    );
    linked.phone.close();
}
