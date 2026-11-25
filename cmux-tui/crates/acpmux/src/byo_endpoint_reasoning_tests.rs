use super::*;

#[test]
fn reasoning_efforts_follow_the_openai_family() {
    let ladder = |id: &str| reasoning_efforts(id).to_vec();
    let none = ["none", "low", "medium", "high"];
    assert_eq!(ladder("gpt-5-mini"), ["minimal", "low", "medium", "high"]);
    assert_eq!(ladder("org/gpt-5"), ["minimal", "low", "medium", "high"]);
    assert_eq!(ladder("gpt-5-nano"), ["minimal", "low", "medium", "high"]);
    assert_eq!(ladder("gpt-5-pro"), ["high"]);
    assert_eq!(ladder("gpt-5-codex"), ["low", "medium", "high"]);
    // gpt-5.1 rejects `minimal`. A dated deployment name is the same model.
    assert_eq!(ladder("gpt-5.1-2025-11-13"), none);
    assert_eq!(ladder("gpt-5.2"), none);
    assert_eq!(ladder("gpt-5.3-codex"), none);
    assert_eq!(ladder("gpt-5.4-mini"), none);
    assert_eq!(ladder("gpt-5.4-nano"), none);
    assert_eq!(ladder("gpt-5.4"), ["none", "low", "medium", "high", "xhigh"]);
    assert_eq!(ladder("gpt-5.5"), ["none", "low", "medium", "high", "xhigh"]);
    assert_eq!(ladder("gpt-5.1-codex-max"), ["none", "low", "medium", "high", "xhigh"]);
    assert_eq!(ladder("o3"), ["low", "medium", "high"]);
    assert_eq!(ladder("o4-mini"), ["low", "medium", "high"]);
    assert_eq!(ladder("O1-PRO"), ["low", "medium", "high"]);
    assert_eq!(ladder("o5-mini-2026-01-01"), ["low", "medium", "high"]);
    assert!(reasoning_efforts("gpt-4o").is_empty());
    assert!(reasoning_efforts("gpt-5.1-chat").is_empty());
    assert!(reasoning_efforts("gpt-5-chat").is_empty());
    assert!(reasoning_efforts("GPT-6.1").is_empty());
    assert!(reasoning_efforts("gpt-5.6-sol").is_empty());
    assert!(reasoning_efforts("o1-mini").is_empty());
    assert!(reasoning_efforts("o2").is_empty());
    assert!(reasoning_efforts("o10").is_empty());
    assert!(reasoning_efforts("o1-").is_empty());
}

/// OpenCode advertises an effort option only for a model whose config names reasoning options.
#[test]
fn a_reasoning_model_declares_its_effort_and_a_plain_model_does_not() {
    let models = ["gpt-5-mini".to_owned(), "o3".to_owned(), "gpt-4o".to_owned()];
    let text = profile_text(&Endpoint {
        kind: Kind::OpenAi,
        id: "foundry",
        name: "Microsoft Foundry",
        base_url: "https://example.openai.azure.com/openai/v1",
        models: &models,
        keychain_item: None,
        icon: None,
        program: None,
    });
    let table: toml::Table = toml::from_str(&text).unwrap();
    let raw = table["env"]["OPENCODE_CONFIG_CONTENT"].as_str().unwrap();
    let config: serde_json::Value = serde_json::from_str(raw).unwrap();
    let listed = &config["provider"]["azure"]["models"];
    assert_eq!(
        listed["gpt-5-mini"]["reasoning_options"],
        serde_json::json!([{"type": "effort", "values": ["minimal", "low", "medium", "high"]}]),
        "{config}"
    );
    assert_eq!(
        listed["o3"]["reasoning_options"][0]["values"],
        serde_json::json!(["low", "medium", "high"]),
        "{config}"
    );
    assert_eq!(listed["gpt-4o"], serde_json::json!({"name": "gpt-4o"}), "{config}");
}

/// Azure must be provider `azure` or OpenCode ignores `useCompletionUrls` and uses Responses,
/// which replays encrypted reasoning (`invalid_encrypted_content`). Any other host stays `byo`.
#[test]
fn an_azure_host_is_provider_azure_and_any_other_host_stays_byo() {
    let models = ["gpt-5-mini".to_owned()];
    let config_of = |base: &str| {
        let text = profile_text(&Endpoint {
            kind: Kind::OpenAi,
            id: "ep",
            name: "Endpoint",
            base_url: base,
            models: &models,
            keychain_item: None,
            icon: None,
            program: None,
        });
        let table: toml::Table = toml::from_str(&text).unwrap();
        let raw = table["env"]["OPENCODE_CONFIG_CONTENT"].as_str().unwrap().to_owned();
        serde_json::from_str::<serde_json::Value>(&raw).unwrap()
    };
    let azure = config_of("https://example.openai.azure.com/openai/v1");
    assert!(azure["provider"].get(OPENCODE_PROVIDER).is_none(), "{azure}");
    assert_eq!(azure["provider"]["azure"]["npm"], "@ai-sdk/azure");
    assert_eq!(azure["provider"]["azure"]["options"]["useCompletionUrls"], true);
    assert_eq!(azure["provider"]["azure"]["options"]["resourceName"], "example");
    assert!(azure["provider"]["azure"]["options"].get("baseURL").is_none());
    assert_eq!(azure["model"], "azure/gpt-5-mini");
    let plain = config_of("https://api.example.com/v1");
    assert!(plain["provider"].get("azure").is_none(), "{plain}");
    assert_eq!(plain["provider"][OPENCODE_PROVIDER]["npm"], "@ai-sdk/openai-compatible");
    assert_eq!(plain["model"], "byo/gpt-5-mini");
}

/// The picker reads `efforts` from the profile. An empty list is a declaration, so a
/// non-reasoner does not inherit the levels of the model the chat is running.
#[test]
fn a_profile_declares_each_models_efforts_including_none() {
    let models = ["gpt-5.1".to_owned(), "gpt-4o".to_owned()];
    let text = profile_text(&Endpoint {
        kind: Kind::OpenAi,
        id: "foundry",
        name: "Microsoft Foundry",
        base_url: "https://example.openai.azure.com/openai/v1",
        models: &models,
        keychain_item: None,
        icon: None,
        program: None,
    });
    let path = std::path::Path::new("foundry.toml");
    let (_id, profile, meta, diagnostics) = crate::config::profiles::parse_profile_toml(
        &text,
        path,
        Some("foundry"),
        crate::config::profiles::ProfileSource::UserFile,
    )
    .unwrap_or_else(|e| panic!("{e:?}\n{text}"));
    assert!(diagnostics.is_empty(), "{diagnostics:?}");
    let listed = |id: &str| {
        let model = profile.models.iter().find(|model| model.id() == id).unwrap();
        crate::hub::declared_model_json(model, Some(&meta))
    };
    assert_eq!(listed("azure/gpt-4o")["efforts"], serde_json::json!([]));
    assert_eq!(
        listed("azure/gpt-5.1")["efforts"],
        serde_json::json!(["none", "low", "medium", "high"])
    );
}
