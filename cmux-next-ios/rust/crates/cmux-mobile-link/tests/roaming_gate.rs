//! Fast headless Wi-Fi/cellular transition detector. Real encrypted Link traffic crosses
//! a blackholed socket, then a new UDP socket / TURN allocation on the same session.
//! The signaling and TURN servers are local fixtures; neither device hardware nor OS
//! interface notifications, radio scheduling, or thermal behavior is covered here.

use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_mobile_link::dial::{self, SessionEvents, wireguard};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling, TestTurn};
use cmux_mobile_link::{
    ChannelEvent, DialOptions, Lane, LinkConfig, LinkPath, SignalingClient, TransportKind,
};

// Includes the deliberate outage and retransmission. This is a functional recovery
// deadline, not a hardware benchmark; a missing path must fail instead of hanging CI.
const RECOVERY_BUDGET: Duration = Duration::from_secs(2);
const INPUTS: u64 = 128;

async fn received(channel: &mut cmux_mobile_link::Channel) -> Bytes {
    match channel.recv().await.expect("channel remained open") {
        ChannelEvent::Data(bytes) => bytes,
        other => panic!("session closed during roam: {other:?}"),
    }
}

async fn transition(relayed: bool) {
    tokio::time::timeout(Duration::from_secs(15), async {
        let started = Instant::now();
        let signal = FakeSignaling::start(FakeOptions::default()).await;
        let turn = TestTurn::start().await;
        let options =
            DialOptions { include_loopback: true, timeout: Duration::from_secs(5), ..DialOptions::default() };
        let phone_options = if relayed {
            DialOptions { relay_only: true, ice_servers: vec![turn.udp_only()], ..options.clone() }
        } else {
            options.clone()
        };
        let mac_id = uuid::Uuid::new_v4().to_string();
        let phone_id = uuid::Uuid::new_v4().to_string();
        let mac = SignalingClient::connect(&signal.base_url, "user:alice", "team", &mac_id).await.unwrap();
        let host = tokio::spawn(async move {
            let session = mac.next_session().await.unwrap();
            let events = SessionEvents {
                backend: mac.events(),
                session_id: session.first.session_id.clone(),
                session: session.events,
            };
            let connected =
                dial::answer(&mac, session.first, events, &options, LinkConfig::default()).await.unwrap();
            let mut incoming = connected.link.accept().await.unwrap();
            assert_eq!(incoming.lane, Lane::Input);
            let mut input = Vec::new();
            while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                let sequence = u64::from_be_bytes(bytes.as_ref().try_into().expect("one input record"));
                // Check at the host, before echo: a duplicated keystroke cannot be
                // hidden by receiver-side deduplication in this fixture.
                assert_eq!(sequence, input.len() as u64, "lost, duplicated, or reordered input");
                input.push(sequence);
                incoming.channel.send(bytes).await.unwrap();
            }
            input
        });
        let phone =
            SignalingClient::connect(&signal.base_url, "user:alice", "team", &phone_id).await.unwrap();
        let connected =
            dial::connect(&phone, &mac_id, TransportKind::WireGuard, &phone_options, LinkConfig::default())
                .await
                .unwrap();
        let mut channel = connected.link.open_on("echo", serde_json::json!({}), Lane::Input).await.unwrap();
        assert!(channel.sender.on_input_stream(), "dedicated production input stream");
        channel.send(Bytes::copy_from_slice(&0u64.to_be_bytes())).await.unwrap();
        assert_eq!(received(&mut channel).await.as_ref(), &0u64.to_be_bytes());
        let path = if relayed { LinkPath::Turn } else { LinkPath::Direct };
        assert_eq!(*connected.path.borrow(), path);
        let before = wireguard::session_endpoints(&connected.session_id, true).unwrap();
        assert!(!before.is_empty());
        let changed = Instant::now();
        assert_eq!(wireguard::simulate_network_loss(Some(&connected.session_id), true), 1);
        // Let the tunnel consume Blackhole before sending the first affected input.
        tokio::time::sleep(Duration::from_millis(25)).await;
        channel.send(Bytes::copy_from_slice(&1u64.to_be_bytes())).await.unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(75), channel.recv()).await.is_err(),
            "fault injection did not interrupt delivery"
        );
        for sequence in 2..=INPUTS {
            channel.send(Bytes::copy_from_slice(&sequence.to_be_bytes())).await.unwrap();
        }
        let remaining = RECOVERY_BUDGET.checked_sub(changed.elapsed()).expect("outage exceeded budget");
        tokio::time::timeout(remaining, async {
            let timeline = wireguard::roam_session(&connected.session_id, true).await.expect("live session");
            for sequence in 1..=INPUTS {
                assert_eq!(
                    received(&mut channel).await.as_ref(),
                    &sequence.to_be_bytes(),
                    "echo input {sequence}"
                );
            }
            assert!(timeline.marks().iter().any(|(name, _)| name == "roam_first_packet"));
        })
        .await
        .expect("same session must recover all input within 2 seconds");
        let recovery = changed.elapsed();
        let after = wireguard::session_endpoints(&connected.session_id, true).unwrap();
        assert_ne!(before, after, "roam must replace the socket / relayed address");
        assert_eq!(*connected.path.borrow(), path);
        assert!(!connected.link.is_closed(), "recovered existing session");
        drop(channel);
        let input = host.await.unwrap();
        assert_eq!(input, (0..=INPUTS).collect::<Vec<_>>());
        connected.link.close("test complete");
        eprintln!(
            "roaming_gate path={path:?} recovery_ms={} inputs={} wall_ms={}",
            recovery.as_millis(),
            input.len(),
            started.elapsed().as_millis()
        );
    })
    .await
    .expect("roaming gate must finish within 15 seconds including setup");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn direct_rebind_preserves_input() {
    transition(false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn turn_reallocation_preserves_input() {
    transition(true).await;
}
