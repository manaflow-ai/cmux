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

#[test]
fn a_claude_app_config_that_is_not_json_is_left_alone() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("claude_desktop_config.json");
    std::fs::write(&path, "{ not json").unwrap();
    assert!(add_to_claude_app_config(&path, &json!({})).is_err());
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "{ not json");
}
