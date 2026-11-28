use cmux_mobile_link::api::{ApiClient, IceServer};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};

#[tokio::test]
async fn old_and_new_ice_clients_interoperate_with_scoped_fake_hop_tickets() {
    // A response from an old backend has no additive field. New clients keep
    // the ordinary STUN row and simply see no hop candidate.
    let old_backend = FakeSignaling::start(FakeOptions::default()).await;
    let old = ApiClient::new(&old_backend.base_url, "user:alice").ice().await.unwrap();
    assert!(old.hop_servers.is_empty());
    assert!(old.ice_servers.iter().all(|server| server.hop_config().is_none()));

    // The new fake backend's open PoP mode mints a different dev ticket for
    // each HTTP response. A legacy client deserializing only iceServers still
    // ignores hopServers, while the new ApiClient normalizes the hop row.
    let new_backend = FakeSignaling::start(FakeOptions {
        hop_servers: vec![cmux_mobile_link::api::HopServer {
            kind: Some("hop".into()),
            url: Some("hop://127.0.0.1:7422".into()),
            ticket: None,
        }],
        ..FakeOptions::default()
    })
    .await;
    let first = ApiClient::new(&new_backend.base_url, "user:alice").ice().await.unwrap();
    let second = ApiClient::new(&new_backend.base_url, "user:alice").ice().await.unwrap();
    let first_hop = first.ice_servers.iter().find_map(IceServer::hop_config).expect("new hop");
    let second_hop = second.ice_servers.iter().find_map(IceServer::hop_config).expect("new hop");
    assert_ne!(first_hop.1, second_hop.1, "tickets are not reused across dials");

    let mut retry = first.ice_servers.clone();
    ApiClient::new(&new_backend.base_url, "user:alice")
        .renew_hop_tickets(&mut retry, std::time::Duration::from_secs(2))
        .await;
    assert_ne!(retry.iter().find_map(IceServer::hop_config).unwrap().1, first_hop.1);
    assert_eq!(retry.iter().filter(|server| server.hop_config().is_none()).count(), old.ice_servers.len());

    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct LegacyResponse {
        ice_servers: Vec<IceServer>,
    }
    let raw = reqwest::Client::new()
        .get(format!("{}/v1/ice", new_backend.base_url))
        .header("authorization", "Bearer user:alice")
        .send()
        .await
        .unwrap()
        .json::<serde_json::Value>()
        .await
        .unwrap();
    let legacy: LegacyResponse = serde_json::from_value(raw).unwrap();
    assert!(legacy.ice_servers.iter().all(|server| server.hop_config().is_none()));
}
