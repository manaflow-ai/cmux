use super::{describe, team};
use base64::Engine as _;

fn jwt(payload: serde_json::Value) -> String {
    let part = |value: &serde_json::Value| {
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(value.to_string())
    };
    format!("{}.{}.c2ln", part(&serde_json::json!({"alg": "ES256", "kid": "k"})), part(&payload))
}

#[test]
fn a_sign_in_session_token_is_named_as_not_a_cmux_access_token() {
    // The Nightly sent this shape: a Stack session's access token, which has no team claim
    // and another issuer, so the production hub answered 401 machine.unauthorized.
    let token = jwt(serde_json::json!({
        "iss": "https://api.stack-auth.com/api/v1/projects/p1",
        "sub": "stack-user",
        "exp": 2_000,
    }));
    let said = describe(&token, 1_000);
    assert_eq!(
        said,
        "not a cmux access token (a sign-in session token? the hub refuses it): issuer \
             https://api.stack-auth.com/api/v1/projects/p1, team none, user stack-user, unexpired"
    );
    assert!(!said.contains(&token));
}

#[test]
fn a_cmux_access_token_names_its_team_and_expiry() {
    let token = jwt(serde_json::json!({
        "iss": "https://cmux-api/production",
        "sub": "user_1",
        "team": "team_d9753ae7bf17ea2f6eaf",
        "exp": 500,
    }));
    assert_eq!(
        describe(&token, 1_000),
        "a cmux access token: issuer https://cmux-api/production, team \
             team_d9753ae7bf17ea2f6eaf, user user_1, expired"
    );
    let teamless = jwt(serde_json::json!({"iss": "https://cmux-api/production", "sub": "u"}));
    assert!(describe(&teamless, 1_000).starts_with("a cmux access token with no team claim"));
    // The team a join minted with it lands in (a sign-in join elsewhere moves there).
    assert_eq!(team(&token).as_deref(), Some("team_d9753ae7bf17ea2f6eaf"));
    assert_eq!(team(&teamless), None);
    assert_eq!(team("cmm_opaque"), None);
}

#[test]
fn an_opaque_token_is_never_echoed() {
    let said = describe("cmm_secret-credential", 1_000);
    assert!(said.starts_with("an access token that is not a JWT"));
    assert!(!said.contains("secret"));
}
