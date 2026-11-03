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
            (crate::mcp_proxy::SERVER_NAME, "mcp-proxy"),
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

/// The session's tool allowlist reaches the `acpmux` server as well as `cmux`, so with
/// no `cmux` to fold into (cmux.json turns MCP off) the standalone server still filters
/// its own tools, after `for_session` too (#30082 review).
#[test]
fn a_tool_allowlist_reaches_a_standalone_acpmux_server() {
    let server = |name: &str| super::McpServer {
        name: name.to_owned(),
        command: "x".into(),
        args: vec![],
        env: vec![],
    };
    let tools = super::AgentTools {
        servers: vec![server(crate::acpmux_mcp::SERVER_NAME), server("cmux-cua")],
        ..Default::default()
    };
    let env = std::collections::BTreeMap::from([
        (super::SERVERS_ENV.to_owned(), "cmux,acpmux".to_owned()),
        (super::MCP_TOOLS_ENV.to_owned(), super::CHIEF_TURN_TOOLS.to_owned()),
    ]);
    // As production builds them: `for_session` resets the server's env to its credentials.
    let folded = tools.scoped(&env).for_session("s-allowlist").folded();
    assert_eq!(folded.servers.len(), 1, "{:?}", folded.servers);
    let acpmux = &folded.servers[0];
    assert_eq!(acpmux.name, crate::acpmux_mcp::SERVER_NAME);
    assert!(
        acpmux.env.iter().any(|(k, v)| k == super::MCP_TOOLS_ENV && v == super::CHIEF_TURN_TOOLS),
        "{:?}",
        acpmux.env
    );
}

/// A hook binary that does not know `__bg-hook` never blocks the chat's Bash calls: as the cmux
/// CLI does (gcp-codex-swarm-09, 2026-11-02), the bare command refuses with exit 2, which Claude
/// Code takes as "block this call", and the plugin's command runs the call instead. A deny the
/// hook prints still reaches Claude Code.
#[test]
fn a_hook_binary_that_does_not_know_the_hook_lets_the_call_run() {
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;
    let root = std::env::temp_dir().join(format!("acpmux-hook-skew-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let script = |name: &str, body: &str| {
        let path = root.join(name);
        std::fs::write(&path, format!("#!/bin/sh\ncat >/dev/null\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path.to_string_lossy().into_owned()
    };
    let run = |command: &str| {
        let mut child = std::process::Command::new("sh")
            .arg("-c")
            .arg(command)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap();
        // A binary that is gone never reads its input: the write may fail with a broken pipe.
        let _ = child.stdin.take().unwrap().write_all(br#"{"tool_name":"Bash"}"#);
        child.wait_with_output().unwrap()
    };
    let words = |exe: String| vec![exe, crate::bg_hook::HOOK_ARG.to_owned(), "/h".to_owned()];
    let old =
        words(script("cmux", r#"echo 'cmux: unknown resource scope "__bg-hook".' >&2; exit 2"#));
    let bare: Vec<String> = old.iter().map(|w| format!("'{w}'")).collect();
    assert_eq!(run(&bare.join(" ")).status.code(), Some(2), "the skew this guards against");
    let out = run(&super::hook_command(&old));
    assert!(out.status.success(), "a refusing hook binary blocked the call: {out:?}");
    // A binary that is gone does not block either.
    let gone = words(root.join("gone").to_string_lossy().into_owned());
    assert!(run(&super::hook_command(&gone)).status.success());
    // The hook's own answer still gets through.
    let deny = words(script("acpmux", r#"echo '{"deny":true}'"#));
    let out = run(&super::hook_command(&deny));
    assert!(out.status.success());
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), r#"{"deny":true}"#);
    let _ = std::fs::remove_dir_all(&root);
}

/// `github_status` lives in the `acpmux` server, which every harness gets the same way: Claude
/// Code in its `--mcp-config`, every ACP harness (Codex, OpenCode, Gemini, pi) in `mcpServers`,
/// and, folded behind `cmux`, in its upstreams.
#[test]
fn the_github_status_server_reaches_every_harness_kind() {
    use std::os::unix::fs::PermissionsExt;
    let root = std::env::temp_dir().join(format!("acpmux-gh-status-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let inputs = super::Inputs {
        acpmux: Some(crate::self_command::SelfCommand::new(
            std::path::PathBuf::from("/usr/local/bin/acpmux"),
            vec![],
        )),
        ..memory_inputs(&root, None)
    };
    let tools = super::resolve(&inputs).for_session("s1");
    let acpmux = crate::acpmux_mcp::SERVER_NAME;
    let acp = tools.acp_servers();
    let entry = acp.as_array().unwrap().iter().find(|s| s["name"] == acpmux).unwrap();
    assert_eq!(entry["args"], serde_json::json!(["acpmux-mcp"]));
    let claude = tools.mcp_config().unwrap();
    assert_eq!(claude["mcpServers"][acpmux]["args"], serde_json::json!(["acpmux-mcp"]));
    // With the cmux server, the acpmux server is one of its upstreams.
    let cmux = root.join("cmux");
    std::fs::write(&cmux, "#!/bin/sh\n").unwrap();
    std::fs::set_permissions(&cmux, std::fs::Permissions::from_mode(0o755)).unwrap();
    let folded = super::resolve(&inputs).for_session("s1").folded();
    let upstreams =
        &folded.servers[0].env.iter().find(|(k, _)| k == super::UPSTREAMS_ENV).unwrap().1;
    let upstreams: serde_json::Value = serde_json::from_str(upstreams).unwrap();
    assert!(upstreams.as_array().unwrap().iter().any(|s| s["name"] == acpmux), "{upstreams}");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn the_claude_guidance_switch_also_leaves_the_chat_skill_out_of_the_plugin() {
    let state = tempfile::tempdir().unwrap();
    let on = super::materialize(state.path(), true).unwrap();
    let off = super::materialize(state.path(), false).unwrap();
    assert_ne!(on, off, "each set of skills gets its own folder");
    assert!(on.join("skills/cmux-chat/SKILL.md").is_file());
    assert!(!off.join("skills/cmux-chat").exists());
    assert!(off.join("skills/cmux-browser/SKILL.md").is_file(), "other skills stay");
}
