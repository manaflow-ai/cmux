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
    }
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
