//! A seeded Stack refresh token through hostd's gated client, on the wire
//! (cmux_egress::capture): the refresh token rides only in
//! `x-stack-refresh-token` of the one refresh POST, never in its path or body.
//! The capture server answers 200 `{}` (no access token), so the refresh fails
//! after it was sent; only what was sent is checked. tests/egress_seeded.json
//! names this test for the `cmux_mobile_host::auth` gate site.

use cmux_egress::capture;
use cmux_mobile_host::auth::{TokenSource, Tokens};

const HOST: &str = "api.stack-auth.com";

#[tokio::test]
async fn the_refresh_token_rides_only_in_its_header() {
    cmux_mobile_link::install_crypto_provider();
    capture::install().unwrap();
    let refresh = "SEEDhostdRefresh-9f30";
    let project = "SEEDhostdProject-14bd";
    let tokens = Tokens::new(TokenSource::Refresh {
        refresh_token: refresh.to_owned(),
        project_id: project.to_owned(),
        publishable_key: Some("SEEDhostdPublishable-5c21".to_owned()),
        api: format!("https://{HOST}"),
    });
    assert!(tokens.access_token().await.is_err(), "the capture server sends no access token");

    let sent = capture::requests_to(HOST);
    let refreshes: Vec<_> =
        sent.iter().filter(|r| r.target == "/api/v1/auth/sessions/current/refresh").collect();
    assert_eq!(refreshes.len(), 1, "{sent:?}");
    assert_eq!(refreshes[0].method, "POST");
    assert_eq!(refreshes[0].body, b"{}");
    assert_eq!(
        capture::leaks(refresh),
        [format!("{HOST} POST /api/v1/auth/sessions/current/refresh: header x-stack-refresh-token")]
    );
    let places = capture::leaks(project);
    assert!(places.len() == 1 && places[0].ends_with(": header x-stack-project-id"), "{places:?}");
}
