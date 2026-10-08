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

/// The MCP config the `--mcp-config` argument names (a file, or inline JSON).
fn config_of(args: &[String]) -> Value {
    let arg = &args[args.iter().position(|a| a == "--mcp-config").unwrap() + 1];
    serde_json::from_str(arg)
        .unwrap_or_else(|_| serde_json::from_str(&std::fs::read_to_string(arg).unwrap()).unwrap())
}

fn inputs(bin: &Path, cmux_json: Option<&str>, state: &Path) -> Inputs {
    Inputs {
        enabled: true,
        bin_dir: Some(bin.to_path_buf()),
        cmux_json: cmux_json.map(str::to_owned),
        state_dir: state.to_path_buf(),
        cua: None,
        cua_v2: None,
        acpmux: None,
    }
}

#[test]
fn both_servers_and_the_skills_plugin_when_the_app_ships_them_and_mcp_is_on() {
    let bin = bin_with(&["cmux-cua", "cmux"]);
    let state = Temp::new();
    let json = "{\n  // comment\n  \"mcp\": {\"enabled\": true}\n}";
    let tools = resolve(&inputs(bin.path(), Some(json), state.path()));
    let names: Vec<&str> = tools.servers.iter().map(|s| s.name.as_str()).collect();
    assert_eq!(names, ["cmux-cua", "cmux"]);
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
        assert!(tools.servers.is_empty(), "{json:?}");
        assert!(tools.plugin_dir.is_some(), "skills do not depend on MCP");
    }
}

#[test]
fn the_switch_turns_everything_off() {
    let bin = bin_with(&["cmux-cua", "cmux"]);
    let state = Temp::new();
    let mut off = inputs(bin.path(), Some("{\"mcp\":{\"enabled\":true}}"), state.path());
    off.enabled = false;
    let tools = resolve(&off);
    assert_eq!(tools, AgentTools::default());
    assert!(tools.claude_args(&state.path().join("unused.json")).is_empty());
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
    let dir = Temp::new();
    let args = tools.claude_args(&dir.path().join("run/mcp/s.json"));
    assert_eq!(args[0], "--mcp-config");
    let config = config_of(&args);
    assert_eq!(config["mcpServers"]["cmux-cua"]["command"], "/b/cmux-cua");
    assert_eq!(config["mcpServers"]["cmux-cua"]["env"]["K"], "v");
    assert_eq!(&args[2..], ["--plugin-dir", "/p"]);
}

#[test]
fn remote_origins_isolated_presets_and_strict_mcp_sessions_get_nothing() {
    let none = BTreeMap::new();
    assert!(left_out(true, &none, &[]));
    assert_eq!(acp_servers_for(true, &none), json!([]));
    assert!(claude_args_for(true, &none, &[], "s").is_empty());
    let isolated = BTreeMap::from([(SWITCH_ENV.to_owned(), "0".to_owned())]);
    assert!(left_out(false, &isolated, &[]));
    assert!(left_out(false, &none, &["--tools".into(), "".into(), "--strict-mcp-config".into()]));
    assert!(!left_out(false, &none, &["--model".into(), "opus".into()]));
}

#[test]
fn the_cua_server_proxies_to_the_apps_tag_helper_socket_with_the_agent_token() {
    let bin = bin_with(&["cmux-cua"]);
    let state = Temp::new();
    let mut with_app = inputs(bin.path(), None, state.path());
    with_app.cua = crate::cua_socket::select(
        Some("/tmp/tag/cmux-cua.sock".into()),
        Some("agent-token".into()),
    );
    let tools = resolve(&with_app);
    let cua = &tools.servers[0];
    assert_eq!(cua.args, ["mcp", "--socket", "/tmp/tag/cmux-cua.sock"]);
    assert!(cua.env.contains(&("CMUX_CUA_SOCKET_AUTH_TOKEN".into(), "agent-token".into())));
    assert!(cua.env.contains(&("CMUX_CUA_MCP_FORCE_PROXY".into(), "1".into())));
    assert!(!cua.env.iter().any(|(k, _)| k.contains("HOST_AUTH")), "never the host token");

    // No token exported: no token env. No socket exported: cmux-cua's default.
    with_app.cua = crate::cua_socket::select(Some("/tmp/tag/cmux-cua.sock".into()), None);
    assert!(
        !resolve(&with_app).servers[0].env.iter().any(|(k, _)| k == "CMUX_CUA_SOCKET_AUTH_TOKEN")
    );
    assert_eq!(crate::cua_socket::select(Some("  ".into()), Some("t".into())), None);
    assert_eq!(resolve(&inputs(bin.path(), None, state.path())).servers[0].args, ["mcp"]);
}

#[test]
fn a_session_scope_reaches_only_the_cua_server_and_defaults_to_empty() {
    let bin = bin_with(&["cmux-cua", "cmux"]);
    let state = Temp::new();
    let tools = resolve(&inputs(bin.path(), Some("{\"mcp\":{\"enabled\":true}}"), state.path()));
    let scope =
        |tools: &AgentTools, name: &str| {
            tools.servers.iter().find(|s| s.name == name).and_then(|s| {
                s.env.iter().find(|(k, _)| k == CUA_SCOPE_ENV).map(|(_, v)| v.clone())
            })
        };
    let unscoped = tools.clone().scoped(&BTreeMap::new());
    assert_eq!(
        scope(&unscoped, "cmux-cua").as_deref(),
        Some(""),
        "no scope unless the session sets one"
    );
    let env =
        BTreeMap::from([(CUA_SCOPE_ENV.to_owned(), "com.cmuxterm.app.debug.agt1".to_owned())]);
    let scoped = tools.scoped(&env);
    assert_eq!(scope(&scoped, "cmux-cua").as_deref(), Some("com.cmuxterm.app.debug.agt1"));
    assert_eq!(scope(&scoped, "cmux"), None, "the scope is for computer use only");
    let config = config_of(&scoped.claude_args(&state.path().join("run/mcp/s.json")));
    assert_eq!(
        config["mcpServers"]["cmux-cua"]["env"][CUA_SCOPE_ENV],
        "com.cmuxterm.app.debug.agt1"
    );
}

#[test]
fn a_spawned_agent_never_inherits_a_helper_token() {
    let mut cmd = tokio::process::Command::new("/bin/true");
    crate::cua_socket::scrub_agent_env(&mut cmd);
    let removed: Vec<String> = cmd
        .as_std()
        .get_envs()
        .filter(|(_, v)| v.is_none())
        .map(|(k, _)| k.to_string_lossy().into_owned())
        .collect();
    for key in [
        "CMUX_NEXT_CUA_SOCKET_HOST_AUTH_TOKEN",
        "CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN",
        "CMUX_CUA_SOCKET_HOST_AUTH_TOKEN",
        "CMUX_CUA_SOCKET_AUTH_TOKEN",
    ] {
        assert!(removed.iter().any(|k| k == key), "{key} must be removed from an agent's env");
    }
}

#[test]
fn the_helper_token_is_never_on_a_command_line_and_its_config_file_is_private() {
    use std::os::unix::fs::PermissionsExt;
    let token = "agent-token-5f1c0d";
    let bin = bin_with(&["cmux-cua"]);
    let state = Temp::new();
    let home = Temp::new();
    let mut with_app = inputs(bin.path(), None, state.path());
    with_app.cua =
        crate::cua_socket::select(Some("/tmp/tag/cmux-cua.sock".into()), Some(token.into()));
    let tools = resolve(&with_app);
    // The cmux-cua child's argv.
    assert!(
        !tools.servers[0].args.iter().any(|a| a.contains(token)),
        "{:?}",
        tools.servers[0].args
    );
    // The claude process's argv.
    let path = mcp_config_path(home.path(), "01a1-session");
    let args = tools.claude_args(&path);
    assert!(!args.iter().any(|a| a.contains(token)), "the token must not be in argv: {args:?}");
    assert_eq!(args[1], path.to_string_lossy());
    let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&path), 0o600);
    assert_eq!(mode(path.parent().unwrap()), 0o700);
    let config = config_of(&args);
    assert_eq!(config["mcpServers"]["cmux-cua"]["env"]["CMUX_CUA_SOCKET_AUTH_TOKEN"], token);
    // Session end removes it.
    remove_mcp_config(home.path(), "01a1-session");
    assert!(!path.exists());
    assert_eq!(
        mcp_config_path(home.path(), "../x"),
        home.path().join("run/mcp/___x.json"),
        "a session id never leaves the folder"
    );
}

#[test]
fn a_running_helper_v2_gives_sessions_the_acpmux_bridge_instead_of_cmux_cua() {
    let bin = bin_with(&["cmux-cua"]);
    let state = Temp::new();
    let mut with_v2 = inputs(bin.path(), None, state.path());
    with_v2.cua = crate::cua_socket::select(
        Some("/tmp/tag/cmux-cua.sock".into()),
        Some("agent-token".into()),
    );
    with_v2.cua_v2 = Some(PathBuf::from("/tmp/cmux-cua-v2/scope"));
    with_v2.acpmux =
        Some(PathBuf::from("/Applications/cmux DEV.app/Contents/Resources/bin/acpmux"));
    let tools = resolve(&with_v2);
    let cua: Vec<_> = tools.servers.iter().filter(|s| s.name == "cmux-cua").collect();
    assert_eq!(cua.len(), 1, "one computer use server: {:?}", tools.servers);
    assert_eq!(
        cua[0].command,
        PathBuf::from("/Applications/cmux DEV.app/Contents/Resources/bin/acpmux")
    );
    assert_eq!(cua[0].args, ["cua-mcp"]);
    // Only the folder: the socket and secret stay in endpoint.json, never in argv or env.
    assert_eq!(
        cua[0].env,
        [(crate::cua_v2::ENDPOINT_DIR_ENV.to_owned(), "/tmp/cmux-cua-v2/scope".to_owned())]
    );
    assert!(!tools.mcp_config().unwrap().to_string().contains("agent-token"));

    // The helper v2 not running (no endpoint.json): the legacy server, unchanged.
    with_v2.cua_v2 = None;
    let legacy = resolve(&with_v2);
    assert_eq!(legacy.servers[0].command, bin.path().join("cmux-cua"));
    assert_eq!(legacy.servers[0].args, ["mcp", "--socket", "/tmp/tag/cmux-cua.sock"]);
}
