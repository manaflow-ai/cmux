//! The phone's actual WireGuard handshake and channel mux across optional wire additions.
//! Complements mobile-pair-skew.sh (actual binaries from different commits): these tests
//! deliberately withhold capabilities or add future fields at the signaling boundary.
//! No daemon stub supplies the answer: bytes travel through both real WireGuard tunnels.
//!
//! cargo test -p cmux-mobile-link --test version_negotiation -- --nocapture

use std::{sync::Arc, time::Duration};

use bytes::Bytes;
use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::signaling::{SignalEnvelope, SignalPayload};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link::{
    ChannelEvent, DialOptions, LinkConfig, ResumeRegistry, SignalingClient, TransportKind,
};
use serde_json::json;

const BOUND: Duration = Duration::from_secs(15);

fn options(reliable: bool, input_lane: bool) -> DialOptions {
    DialOptions {
        include_loopback: true,
        timeout: Duration::from_secs(10),
        reliable,
        input_lane,
        ..DialOptions::default()
    }
}

async fn pair(
    legacy_version: bool,
    phone_reliable: bool,
    mac_reliable: bool,
    future: bool,
    input_lanes: (bool, bool),
) {
    let server =
        FakeSignaling::start(FakeOptions { strip_wg_version: legacy_version, ..FakeOptions::default() })
            .await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let phone_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let agreed = phone_reliable && mac_reliable;
    let answer = tokio::spawn(async move {
        let session = mac.next_session().await.expect("phone's real wg-init");
        let mut first = session.first;
        let SignalPayload::WgInit { version, .. } = &first.payload else {
            panic!("the phone did not start with wg-init")
        };
        if legacy_version {
            assert_eq!(*version, 0, "missing version must take the legacy path");
        }
        if future {
            // Transform the real offer, preserving its real ephemeral tunnel key/endpoints.
            // Deserialize with the production decoder, then answer with the production dialer.
            let mut wire = serde_json::to_value(&first).unwrap();
            wire["futureEnvelopeField"] = json!({"ignored": true});
            wire["payload"]["version"] = json!(99);
            wire["payload"]["futureCapability"] = json!({"revision": 7});
            wire["payload"]["lanes"].as_array_mut().unwrap().push(json!("future-lane-v99"));
            first = serde_json::from_value(wire).expect("additive fields are compatible");
        }
        let events = SessionEvents {
            backend: mac.events(),
            session_id: first.session_id.clone(),
            session: session.events,
        };
        let mac_options = DialOptions {
            resume_registry: Some(Arc::new(ResumeRegistry::default())),
            ..options(mac_reliable, input_lanes.1)
        };
        let connected = dial::answer(&mac, first, events, &mac_options, LinkConfig::default())
            .await
            .expect("real Mac handshake");
        assert_eq!(connected.link.reliable_stats().is_some(), agreed, "Mac's negotiated mode");
        let keys = connected.tunnel_keys.clone().expect("authenticated WireGuard keys");
        let mut incoming = connected.link.accept().await.expect("phone channel open");
        assert_eq!(incoming.service, "compatibility-probe");
        let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await else {
            panic!("phone payload missing")
        };
        assert_eq!(bytes.as_ref(), b"phone-to-mac");
        incoming.channel.send(Bytes::from_static(b"mac-to-phone")).await.unwrap();
        // Keep the tunnel alive until the phone confirms receipt.
        assert!(
            matches!(incoming.channel.recv().await, Some(ChannelEvent::Data(b)) if b.as_ref() == b"received")
        );
        (connected, keys, mac)
    });
    let connected = dial::connect(
        &phone,
        &mac_id,
        TransportKind::WireGuard,
        &options(phone_reliable, input_lanes.0),
        LinkConfig::default(),
    )
    .await
    .expect("real phone handshake");
    assert_eq!(connected.link.reliable_stats().is_some(), agreed, "phone's negotiated mode");
    let mut channel = connected.link.open("compatibility-probe", json!({})).await.unwrap();
    channel.send(Bytes::from_static(b"phone-to-mac")).await.unwrap();
    assert!(matches!(channel.recv().await, Some(ChannelEvent::Data(b)) if b.as_ref() == b"mac-to-phone"));
    connected.link.ping().await.expect("control round trip after channel data");
    channel.send(Bytes::from_static(b"received")).await.unwrap();
    let (host, keys, mac) = answer.await.unwrap();
    assert_eq!(connected.tunnel_keys.as_ref(), Some(&keys), "both ends authenticated the same tunnel");
    connected.link.close("done");
    host.link.close("done");
    phone.close();
    mac.close();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn legacy_version_zero_exchanges_real_channel_bytes() {
    tokio::time::timeout(BOUND, pair(true, true, true, false, (true, true))).await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn missing_reliable_capability_falls_back_in_both_directions() {
    for (phone, mac) in [(false, true), (true, false), (false, false)] {
        tokio::time::timeout(BOUND, pair(false, phone, mac, false, (true, true))).await.unwrap();
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn future_version_fields_and_lane_preserve_real_handshake() {
    tokio::time::timeout(BOUND, pair(false, true, true, true, (true, true))).await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn missing_input_lane_preserves_data_with_each_reliable_offer() {
    for input_lanes in [(false, true), (true, false), (false, false)] {
        for (phone, mac) in [(false, false), (false, true), (true, false), (true, true)] {
            tokio::time::timeout(BOUND, pair(false, phone, mac, false, input_lanes))
                .await
                .unwrap_or_else(|_| panic!("input={input_lanes:?}, reliable=({phone},{mac}) timed out"));
        }
    }
}

#[test]
fn mandatory_handshake_fields_are_not_optional_capabilities() {
    for kind in ["wg-init", "wg-resp"] {
        let valid = json!({"to":"mac","from":"phone","sessionId":"s","payload":{
            "kind":kind,"publicKey":"key","endpoints":[],"overlayIP":"10.0.0.1"}});
        let decoded: SignalEnvelope = serde_json::from_value(valid.clone()).expect("legacy fields suffice");
        assert!(matches!(
            decoded.payload,
            SignalPayload::WgInit { version: 0, .. } | SignalPayload::WgResp { version: 0, .. }
        ));
        for field in ["publicKey", "endpoints", "overlayIP"] {
            let mut missing = valid.clone();
            missing["payload"].as_object_mut().unwrap().remove(field);
            assert!(serde_json::from_value::<SignalEnvelope>(missing).is_err(), "{kind}: missing {field}");
        }
    }
}
