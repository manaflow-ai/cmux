use super::*;

/// A fresh folder under the system temp directory (removed on drop).
struct Temp(PathBuf);

impl Temp {
    fn new() -> Self {
        let dir = std::env::temp_dir().join(format!("acpmux-agent-tools-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        Temp(dir)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for Temp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn bin_with(names: &[&str]) -> Temp {
    use std::os::unix::fs::PermissionsExt;
    let dir = Temp::new();
    for name in names {
        let path = dir.path().join(name);
        std::fs::write(&path, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    dir
}

fn inputs(bin: &Path, cmux_json: Option<&str>, state: &Path) -> Inputs {
    Inputs {
        enabled: true,
        bin_dir: Some(bin.to_path_buf()),
        cmux_json: cmux_json.map(str::to_owned),
        state_dir: state.to_path_buf(),
    }
}

#[test]
fn both_servers_and_the_skills_plugin_when_the_app_ships_them_and_mcp_is_on() {
    let bin = bin_with(&["cmux-cua", "cmux"]);
    let state = Temp::new();
    let json = "{\n  // comment\n  \"mcp\": {\"enabled\": true}\n}";
    let tools = resolve(&inputs(bin.path(), Some(json), state.path()));
    let names: Vec<&str> = tools.servers.iter().map(|s| s.name.as_str()).collect();
    assert_eq!(names, ["cmux-cua", "cmux", crate::render_mcp::SERVER_NAME]);
    assert_eq!(tools.servers[0].args, ["mcp"]);
    assert!(tools.servers[0].env.contains(&("CMUX_CUA_MCP_FORCE_PROXY".into(), "1".into())));
    assert_eq!(tools.servers[1].args, ["mcp", "serve"]);
    let plugin = tools.plugin_dir.clone().unwrap();
    for file in [
        ".claude-plugin/plugin.json",
        "skills/cmux-browser/SKILL.md",
        "skills/cmux-browser/references/repl-guide.md",
        "skills/cmux-cua/SKILL.md",
    ] {
        assert!(plugin.join(file).is_file(), "{file}");
    }
    let cua = std::fs::read_to_string(plugin.join("skills/cmux-cua/SKILL.md")).unwrap();
    assert!(cua.contains("disable-model-invocation: true"), "the consent rule stays");
    // Same content, same folder: nothing is rewritten on the next spawn.
    assert_eq!(resolve(&inputs(bin.path(), Some(json), state.path())).plugin_dir, Some(plugin));
}

#[test]
fn the_cmux_server_needs_mcp_enabled_and_a_missing_binary_is_left_out() {
    let state = Temp::new();
    let bin = bin_with(&["cmux"]);
    for json in [None, Some("{}"), Some("{\"mcp\": {\"enabled\": false}}"), Some("not json")] {
        let tools = resolve(&inputs(bin.path(), json, state.path()));
        // Only the render server, which needs no setting.
        let names: Vec<&str> = tools.servers.iter().map(|s| s.name.as_str()).collect();
        assert_eq!(names, [crate::render_mcp::SERVER_NAME], "{json:?}");
        assert!(tools.plugin_dir.is_some(), "skills do not depend on MCP");
    }
}

#[test]
fn the_render_server_comes_with_cmux_and_needs_no_mcp_switch() {
    // `cmux mcp serve --render-only` reaches nothing, so it is on wherever the app ships cmux,
    // and Claude Code may call its one tool without a permission card.
    let state = Temp::new();
    let bin = bin_with(&["cmux"]);
    let tools = resolve(&inputs(bin.path(), None, state.path()));
    let names: Vec<&str> = tools.servers.iter().map(|s| s.name.as_str()).collect();
    assert_eq!(names, [crate::render_mcp::SERVER_NAME]);
    assert_eq!(tools.servers[0].args, ["mcp", "serve", "--render-only"]);
    assert_eq!(tools.acp_servers()[0]["name"], crate::render_mcp::SERVER_NAME);
    let args = tools.claude_args();
    let allowed =
        args.iter().position(|a| a == "--allowedTools").expect("the render tool is allowed");
    assert_eq!(args[allowed + 1], crate::render_mcp::CLAUDE_TOOL);
    let config = args.iter().position(|a| a == "--mcp-config").unwrap();
    let config: Value = serde_json::from_str(&args[config + 1]).unwrap();
    assert_eq!(
        config["mcpServers"]["cmux-render"]["args"],
        json!(["mcp", "serve", "--render-only"])
    );
    // With MCP on, the full cmux server comes too, each once.
    let on = resolve(&inputs(bin.path(), Some("{\"mcp\": {\"enabled\": true}}"), state.path()));
    let names: Vec<&str> = on.servers.iter().map(|s| s.name.as_str()).collect();
    assert_eq!(names, ["cmux", crate::render_mcp::SERVER_NAME]);
}

#[test]
fn the_switch_turns_everything_off() {
    let bin = bin_with(&["cmux-cua", "cmux"]);
    let state = Temp::new();
    let mut off = inputs(bin.path(), Some("{\"mcp\":{\"enabled\":true}}"), state.path());
    off.enabled = false;
    let tools = resolve(&off);
    assert_eq!(tools, AgentTools::default());
    assert!(tools.claude_args().is_empty());
    assert_eq!(tools.acp_servers(), json!([]));
}

#[test]
fn acp_and_claude_shapes() {
    let tools = AgentTools {
        servers: vec![McpServer {
            name: "cmux-cua".into(),
            command: "/b/cmux-cua".into(),
            args: vec!["mcp".into()],
            env: vec![("K".into(), "v".into())],
        }],
        plugin_dir: Some("/p".into()),
    };
    assert_eq!(
        tools.acp_servers(),
        json!([{"name": "cmux-cua", "command": "/b/cmux-cua", "args": ["mcp"], "env": [{"name": "K", "value": "v"}]}])
    );
    let args = tools.claude_args();
    assert_eq!(args[0], "--mcp-config");
    let config: Value = serde_json::from_str(&args[1]).unwrap();
    assert_eq!(config["mcpServers"]["cmux-cua"]["command"], "/b/cmux-cua");
    assert_eq!(config["mcpServers"]["cmux-cua"]["env"]["K"], "v");
    assert_eq!(&args[2..], ["--plugin-dir", "/p"]);
}

#[test]
fn remote_origins_isolated_presets_and_strict_mcp_sessions_get_nothing() {
    let none = BTreeMap::new();
    assert!(left_out(true, &none, &[]));
    assert_eq!(acp_servers_for(true, &none), json!([]));
    assert!(claude_args_for(true, &none, &[]).is_empty());
    let isolated = BTreeMap::from([(SWITCH_ENV.to_owned(), "0".to_owned())]);
    assert!(left_out(false, &isolated, &[]));
    assert!(left_out(false, &none, &["--tools".into(), "".into(), "--strict-mcp-config".into()]));
    assert!(!left_out(false, &none, &["--model".into(), "opus".into()]));
}
