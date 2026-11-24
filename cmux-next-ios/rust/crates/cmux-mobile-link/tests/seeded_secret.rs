//! Seeded secrets through every gated client this crate builds, on the wire
//! (cmux_egress::capture): the Stack token rides only in `Authorization`, on the
//! pairing API's requests, the signaling upgrade and the hub join; the team,
//! device and session ride only in the path or query they name. The capture
//! server answers 200 `{}`, so each call fails after it was sent; only what was
//! sent is checked. tests/egress_seeded.json names these tests for the
//! `cmux_mobile_link::api`, `::signaling` and `::hub` gate sites.

use cmux_egress::capture;
use cmux_mobile_link::SignalingClient;
use cmux_mobile_link::api::ApiClient;
use cmux_mobile_link::hub::{HubParams, HubSource};
use cmux_transport::hub::HubRole;

const HOST: &str = "mobile-api.cmux.dev";

fn start() -> String {
    cmux_mobile_link::install_crypto_provider();
    capture::install().unwrap();
    format!("https://{HOST}")
}

/// Every place `secret` was sent is an `Authorization` header, and there are `count`.
fn only_in_authorization(secret: &str, count: usize) {
    let places = capture::leaks(secret);
    assert_eq!(places.len(), count, "{places:?}");
    assert!(places.iter().all(|p| p.ends_with(": header authorization")), "{places:?}");
}

#[tokio::test]
async fn the_api_token_rides_only_in_authorization() {
    let base = start();
    let token = "SEEDmobileApiToken-3e9a";
    let api = ApiClient::new(&base, token);
    let _ = api.ice().await;
    let _ = api.my_devices().await;
    let _ = api.macs("SEEDapiTeam-71c2").await;

    let sent = capture::requests_to(HOST);
    for target in ["/v1/ice", "/v1/me/devices", "/v1/teams/SEEDapiTeam-71c2/macs"] {
        assert!(sent.iter().any(|r| r.target == target), "{target}: {sent:?}");
    }
    only_in_authorization(token, 3);
    let places = capture::leaks("SEEDapiTeam-71c2");
    assert!(places.iter().all(|p| p.ends_with(": target")), "{places:?}");
}

#[tokio::test]
async fn the_signaling_token_rides_only_in_authorization() {
    let base = start();
    let token = "SEEDmobileSignalToken-8d14";
    let team = "SEEDsignalTeam-0b5f";
    let refused = SignalingClient::connect(&base, token, team, "SEEDsignalDevice-62aa").await;
    assert!(refused.is_err(), "the capture server answers 200, not an upgrade");

    let sent = capture::requests_to(HOST);
    let upgrade = sent
        .iter()
        .find(|r| r.target.starts_with(&format!("/v1/teams/{team}/signal")))
        .unwrap_or_else(|| panic!("{sent:?}"));
    assert!(upgrade.headers.iter().any(|(n, v)| n == "upgrade" && v == "websocket"), "{upgrade:?}");
    only_in_authorization(token, 1);
    let places = capture::leaks("SEEDsignalDevice-62aa");
    assert!(places.len() == 1 && places[0].ends_with(": target"), "{places:?}");
}

#[tokio::test]
async fn the_hub_token_rides_only_in_authorization() {
    let base = start();
    let token = "SEEDmobileHubToken-c47e";
    let session = uuid::Uuid::from_u128(0x5eed_0000_0000_4000_8000_0000_0000_00c4);
    let params = HubParams {
        base_url: base,
        token: token.to_owned(),
        build_space: None,
        session,
        device_id: "5eed0000-0000-4000-8000-0000000000d1".to_owned(),
        secret: [0x5e; 32],
    };
    assert!(HubSource::join(&params, HubRole::Mac).await.is_err(), "the capture server answers 200");

    let sent = capture::requests_to(HOST);
    let join = sent
        .iter()
        .find(|r| r.target.starts_with(&format!("/v1/hub/{session}")))
        .unwrap_or_else(|| panic!("{sent:?}"));
    assert!(join.headers.iter().any(|(n, v)| n == "upgrade" && v == "websocket"), "{join:?}");
    only_in_authorization(token, 1);
    // The room secret never leaves the device: not raw, not as hex.
    let hex: String = params.secret.iter().map(|b| format!("{b:02x}")).collect();
    assert!(capture::leaks(&hex).is_empty());
    assert!(sent.iter().all(|r| !r.body.windows(32).any(|w| w == params.secret)), "{sent:?}");
}
