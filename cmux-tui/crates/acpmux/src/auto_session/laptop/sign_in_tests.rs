use super::*;

#[test]
fn a_token_goes_only_to_the_api_that_issued_it() {
    let now = Instant::now();
    let issuer = Backend::Production.owner_api();
    let good = format!(
        r#"{{"access_token":"tok","expires_in":600,"api_origin":"{issuer}/","team":"t1"}}"#
    );
    let held = parse(good.as_bytes(), now, false);
    let signed_in = held.answer.unwrap();
    assert_eq!(signed_in.api, issuer);
    assert_eq!(signed_in.team.as_deref(), Some("t1"));
    assert_eq!(held.until, now + Duration::from_secs(540));

    let elsewhere = r#"{"access_token":"tok","api_origin":"https://example.com"}"#;
    assert!(parse(elsewhere.as_bytes(), now, true).answer.is_err());
    // A pull request's preview of the API is cmux's own; a look-alike host is not.
    let preview = "https://cmux-api-preview-42.debussy.workers.dev";
    let at_preview = format!(r#"{{"access_token":"tok","api_origin":"{preview}/"}}"#);
    assert_eq!(parse(at_preview.as_bytes(), now, false).answer.unwrap().api, preview);
    for other in [
        "https://cmux-api-preview-42.debussy.workers.dev.example.com",
        "https://cmux-api-preview-x.debussy.workers.dev",
        "http://127.0.0.1:8787",
        "preview-42",
        "dev",
    ] {
        let json = format!(r#"{{"access_token":"tok","api_origin":"{other}"}}"#);
        assert!(parse(json.as_bytes(), now, true).answer.is_err(), "{other}");
    }
    // A tag's own stack on the dev VM: a DEV build's daemon only.
    let stack = "https://cmux-dev-backend-1.tail137216.ts.net:4321";
    let at_stack = format!(r#"{{"access_token":"tok","api_origin":"{stack}/"}}"#);
    assert_eq!(parse(at_stack.as_bytes(), now, true).answer.unwrap().api, stack);
    assert!(parse(at_stack.as_bytes(), now, false).answer.is_err());
    let none = r#"{"access_token":"","api_origin":"x"}"#;
    assert!(parse(none.as_bytes(), now, false).answer.is_err());
    assert!(parse(b"not json", now, false).answer.is_err());
}
