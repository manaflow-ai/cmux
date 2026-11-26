//! Seeded secrets through this crate's gated clients, on the wire (cmux_egress::capture): the
//! Stack token rides only in `Authorization`, and the hub's shared session secret goes nowhere.
//! tests/egress_seeded.json names these tests for the `cmux_mobile_link::api`,
//! `cmux_mobile_link::dial::relay`, `cmux_mobile_link::hub` and `cmux_mobile_link::signaling` gate sites.

use cmux_egress::capture;
use cmux_mobile_link::api::ApiClient;
use cmux_mobile_link::dial::relay::{RelayCarrier, RelayEndpoint};
use cmux_mobile_link::hub::{HubParams, HubSource};
use cmux_mobile_link::signaling::SignalingClient;
use cmux_transport::hub::HubRole;

const HOST: &str = "mobile-api.cmux.dev";

fn setup() {
    cmux_mobile_link::install_crypto_provider();
    capture::install().unwrap();
}

/// Every place `secret` was sent must be the `Authorization` header of a request to HOST whose
/// target starts with `prefix`, and there must be `want` of them.
fn only_in_authorization(secret: &str, prefix: &str, want: usize) {
    let places = capture::leaks(secret);
    assert_eq!(places.len(), want, "{places:?}");
    let head = format!("{HOST} ");
    for place in &places {
        assert!(place.starts_with(&head), "{place}");
        assert!(place.ends_with(": header authorization"), "{place}");
        assert!(place.contains(prefix), "{place}");
    }
}

#[tokio::test]
async fn api_bearer_rides_only_in_authorization() {
    setup();
    let token = "SEEDmobileApiBearer-3b7e";
    let api = ApiClient::new(&format!("https://{HOST}"), token);
    let _ = api.ice().await;
    let sent = capture::requests_to(HOST);
    assert!(sent.iter().any(|r| r.target == "/v1/ice"), "{sent:?}");
    only_in_authorization(token, "/v1/ice", 1);
}

#[tokio::test]
async fn relay_join_sends_the_token_only_in_authorization() {
    setup();
    let token = "SEEDrelayBearer-9c41";
    let session = "5e1d0c4a-0000-4000-8000-00000000a11a";
    let device = "d0d0d0d0-0000-4000-8000-00000000beef";
    let endpoint = RelayEndpoint::with_token(format!("https://{HOST}"), None, device, token);
    // The capture server answers the upgrade `200`, so the join fails after the request was seen.
    assert!(RelayCarrier::join(&endpoint, session, device, Some("ticket-1")).await.is_err());
    let sent = capture::requests_to(HOST);
    assert!(sent.iter().any(|r| r.target.starts_with(&format!("/v1/relay/{session}"))), "{sent:?}");
    only_in_authorization(token, "/v1/relay/", 1);
}

#[tokio::test]
async fn hub_join_sends_the_token_only_in_authorization_and_the_secret_nowhere() {
    setup();
    let token = "SEEDhubBearer-71f2";
    let secret = *b"SEEDhubSharedSecret-never-sent!!";
    let params = HubParams {
        base_url: format!("https://{HOST}"),
        token: token.to_owned(),
        build_space: None,
        session: uuid::Uuid::parse_str("6a2e0c4a-0000-4000-8000-00000000c0de").unwrap(),
        device_id: "d1d1d1d1-0000-4000-8000-00000000f00d".to_owned(),
        secret,
    };
    assert!(HubSource::join(&params, HubRole::Mac).await.is_err());
    let sent = capture::requests_to(HOST);
    assert!(sent.iter().any(|r| r.target.starts_with("/v1/hub/")), "{sent:?}");
    only_in_authorization(token, "/v1/hub/", 1);
    let secret = std::str::from_utf8(&secret).unwrap();
    assert!(capture::leaks(secret).is_empty(), "{:?}", capture::leaks(secret));
}

#[tokio::test]
async fn signaling_upgrade_sends_the_token_only_in_authorization() {
    setup();
    let token = "SEEDsignalBearer-4d8a";
    let team = "team-seeded";
    let device = "d2d2d2d2-0000-4000-8000-00000000cafe";
    // The capture server answers the upgrade `200`, so the connect fails after the request was seen.
    assert!(SignalingClient::connect(&format!("https://{HOST}"), token, team, device).await.is_err());
    let sent = capture::requests_to(HOST);
    assert!(sent.iter().any(|r| r.target.starts_with(&format!("/v1/teams/{team}/signal"))), "{sent:?}");
    only_in_authorization(token, "/v1/teams/", 1);
}
