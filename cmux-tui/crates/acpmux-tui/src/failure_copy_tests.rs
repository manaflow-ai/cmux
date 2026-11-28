use super::*;

#[test]
fn a_refused_key_and_an_expired_sign_in_read_apart() {
    // 65f286b81d6a: an expired OpenCode Go key never asks to sign in again.
    assert_eq!(kind("Internal error: This API key has expired."), Some(Kind::InvalidKey));
    assert_eq!(kind("Invalid API key · Please run /login"), Some(Kind::InvalidKey));
    assert_eq!(kind("OAuth token has expired. Please run /login"), Some(Kind::SignedOut));
    assert_eq!(kind("Not logged in · Please run /login"), Some(Kind::SignedOut));
    assert_eq!(
        sentence_for(r#"API Error: 403 {"type":"forbidden"}"#, None).as_deref(),
        Some("The provider refused the agent’s credentials (403).")
    );
}

#[test]
fn each_kind_says_what_to_do() {
    let cases = [
        ("write failed: ENOSPC", Kind::DiskFull),
        ("Prompt is too long", Kind::ContextFull),
        ("This organization has been disabled.", Kind::AccountDisabled),
        ("You've hit your weekly limit · resets Nov 27, 7am (UTC)", Kind::UsageLimit),
        ("Your credit balance is too low to access the Anthropic API", Kind::NoCredit),
        ("API Error: 529 Overloaded", Kind::RateLimited),
        ("tailscale: not connected", Kind::Tailscale),
        ("stream disconnected before completion: error sending request", Kind::Unreachable),
        ("connect ECONNREFUSED 127.0.0.1:443", Kind::Unreachable),
        ("agent process closed", Kind::AgentExited),
        ("failed to spawn claude: No such file or directory", Kind::SpawnFailed),
    ];
    for (message, want) in cases {
        assert_eq!(kind(message), Some(want), "{message}");
    }
    assert_eq!(
        sentence_for("Prompt is too long", Some("claude-sr")).as_deref(),
        Some("This chat is too long for Claude Code’s context window. Compact it, then retry.")
    );
    assert_eq!(
        sentence_for("API Error: 529 Overloaded", Some("codex")).as_deref(),
        Some("Codex is rate limited or out of capacity. Try again in a moment, or switch model.")
    );
}

#[test]
fn every_rule_compiles() {
    for rule in [
        &DISK_FULL,
        &CONTEXT_FULL,
        &ACCOUNT_DISABLED,
        &USAGE_LIMIT,
        &NO_CREDIT,
        &RATE,
        &INVALID_KEY,
        &SUBSCRIPTION,
        &AUTH,
        &STATUS,
        &TAILSCALE,
        &TAILNET_DOWN,
        &UNREACHABLE,
        &DROPPED,
        &AGENT_EXITED,
        &SPAWN_FAILED,
    ] {
        assert!(rule.0.is_some());
    }
}

#[test]
fn an_unknown_message_keeps_its_own_words() {
    assert_eq!(kind("The model replied with something odd"), None);
    assert_eq!(sentence_for("", None), None);
}
