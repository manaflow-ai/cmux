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

/// A Cloud machine's sign-in failure says how to sign it in from the Mac, and nothing about
/// a terminal, a shell file or the CodeRouter.
#[test]
fn a_cloud_machine_says_only_how_to_sign_it_in() {
    let none = super::Found {
        home: dirs::home_dir().unwrap_or_default().join(".claude"),
        ..super::Found::default()
    };
    let text = super::compose_cloud(&none, "Not logged in · Please run /login", false);
    assert!(text.starts_with("Claude is not signed in here."), "{text}");
    // The gateway is named only where the machine's team has it.
    assert!(!text.contains(super::GATEWAY_OFFER), "{text}");
    assert!(text.contains("no Claude sign-in (Claude home ~/.claude)"), "{text}");
    assert!(text.contains("Set up Claude Code credentials"), "{text}");
    assert!(text.ends_with("(Claude said: Not logged in · Please run /login)"), "{text}");
    for word in ["terminal", "zshrc", "ANTHROPIC_API_KEY", "CodeRouter", "router", "fallback"] {
        assert!(!text.contains(word), "{word}: {text}");
    }
    // Not explained twice.
    assert!(!super::explains(&text));
    let had = super::Found { sources: vec!["a Claude.ai login".into()], ..none };
    let text = super::compose_cloud(&had, "API Error: 401 OAuth token has expired", false);
    assert!(text.contains("had a Claude.ai login, and Claude did not accept it"), "{text}");
}

/// A Cloud machine whose team cmux's gateway serves names that choice beside the sign-in,
/// and the gateway fallback's own failure is never explained again.
#[test]
fn a_cloud_machine_with_the_gateway_offers_it() {
    let none = super::Found::default();
    let text = super::compose_cloud(&none, "Not logged in · Please run /login", true);
    assert!(text.contains("Or click Use cmux's gateway"), "{text}");
    assert!(text.contains("Set up Claude Code credentials"), "{text}");
    assert!(text.ends_with("(Claude said: Not logged in · Please run /login)"), "{text}");
    assert!(!super::explains(&text));
    let fell_back = super::gateway_fallback_text("Not logged in · Please run /login");
    assert!(super::is_gateway_fallback(&fell_back), "{fell_back}");
    assert!(!super::explains(&fell_back));
    assert!(!super::is_gateway_fallback(&text));
    assert!(!super::is_gateway_fallback("Not logged in · Please run /login"));
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
