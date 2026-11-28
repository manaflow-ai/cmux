//! Workstream 12 (Cloud Chiefs): a Chief host on a cmux Cloud machine answered every turn with
//! "Claude is not signed in here". Staging and production machines have no shared model route
//! (cmux-platform `CoderouterEdge.ts`; acpmux `cloud_model_plane.rs` drops it), and a Chief turn
//! got neither a login nor the credential a Cloud chat's launch carries.
//!
//! These pin the environment a Chief's Claude turn gets: the preset never overrides the login or
//! the route (so a machine sign-in, a route, or the launch credential reaches the turn), and an
//! opted-in host sends its credential with its own Claude sessions only.

use optchat_chief::acpmux::{CHIEF_TAG, Family, SessionSpec, chief_tags};
use optchat_chief::host::turn_preset;
use optchat_chief::turn_credential::{self, Credential, OPT_IN_ENV};
use std::collections::BTreeMap;

/// What decides where a Claude turn signs in and which endpoint it calls. A preset that set any of
/// these would outrank the machine's sign-in, route, or the launch credential acpmux applies.
const LOGIN_AND_ROUTE: [&str; 11] = [
    "HOME",
    "CLAUDE_CONFIG_DIR",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_CUSTOM_HEADERS",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
    "CMUX_CODEROUTER_URL",
];

#[test]
fn a_claude_turn_preset_leaves_login_and_route_alone() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("mux");
    let paths = optchat_chief::paths::Paths::new(&home);
    for harness in ["claude", "claude-sr", "claude-sr2"] {
        for isolate in [true, false] {
            let preset =
                turn_preset(&paths, &home, harness, Family::Claude, isolate, "SYS").unwrap();
            for key in LOGIN_AND_ROUTE {
                assert!(
                    !preset.env.contains_key(key),
                    "{harness} isolate={isolate} sets {key}: {:?}",
                    preset.env.keys()
                );
            }
        }
    }
}

fn lookup(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
    let map: BTreeMap<String, String> = pairs
        .iter()
        .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
        .collect();
    move |k| map.get(k).cloned()
}

#[test]
fn only_an_opted_in_host_takes_a_credential() {
    let none = turn_credential::from_env(&lookup(&[("CLAUDE_CODE_OAUTH_TOKEN", "tok")]));
    assert!(
        none.is_none(),
        "a host without {OPT_IN_ENV} keeps today's behavior"
    );
    let token = turn_credential::from_env(&lookup(&[
        (OPT_IN_ENV, "1"),
        ("ANTHROPIC_API_KEY", "key"),
        ("CLAUDE_CODE_OAUTH_TOKEN", "tok"),
    ]))
    .unwrap();
    assert_eq!(token.name(), "CLAUDE_CODE_OAUTH_TOKEN");
    assert!(
        !format!("{token:?}").contains("tok"),
        "Debug never shows the value"
    );
    let key = turn_credential::from_env(&lookup(&[
        (OPT_IN_ENV, "1"),
        ("CLAUDE_CODE_OAUTH_TOKEN", "  "),
        ("ANTHROPIC_API_KEY", "key"),
    ]))
    .unwrap();
    assert_eq!(key.name(), "ANTHROPIC_API_KEY");
    assert!(turn_credential::from_env(&lookup(&[(OPT_IN_ENV, "1")])).is_none());
}

fn credential() -> Credential {
    turn_credential::from_env(&lookup(&[
        (OPT_IN_ENV, "1"),
        ("CLAUDE_CODE_OAUTH_TOKEN", "tok"),
    ]))
    .unwrap()
}

fn spec(harness: &str, role: Option<&str>, peer: Option<&str>) -> SessionSpec {
    SessionSpec {
        harness: harness.to_owned(),
        tags: role.map(|r| chief_tags("home", r)).unwrap_or_default(),
        peer: peer.map(str::to_owned),
        ..Default::default()
    }
}

#[test]
fn the_credential_goes_to_the_chiefs_own_claude_sessions_only() {
    let cred = credential();
    let turn = spec("claude", Some("turn"), None);
    assert!(turn.tags.contains_key(CHIEF_TAG));
    assert_eq!(
        turn_credential::meta_for(&turn, Some(&cred)),
        Some(serde_json::json!({"env": {"CLAUDE_CODE_OAUTH_TOKEN": "tok"}})),
        "the field acpmux agent_credentials::requested reads"
    );
    let compactor = spec("claude", Some("compactor"), None);
    assert!(turn_credential::meta_for(&compactor, Some(&cred)).is_some());
    // Not to another Claude route (it would lose its own route), Codex, a peer machine's
    // session, or a session that is not the Chief's own.
    for other in [
        spec("claude-sr2", Some("turn"), None),
        spec("codex", Some("turn"), None),
        spec("claude", Some("turn"), Some("peer-vm")),
        spec("claude", None, None),
    ] {
        assert_eq!(
            turn_credential::meta_for(&other, Some(&cred)),
            None,
            "{other:?}"
        );
    }
    assert_eq!(turn_credential::meta_for(&turn, None), None);
}
