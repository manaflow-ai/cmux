use super::*;
use serde_json::json;

const CHATGPT: &str = "eyJhbGciOi.eyJzdWIiOi.c2lnbmF0dXJl";

fn env(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
}

#[test]
fn only_one_known_token_shaped_variable_is_taken() {
    let ok = AgentCredential::parse(&json!({"env": {CLAUDE_OAUTH: "sk-ant-oat01-abc_DEF"}}));
    assert_eq!(ok.unwrap().family(), Family::Claude);
    for bad in [
        json!({"env": {"PATH": "/evil"}}),
        json!({"env": {CLAUDE_OAUTH: "a b"}}),
        json!({"env": {CLAUDE_OAUTH: "${env:HOME}"}}),
        json!({"env": {CLAUDE_OAUTH: ""}}),
        json!({"env": {CLAUDE_OAUTH: "x", OPENAI_KEY: "y"}}),
        json!({"env": {}}),
        json!({"env": {CLAUDE_OAUTH: "x"}, "file": "/tmp/x"}),
        json!("sk-ant-oat01"),
    ] {
        assert!(AgentCredential::parse(&bad).is_err(), "{bad}");
    }
}

#[test]
fn its_debug_names_the_variable_never_the_value() {
    let c = AgentCredential::parse(&json!({"env": {CHATGPT_TOKEN: CHATGPT}})).unwrap();
    let shown = format!("{c:?}");
    assert!(shown.contains(CHATGPT_TOKEN));
    assert!(!shown.contains(CHATGPT));
}

#[test]
fn only_the_unix_socket_without_a_caller_token_sets_one() {
    assert!(admit(true, None).is_ok());
    assert!(admit(true, Some("agent-session")).is_err());
    assert!(admit(false, None).is_err());
}

#[test]
fn a_claude_launch_drops_the_coderouter_route_and_takes_the_token() {
    let c = AgentCredential::parse(&json!({"env": {CLAUDE_OAUTH: "sk-ant-oat01-abc"}})).unwrap();
    let mut argv = vec!["claude".to_owned()];
    let mut e = env(&[
        ("ANTHROPIC_BASE_URL", "https://coderouter.cmux.internal"),
        ("ANTHROPIC_API_KEY", crate::cloud_model_plane::PLACEHOLDER),
        (crate::routes::UNSET_KEY, "FOO"),
    ]);
    assert!(apply(&c, "claude", &mut argv, &mut e));
    assert_eq!(e[CLAUDE_OAUTH], "sk-ant-oat01-abc");
    assert!(!e.contains_key("ANTHROPIC_BASE_URL"));
    assert!(!e.contains_key("ANTHROPIC_API_KEY"));
    let unset: Vec<&str> = e[crate::routes::UNSET_KEY].split(',').collect();
    assert!(unset.contains(&"FOO"));
    for key in crate::cloud_model_plane::KEYS {
        assert!(unset.contains(&key), "{key} is removed from what the agent inherits");
    }
    assert_eq!(argv, ["claude"], "Claude needs only its env");
}

#[test]
fn an_anthropic_key_stays_set_though_its_name_is_on_the_unset_list() {
    let c = AgentCredential::parse(&json!({"env": {ANTHROPIC_KEY: "sk-ant-api03-x"}})).unwrap();
    let (mut argv, mut e) = (vec!["claude".to_owned()], BTreeMap::new());
    assert!(apply(&c, "claude", &mut argv, &mut e));
    // The spawn removes the unset names from the inherited env before it sets the profile's.
    assert_eq!(e[ANTHROPIC_KEY], "sk-ant-api03-x");
}

/// A ChatGPT access token whose claims name `account`.
fn chatgpt_token(account: Option<&str>) -> String {
    use base64::Engine as _;
    let b64 = |v: serde_json::Value| {
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(v.to_string())
    };
    let auth = account.map_or(json!({}), |a| json!({"chatgpt_account_id": a}));
    format!(
        "{}.{}.c2lnbmF0dXJl",
        b64(json!({"alg": "RS256"})),
        b64(json!({"sub": "user-1", "https://api.openai.com/auth": auth}))
    )
}

/// cmux#45774: Sign in with ChatGPT's token (Codex's own OAuth client) runs on the ChatGPT
/// Codex backend with the account it names, as Codex itself runs a ChatGPT sign-in.
#[test]
fn codex_on_a_chatgpt_plan_runs_the_chatgpt_codex_backend_for_the_tokens_account() {
    let token = chatgpt_token(Some("acct-1234"));
    let c = AgentCredential::parse(&json!({"env": {CHATGPT_TOKEN: token}})).unwrap();
    let mut argv: Vec<String> =
        ["codex", "-c", "model_provider=\"openai\"", "app-server"].map(str::to_owned).into();
    let mut e = env(&[
        ("OPENAI_BASE_URL", "https://coderouter.cmux.internal/v1"),
        (CHATGPT_ACCOUNT, "acct-stale"),
    ]);
    assert!(apply(&c, "codex", &mut argv, &mut e));
    assert_eq!(e[CHATGPT_TOKEN], token);
    assert_eq!(e[CHATGPT_ACCOUNT], "acct-1234");
    assert!(!e.contains_key("OPENAI_BASE_URL"));
    let joined = argv.join(" ");
    assert!(joined.contains("model_provider=\"openai_chatgpt_plan\""));
    assert!(!joined.contains("model_provider=\"openai\""), "{joined}");
    assert!(!joined.contains("api.openai.com"), "{joined}");
    for want in [
        "model_providers.openai_chatgpt_plan.base_url=\"https://chatgpt.com/backend-api/codex\"",
        "model_providers.openai_chatgpt_plan.env_key=\"CMUX_CHATGPT_ACCESS_TOKEN\"",
        "model_providers.openai_chatgpt_plan.env_http_headers.chatgpt-account-id=\"CMUX_CHATGPT_ACCOUNT_ID\"",
        "model_providers.openai_chatgpt_plan.wire_api=\"responses\"",
        "model_providers.openai_chatgpt_plan.requires_openai_auth=false",
        "model_providers.openai_chatgpt_plan.supports_websockets=false",
    ] {
        assert!(argv.iter().any(|a| a == want), "{want} in {joined}");
    }
    assert!(!joined.contains(&token), "the token is never on the command line");
    assert!(!joined.contains("tool_search"));
    assert_eq!(argv.first().map(String::as_str), Some("codex"));
    // After the subcommand, where codex keeps it beside the subcommand's own overrides.
    let sub = argv.iter().position(|a| a == "app-server").unwrap();
    let picked = argv.iter().position(|a| a == "model_provider=\"openai_chatgpt_plan\"");
    assert!(picked.unwrap() > sub, "{joined}");
    // A token that names no account sends no header, and a stale account never stays.
    let bare = AgentCredential::parse(&json!({"env": {CHATGPT_TOKEN: chatgpt_token(None)}}));
    let mut e = env(&[(CHATGPT_ACCOUNT, "acct-stale")]);
    assert!(apply(&bare.unwrap(), "codex", &mut vec!["codex".to_owned()], &mut e));
    assert!(!e.contains_key(CHATGPT_ACCOUNT));
}

/// cmux#45774: acpmux's codex line ends `app-server -c developer_instructions=…`, and codex
/// drops every override before a subcommand that has its own: the provider goes after it.
#[test]
fn the_provider_goes_after_the_app_server_word_beside_its_own_overrides() {
    let c = AgentCredential::parse(&json!({"env": {OPENAI_KEY: "sk-proj-abc"}})).unwrap();
    let mut argv: Vec<String> = [
        "/opt/cmux/current/bin/codex",
        "-c",
        "agents.max_depth=16",
        "app-server",
        "-c",
        "model_provider=\"cmux\"",
        "-c",
        "developer_instructions=\"x\"",
    ]
    .map(str::to_owned)
    .into();
    assert!(apply(&c, "codex", &mut argv, &mut BTreeMap::new()));
    assert_eq!(
        argv[..5],
        ["/opt/cmux/current/bin/codex", "-c", "agents.max_depth=16", "app-server", "-c"]
    );
    assert_eq!(argv[5], "model_provider=\"openai_api_key\"");
    assert_eq!(argv.iter().filter(|a| a.starts_with("model_provider=")).count(), 1, "{argv:?}");
    assert_eq!(argv[argv.len() - 2..], ["-c", "developer_instructions=\"x\""]);
    // A line with no subcommand takes it right after the program.
    assert_eq!(codex_config_index(&["codex".to_owned()]), 1);
    assert_eq!(codex_config_index(&[]), 0);
}

#[test]
fn codex_on_an_openai_key_reads_that_key() {
    let c = AgentCredential::parse(&json!({"env": {OPENAI_KEY: "sk-proj-abc"}})).unwrap();
    let (mut argv, mut e) = (vec!["codex".to_owned(), "app-server".to_owned()], BTreeMap::new());
    assert!(apply(&c, "codex", &mut argv, &mut e));
    assert_eq!(e[OPENAI_KEY], "sk-proj-abc");
    assert!(argv.iter().any(|a| a == "model_providers.openai_api_key.env_key=\"OPENAI_API_KEY\""));
}

#[test]
fn apply_marks_the_agent_with_the_variable_name_only() {
    let c = AgentCredential::parse(&json!({"env": {CLAUDE_OAUTH: "sk-ant-oat01-abc"}})).unwrap();
    let (mut argv, mut e) = (vec!["claude".to_owned()], BTreeMap::new());
    assert!(apply(&c, "claude", &mut argv, &mut e));
    assert_eq!(e[MARKER], CLAUDE_OAUTH);
}

fn environ(pairs: &[(&str, &str)]) -> Vec<u8> {
    pairs.iter().flat_map(|(k, v)| format!("{k}={v}\0").into_bytes()).collect()
}

#[test]
fn the_marked_variable_comes_back_from_the_agents_env() {
    let c = AgentCredential::parse(&json!({"env": {CLAUDE_OAUTH: "sk-ant-oat01-abc"}})).unwrap();
    let (mut argv, mut e) = (vec!["claude".to_owned()], env(&[("HOME", "/home/cmux")]));
    assert!(apply(&c, "claude", &mut argv, &mut e));
    let pairs: Vec<(&str, &str)> = e.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    assert_eq!(recovered(&environ(&pairs)), Some(c));
}

#[test]
fn an_inherited_or_unchecked_variable_never_comes_back() {
    // A login the agent merely inherited: no marker.
    assert_eq!(recovered(&environ(&[(CLAUDE_OAUTH, "sk-ant-oat01-abc")])), None);
    // A marker naming a variable a credential never sets.
    assert_eq!(recovered(&environ(&[(MARKER, "PATH"), ("PATH", "/evil")])), None);
    // A marked value that is not a token, or no value at all.
    assert_eq!(recovered(&environ(&[(MARKER, CLAUDE_OAUTH), (CLAUDE_OAUTH, "a b")])), None);
    assert_eq!(recovered(&environ(&[(MARKER, CLAUDE_OAUTH)])), None);
    assert_eq!(recovered(b""), None);
    assert_eq!(recovered_from_pid(u32::MAX), None);
}

#[test]
fn a_credential_of_another_family_is_not_applied() {
    let c = AgentCredential::parse(&json!({"env": {CLAUDE_OAUTH: "sk-ant-oat01-abc"}})).unwrap();
    let mut argv = vec!["codex".to_owned()];
    let mut e = env(&[("OPENAI_BASE_URL", "https://coderouter.cmux.internal/v1")]);
    assert!(!apply(&c, "codex", &mut argv, &mut e));
    assert!(!apply(&c, "opencode", &mut argv, &mut e));
    assert_eq!(e["OPENAI_BASE_URL"], "https://coderouter.cmux.internal/v1");
    assert!(!e.contains_key(CLAUDE_OAUTH));
}
