use super::*;

#[test]
fn opencode_go_uses_the_console_model_list_and_stable_session_header() {
    let base = GO_BASE;
    assert_eq!(models_url(Kind::OpenAi, base), "https://opencode.ai/inference/go/v1/models");
    let mut env = opencode_env("OpenCode Go", base, &["kimi-k3".into()], true);
    let content = env.get_mut("OPENCODE_CONFIG_CONTENT").unwrap();
    configure_opencode_session(content, "test-chat");
    let first = content.clone();
    configure_opencode_session(content, "test-chat");
    assert_eq!(*content, first);
    let config: serde_json::Value = serde_json::from_str(content).unwrap();
    assert_eq!(
        config["provider"]["byo"]["options"]["headers"]["x-opencode-session"],
        "ses_test-chat"
    );
    configure_opencode_session(content, "another-chat");
    let config: serde_json::Value = serde_json::from_str(content).unwrap();
    assert_eq!(
        config["provider"]["byo"]["options"]["headers"]["x-opencode-session"],
        "ses_another-chat"
    );
    let mut other = "{\"provider\": []}".to_owned();
    configure_opencode_session(&mut other, "test-chat");
    assert_eq!(other, "{\"provider\": []}");
}

#[test]
fn cloudflare_gateway_uses_the_gateway_header_without_bearer_auth() {
    let env = opencode_env(
        "Cloudflare AI Gateway",
        "https://gateway.ai.cloudflare.com/v1/1234567890abcdef1234567890abcdef/default/compat",
        &["workers-ai/@cf/meta/model".into()],
        true,
    );
    let config: serde_json::Value =
        serde_json::from_str(&env["OPENCODE_CONFIG_CONTENT"]).unwrap();
    let options = &config["provider"]["byo"]["options"];
    assert_eq!(options["headers"]["cf-aig-authorization"], "Bearer {env:CMUX_BYO_API_KEY}");
    assert!(options.get("apiKey").is_none());
}

#[test]
fn minimax_regional_plans_use_the_anthropic_adapter() {
    for base in ["https://api.minimax.io/anthropic", "https://api.minimaxi.com/anthropic"] {
        let env = opencode_env("MiniMax", base, &["MiniMax-M3.1-Flash".into()], true);
        let config: serde_json::Value =
            serde_json::from_str(&env["OPENCODE_CONFIG_CONTENT"]).unwrap();
        let provider = &config["provider"]["byo"];
        assert_eq!(provider["npm"], "@ai-sdk/anthropic");
        assert_eq!(provider["options"]["baseURL"], format!("{base}/v1"));
    }
}
