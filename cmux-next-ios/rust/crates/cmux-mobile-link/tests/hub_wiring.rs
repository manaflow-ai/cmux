//! The hub clients against the in-process hub relay, and lockstep both ways:
//! a new client against every older relay falls back to today's path, and a
//! client that does not offer `cmux-hub.v1` (every client before this one)
//! is refused by the hub without touching the room.

use std::time::Duration;

use cmux_mobile_link::hub::{
    HubError, HubNotice, HubParams, HubSource, HubViewer, ViewPlan, ViewerEvent, view,
};
use cmux_mobile_link::testing::{FakeHub, FakeHubMode};
use cmux_transport::hub::{HubFallback, HubPos, HubRole};
use cmux_transport::hub_truth::{TruthConfig, TruthEvent};
use tokio::time::timeout;

const WAIT: Duration = Duration::from_secs(5);

fn params(hub: &FakeHub, session: uuid::Uuid, device: u128) -> HubParams {
    HubParams {
        base_url: hub.base_url(),
        token: "user:hub-test".into(),
        build_space: None,
        session,
        device_id: uuid::Uuid::from_u128(device).to_string(),
        secret: [7; 32],
    }
}

async fn next_delivery(viewer: &mut HubViewer) -> (HubRole, HubPos, Vec<u8>) {
    loop {
        match timeout(WAIT, viewer.next()).await.expect("viewer event in time").expect("viewer open") {
            ViewerEvent::Truth(TruthEvent::Deliver { source, pos, event }) => return (source, pos, event),
            ViewerEvent::Closed => panic!("viewer closed"),
            _ => {}
        }
    }
}

async fn wait_for(viewer: &mut HubViewer, wanted: HubNotice) {
    loop {
        match timeout(WAIT, viewer.next()).await.expect("notice in time").expect("viewer open") {
            ViewerEvent::Notice(n) if n == wanted => return,
            ViewerEvent::Closed => panic!("viewer closed"),
            _ => {}
        }
    }
}

#[tokio::test]
async fn both_sources_publish_and_the_viewer_sees_each_event_once_in_order() {
    let hub = FakeHub::start(FakeHubMode::Hub).await.unwrap();
    let session = uuid::Uuid::new_v4();
    let mut viewer = HubViewer::join(&params(&hub, session, 3), TruthConfig::default()).await.unwrap();
    let mac = HubSource::join(&params(&hub, session, 1), HubRole::Mac).await.unwrap();
    let vm = HubSource::join(&params(&hub, session, 2), HubRole::Vm).await.unwrap();
    wait_for(&mut viewer, HubNotice::Source { role: HubRole::Vm, online: true }).await;

    for seq in 1..=20u64 {
        let event = format!("event {seq}").into_bytes();
        mac.publish(HubPos::new(1, seq), &event).unwrap();
        vm.publish(HubPos::new(1, seq), &event).unwrap();
    }
    for seq in 1..=20u64 {
        let (_, pos, event) = next_delivery(&mut viewer).await;
        assert_eq!(pos, HubPos::new(1, seq));
        assert_eq!(event, format!("event {seq}").into_bytes());
    }
    // Every position went to the viewers once; the other copy was dropped at the relay.
    tokio::time::sleep(Duration::from_millis(100)).await;
    let stats = hub.stats(&session);
    assert_eq!((stats.forwarded, stats.dropped), (20, 20));

    // The Mac sleeps mid-turn; the VM's copies keep the stream whole.
    mac.close();
    wait_for(&mut viewer, HubNotice::Source { role: HubRole::Mac, online: false }).await;
    for seq in 21..=30u64 {
        vm.publish(HubPos::new(1, seq), format!("event {seq}").as_bytes()).unwrap();
    }
    for seq in 21..=30u64 {
        let (source, pos, _) = next_delivery(&mut viewer).await;
        assert_eq!((source, pos), (HubRole::Vm, HubPos::new(1, seq)));
    }
}

#[tokio::test]
async fn the_sources_sync_through_the_room_without_the_viewers() {
    let hub = FakeHub::start(FakeHubMode::Hub).await.unwrap();
    let session = uuid::Uuid::new_v4();
    let mac = HubSource::join(&params(&hub, session, 1), HubRole::Mac).await.unwrap();
    let vm = HubSource::join(&params(&hub, session, 2), HubRole::Vm).await.unwrap();
    mac.sync_to_other(HubPos::new(1, 1), b"turn state").unwrap();
    let deadline = tokio::time::Instant::now() + WAIT;
    let synced = loop {
        let got = vm.take_synced();
        if !got.is_empty() || tokio::time::Instant::now() > deadline {
            break got;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    };
    assert_eq!(synced, vec![(HubPos::new(1, 1), b"turn state".to_vec())]);
    assert_eq!(hub.stats(&session).forwarded, 0, "a source-to-source frame is not a viewer frame");
}

#[tokio::test]
async fn a_new_client_falls_back_from_every_older_relay() {
    for (mode, want) in [
        (FakeHubMode::NoRoute, HubFallback::NoRoute),
        (FakeHubMode::Off, HubFallback::Off),
        (FakeHubMode::NoEcho, HubFallback::NoSubprotocol),
    ] {
        let hub = FakeHub::start(mode).await.unwrap();
        let session = uuid::Uuid::new_v4();
        match view(&params(&hub, session, 3), true, true, TruthConfig::default()).await {
            ViewPlan::Direct(Some(HubError::Fallback(got))) => assert_eq!(got, want, "{mode:?}"),
            ViewPlan::Direct(other) => panic!("{mode:?}: {other:?}"),
            ViewPlan::Hub(_) => panic!("{mode:?}: joined a relay that is not a hub"),
        }
        match HubSource::join(&params(&hub, session, 1), HubRole::Mac).await {
            Err(HubError::Fallback(got)) => assert_eq!(got, want, "{mode:?}"),
            Err(other) => panic!("{mode:?}: {other:?}"),
            Ok(_) => panic!("{mode:?}: a source joined a relay that is not a hub"),
        }
    }

    // A two-party relay that upgrades but refuses kind 4: the source hears it and falls back.
    let hub = FakeHub::start(FakeHubMode::KindRefused).await.unwrap();
    let mut mac = HubSource::join(&params(&hub, uuid::Uuid::new_v4(), 1), HubRole::Mac).await.unwrap();
    mac.publish(HubPos::new(1, 1), b"x").unwrap();
    assert_eq!(
        timeout(WAIT, mac.notice()).await.unwrap(),
        Some(HubNotice::Fallback(HubFallback::KindRefused))
    );
}

#[tokio::test]
async fn one_source_keeps_todays_path_without_asking() {
    let hub = FakeHub::start(FakeHubMode::Hub).await.unwrap();
    assert!(matches!(
        view(&params(&hub, uuid::Uuid::new_v4(), 3), true, false, TruthConfig::default()).await,
        ViewPlan::Direct(None)
    ));
}

#[tokio::test]
async fn a_client_that_does_not_offer_the_subprotocol_is_refused() {
    use tokio_tungstenite::tungstenite::Error;
    let hub = FakeHub::start(FakeHubMode::Hub).await.unwrap();
    let session = uuid::Uuid::new_v4();
    let url =
        format!("ws://{}/v1/hub/{session}?deviceId={}&role=viewer", hub.addr(), uuid::Uuid::from_u128(9));
    match tokio_tungstenite::connect_async(url).await {
        Err(Error::Http(response)) => assert_eq!(response.status().as_u16(), 426),
        other => panic!("expected 426, got {:?}", other.map(|_| ())),
    }
    assert_eq!(hub.stats(&session).forwarded, 0);
}

#[tokio::test]
async fn a_viewer_with_the_wrong_secret_delivers_nothing() {
    let hub = FakeHub::start(FakeHubMode::Hub).await.unwrap();
    let session = uuid::Uuid::new_v4();
    let mut wrong = params(&hub, session, 3);
    wrong.secret = [8; 32];
    let mut viewer = HubViewer::join(&wrong, TruthConfig::default()).await.unwrap();
    let mac = HubSource::join(&params(&hub, session, 1), HubRole::Mac).await.unwrap();
    mac.publish(HubPos::new(1, 1), b"secret").unwrap();
    loop {
        match timeout(WAIT, viewer.next()).await.unwrap().unwrap() {
            ViewerEvent::Rejected(_) => break,
            ViewerEvent::Truth(TruthEvent::Deliver { .. }) => panic!("delivered under the wrong key"),
            _ => {}
        }
    }
}
