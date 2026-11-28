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
use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest};

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

// Change the real Mac response on the wire, before the phone's production
// signaling decoder sees it. Everything else, including keys and endpoints,
// passes through unchanged; the proxy never manufactures a handshake answer.
async fn future_response_proxy(backend: &str, phone_id: &str) -> (String, tokio::task::JoinHandle<usize>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let mut request = cmux_mobile_link::signaling::signal_url(backend, "team", phone_id)
        .unwrap()
        .into_client_request()
        .unwrap();
    request.headers_mut().insert("authorization", "Bearer user:alice".parse().unwrap());
    let task = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        let phone = tokio_tungstenite::accept_async(socket).await.unwrap();
        let (backend, _) = tokio_tungstenite::connect_async(request).await.unwrap();
        let (mut phone_write, mut phone_read) = phone.split();
        let (mut backend_write, mut backend_read) = backend.split();
        let mut responses = 0;
        loop {
            tokio::select! {
                message = phone_read.next() => {
                    let Some(message) = message else { break };
                    let message = message.expect("phone signaling frame");
                    if matches!(message, Message::Close(_)) { break; }
                    backend_write.send(message).await.expect("forward phone signaling");
                }
                message = backend_read.next() => {
                    let mut message = message.expect("backend signaling stays open")
                        .expect("backend signaling frame");
                    if let Message::Text(text) = &message {
                        let mut wire: serde_json::Value = serde_json::from_str(text).unwrap();
                        if wire["type"] == "signal" && wire["payload"]["kind"] == "wg-resp" {
                            wire["futureEnvelopeField"] = json!({"ignored": true});
                            wire["payload"]["version"] = json!(99);
                            wire["payload"]["futureCapability"] = json!({"revision": 7});
                            wire["payload"]["lanes"].as_array_mut().unwrap()
                                .push(json!("future-lane-v99"));
                            message = Message::Text(wire.to_string().into());
                            responses += 1;
                        }
                    }
                    phone_write.send(message).await.expect("forward Mac signaling");
                }
            }
        }
        responses
    });
    (base, task)
}

async fn pair(
    legacy_version: bool,
    phone_reliable: bool,
    mac_reliable: bool,
    (future_offer, future_response): (bool, bool),
    input_lanes: (bool, bool),
) {
    let server =
        FakeSignaling::start(FakeOptions { strip_wg_version: legacy_version, ..FakeOptions::default() })
            .await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let phone_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let proxy =
        if future_response { Some(future_response_proxy(&server.base_url, &phone_id).await) } else { None };
    let phone_base = proxy.as_ref().map_or(server.base_url.as_str(), |(base, _)| base.as_str());
    let phone = SignalingClient::connect(phone_base, "user:alice", "team", &phone_id).await.unwrap();
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
        if future_offer {
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
    if let Some((_, proxy)) = proxy {
        assert_eq!(proxy.await.expect("response proxy must not panic"), 1, "mutated the real wg-resp");
    }
    mac.close();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn legacy_version_zero_exchanges_real_channel_bytes() {
    tokio::time::timeout(BOUND, pair(true, true, true, (false, false), (true, true))).await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn missing_reliable_capability_falls_back_in_both_directions() {
    for (phone, mac) in [(false, true), (true, false), (false, false)] {
        tokio::time::timeout(BOUND, pair(false, phone, mac, (false, false), (true, true))).await.unwrap();
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn future_version_fields_and_lane_preserve_real_handshake() {
    tokio::time::timeout(BOUND, pair(false, true, true, (true, false), (true, true))).await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn future_response_fields_and_lane_preserve_real_handshake() {
    // A future Mac answering today's phone, then both sides adding fields.
    for future_offer in [false, true] {
        tokio::time::timeout(BOUND, pair(false, true, true, (future_offer, true), (true, true)))
            .await
            .unwrap();
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn missing_input_lane_preserves_data_with_each_reliable_offer() {
    for input_lanes in [(false, true), (true, false), (false, false)] {
        for (phone, mac) in [(false, false), (false, true), (true, false), (true, true)] {
            tokio::time::timeout(BOUND, pair(false, phone, mac, (false, false), input_lanes))
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
