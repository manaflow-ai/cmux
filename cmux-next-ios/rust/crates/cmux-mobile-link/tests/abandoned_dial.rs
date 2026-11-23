//! A phone dial given up before the Mac's answer came back says `bye`. The Mac ends what it
//! set up for that session at once, instead of holding a tunnel for a phone that left until its
//! own timeout. That happens when the phone's stale-socket check gives the dial up on a slow
//! but live socket (a lossy path), and when an app cancels a redial.

use std::time::Duration;

use cmux_mobile_link::dial;
use cmux_mobile_link::signaling::{SessionEvent, SignalPayload};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link::{DialOptions, LinkConfig, SignalingClient, TransportKind};

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_dial_dropped_before_the_answer_says_bye() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let phone_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();

    let dialing = {
        let (phone, mac_id) = (phone.clone(), mac_id.clone());
        tokio::spawn(async move {
            let options = DialOptions { include_loopback: true, ..DialOptions::default() };
            dial::connect(&phone, &mac_id, TransportKind::WireGuard, &options, LinkConfig::default()).await
        })
    };
    // The offer reaches the Mac, which does not answer yet; the phone gives the dial up.
    let mut session = tokio::time::timeout(Duration::from_secs(10), mac.next_session())
        .await
        .expect("the offer reaches the Mac")
        .expect("the Mac's socket is open");
    dialing.abort();
    let _ = dialing.await;

    let ended = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            match session.events.recv().await {
                Some(SessionEvent::Signal(envelope))
                    if matches!(envelope.payload, SignalPayload::Bye { .. }) =>
                {
                    return true;
                }
                Some(SessionEvent::Signal(_)) => {}
                Some(SessionEvent::Disconnected) | None => return false,
            }
        }
    })
    .await;
    assert_eq!(ended, Ok(true), "the Mac heard no bye for the abandoned session");
}
