//! Seeded secrets through hostd's Stack refresh, on the wire (cmux_egress::capture): the refresh
//! token rides only in `x-stack-refresh-token` and the publishable key only in its own header, to
//! the Stack API and nowhere else. tests/egress_seeded.json names this test for the
//! `cmux_mobile_host::auth` gate site.

use cmux_egress::capture;
use cmux_mobile_host::auth::{TokenSource, Tokens};

const HOST: &str = "api.stack-auth.com";

#[tokio::test]
async fn the_refresh_token_rides_only_in_its_header() {
    cmux_mobile_link::install_crypto_provider();
    capture::install().unwrap();
    let refresh = "SEEDstackRefreshToken-5d0a";
    let key = "SEEDpublishableKey-e81c";
    let tokens = Tokens::new(TokenSource::Refresh {
        refresh_token: refresh.to_owned(),
        project_id: "seeded-project".to_owned(),
        publishable_key: Some(key.to_owned()),
        api: format!("https://{HOST}"),
    });
    // The capture server answers `200 {}`: no access token, so the refresh fails after it was sent.
    assert!(tokens.access_token().await.is_err());

    let sent = capture::requests_to(HOST);
    assert_eq!(
        sent.iter().filter(|r| r.target == "/api/v1/auth/sessions/current/refresh").count(),
        1,
        "{sent:?}"
    );
    assert_eq!(
        capture::leaks(refresh),
        vec![format!("{HOST} POST /api/v1/auth/sessions/current/refresh: header x-stack-refresh-token")]
    );
    assert_eq!(
        capture::leaks(key),
        vec![format!(
            "{HOST} POST /api/v1/auth/sessions/current/refresh: header x-stack-publishable-client-key"
        )]
    );
}
