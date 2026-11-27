use super::*;

/// A sign-in failure is explained; one that says the provider was unreachable is not.
#[test]
fn an_outage_that_names_a_token_is_not_explained_as_a_sign_in() {
    assert!(super::explains("Not logged in · Please run /login"));
    assert!(super::explains("API Error: 401 OAuth token has expired"));
    assert!(!super::explains("HTTP 503: OAuth token has expired"));
    assert!(!super::explains("connection error: Not logged in"));
    assert!(!super::explains("Claude is not signed in here. Not logged in"));
}

/// A Cloud machine's sign-in failure points at its model route (an account or a gateway), never
/// at a terminal, a shell file or a login copied from the Mac.
#[test]
fn a_cloud_machine_points_at_its_model_route() {
    let none = super::Found {
        home: dirs::home_dir().unwrap_or_default().join(".claude"),
        ..super::Found::default()
    };
    let text = super::compose_cloud(&none, "Not logged in · Please run /login", false);
    assert!(text.starts_with("Claude is not signed in here."), "{text}");
    // The gateway is named only where the machine's team has it.
    assert!(!text.contains(super::GATEWAY_OFFER), "{text}");
    assert!(text.contains("has no model route (Claude home ~/.claude)"), "{text}");
    // A fresh account's machine runs the current image and still has no route on staging and
    // production (`cloud_model_plane::machine_plane`): a new machine changes nothing, so the
    // text never sends the person to make one; it names the card's sign-in.
    assert!(!text.contains("new machine"), "{text}");
    assert!(text.contains("Sign in to Claude"), "{text}");
    assert!(text.ends_with("(Claude said: Not logged in · Please run /login)"), "{text}");
    let routed = super::Found { endpoint: Some("coderouter.cmux.internal".into()), ..none };
    let text = super::compose_cloud(&routed, "API Error: 403 No Claude upstream account", false);
    assert!(text.contains("through the Cloud service"), "{text}");
    assert!(text.contains("cmux inference setup"), "{text}");
    for text in [
        super::compose_cloud(&routed, "x", false),
        super::compose_cloud(&super::Found::default(), "x", false),
    ] {
        for word in [
            "terminal",
            "zshrc",
            "ANTHROPIC_API_KEY",
            "credentials",
            "from your Mac",
            "setup-token",
            "/login",
        ] {
            assert!(!text.contains(word), "{word}: {text}");
        }
        // Not explained twice.
        assert!(!super::explains(&text));
    }
}

/// A Cloud machine whose team cmux's gateway serves names that choice beside the sign-in,
/// and the gateway fallback's own failure is never explained again.
#[test]
fn a_cloud_machine_with_the_gateway_offers_it() {
    let none = super::Found::default();
    let text = super::compose_cloud(&none, "Not logged in · Please run /login", true);
    assert!(text.contains("Or click Use cmux's gateway"), "{text}");
    // No login is copied from the Mac to a Cloud machine: the text never offers that.
    assert!(!text.contains("Set up Claude Code credentials"), "{text}");
    assert!(text.ends_with("(Claude said: Not logged in · Please run /login)"), "{text}");
    assert!(!super::explains(&text));
    let fell_back = super::gateway_fallback_text("Not logged in · Please run /login");
    assert!(super::is_gateway_fallback(&fell_back), "{fell_back}");
    assert!(!super::explains(&fell_back));
    assert!(!super::is_gateway_fallback(&text));
    assert!(!super::is_gateway_fallback("Not logged in · Please run /login"));
}

/// A route that was only late (production cloud-chat-replies 2026-11-26): its text is not the
/// sign-in explanation, is not the gateway's, and is the one the first send goes again on.
#[test]
fn a_late_route_is_not_a_sign_in_ask() {
    let text = super::route_arrived_text("Not logged in · Please run /login ");
    assert!(super::is_route_arrived(&text), "{text}");
    assert!(!super::is_gateway_fallback(&text));
    assert!(!super::explains(&text));
    assert!(text.ends_with("(Claude said: Not logged in · Please run /login)"), "{text}");
    assert!(!super::is_route_arrived(&super::gateway_fallback_text("Not logged in")));
    assert!(!super::is_route_arrived("Not logged in · Please run /login"));
}

/// Dogfood 2026-10-26: Claude Code's 401 ("Failed to authenticate") reached the person as
/// raw API text instead of the sign-in explanation.
#[test]
fn a_rejected_credential_is_a_sign_in_failure() {
    let said = r#"Failed to authenticate. API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#;
    assert!(is_sign_in_failure(said));
    assert!(is_sign_in_failure("Not logged in · Please run /login"));
    assert!(!is_sign_in_failure("API Error: 529 overloaded_error"));
}

/// A rejected ANTHROPIC_API_KEY wins over `claude auth login`, so the fix names the key, not a
/// login that would not help.
#[test]
fn a_rejected_env_api_key_says_to_remove_it() {
    let agent = Found {
        home: PathBuf::from("/h/.claude"),
        sources: vec!["an API key (ANTHROPIC_API_KEY)".to_owned()],
        env_keys: vec!["ANTHROPIC_API_KEY".to_owned()],
        ..Found::default()
    };
    let text =
        compose(&agent, &agent, Some("/bin/zsh"), "Failed to authenticate. API Error: 401", false);
    assert!(text.contains("remove ANTHROPIC_API_KEY from ~/.zshrc"), "{text}");
    assert!(!text.contains("Run `claude auth login`"), "{text}");

    // Review of #25950: a route's key (with its endpoint) is not the person's to remove.
    let routed = Found { endpoint: Some("router.example:443".to_owned()), ..agent };
    let text = compose(
        &routed,
        &routed,
        Some("/bin/zsh"),
        "Failed to authenticate. API Error: 401",
        false,
    );
    assert!(!text.contains("remove ANTHROPIC_API_KEY"), "{text}");
}

#[test]
fn a_subscription_route_without_a_key_keeps_login_advice() {
    let agent = Found::default();
    let text = compose(&agent, &agent, None, "Not logged in", true);
    assert!(text.contains("Run `claude auth login`"), "{text}");
    assert!(!text.contains("selected model route"), "{text}");
}

#[test]
fn a_routed_api_key_without_an_endpoint_says_to_change_the_route() {
    let home = tempfile::tempdir().unwrap();
    let mut profile: crate::config::HarnessProfile = serde_json::from_value(serde_json::json!({
        "kind": "claude-stdio",
        "argv": ["claude"],
        "env": {
            "HOME": home.path(),
            "CLAUDE_CONFIG_DIR": home.path(),
            (crate::agent::REMOTE_ENV_POLICY_KEY): "1"
        }
    }))
    .unwrap();
    crate::routes::apply(
        &mut profile.env,
        &crate::routes::RouteEnv {
            set: BTreeMap::from([("ANTHROPIC_API_KEY".into(), "rejected-test-key".into())]),
            unset: crate::routes::SCRUBBED.iter().map(|key| (*key).to_owned()).collect(),
        },
    );
    let id = "claude-auth-routed-key-without-endpoint";
    let _command = crate::agent::harness_command(
        "claude",
        &profile,
        home.path(),
        None,
        Some((id, "route auth test")),
    )
    .unwrap();
    let text = explain(id, "Failed to authenticate. API Error: 401", false, false).unwrap();
    forget(id);
    assert!(text.contains("route"), "{text}");
    assert!(!text.contains("remove ANTHROPIC_API_KEY"), "{text}");
    assert!(!text.contains("rejected-test-key"), "{text}");
}

/// Only a revoked token is one: not an expired or missing sign-in, nor an outage.
#[test]
fn a_revoked_token_is_told_from_other_sign_in_failures() {
    use super::is_revoked_token as revoked;
    assert!(revoked("Failed to authenticate: OAuth token revoked"));
    assert!(revoked("Failed to authenticate: oauth TOKEN REVOKED"));
    assert!(revoked(
        r#"API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"OAuth token has been revoked. Please obtain a new token or refresh your existing token."}}"#
    ));
    assert!(!revoked("API Error: 401 OAuth token has expired"));
    assert!(!revoked("Not logged in · Please run /login"));
    assert!(!revoked("Invalid API key · Fix external API key"));
    assert!(!revoked("HTTP 503 service unavailable: OAuth token revoked"));
    assert!(!revoked("stream disconnected: OAuth token has been revoked"));
    assert!(!revoked("the revoked token list was refreshed"));
}

/// cmux#57418: a Cloud chat whose sign-in from the Mac the machine lost to an acpmux restart
/// says that, not that the person has no account for Cloud; and it is never explained again.
#[test]
fn a_lost_cloud_sign_in_says_it_was_lost() {
    let text = super::lost_credential_text(" Not logged in · Please run /login ");
    assert!(text.starts_with("Claude is not signed in here"), "{text}");
    assert!(text.contains("lost the Claude sign-in your Mac sent"), "{text}");
    assert!(!text.contains("has no model route"), "{text}");
    assert!(text.ends_with("(Claude said: Not logged in · Please run /login)"), "{text}");
    assert!(!super::explains(&text));
}
