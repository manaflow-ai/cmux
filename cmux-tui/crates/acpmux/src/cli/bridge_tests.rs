use super::*;

#[test]
fn the_claude_app_config_gains_the_server_and_keeps_the_rest() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("claude_desktop_config.json");
    std::fs::write(
        &path,
        r#"{"mcpServers": {"other": {"command": "x"}}, "globalShortcut": "Alt+Space"}"#,
    )
    .unwrap();
    let entry = server_entry(
        &[
            "/opt/acpmux".into(),
            "bridge".into(),
            "mcp".into(),
            "--as".into(),
            "claude-desktop".into(),
        ],
        "ACPMUX_HOME=/h",
    );
    add_to_claude_app_config(&path, &entry).unwrap();
    let config: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(config["globalShortcut"], "Alt+Space");
    assert_eq!(config["mcpServers"]["other"]["command"], "x");
    let ours = &config["mcpServers"][SERVER_NAME];
    assert_eq!(ours["command"], "/opt/acpmux");
    assert_eq!(ours["args"], json!(["bridge", "mcp", "--as", "claude-desktop"]));
    assert_eq!(ours["env"]["ACPMUX_HOME"], "/h");
}

#[test]
fn a_fresh_claude_app_install_gets_its_config_folder_and_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("Claude/claude_desktop_config.json");
    add_to_claude_app_config(&path, &json!({"command": "/opt/acpmux"})).unwrap();
    let config: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(config["mcpServers"][SERVER_NAME]["command"], "/opt/acpmux");
}

#[test]
fn a_cmux_bridge_entry_that_is_not_ours_is_left_alone() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("claude_desktop_config.json");
    let theirs = r#"{"mcpServers": {"cmux-bridge": {"command": "/opt/other", "args": ["serve"]}}}"#;
    std::fs::write(&path, theirs).unwrap();
    assert!(add_to_claude_app_config(&path, &json!({"command": "/opt/acpmux"})).is_err());
    assert_eq!(std::fs::read_to_string(&path).unwrap(), theirs);
    // Ours, from an older install, is replaced.
    let older = r#"{"mcpServers": {"cmux-bridge": {"command": "/old/acpmux", "args": ["bridge", "mcp", "--as", "claude-desktop"]}}}"#;
    std::fs::write(&path, older).unwrap();
    add_to_claude_app_config(&path, &json!({"command": "/new/acpmux"})).unwrap();
    let config: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(config["mcpServers"][SERVER_NAME]["command"], "/new/acpmux");
}

#[test]
fn the_server_runs_this_binary_under_its_prefix() {
    let argv = server_argv(desktop_bridge::APPS[1]).unwrap();
    assert!(argv.ends_with(&[
        "bridge".into(),
        "mcp".into(),
        "--as".into(),
        "codex-desktop".into()
    ]));
    let me = crate::self_command::SelfCommand::current().unwrap();
    assert_eq!(argv[1..argv.len() - 4], me.args_lossy::<&str>(&[])[..]);
    assert!(ours(&json!({"args": argv[1..]})));
    assert!(!ours(&json!({"args": ["serve", "bridge mcp --as claude-desktop"]})));
    assert!(!ours(&json!({"args": ["bridge", "mcp", "--as", "other"]})));
}

#[tokio::test]
async fn connecting_chatgpt_desktop_prints_the_server_to_add_and_writes_nothing() {
    let chatgpt = desktop_bridge::app("chatgpt").unwrap();
    // Not a dry run: there is still nothing for it to run or write.
    let steps = connect(chatgpt, false).await;
    assert_eq!(steps.len(), 1);
    assert_eq!((&steps[0]["ok"], &steps[0]["byHand"]), (&json!(true), &json!(true)));
    let args = steps[0]["server"]["args"].as_array().unwrap();
    let tail: Vec<&str> = args[args.len() - 4..].iter().filter_map(Value::as_str).collect();
    assert_eq!(tail, ["bridge", "mcp", "--as", "chatgpt-desktop"]);
    assert!(ours(&steps[0]["server"]));
    let text = steps[0]["text"].as_str().unwrap();
    assert!(text.contains("--as chatgpt-desktop") && text.contains("ACPMUX_HOME="), "{text}");
}

#[test]
fn a_claude_app_config_that_is_not_json_is_left_alone() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("claude_desktop_config.json");
    std::fs::write(&path, "{ not json").unwrap();
    assert!(add_to_claude_app_config(&path, &json!({})).is_err());
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "{ not json");
}
