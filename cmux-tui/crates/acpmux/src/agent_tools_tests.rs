#[test]
fn chief_turn_tools_contain_no_mac_app_actions() {
    let tools: Vec<_> = super::CHIEF_TURN_TOOLS.split(',').map(str::trim).collect();
    assert!(tools.iter().all(|tool| !tool.starts_with("app_")), "{tools:?}");
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

fn memory_inputs(bin: &std::path::Path, cmux_json: Option<&str>) -> super::Inputs {
    super::Inputs {
        enabled: true,
        bin_dir: Some(bin.to_owned()),
        cmux_json: cmux_json.map(str::to_owned),
        state_dir: bin.join("state"),
        cua: None,
        cua_v2: None,
        acpmux: None,
        secrets: false,
        offers: false,
        subsessions: false,
        displays: None,
    }
}

#[test]
fn agent_memory_is_off_until_the_setting_turns_it_on() {
    use std::os::unix::fs::PermissionsExt;
    let root = std::env::temp_dir().join(format!("acpmux-agent-memory-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let chief = root.join("optchat-chief");
    std::fs::write(&chief, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&chief, std::fs::Permissions::from_mode(0o755)).unwrap();
    let names = |json: Option<&str>| -> Vec<String> {
        super::resolve(&memory_inputs(&root, json)).servers.into_iter().map(|s| s.name).collect()
    };
    // Off by default: no file, no key, another value, a file that does not parse.
    for json in [None, Some("{}"), Some(r#"{"agents":{"memory":{"enabled":"yes"}}}"#), Some("{")] {
        assert!(!names(json).contains(&super::MEMORY_SERVER_NAME.to_owned()), "{json:?}");
    }
    // On, nested or flat, in JSONC.
    for json in [
        "{\"agents\": {\"memory\": {\"enabled\": true}}}",
        "{\n// mine\n\"agents.memory.enabled\": true,\n}",
    ] {
        let tools = super::resolve(&memory_inputs(&root, Some(json)));
        let memory = tools
            .servers
            .iter()
            .find(|s| s.name == super::MEMORY_SERVER_NAME)
            .unwrap_or_else(|| panic!("{json}"));
        assert_eq!(memory.command, chief);
        assert_eq!(memory.args, ["agent-memory", "mcp"]);
        // The session reaches the server, for the notes' provenance.
        let one = tools.for_session("s-1");
        let memory = one.servers.iter().find(|s| s.name == super::MEMORY_SERVER_NAME).unwrap();
        assert_eq!(memory.env, [(super::AGENT_SESSION_ENV.to_owned(), "s-1".to_owned())]);
    }
    // No optchat-chief next to acpmux: no server, even when on.
    std::fs::remove_file(&chief).unwrap();
    assert!(names(Some(r#"{"agents":{"memory":{"enabled":true}}}"#)).is_empty());
    let _ = std::fs::remove_dir_all(&root);
}

/// A shipped NIGHTLY/NEXT app has no `Contents/Resources/bin/cmux-cua`: its
/// only copy is the signed helper app at `Contents/Library/cmux Computer
/// Use.app` (nightly.yml removes the scratch bin copy). Sessions must still
/// get the `cmux-cua` server, from that helper's executable.
#[test]
fn cmux_cua_falls_back_to_the_nested_helper_app() {
    use std::os::unix::fs::PermissionsExt;
    let root = std::env::temp_dir().join(format!("acpmux-cua-helper-{}", uuid::Uuid::now_v7()));
    let bin = root.join("Contents/Resources/bin");
    let helper_dir = root.join("Contents/Library/cmux Computer Use.app/Contents/MacOS");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::create_dir_all(&helper_dir).unwrap();
    let helper = helper_dir.join("cmux-cua");
    std::fs::write(&helper, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
    let cua = |tools: &super::AgentTools| {
        tools.servers.iter().find(|s| s.name == "cmux-cua").map(|s| s.command.clone())
    };
    let tools = super::resolve(&memory_inputs(&bin, None));
    assert_eq!(cua(&tools), Some(helper.clone()), "the nested helper stands in");
    // A bin copy (a DEV build) wins over the helper.
    let bin_cua = bin.join("cmux-cua");
    std::fs::write(&bin_cua, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&bin_cua, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert_eq!(cua(&super::resolve(&memory_inputs(&bin, None))), Some(bin_cua.clone()));
    // Neither: no server.
    std::fs::remove_file(&bin_cua).unwrap();
    std::fs::remove_file(&helper).unwrap();
    assert_eq!(cua(&super::resolve(&memory_inputs(&bin, None))), None);
    let _ = std::fs::remove_dir_all(&root);
}

/// On a Linux machine `acpmux` is a symlink to `cmux-tui`, and `current_exe`
/// resolves it: the daemon runs as `cmux-tui acp daemon run` with the prefix
/// `acp`. cmux-tui starts acpmux only under `acp` (or as argv0 `acpmux`), so
/// this daemon's own MCP servers must be `cmux-tui acp <word>` too, or the
/// sub-session tools never start on a cloud VM.
#[test]
fn own_servers_run_under_the_daemon_prefix() {
    let root = std::env::temp_dir().join(format!("acpmux-own-servers-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let exe = std::path::PathBuf::from("/usr/local/lib/cmux/cmux-tui");
    let inputs = |prefix: &[&str]| super::Inputs {
        acpmux: Some(crate::self_command::SelfCommand::new(
            exe.clone(),
            prefix.iter().map(std::ffi::OsString::from).collect(),
        )),
        cua_v2: Some(root.join("cua-v2")),
        secrets: true,
        offers: true,
        subsessions: true,
        ..memory_inputs(&root, None)
    };
    let servers = |prefix: &[&str]| -> Vec<(String, Vec<String>)> {
        let tools = super::resolve(&inputs(prefix));
        assert!(tools.servers.iter().all(|s| s.command == exe), "{:?}", tools.servers);
        tools.servers.into_iter().map(|s| (s.name, s.args)).collect()
    };
    let expect = |prefix: &[&str]| -> Vec<(String, Vec<String>)> {
        [
            (crate::cua_v2::SERVER_NAME, "cua-mcp"),
            (crate::secret_mcp::SERVER_NAME, "secret-mcp"),
            (crate::offer_mcp::SERVER_NAME, "offer-mcp"),
            (crate::subsession_mcp::SERVER_NAME, "subsession-mcp"),
            (crate::forum_mcp::SERVER_NAME, "forum-mcp"),
            (crate::acpmux_mcp::SERVER_NAME, "acpmux-mcp"),
        ]
        .into_iter()
        .map(|(name, word)| {
            let args = prefix.iter().copied().chain([word]).map(str::to_owned).collect();
            (name.to_owned(), args)
        })
        .collect()
    };
    // A standalone acpmux (the app's bundled copy): the bare command word.
    assert_eq!(servers(&[]), expect(&[]));
    // cmux-tui: `cmux-tui acp subsession-mcp`.
    assert_eq!(servers(&["acp"]), expect(&["acp"]));
    // Per-workspace displays (a Linux cloud machine) still drop the helper v2
    // bridge, which cannot be pinned to a display, under the prefix too.
    let mut tools = super::resolve(&inputs(&["acp"]));
    tools.displays = Some(root.join("displays"));
    let env = std::collections::BTreeMap::from([(
        crate::agent_displays::WORKSPACE_KEY.to_owned(),
        "ws-1".to_owned(),
    )]);
    let names: Vec<String> = tools.scoped(&env).servers.into_iter().map(|s| s.name).collect();
    assert!(!names.iter().any(|n| n == crate::cua_v2::SERVER_NAME), "{names:?}");
    assert!(names.iter().any(|n| n == crate::subsession_mcp::SERVER_NAME), "{names:?}");
    let _ = std::fs::remove_dir_all(&root);
}

/// A launch without servers removes the last launch's MCP config, so the background-shell hook
/// (`bg_hook.rs`) never points the agent at a `bg_start` it no longer has, and every launch drops
/// the calls the hook turned away under the last one.
#[test]
fn a_launch_without_servers_removes_the_last_mcp_config() {
    let root = std::env::temp_dir().join(format!("acpmux-stale-mcp-{}", uuid::Uuid::now_v7()));
    let file = root.join("s.json");
    let mut with = super::AgentTools::default();
    with.servers.push(super::McpServer {
        name: crate::acpmux_mcp::SERVER_NAME.to_owned(),
        command: "acpmux".into(),
        args: vec![],
        env: vec![],
    });
    assert!(with.claude_args(&file).contains(&"--mcp-config".to_owned()));
    assert!(file.is_file());
    // A call the hook turned away under the last launch is no retry under the next.
    let denied = crate::bg_hook::denied_path(&file);
    std::fs::write(&denied, "a-hash\n").unwrap();
    with.claude_args(&file);
    assert!(!denied.exists(), "a launch kept the last launch's turned-away calls");
    let args = super::AgentTools::default().claude_args(&file);
    assert!(!args.contains(&"--mcp-config".to_owned()), "{args:?}");
    assert!(!file.exists(), "the last launch's config stayed for the hook to read");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn cloud_repo_tools_receive_complete_protected_caller_identity() {
    let tools = super::AgentTools {
        servers: vec![super::McpServer {
            name: crate::cloud_repo_mcp::SERVER_NAME.to_owned(),
            command: "/bin/acpmux".into(),
            args: vec!["repo-mcp".into()],
            env: vec![
                ("ACPMUX_SESSION_ID".into(), "foreign".into()),
                ("CMUX_BIN".into(), "/bin/cmux".into()),
            ],
        }],
        ..Default::default()
    }
    .for_session("own-chat");
    let env: std::collections::HashMap<_, _> = tools.servers[0].env.iter().cloned().collect();
    assert_eq!(env["ACPMUX_SESSION_ID"], "own-chat");
    assert_eq!(env[crate::cloud_repo_mcp::SESSION_ENV], "own-chat");
    assert_eq!(
        env[crate::hub::person::CALLER_TOKEN_ENV],
        crate::hub::person::caller_token("own-chat")
    );
    assert_eq!(env[crate::hub::person::CALLER_SOCKET_ENV], env["ACPMUX_SOCKET"]);
    assert_eq!(env["CMUX_BIN"], "/bin/cmux");
}
