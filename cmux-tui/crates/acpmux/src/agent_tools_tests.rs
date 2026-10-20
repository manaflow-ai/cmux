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
