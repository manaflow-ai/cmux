use super::*;
use serde_json::json;

const CHATGPT: &str = "eyJhbGciOi.eyJzdWIiOi.c2lnbmF0dXJl";

fn env(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
}

#[test]
fn copilot_is_never_recovered_from_agent_state() {
    let marked = format!("{MARKER}={COPILOT_TOKEN}\0XDG_DATA_HOME=/tmp/fixture\0");
    assert!(recovered(marked.as_bytes()).is_none());
    let with_token = format!("{marked}{COPILOT_TOKEN}=fixture-token\0");
    assert!(recovered(with_token.as_bytes()).is_none());
}

#[test]
fn endpoint_credentials_apply_after_the_route_unset_and_recover() {
    for (kind, key, harness) in [
        ("openai", byo_endpoint::OPENAI_KEY_ENV, "opencode"),
        ("anthropic", byo_endpoint::ANTHROPIC_KEY_ENV, "claude"),
    ] {
        let token = "fixture-endpoint-credential";
        let wire = json!({
            "env": {key: token},
            "endpoint": {"kind": kind, "baseUrl": "https://provider.example/v1",
                         "models": ["big", "small"]}
        });
        let credential = AgentCredential::parse(&wire).unwrap();
        let mut argv = vec![harness.to_owned()];
        let mut env = env(&[
            ("ANTHROPIC_BASE_URL", "https://old.example"),
            ("OPENAI_BASE_URL", "https://old.example"),
        ]);
        assert!(!apply(&credential, "codex", &mut argv, &mut env));
        assert!(apply(&credential, harness, &mut argv, &mut env));
        if kind == "anthropic" {
            assert_eq!(env["ANTHROPIC_BASE_URL"], "https://provider.example/v1");
            assert_eq!(env["ANTHROPIC_MODEL"], "big");
            assert_eq!(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "small");
        } else {
            let config: Value = serde_json::from_str(&env["OPENCODE_CONFIG_CONTENT"]).unwrap();
            assert_eq!(config["model"], "byo/big");
            assert_eq!(config["provider"]["byo"]["options"]["apiKey"], "{env:CMUX_BYO_API_KEY}");
            assert!(config["provider"]["byo"]["models"].get("small").is_some());
        }
        assert_eq!(env[key], token);
        assert!(!env.contains_key("OPENAI_BASE_URL"));
        if kind == "anthropic" {
            assert_eq!(argv, [harness, "--setting-sources", ""]);
        } else {
            assert_eq!(argv, [harness]);
        }
        assert!(argv.iter().all(|word| !word.contains(token)));
        assert!(!format!("{credential:?}").contains(token));
        assert!(!format!("{credential:?}").contains("provider.example"));
        assert!(!env[ENDPOINT_MARKER].contains(token));
        let environ =
            env.iter().map(|(name, value)| format!("{name}={value}\0")).collect::<String>();
        assert_eq!(recovered(environ.as_bytes()).as_ref(), Some(&credential));
    }
}

#[test]
fn endpoint_credentials_do_not_read_settings_that_can_replace_the_provider() {
    let wire = json!({"env": {byo_endpoint::ANTHROPIC_KEY_ENV: "fixture-key"},
        "endpoint":{"kind":"anthropic", "baseUrl":"https://provider.example", "models":["model-a"]}});
    let credential = AgentCredential::parse(&wire).unwrap();
    let mut argv =
        ["claude", "--setting-sources", "user,project,local", "--settings=supplied.json"]
            .into_iter()
            .map(str::to_owned)
            .collect();
    assert!(apply(&credential, "claude", &mut argv, &mut BTreeMap::new()));
    assert_eq!(argv, ["claude", "--setting-sources", ""]);
}

#[test]
fn endpoint_credentials_reject_local_hosts_and_unpaired_variables() {
    for url in [
        "http://localhost:11434/v1",
        "https://localhost.",
        "https://127.1",
        "https://10.0.0.1",
        "https://192.168.1.10",
        "https://169.254.1.2",
        "https://[::1]",
        "https://[::ffff:127.0.0.1]",
        "https://[fd00::1]",
        "https://model.local",
    ] {
        let wire = json!({"env": {byo_endpoint::OPENAI_KEY_ENV: "fixture-key"},
            "endpoint":{"kind":"openai", "baseUrl":url, "models":["model-a"]}});
        assert!(AgentCredential::parse(&wire).is_err(), "{url}");
    }
    assert!(
        AgentCredential::parse(&json!({"env": {byo_endpoint::OPENAI_KEY_ENV: "fixture-key"}}))
            .is_err()
    );
    assert!(
        AgentCredential::parse(&json!({"env": {OPENAI_KEY: "fixture-key"},
        "endpoint":{"kind":"openai", "baseUrl":"https://host.example", "models":["model-a"]}}))
        .is_err()
    );
    assert!(
        AgentCredential::parse(&json!({"env": {byo_endpoint::OPENAI_KEY_ENV: "fixture-key"},
        "endpoint":{"kind":"openai", "baseUrl":"https://host.example", "models":["fixture-key"]}}))
        .is_err()
    );
}

#[test]
fn native_credentials_clear_alternate_keys_and_model_routes() {
    for (harness, key, alternate_key, route) in [
        ("gemini", GEMINI_KEY, "GOOGLE_API_KEY", "GOOGLE_GEMINI_BASE_URL"),
        ("grok", GROK_KEY, "GROK_CODE_XAI_API_KEY", "GROK_MODELS_BASE_URL"),
    ] {
        let credential = AgentCredential::parse(&json!({"env": {key: "fixture-key"}})).unwrap();
        let mut argv = vec![harness.into()];
        let mut env = env(&[(alternate_key, "alternate"), (route, "https://route.example")]);
        assert!(!apply(&credential, "codex", &mut argv, &mut env));
        assert!(apply(&credential, harness, &mut argv, &mut env));
        assert_eq!(env[key], "fixture-key");
        assert!(!env.contains_key(alternate_key));
        if harness == "gemini" {
            assert_eq!(env[route], "https://generativelanguage.googleapis.com");
            for flag in ["GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_GENAI_USE_GCA"] {
                assert_eq!(env[flag], "false");
            }
        } else {
            assert!(!env.contains_key(route));
        }
        assert!(env[crate::routes::UNSET_KEY].split(',').any(|name| name == route));
    }
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
fn a_delivered_setup_token_uses_anthropic_and_drops_competing_settings() {
    let name = byo_endpoint::ANTHROPIC_KEY_ENV;
    assert!(AgentCredential::parse(&json!({"env": {name: "endpoint-only"}})).is_err());
    let token = "sk-ant-oat01-fixture";
    let credential = AgentCredential::parse(&json!({"env": {name: token}})).unwrap();
    let mut argv =
        vec!["claude".to_owned(), "--settings".to_owned(), "untrusted-settings.json".to_owned()];
    let mut env = env(&[("ANTHROPIC_BASE_URL", "https://coderouter.example")]);
    assert!(apply(&credential, "claude", &mut argv, &mut env));
    assert_eq!(argv, ["claude", "--setting-sources", ""]);
    assert_eq!(env["ANTHROPIC_BASE_URL"], "https://api.anthropic.com");
    assert_eq!(env[name], token);
    assert_eq!(env[ANTHROPIC_KEY], "");
    assert_eq!(env[MARKER], name);
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
fn local_openai_key_route_does_not_use_codex_login() {
    let mut argv =
        ["codex", "-c", "model_provider=\"openai\"", "app-server"].map(str::to_owned).to_vec();
    let mut env = BTreeMap::from([
        ("OPENAI_BASE_URL".into(), OPENAI_BASE.into()),
        (OPENAI_KEY.into(), "fixture-key".into()),
        (CHATGPT_TOKEN.into(), "fixture-plan-token".into()),
    ]);
    configure_local_codex_route(&mut argv, &mut env);
    assert!(!env.contains_key(CHATGPT_TOKEN));
    assert!(argv.iter().any(|arg| arg == "model_provider=\"openai_api_key\""));
    assert!(
        argv.iter().any(|arg| arg == "model_providers.openai_api_key.requires_openai_auth=false")
    );
    assert!(
        argv.iter().any(|arg| arg == "model_providers.openai_api_key.env_key=\"OPENAI_API_KEY\"")
    );
    assert!(!argv.iter().any(|arg| arg.contains("fixture-key")));
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
fn the_host_says_only_the_launch_credential_and_never_shows_its_value() {
    let c = AgentCredential::parse(&json!({"env": {CLAUDE_OAUTH: "sk-ant-oat01-abc"}})).unwrap();
    let (mut argv, mut e) = (vec!["claude".to_owned()], env(&[("HOME", "/home/cmux")]));
    assert!(apply(&c, "claude", &mut argv, &mut e));
    let spec_env: Vec<(String, String)> = e.into_iter().collect();
    let said = launched_with(&spec_env);
    assert!(said.iter().all(|(k, _)| k != "HOME"), "only the credential's variables: {said:?}");
    assert_eq!(recovered_from_launch(&said), Some(c));
    let shown = format!("{:?}", crate::agent_host::LaunchCredential(said));
    assert!(!shown.contains("sk-ant-oat01-abc"), "{shown}");
    assert!(launched_with(&[("HOME".into(), "/h".into())]).is_empty());
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
    assert_eq!(recovered_from_pid(u32::MAX, 1, "chat"), None);
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

#[test]
fn delivered_claude_api_key_isolated_in_settings_and_absent_from_argv() {
    let credential = AgentCredential::parse(&serde_json::json!({
        "env": {ANTHROPIC_KEY: "fixture-secret"},
        "connection": "anthropic-personal",
    }))
    .unwrap();
    let mut argv = ["claude", "--settings", "project.json", "--setting-sources=project,user"]
        .into_iter()
        .map(ToOwned::to_owned)
        .collect();
    let mut env =
        BTreeMap::from([("ANTHROPIC_BASE_URL".to_owned(), "https://wrong.example".to_owned())]);
    assert!(apply(&credential, "claude", &mut argv, &mut env));
    assert_eq!(env["ANTHROPIC_BASE_URL"], "https://api.anthropic.com");
    assert!(env[ANTHROPIC_KEY] == "fixture-secret");
    assert_eq!(argv.iter().filter(|arg| arg.as_str() == "--settings").count(), 1);
    assert!(!argv.iter().any(|arg| arg.contains("fixture-secret") || arg.contains("project.json")));
    let settings: Value = serde_json::from_str(argv.last().unwrap()).unwrap();
    for key in crate::claude_cloud_auth::TEAM_CLEARS {
        assert_eq!(settings["env"][key], "");
    }
}

#[test]
fn delivered_vertex_express_key_uses_the_gemini_cli_without_project_auth() {
    let cred =
        AgentCredential::parse(&serde_json::json!({"env": {VERTEX_EXPRESS_KEY: "AQ.fixture"}}))
            .unwrap();
    let mut env = BTreeMap::from([("GOOGLE_CLOUD_PROJECT".into(), "prior-project".into())]);
    let mut argv = vec!["gemini".into(), "--acp".into()];
    assert_eq!(cred.family(), Family::Gemini);
    assert!(apply(&cred, "gemini", &mut argv, &mut env));
    assert_eq!(env["GEMINI_CLI_AUTH_OVERRIDE"], "vertex-ai");
    assert_eq!(env["GOOGLE_VERTEX_BASE_URL"], "https://aiplatform.googleapis.com");
    assert_eq!(env["GOOGLE_CLOUD_PROJECT"], "");
    assert_eq!(env["GEMINI_CLI_TRUST_WORKSPACE"], "false");
    assert!(!argv.iter().any(|arg| arg.contains("AQ.fixture")));
}
