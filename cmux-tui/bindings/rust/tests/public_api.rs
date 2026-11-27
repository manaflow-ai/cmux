use cmux::{
    Client, Config, CreatedPath, MutationOptions, RendererGrant, RunCommand, Selector, SessionId,
    Size, TerminalId, Update, WorkspaceId,
};
use std::collections::HashSet;

const HEX: &str = "0123456789abcdef0123456789abcdef";

#[test]
fn opaque_ids_validate_their_exact_prefix_and_payload() {
    let workspace = WorkspaceId::parse(format!("ws_{HEX}")).unwrap();
    assert_eq!(workspace.as_str(), format!("ws_{HEX}"));
    assert!(TerminalId::parse(format!("ws_{HEX}")).is_err());
    assert!(WorkspaceId::parse("ws_01").is_err());
    assert!(WorkspaceId::parse(format!("ws_{}", HEX.to_uppercase())).is_err());
}

#[test]
fn selectors_are_tagged_public_values() {
    let id = WorkspaceId::parse(format!("ws_{HEX}")).unwrap();
    assert_eq!(
        serde_json::to_value(Selector::id(id)).unwrap(),
        serde_json::json!({"kind": "id", "id": format!("ws_{HEX}")})
    );
    assert_eq!(
        serde_json::to_value(Selector::<WorkspaceId>::current()).unwrap(),
        serde_json::json!({"kind": "current"})
    );
    assert_eq!(
        serde_json::to_value(Selector::<WorkspaceId>::name("")).unwrap(),
        serde_json::json!({"kind": "name", "name": ""})
    );
}

#[test]
fn exact_and_shell_commands_remain_distinct() {
    assert_eq!(
        RunCommand::argv(["printf", "", "$HOME"]).unwrap(),
        RunCommand::Exact { argv: vec!["printf".into(), "".into(), "$HOME".into()] }
    );
    assert_eq!(
        RunCommand::shell("printf '%s' \"$HOME\"").unwrap(),
        RunCommand::Shell { script: "printf '%s' \"$HOME\"".into() }
    );
    assert!(RunCommand::shell("").is_err());
    assert_eq!(
        RunCommand::shell_executable("/bin/zsh", "echo ok").unwrap(),
        RunCommand::Exact { argv: vec!["/bin/zsh".into(), "-lc".into(), "echo ok".into()] }
    );
}

#[test]
fn idempotency_keys_are_injectable_and_random_defaults_do_not_reuse_a_counter_space() {
    assert_eq!(
        MutationOptions::new("deterministic-retry").unwrap().idempotency_key,
        "deterministic-retry"
    );
    let keys = (0..1024)
        .map(|_| MutationOptions::unique().unwrap().idempotency_key)
        .collect::<HashSet<_>>();
    assert_eq!(keys.len(), 1024);
    assert!(keys.iter().all(|key| {
        key.starts_with("rust-")
            && key.len() == 37
            && key[5..].bytes().all(|byte| byte.is_ascii_hexdigit())
    }));
}

#[test]
fn idempotency_keys_match_the_durable_identifier_contract() {
    for invalid in [
        "".to_string(),
        " \u{00a0}\u{3000}".to_string(),
        "key\ncontrol".to_string(),
        "key\u{0085}control".to_string(),
        "\u{00e9}".repeat(65),
    ] {
        assert!(MutationOptions::new(invalid).is_err());
    }
    for valid in [" key ".to_string(), "\u{feff}".to_string(), "\u{00e9}".repeat(64)] {
        assert_eq!(MutationOptions::new(&valid).unwrap().idempotency_key, valid);
    }
}

#[test]
fn sensitive_debug_output_is_redacted() {
    let grant = RendererGrant::new(
        "renderer-secret",
        "unix:///tmp/cmux-renderer.sock",
        TerminalId::parse("term_00000000000000000000000000000001").unwrap(),
        vec!["render".to_string()],
        5_000,
    )
    .unwrap();
    let grant_debug = format!("{grant:?}");
    assert!(grant_debug.contains("[REDACTED]"));
    assert!(!grant_debug.contains("renderer-secret"));

    fn assert_renderer_api(_: fn(&RendererGrant) -> &str) {}
    assert_renderer_api(RendererGrant::expose_token);
    assert!(
        RendererGrant::new(
            "",
            "unix:///tmp/cmux-renderer.sock",
            TerminalId::parse("term_00000000000000000000000000000001").unwrap(),
            vec!["render".to_string()],
            5_000,
        )
        .is_err()
    );
}

#[test]
fn created_paths_are_explicit_variants_and_sizes_reject_zero() {
    let workspace_id = WorkspaceId::parse("ws_00000000000000000000000000000001").unwrap();
    let path = CreatedPath::Workspace { workspace_id: workspace_id.clone() };
    assert_eq!(path.workspace_id(), &workspace_id);
    assert!(path.terminal_id().is_none());
    assert!(Size::new(80, 24).is_ok());
    assert!(Size::new(0, 24).is_err());
}

#[test]
fn root_and_raw_clients_are_distinct_and_both_importable() {
    fn high_level(_: Option<Client>, _: Config, _: Selector<SessionId>) {}
    fn low_level(_: Option<cmux::raw::Client>, _: cmux::raw::ClientConfig) {}
    high_level(None, Config::default(), Selector::current());
    low_level(None, cmux::raw::ClientConfig::default());
}

#[test]
fn optional_metadata_updates_distinguish_unchanged_clear_and_empty() {
    assert_ne!(Update::<String>::Unchanged, Update::Clear);
    assert_ne!(Update::<String>::Clear, Update::Set(String::new()));
}

#[test]
fn generated_numeric_models_are_only_under_raw() {
    let numeric: cmux::raw::Id = 42;
    assert_eq!(numeric, 42);
    let _legacy_type: Option<cmux::raw::SurfaceResult> = None;
}
