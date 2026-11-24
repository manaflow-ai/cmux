/// `super::resolve`: the tool list no longer depends on the machine's consent (the worker's
/// host and the remote relay enforce it where a call runs).
fn resolve(inputs: &super::Inputs) -> super::AgentTools {
    super::resolve(inputs)
}

/// A `cmux` without `mcp serve` (the static `cmux 0.1.0` lane VMs had) is no `cmux` server, so
/// the other servers stay listed on their own instead of folding behind one that exits at once.
#[test]
fn a_cmux_without_mcp_serve_is_no_server_and_folds_nothing() {
    let root = std::env::temp_dir().join(format!("acpmux-cmux-no-mcp-{}", uuid::Uuid::now_v7()));
    let names = |cmux: &str| -> Vec<String> {
        let bin = root.join(uuid::Uuid::now_v7().to_string());
        std::fs::create_dir_all(&bin).unwrap();
        for (name, body) in [("cmux", cmux), ("optchat-chief", "exit 0")] {
            crate::test_exec::write_executable(bin.join(name), format!("#!/bin/sh\n{body}\n"));
        }
        let inputs = memory_inputs(&bin, Some(r#"{"agents":{"memory":{"enabled":true}}}"#));
        resolve(&inputs).folded().servers.into_iter().map(|s| s.name).collect()
    };
    let serves = names("exit 0");
    assert_eq!(serves, ["cmux"], "the other servers fold behind it");
    let old = names(r#"echo 'cmux: unknown resource scope "mcp".' >&2; exit 2"#);
    // The saved MCP servers (the optchat-chief stub beside it) are listed on their own too.
    assert_eq!(
        old,
        [super::MEMORY_SERVER_NAME, super::SAVED_SERVERS_NAME],
        "listed on their own, not lost"
    );
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn chief_turn_tools_contain_no_mac_app_actions() {
    let tools: Vec<_> = super::CHIEF_TURN_TOOLS.split(',').map(str::trim).collect();
    assert!(tools.iter().all(|tool| !tool.starts_with("app_")), "{tools:?}");
}

fn memory_inputs(bin: &std::path::Path, cmux_json: Option<&str>) -> super::Inputs {
    super::Inputs {
        enabled: true,
        bin_dir: Some(bin.to_owned()),
        cmux_json: cmux_json.map(str::to_owned),
        state_dir: bin.join("state"),
        acpmux: None,
        secrets: false,
        offers: false,
        subsessions: false,
        displays: None,
        hosted: false,
        github: false,
        desktop_lease: None,
    }
}

#[test]
fn agent_memory_is_off_until_the_setting_turns_it_on() {
    let root = std::env::temp_dir().join(format!("acpmux-agent-memory-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let chief = root.join("optchat-chief");
    crate::test_exec::write_executable(&chief, "#!/bin/sh\nexit 0\n");
    let names = |json: Option<&str>| -> Vec<String> {
        resolve(&memory_inputs(&root, json)).servers.into_iter().map(|s| s.name).collect()
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
        let tools = resolve(&memory_inputs(&root, Some(json)));
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

/// Every session gets the Computer Use bridge, whether or not a worker runs:
/// nothing on disk decides it, not even `computerUse.mode: "off"` (a chat
/// keeps its tools when the person turns Computer Use on later), only no
/// acpmux binary to run it, in a test without one.
#[test]
fn every_session_gets_computer_use_even_when_the_mode_is_off() {
    let root = std::env::temp_dir().join(format!("acpmux-cu-server-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let exe = std::path::PathBuf::from("/usr/local/bin/acpmux");
    let inputs = |json: Option<&str>| super::Inputs {
        acpmux: Some(crate::self_command::SelfCommand::new(exe.clone(), Vec::new())),
        ..memory_inputs(&root, json)
    };
    let has = |json: Option<&str>| {
        super::resolve(&inputs(json))
            .servers
            .iter()
            .any(|s| s.name == crate::computer_use::mcp::SERVER_NAME)
    };
    for json in [
        None,
        Some("{}"),
        Some("{"),
        Some(r#"{"computerUse":{"mode":"fullAccess"}}"#),
        Some(r#"{"computerUse":{"mode":"lookOnly"}}"#),
        Some(r#"{"computerUse.mode":"askEveryTime"}"#),
        Some(r#"{"computerUse":{"mode":"off"}}"#),
        Some("{\n// mine\n\"computerUse.mode\": \"off\",\n}"),
    ] {
        assert!(has(json), "{json:?}");
    }
    // Off still lists the cmux-computer-use skill beside the server.
    let off = super::resolve(&inputs(Some(r#"{"computerUse":{"mode":"off"}}"#)));
    assert!(off.lists_skill("cmux-computer-use"));
    // The session's own key, this daemon and nothing inherited.
    let tools = super::resolve(&inputs(None)).for_session("s-cu");
    let cu =
        tools.servers.iter().find(|s| s.name == crate::computer_use::mcp::SERVER_NAME).unwrap();
    assert_eq!(cu.args, [crate::computer_use::mcp::COMMAND]);
    let env: std::collections::HashMap<_, _> = cu.env.iter().cloned().collect();
    assert_eq!(env[crate::computer_use::mcp::SESSION_ENV], "s-cu");
    assert!(env.contains_key("ACPMUX_SOCKET"), "{env:?}");
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
        secrets: true,
        offers: true,
        subsessions: true,
        ..memory_inputs(&root, None)
    };
    let servers = |prefix: &[&str]| -> Vec<(String, Vec<String>)> {
        let tools = resolve(&inputs(prefix));
        assert!(tools.servers.iter().all(|s| s.command == exe), "{:?}", tools.servers);
        tools.servers.into_iter().map(|s| (s.name, s.args)).collect()
    };
    let expect = |prefix: &[&str]| -> Vec<(String, Vec<String>)> {
        [
            (crate::computer_use::mcp::SERVER_NAME, crate::computer_use::mcp::COMMAND),
            (crate::secret_mcp::SERVER_NAME, "secret-mcp"),
            (crate::offer_mcp::SERVER_NAME, "offer-mcp"),
            (crate::subsession_mcp::SERVER_NAME, "subsession-mcp"),
            (crate::forum_mcp::SERVER_NAME, "forum-mcp"),
            (crate::acpmux_mcp_names::SERVER_NAME, "acpmux-mcp"),
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
    // Per-workspace displays (a Linux cloud machine) drop the Computer Use
    // bridge, which drives the machine's one desktop, under the prefix too.
    let mut tools = resolve(&inputs(&["acp"]));
    tools.displays = Some(root.join("displays"));
    let env = std::collections::BTreeMap::from([(
        crate::agent_displays::WORKSPACE_KEY.to_owned(),
        "ws-1".to_owned(),
    )]);
    let names: Vec<String> = tools.scoped(&env).servers.into_iter().map(|s| s.name).collect();
    assert!(!names.iter().any(|n| n == crate::computer_use::mcp::SERVER_NAME), "{names:?}");
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
        name: crate::acpmux_mcp_names::SERVER_NAME.to_owned(),
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
        servers: vec![
            server(crate::acpmux_mcp_names::SERVER_NAME),
            server(crate::computer_use::mcp::SERVER_NAME),
        ],
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
    assert_eq!(acpmux.name, crate::acpmux_mcp_names::SERVER_NAME);
    assert!(
        acpmux.env.iter().any(|(k, v)| k == super::MCP_TOOLS_ENV && v == super::CHIEF_TURN_TOOLS),
        "{:?}",
        acpmux.env
    );
}

/// CMUX-288: the `acpmux` server's `pr_state` runs `gh` with the server's env, and a client that
/// passes a stdio server only an allowlisted env (Codex) left out the agent's gh sign-in. The
/// server now gets the agent's own `GH_TOKEN`, `GITHUB_TOKEN` and `GH_CONFIG_DIR` after
/// `for_session` resets its env, folded behind `cmux` too; no other server gets them.
#[test]
fn the_acpmux_server_gets_the_agents_gh_sign_in() {
    let server = |name: &str| super::McpServer {
        name: name.to_owned(),
        command: "x".into(),
        args: vec![],
        env: vec![],
    };
    let tools = super::AgentTools {
        servers: vec![server("cmux"), server(crate::acpmux_mcp_names::SERVER_NAME)],
        // cmux's tools are on for agents (agents.cmuxMcp), so `cmux` stays.
        cmux_for_agents: true,
        ..Default::default()
    };
    let env = std::collections::BTreeMap::from([
        ("GH_TOKEN".to_owned(), "gho_profile".to_owned()),
        ("GH_CONFIG_DIR".to_owned(), "/home/u/.config/gh-work".to_owned()),
    ]);
    let folded = tools.scoped(&env).for_session("s-gh").folded();
    let cmux = &folded.servers[0];
    assert!(cmux.env.iter().all(|(k, _)| !super::GH_ENV.contains(&k.as_str())), "{:?}", cmux.env);
    let upstreams = &cmux.env.iter().find(|(k, _)| k == super::UPSTREAMS_ENV).unwrap().1;
    let upstreams: serde_json::Value = serde_json::from_str(upstreams).unwrap();
    let acpmux = upstreams
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["name"] == crate::acpmux_mcp_names::SERVER_NAME)
        .unwrap();
    assert_eq!(acpmux["env"]["GH_TOKEN"], "gho_profile", "{acpmux}");
    assert_eq!(acpmux["env"]["GH_CONFIG_DIR"], "/home/u/.config/gh-work", "{acpmux}");
}

/// Which gh values the agent has: a literal profile value first, else what every local child
/// gets; a profile reference is left out (only the launch resolves it), and nothing else comes in.
#[test]
fn gh_env_is_what_the_agent_starts_with() {
    let child = || {
        vec![
            ("GITHUB_TOKEN".to_owned(), "ghp_login".to_owned()),
            ("GH_TOKEN".to_owned(), "gho_login".to_owned()),
            ("GH_HOST".to_owned(), String::new()),
            ("NPM_TOKEN".to_owned(), "npm".to_owned()),
        ]
    };
    let profile = std::collections::BTreeMap::from([
        ("GH_TOKEN".to_owned(), "${keychain:gh}".to_owned()),
        ("GH_CONFIG_DIR".to_owned(), "/cfg".to_owned()),
    ]);
    assert_eq!(
        super::gh_env(&profile, child),
        vec![
            ("GITHUB_TOKEN".to_owned(), "ghp_login".to_owned()),
            ("GH_CONFIG_DIR".to_owned(), "/cfg".to_owned()),
        ]
    );
    assert!(super::gh_env(&std::collections::BTreeMap::new(), Vec::new).is_empty());
}

/// `github_status` lives in the `acpmux` server, which every harness gets the same way: Claude
/// Code in its `--mcp-config`, every ACP harness (Codex, OpenCode, Gemini, pi) in `mcpServers`,
/// and, folded behind `cmux`, in its upstreams.
#[test]
fn the_github_status_server_reaches_every_harness_kind() {
    let root = std::env::temp_dir().join(format!("acpmux-gh-status-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let inputs = super::Inputs {
        acpmux: Some(crate::self_command::SelfCommand::new(
            std::path::PathBuf::from("/usr/local/bin/acpmux"),
            vec![],
        )),
        ..memory_inputs(&root, None)
    };
    let tools = resolve(&inputs).for_session("s1");
    let acpmux = crate::acpmux_mcp_names::SERVER_NAME;
    let acp = tools.acp_servers();
    let entry = acp.as_array().unwrap().iter().find(|s| s["name"] == acpmux).unwrap();
    assert_eq!(entry["args"], serde_json::json!(["acpmux-mcp"]));
    let claude = tools.mcp_config().unwrap();
    assert_eq!(claude["mcpServers"][acpmux]["args"], serde_json::json!(["acpmux-mcp"]));
    // With the cmux server, the acpmux server is one of its upstreams.
    let cmux = root.join("cmux");
    crate::test_exec::write_executable(&cmux, "#!/bin/sh\n");
    let folded = resolve(&inputs).for_session("s1").folded();
    let upstreams =
        &folded.servers[0].env.iter().find(|(k, _)| k == super::UPSTREAMS_ENV).unwrap().1;
    let upstreams: serde_json::Value = serde_json::from_str(upstreams).unwrap();
    assert!(upstreams.as_array().unwrap().iter().any(|s| s["name"] == acpmux), "{upstreams}");
    let _ = std::fs::remove_dir_all(&root);
}

/// The Chief's engine file reaches only the `cmux` server (its `cloud_computer` default machine),
/// and a daemon's own value never does.
#[test]
fn the_chief_engine_file_reaches_only_the_cmux_server() {
    let server = |name: &str, env: Vec<(String, String)>| super::McpServer {
        name: name.to_owned(),
        command: "x".into(),
        args: vec![],
        env,
    };
    let stale = vec![(super::CHIEF_ENGINE_ENV.to_owned(), "/stale/engine.json".to_owned())];
    let tools = super::AgentTools {
        servers: vec![server("cmux", stale.clone()), server("cmux-cua", stale)],
        cmux_for_agents: true,
        ..Default::default()
    };
    let env = std::collections::BTreeMap::from([(
        super::CHIEF_ENGINE_ENV.to_owned(),
        "/chief/optchat/engine.json".to_owned(),
    )]);
    let scoped = tools.clone().scoped(&env);
    let engine = |s: &super::McpServer| {
        s.env
            .iter()
            .filter(|(k, _)| k == super::CHIEF_ENGINE_ENV)
            .map(|(_, v)| v.clone())
            .collect::<Vec<_>>()
    };
    assert_eq!(engine(&scoped.servers[0]), ["/chief/optchat/engine.json"]);
    assert!(engine(&scoped.servers[1]).is_empty());
    let unset = tools.scoped(&std::collections::BTreeMap::new());
    assert!(unset.servers.iter().all(|s| engine(s).is_empty()));
}

#[test]
fn the_claude_guidance_switch_also_leaves_the_chat_skill_out_of_the_plugin() {
    let state = tempfile::tempdir().unwrap();
    let on = super::materialize(state.path(), |_| true).unwrap();
    let off = super::materialize(state.path(), |skill| skill != "cmux-chat").unwrap();
    assert_ne!(on, off, "each set of skills gets its own folder");
    assert!(on.join("skills/cmux-chat/SKILL.md").is_file());
    assert!(!off.join("skills/cmux-chat").exists());
    assert!(off.join("skills/cmux-browser/SKILL.md").is_file(), "other skills stay");
}

/// A chat without computer use or the secrets server is not told about their skills: the
/// fitted plugin leaves out `cmux-computer-use` and `cmux-sudo`, keeps the rest (the chat skill
/// as the full plugin had it), and the tool rows and context sources say the same.
#[test]
fn a_skill_for_a_server_the_chat_lacks_is_not_listed() {
    let state = tempfile::tempdir().unwrap();
    let server = |name: &str| super::McpServer {
        name: name.into(),
        command: "/bin/true".into(),
        args: vec![],
        env: vec![],
    };
    let full = super::materialize(state.path(), |_| true).unwrap();
    let with = super::AgentTools {
        servers: vec![
            server("cmux"),
            server("cmux-computer-use"),
            server(crate::secret_mcp::SERVER_NAME),
        ],
        plugin_dir: Some(full.clone()),
        ..Default::default()
    };
    assert_eq!(with.clone().fit_skills().plugin_dir, Some(full.clone()), "nothing to leave out");
    let without = super::AgentTools { servers: vec![server("cmux")], ..with }.fit_skills();
    let fit = without.plugin_dir.clone().unwrap();
    assert_ne!(fit, full);
    assert_eq!(fit.parent(), full.parent());
    for gone in ["cmux-computer-use", "cmux-sudo"] {
        assert!(!fit.join("skills").join(gone).exists(), "{gone} is listed");
    }
    for kept in ["cmux-browser", "cmux-chat", "acpmux", "cmux-live"] {
        assert!(fit.join("skills").join(kept).join("SKILL.md").is_file(), "{kept} is gone");
    }
    assert!(!fit.join("hooks/hooks.json").exists());
    let rows: Vec<_> = without.tool_rows(true, true).into_iter().map(|r| r.id).collect();
    assert!(rows.contains(&"skill:cmux:cmux-browser".to_owned()), "{rows:?}");
    assert!(
        !rows.iter().any(|r| r.ends_with("cmux-computer-use") || r.ends_with("cmux-sudo")),
        "{rows:?}"
    );
    let parts: Vec<_> = without.context_parts(true).into_iter().map(|p| p.id).collect();
    assert!(!parts.iter().any(|p| p == "cmux-source-skill-cmux-cmux-computer-use"), "{parts:?}");
    // A plugin without the chat skill (`agents.guidance.claude` off) stays without it.
    let no_chat = super::materialize(state.path(), |skill| skill != "cmux-chat").unwrap();
    let fit = super::AgentTools { plugin_dir: Some(no_chat), ..without }.fit_skills();
    let fit = fit.plugin_dir.unwrap();
    assert!(
        !fit.join("skills/cmux-chat").exists() && !fit.join("skills/cmux-computer-use").exists()
    );
}

/// cmux's hosted MCP server (`hosted_mcp.rs`) reaches a session only while the daemon turns it
/// on, as an acpmux subcommand whose env holds the `cmux` CLI's path and nothing that signs in;
/// folded behind `cmux`, its upstream spec carries the same.
#[test]
fn the_hosted_mcp_server_is_off_by_default_and_its_config_holds_no_token() {
    let root = std::env::temp_dir().join(format!("acpmux-hosted-mcp-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let cmux = root.join("cmux");
    crate::test_exec::write_executable(&cmux, "#!/bin/sh\n");
    let inputs = |hosted: bool| super::Inputs {
        acpmux: Some(crate::self_command::SelfCommand::new(
            std::path::PathBuf::from("/usr/local/bin/acpmux"),
            vec![],
        )),
        hosted,
        ..memory_inputs(&root, None)
    };
    let name = crate::hosted_mcp::SERVER_NAME;
    let off = resolve(&inputs(false));
    assert!(off.servers.iter().all(|s| s.name != name), "{:?}", off.servers);
    let on = resolve(&inputs(true)).for_session("s1");
    let server = on.servers.iter().find(|s| s.name == name).expect("the hosted server");
    assert_eq!(server.args, ["hosted-mcp"]);
    assert_eq!(
        server.env,
        [(crate::hosted_mcp::CMUX_BIN_ENV.to_owned(), cmux.to_string_lossy().into_owned())]
    );
    let folded = resolve(&inputs(true)).for_session("s1").folded();
    let upstreams: serde_json::Value = serde_json::from_str(
        &folded.servers[0].env.iter().find(|(k, _)| k == super::UPSTREAMS_ENV).unwrap().1,
    )
    .unwrap();
    let spec = upstreams.as_array().unwrap().iter().find(|s| s["name"] == name).unwrap();
    assert_eq!(spec["args"], serde_json::json!(["hosted-mcp"]));
    assert_eq!(spec["env"], serde_json::json!({"CMUX_BIN": cmux.to_string_lossy()}));
    // No `cmux` CLI to ask the app for a token: no server.
    std::fs::remove_file(&cmux).unwrap();
    assert!(resolve(&inputs(true)).servers.iter().all(|s| s.name != name));
    let _ = std::fs::remove_dir_all(&root);
}

/// acpmux audit finding 10: a chat ran five `acpmux *-mcp` processes (secrets, offers,
/// sub-sessions, forum, acpmux), about 4 MB and 5 threads each, 330 MB and 400 threads at 18
/// live chats (Leo's Mac, 2026-11-11). Every one of acpmux's own servers in a chat's list now
/// names one process to run in, `acpmux tools-mcp`, with each server's own env in its env; each
/// keeps its name and own command, so the tool names the agent sees stay as they were.
#[test]
fn a_chat_runs_acpmux_s_own_tool_servers_in_one_process() {
    let root = std::env::temp_dir().join(format!("acpmux-one-helper-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let cmux = root.join("cmux");
    crate::test_exec::write_executable(&cmux, "#!/bin/sh\n");
    let exe = std::path::PathBuf::from("/usr/local/lib/cmux/cmux-tui");
    let inputs = super::Inputs {
        acpmux: Some(crate::self_command::SelfCommand::new(exe.clone(), vec!["acp".into()])),
        secrets: true,
        offers: true,
        subsessions: true,
        ..memory_inputs(&root, None)
    };
    let folded = resolve(&inputs).for_session("s-one").folded();
    let upstreams =
        &folded.servers[0].env.iter().find(|(k, _)| k == super::UPSTREAMS_ENV).unwrap().1;
    let upstreams: serde_json::Value = serde_json::from_str(upstreams).unwrap();
    let upstreams = upstreams.as_array().unwrap();
    let own = ["cmux-secrets", "cmux-sessions", "cmux-subsessions", "cmux-forum", "acpmux"];
    let names: Vec<&str> = upstreams.iter().filter_map(|s| s["name"].as_str()).collect();
    assert_eq!(
        names,
        [
            crate::computer_use::mcp::SERVER_NAME,
            "cmux-secrets",
            "cmux-sessions",
            "cmux-subsessions",
            "cmux-forum",
            "acpmux"
        ]
    );
    // The process each server runs in: its shared launch, else its own command.
    let launch = |s: &serde_json::Value| -> serde_json::Value {
        match s.get("shared") {
            Some(shared) => serde_json::json!([shared["command"], shared["args"]]),
            None => serde_json::json!([s["command"], s["args"]]),
        }
    };
    let launches: std::collections::BTreeSet<String> = upstreams
        .iter()
        .filter(|s| own.contains(&s["name"].as_str().unwrap()))
        .map(|s| launch(s).to_string())
        .collect();
    assert_eq!(launches.len(), 1, "one helper process per chat, not one per server: {launches:?}");
    let shared = &upstreams[1]["shared"];
    assert_eq!(shared["command"], serde_json::json!(exe), "{shared}");
    assert_eq!(shared["args"], serde_json::json!(["acp", "tools-mcp"]), "{shared}");
    // Its env has every server's own env: each server's session and caller token, the same values.
    for server in upstreams.iter().filter(|s| own.contains(&s["name"].as_str().unwrap())) {
        for (key, value) in server["env"].as_object().unwrap() {
            assert_eq!(&shared["env"][key], value, "{key} of {}", server["name"]);
        }
        // Each keeps its own command, for a `cmux` that starts it alone.
        assert_eq!(server["args"][0], "acp", "{server}");
        assert!(server["args"][1].as_str().unwrap().ends_with("-mcp"), "{server}");
    }
    assert_eq!(shared["env"]["ACPMUX_SECRET_SESSION"], "s-one", "{shared}");
    assert_eq!(shared["env"]["ACPMUX_OFFER_SESSION"], "s-one", "{shared}");
    assert_eq!(shared["env"]["ACPMUX_SESSION_ID"], "s-one", "{shared}");
    // Computer use is not acpmux's own: it keeps its process.
    assert!(upstreams[0].get("shared").is_none(), "{}", upstreams[0]);
    let _ = std::fs::remove_dir_all(&root);
}

/// Leo, 2026-11-10: a session on a Cloud machine gets GitHub's MCP server through the team's
/// GitHub connection, with no setup there; its config holds no token.
#[test]
fn a_cloud_machine_session_gets_the_github_mcp_server_with_no_token_in_its_config() {
    let root = std::env::temp_dir().join(format!("acpmux-github-mcp-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    // The `cmux` CLI, so the `cmux` server exists to fold the github server under.
    let cmux = root.join("cmux");
    crate::test_exec::write_executable(&cmux, "#!/bin/sh\n");
    let inputs = |github: bool| super::Inputs {
        acpmux: Some(crate::self_command::SelfCommand::new(
            std::path::PathBuf::from("/usr/local/bin/acpmux"),
            vec![],
        )),
        github,
        ..memory_inputs(&root, None)
    };
    let name = crate::github_mcp::SERVER_NAME;
    assert!(resolve(&inputs(false)).servers.iter().all(|s| s.name != name));
    let on = resolve(&inputs(true)).for_session("s1");
    let server = on.servers.iter().find(|s| s.name == name).expect("the github server");
    assert_eq!(server.args, ["github-mcp"]);
    assert!(server.env.iter().all(|(k, v)| !k.contains("TOKEN") && !v.starts_with("ghs_")));
    let folded = resolve(&inputs(true)).for_session("s1").folded();
    let upstreams: serde_json::Value = serde_json::from_str(
        &folded.servers[0].env.iter().find(|(k, _)| k == super::UPSTREAMS_ENV).unwrap().1,
    )
    .unwrap();
    assert!(upstreams.as_array().unwrap().iter().any(|s| s["name"] == name));
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn leased_desktops_are_off_until_the_env_names_a_binary_and_owned_by_the_session() {
    let root = std::env::temp_dir().join(format!("acpmux-desktop-lease-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let name = super::DESKTOP_LEASE_SERVER;
    assert!(resolve(&memory_inputs(&root, None)).servers.iter().all(|s| s.name != name));
    let lease = root.join("desktop-lease");
    let inputs = super::Inputs { desktop_lease: Some(lease.clone()), ..memory_inputs(&root, None) };
    let tools = resolve(&inputs).for_session("s1").for_session("s2");
    let server = tools.servers.iter().find(|s| s.name == name).expect("the leased-desktop server");
    assert_eq!(server.command, lease);
    assert_eq!(server.args, ["mcp"]);
    let owners: Vec<_> = server.env.iter().filter(|(k, _)| k == "DESKTOP_LEASE_OWNER").collect();
    assert_eq!(owners, [&("DESKTOP_LEASE_OWNER".to_owned(), "s2".to_owned())]);
    let _ = std::fs::remove_dir_all(&root);
}

/// Each chat ran its own `acpmux tools-mcp` under its `cmux mcp serve` (Leo's NIGHTLY,
/// 2026-11-17). With the daemon's gateway, each of acpmux's own upstream specs names the
/// gateway's tool endpoint for the chat (`http`) beside its launch, and the `cmux` server the
/// gateway keeps is the one with them.
#[tokio::test]
async fn with_a_gateway_acpmux_s_own_upstreams_name_its_tool_endpoint() {
    let root = std::env::temp_dir().join(format!("acpmux-gw-tools-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let cmux = root.join("cmux");
    crate::test_exec::write_executable(&cmux, "#!/bin/sh\n");
    let exe = std::path::PathBuf::from("/usr/local/lib/cmux/cmux-tui");
    let inputs = super::Inputs {
        acpmux: Some(crate::self_command::SelfCommand::new(exe, vec!["acp".into()])),
        secrets: true,
        offers: true,
        subsessions: true,
        ..memory_inputs(&root, None)
    };
    let home = root.join("home");
    let gateway = crate::mcp_gateway::bind(
        &home,
        crate::mcp_gateway::IDLE_STOP,
        std::time::Duration::from_secs(60),
    )
    .await
    .unwrap();
    let upstreams = |tools: &super::AgentTools| -> Vec<serde_json::Value> {
        let cmux = tools.servers.iter().find(|s| s.name == "cmux").unwrap();
        let specs = &cmux.env.iter().find(|(k, _)| k == super::UPSTREAMS_ENV).unwrap().1;
        serde_json::from_str(specs).unwrap()
    };
    let plain = resolve(&inputs).for_session("s-gw").folded();
    assert!(upstreams(&plain).iter().all(|s| s.get("http").is_none()), "no gateway, no http");
    let tools =
        resolve(&inputs).for_session("s-gw").folded().via_gateway_on(Some(&gateway), "s-gw", &root);
    let endpoint = gateway.tools_endpoint("s-gw");
    assert!(endpoint.url.ends_with("/mcp/s-gw/tools"), "{}", endpoint.url);
    let want = serde_json::json!({"url": endpoint.url, "headers": {"Authorization": endpoint.authorization}});
    let own = ["cmux-secrets", "cmux-sessions", "cmux-subsessions", "cmux-forum", "acpmux"];
    let specs = upstreams(&tools);
    for spec in &specs {
        let name = spec["name"].as_str().unwrap();
        if own.contains(&name) {
            assert_eq!(spec["http"], want, "{name}");
            // An older `cmux` that does not read `http` starts it as before.
            assert!(spec.get("shared").is_some() && spec.get("command").is_some(), "{spec}");
        } else {
            assert!(spec.get("http").is_none(), "{name} is not acpmux's: {spec}");
        }
    }
    assert_eq!(specs.iter().filter(|s| s.get("http").is_some()).count(), own.len());
    // The harness gets the gateway, and the gateway keeps the launch with the same upstreams.
    assert!(tools.http.contains_key("cmux"));
    let kept: serde_json::Value = serde_json::from_slice(
        &std::fs::read(crate::mcp_gateway::launch_path(&home, "s-gw")).unwrap(),
    )
    .unwrap();
    let kept_env: Vec<(String, String)> =
        serde_json::from_value(kept["launch"]["env"].clone()).unwrap();
    let cmux = tools.servers.iter().find(|s| s.name == "cmux").unwrap();
    assert_eq!(kept_env, cmux.env);
    let _ = std::fs::remove_dir_all(&root);
}

/// The most acpmux processes cmux's own tools may run under one agent harness: the Computer Use
/// bridge (`acpmux computer-use-mcp`), which ends the chat's Computer Use session (approvals,
/// cursor) when its pipe closes, so it lives exactly as long as the harness. Every other tool
/// family of acpmux's (`tools_mcp::SERVERS`) is served by the daemon (`mcp_gateway.rs`), folded
/// behind the `cmux` server or not. Measured on Leo's Mac 2026-11-21: 5 per chat (14 chats, 65
/// processes). Leo, 2026-11-21: "if it has tons of processes tbats a prkduct bug", "movjng
/// everything out is not the actual solution".
const ACPMUX_PROCESSES_PER_CHAT: usize = 1;

/// The stdio entries of a Claude Code config that start `exe`: the acpmux processes the harness
/// starts for the chat.
fn acpmux_processes(config: &serde_json::Value, exe: &std::path::Path) -> Vec<String> {
    let exe = exe.to_string_lossy();
    config["mcpServers"]
        .as_object()
        .into_iter()
        .flatten()
        .filter(|(_, entry)| {
            entry.get("type").and_then(serde_json::Value::as_str) != Some("http")
                && entry.get("command").and_then(serde_json::Value::as_str) == Some(exe.as_ref())
        })
        .map(|(name, _)| name.clone())
        .collect()
}

/// One chat starts at most [`ACPMUX_PROCESSES_PER_CHAT`] acpmux processes, with the `cmux`
/// server (folded) and without it (the person turned cmux's tools off: each of acpmux's
/// servers its own entry), and the entries keep their names, so the tool names
/// (`mcp__cmux-forum__...`) and every allowlist naming them stay.
#[tokio::test]
async fn a_chat_starts_at_most_its_budget_of_acpmux_processes() {
    let root = std::env::temp_dir().join(format!("acpmux-proc-budget-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let cmux = root.join("cmux");
    crate::test_exec::write_executable(&cmux, "#!/bin/sh\n");
    let exe = std::path::PathBuf::from("/usr/local/lib/cmux/acpmux");
    let inputs = super::Inputs {
        acpmux: Some(crate::self_command::SelfCommand::new(exe.clone(), Vec::new())),
        secrets: true,
        offers: true,
        subsessions: true,
        ..memory_inputs(&root, Some(r#"{"agents": {"cmuxMcp": "off"}}"#))
    };
    let gateway = crate::mcp_gateway::bind(
        &root.join("home"),
        crate::mcp_gateway::IDLE_STOP,
        std::time::Duration::from_secs(60),
    )
    .await
    .unwrap();
    let own: Vec<&str> = crate::tools_mcp::SERVERS.iter().map(|(name, _)| *name).collect();
    // No `cmux` server: without the gateway each of acpmux's servers is a process of its own
    // (the count the budget cuts), with it none is.
    let standalone = || resolve(&inputs).scoped(&Default::default()).for_session("s-budget");
    let before = standalone().folded().mcp_config().unwrap();
    assert!(before["mcpServers"].get("cmux").is_none(), "{before}");
    let started = acpmux_processes(&before, &exe);
    assert_eq!(started.len(), own.len() + 1, "five tool servers and Computer Use: {started:?}");
    let after = standalone().folded().via_gateway_on(Some(&gateway), "s-budget", &root);
    let config = after.mcp_config().unwrap();
    let started = acpmux_processes(&config, &exe);
    assert!(started.len() <= ACPMUX_PROCESSES_PER_CHAT, "{started:?} in {config}");
    for name in &own {
        let entry = &config["mcpServers"][*name];
        let endpoint = gateway.server_endpoint("s-budget", name);
        assert_eq!(entry["type"], "http", "{name}: {entry}");
        assert_eq!(entry["url"], endpoint.url.as_str(), "{name}");
        assert!(endpoint.url.ends_with(&format!("/mcp/s-budget/tools/{name}")), "{}", endpoint.url);
    }
    // The gateway keeps the one launch they would share, with each one's spec.
    let kept: serde_json::Value = serde_json::from_slice(
        &std::fs::read(crate::mcp_gateway::launch_path(&root.join("home"), "s-budget")).unwrap(),
    )
    .unwrap();
    assert_eq!(kept["launch"]["args"], serde_json::json!([crate::tools_mcp::ARG]));
    // An ACP harness that takes HTTP servers gets the same.
    let acp = after.acp_servers();
    let stdio_acpmux = acp
        .as_array()
        .unwrap()
        .iter()
        .filter(|s| s.get("type").is_none() && s["command"] == exe.to_string_lossy().as_ref())
        .count();
    assert!(stdio_acpmux <= ACPMUX_PROCESSES_PER_CHAT, "{acp}");
    // With the `cmux` server (folded): acpmux's servers are its upstreams, served by the daemon.
    let folded = resolve(&inputs).for_session("s-budget-cmux").folded().via_gateway_on(
        Some(&gateway),
        "s-budget-cmux",
        &root,
    );
    let config = folded.mcp_config().unwrap();
    let started = acpmux_processes(&config, &exe);
    assert!(started.len() <= ACPMUX_PROCESSES_PER_CHAT, "{started:?} in {config}");
    let _ = std::fs::remove_dir_all(&root);
}

/// Every agent cmux starts gets the one `cmux` server ([`super::cmux_server`]): this CLI's `mcp
/// serve` with the app's settings file, unless the person turned it off (`agents.cmuxMcp` `off`):
/// then the session's other servers, standalone. No file, no key, `ask`, another value or a file
/// that does not parse: on. A Chief turn (a preset naming its cmux tools) keeps it either way.
#[test]
fn the_cmux_server_goes_unless_the_person_turned_it_off() {
    let root = tempfile::tempdir().unwrap();
    let cmux = root.path().join("cmux");
    crate::test_exec::write_executable(&cmux, "#!/bin/sh\nexit 0\n");
    let exe = std::path::PathBuf::from("/usr/local/bin/acpmux");
    let inputs = |json: Option<&str>| super::Inputs {
        acpmux: Some(crate::self_command::SelfCommand::new(exe.clone(), Vec::new())),
        ..memory_inputs(root.path(), json)
    };
    let names = |json: Option<&str>, env: &std::collections::BTreeMap<String, String>| {
        super::resolve(&inputs(json))
            .scoped(env)
            .servers
            .into_iter()
            .map(|s| s.name)
            .collect::<Vec<_>>()
    };
    let none = std::collections::BTreeMap::new();
    for json in [Some(r#"{"agents": {"cmuxMcp": "off"}}"#), Some(r#"{"agents.cmuxMcp": "off"}"#)] {
        let names = names(json, &none);
        assert!(!names.contains(&"cmux".to_owned()), "{json:?}: {names:?}");
        assert!(names.contains(&crate::acpmux_mcp::SERVER_NAME.to_owned()), "{json:?}: {names:?}");
        let chief = std::collections::BTreeMap::from([(
            super::MCP_TOOLS_ENV.to_owned(),
            super::CHIEF_TURN_TOOLS.to_owned(),
        )]);
        assert!(
            super::resolve(&inputs(json)).scoped(&chief).servers.iter().any(|s| s.name == "cmux")
        );
    }
    for json in [
        None,
        Some("{}"),
        Some(r#"{"agents": {"cmuxMcp": "on"}}"#),
        Some(r#"{"agents": {"cmuxMcp": "ask"}}"#),
        Some(r#"{"agents.cmuxMcp": "yes"}"#),
        Some("{\n// mine\n\"agents.cmuxMcp\": \"on\",\n}"),
        Some("{"),
    ] {
        let tools = super::resolve(&inputs(json)).scoped(&none);
        let server =
            tools.servers.iter().find(|s| s.name == "cmux").unwrap_or_else(|| panic!("{json:?}"));
        assert_eq!(server.command, cmux);
        assert_eq!(server.args, ["mcp", "serve"]);
        // Folded: one server, `cmux`, the others behind it.
        let folded = tools.for_session("s-1").folded();
        assert_eq!(folded.servers.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(), ["cmux"]);
    }
    // MCP off in the settings file: no `cmux` server even with the setting on.
    for off in [
        r#"{"agents": {"cmuxMcp": "on"}, "mcp": {"enabled": false}}"#,
        r#"{"mcp": {"enabled": false}}"#,
    ] {
        assert!(!names(Some(off), &none).contains(&"cmux".to_owned()), "{off}");
    }
}

#[test]
fn the_cmux_server_definition_names_the_settings_file() {
    let settings = std::path::Path::new("/h/cmux-next-x.json");
    let server = super::cmux_server(std::path::Path::new("/A/cmux"), false, settings);
    assert_eq!(server.name, "cmux");
    assert_eq!(server.command, std::path::PathBuf::from("/A/cmux"));
    assert_eq!(server.args, ["mcp", "serve"]);
    // Always the resolved settings file, and the acpmux guest mode always off: Codex merges these
    // keys into a person's own `cmux` entry, one `cmux acp desktop link` wrote among them.
    assert_eq!(
        server.env,
        [
            ("CMUX_NEXT_CONFIG_FILE".to_owned(), "/h/cmux-next-x.json".to_owned()),
            (crate::desktop_link::GUEST_ENV.to_owned(), String::new()),
        ]
    );
    let all = super::cmux_server(std::path::Path::new("/A/cmux"), true, settings);
    assert_eq!(all.args, ["mcp", "serve", "--all-tools"]);
}

/// A Codex chat whose person's own server named `cmux` is HTTP, as Codex itself answers for the
/// launch, gets no `cmux` server (Codex would refuse the merged entry), the rule the `codex`
/// terminal shim follows; its other servers stay. A stdio entry, none, or no answer keeps it.
#[test]
fn a_codex_chat_beside_an_http_cmux_entry_gets_no_cmux_server() {
    let root = tempfile::tempdir().unwrap();
    let work = root.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let codex = fake_codex(root.path());
    let server = |name: &str| super::McpServer {
        name: name.to_owned(),
        command: "/x".into(),
        args: vec![],
        env: vec![],
    };
    let tools = super::AgentTools {
        servers: vec![server("cmux"), server(crate::acpmux_mcp::SERVER_NAME)],
        cmux_for_agents: true,
        ..Default::default()
    };
    let env = std::collections::BTreeMap::new();
    let names = |t: super::AgentTools| t.servers.into_iter().map(|s| s.name).collect::<Vec<_>>();
    let argv =
        vec![codex.to_string_lossy().into_owned(), "-p".into(), "w".into(), "app-server".into()];
    let at = super::CodexLaunch { cwd: &work, argv: &argv, answer: None };
    for (answer, want) in [
        (Some("/opt/x"), &["cmux", "acpmux"][..]),
        (Some("http"), &["acpmux"]),
        (None, &["cmux", "acpmux"]),
    ] {
        codex_answers(root.path(), answer);
        assert_eq!(
            names(tools.clone().without_cmux_beside_an_http_entry(at, &env)),
            want,
            "{answer:?}"
        );
    }
    // The person's own options went to `mcp get`.
    let calls = std::fs::read_to_string(root.path().join("calls")).unwrap();
    assert!(calls.lines().all(|l| l == "-p w mcp get cmux --json"), "{calls}");
    // Skip on doubt: no answer from Codex (output it cannot read, or a program that is not
    // there), and a project file Codex's answer does not show it loads, drop `cmux` too.
    std::fs::write(root.path().join("answer"), "not json").unwrap();
    assert_eq!(names(tools.clone().without_cmux_beside_an_http_entry(at, &env)), ["acpmux"]);
    let gone = vec!["/nowhere/codex".to_owned(), "app-server".to_owned()];
    let missing = super::CodexLaunch { cwd: &work, argv: &gone, answer: None };
    assert_eq!(names(tools.clone().without_cmux_beside_an_http_entry(missing, &env)), ["acpmux"]);
    std::fs::create_dir_all(work.join(".git")).unwrap();
    std::fs::create_dir_all(work.join(".codex")).unwrap();
    std::fs::write(
        work.join(".codex/config.toml"),
        "[mcp_servers.cmux]\nurl = \"http://127.0.0.1:1/mcp\"\n",
    )
    .unwrap();
    for answer in [None, Some("/opt/x")] {
        codex_answers(root.path(), answer);
        assert_eq!(
            names(tools.clone().without_cmux_beside_an_http_entry(at, &env)),
            ["acpmux"],
            "an untrusted project entry, {answer:?}"
        );
    }
    // The same stdio entry Codex answers is one it loads: no doubt.
    std::fs::write(
        work.join(".codex/config.toml"),
        "[mcp_servers.cmux]\ncommand = \"/opt/x\"\nargs = [\"mcp\", \"serve\"]\n",
    )
    .unwrap();
    assert_eq!(
        names(tools.clone().without_cmux_beside_an_http_entry(at, &env)),
        ["cmux", "acpmux"]
    );
    std::fs::remove_dir_all(work.join(".codex")).unwrap();
    // An ACP adapter (not a Codex app-server launch) loads the person's config through the
    // `codex` on its PATH, asked with no options.
    std::fs::remove_file(root.path().join("calls")).unwrap();
    let adapter = vec!["/opt/codex-acp-adapter".to_owned(), "--x".to_owned()];
    let other = super::CodexLaunch { cwd: &work, argv: &adapter, answer: None };
    let on_path: std::collections::BTreeMap<String, String> =
        [("PATH".to_owned(), format!("{}:/usr/bin:/bin", codex.parent().unwrap().display()))]
            .into();
    codex_answers(root.path(), Some("http"));
    assert_eq!(names(tools.clone().without_cmux_beside_an_http_entry(other, &on_path)), ["acpmux"]);
    codex_answers(root.path(), Some("/opt/x"));
    assert_eq!(names(tools.without_cmux_beside_an_http_entry(other, &on_path)), ["cmux", "acpmux"]);
    let calls = std::fs::read_to_string(root.path().join("calls")).unwrap();
    assert!(calls.lines().all(|l| l == "mcp get cmux --json"), "{calls}");
}

/// The servers a Codex chat's session start and fork send (`acp_servers_with`, which
/// `hub/spawn.rs` `acp_params` and `hub/fork.rs` use): no `cmux` beside the person's own HTTP
/// `cmux` entry (as Codex answers), the others standalone; another harness, or no such entry,
/// keeps `cmux` with the others folded behind it.
#[test]
fn a_codex_session_start_or_fork_beside_an_http_cmux_entry_sends_no_cmux() {
    let root = tempfile::tempdir().unwrap();
    let work = root.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let codex = fake_codex(root.path());
    let server = |name: &str| super::McpServer {
        name: name.to_owned(),
        command: "/x".into(),
        args: vec![],
        env: vec![],
    };
    let tools = super::AgentTools {
        servers: vec![server("cmux"), server(crate::acpmux_mcp::SERVER_NAME)],
        cmux_for_agents: true,
        ..Default::default()
    };
    let env = std::collections::BTreeMap::new();
    let argv = vec![codex.to_string_lossy().into_owned(), "app-server".to_owned()];
    let names = |cwd: Option<&std::path::Path>| {
        let codex = cwd.map(|cwd| super::CodexLaunch { cwd, argv: &argv, answer: None });
        super::acp_servers_with(tools.clone(), &env, "s-1", false, codex)
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s["name"].as_str().unwrap().to_owned())
            .collect::<Vec<_>>()
    };
    assert_eq!(names(Some(&work)), ["cmux"]);
    codex_answers(root.path(), Some("http"));
    assert_eq!(names(Some(&work)), ["acpmux"]);
    assert_eq!(names(None), ["cmux"], "not Codex: the person's Codex config does not matter");
}

/// A chat started from another Mac follows that Mac's answer (`hub/cmux_tools_answer.rs`), as
/// its session env carries it, over this machine's settings file either way.
#[test]
fn a_chat_started_from_another_mac_gets_cmux_by_that_macs_answer() {
    let root = tempfile::tempdir().unwrap();
    let cmux = root.path().join("cmux");
    crate::test_exec::write_executable(&cmux, "#!/bin/sh\nexit 0\n");
    let has_cmux = |json: &str, answer: Option<&str>| {
        let env: std::collections::BTreeMap<String, String> = answer
            .map(|a| (super::TOOLS_ANSWER_ENV.to_owned(), a.to_owned()))
            .into_iter()
            .collect();
        super::resolve(&memory_inputs(root.path(), Some(json)))
            .scoped(&env)
            .servers
            .iter()
            .any(|s| s.name == super::CMUX_SERVER)
    };
    let (on, off) = (r#"{"agents": {"cmuxMcp": "on"}}"#, r#"{"agents": {"cmuxMcp": "off"}}"#);
    assert!(has_cmux(off, Some("on")));
    assert!(!has_cmux(on, Some("off")));
    assert!(!has_cmux(on, Some("ask")), "a forwarded answer other than on is no");
    // Started here: this machine's answer.
    assert!(has_cmux(on, None));
    assert!(!has_cmux(off, None));
}

/// A Codex chat whose servers hold no `cmux` of cmux's own sends the person's own stdio `cmux`
/// entry back whole, exactly as Codex itself answers it, with the chat's session and answer
/// (`person_entry_env`): never for an HTTP entry, none or no answer, and not when cmux gives its
/// own `cmux`.
#[test]
fn a_persons_own_stdio_cmux_entry_learns_which_chat_starts_it() {
    let root = tempfile::tempdir().unwrap();
    let work = root.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let codex = fake_codex(root.path());
    let argv = vec![codex.to_string_lossy().into_owned(), "app-server".to_owned()];
    let launch = super::CodexLaunch { cwd: &work, argv: &argv, answer: None };
    let mut env =
        std::collections::BTreeMap::from([(super::TOOLS_ANSWER_ENV.to_owned(), "off".to_owned())]);
    let without = serde_json::json!([{"name": "acpmux"}]);
    let with_cmux = serde_json::json!([{"name": "cmux"}]);
    assert_eq!(super::person_entry_env(&without, launch, &env, "s-1"), None, "no entry");
    codex_answers(root.path(), Some("http"));
    assert_eq!(super::person_entry_env(&without, launch, &env, "s-1"), None, "an HTTP entry");
    codex_answers(root.path(), Some("/opt/cmux"));
    assert_eq!(
        super::person_entry_env(&without, launch, &env, "s-1"),
        Some(serde_json::json!({"cmux": {"command": "/opt/cmux", "args": ["mcp", "serve"],
            "env": {"CMUX_AGENT_SESSION": "s-1", "CMUX_AGENT_TOOLS_ANSWER": "off"}}}))
    );
    env.insert(super::TOOLS_ANSWER_ENV.to_owned(), "on".to_owned());
    let answer_of = |env: &std::collections::BTreeMap<String, String>| {
        super::person_entry_env(&without, launch, env, "s-3").unwrap()["cmux"]["env"]
            ["CMUX_AGENT_TOOLS_ANSWER"]
            .clone()
    };
    assert_eq!(answer_of(&env), "on");
    assert_eq!(
        super::person_entry_env(&with_cmux, launch, &env, "s-1"),
        None,
        "cmux gives its own"
    );
    // A session cut off from cmux's tools: off, whatever the answer.
    for (key, value) in [(super::SWITCH_ENV, "0"), (super::SERVERS_ENV, "acpmux,cmux-forum")] {
        let mut cut = env.clone();
        cut.insert(key.to_owned(), value.to_owned());
        assert_eq!(answer_of(&cut), "off", "{key}={value}");
    }
    // A Codex that does not answer in time (or fails): nothing is sent.
    std::fs::write(root.path().join("answer"), "not json").unwrap();
    assert_eq!(super::person_entry_env(&without, launch, &env, "s-1"), None, "no answer");
    // On the ACP params: `_meta.cmux.mcpServerEntry`, beside what is there.
    let mut params = serde_json::json!({"cwd": "/w", "_meta": {"cmux": {"generateTitle": false}}});
    super::send_person_entry_env(&mut params, Some(serde_json::json!({"cmux": {"K": "v"}})));
    assert_eq!(params["_meta"]["cmux"]["mcpServerEntry"]["cmux"]["K"], "v");
    assert_eq!(params["_meta"]["cmux"]["generateTitle"], false);
    let mut bare = serde_json::json!({"cwd": "/w"});
    super::send_person_entry_env(&mut bare, None);
    assert!(bare.get("_meta").is_none());
}

/// A remote-origin chat with no answer of its own (a phone or Web client started it) gets `off`;
/// one another Mac's daemon started keeps that Mac's answer; a local chat is untouched.
#[test]
fn a_remote_origin_chat_without_its_own_answer_gets_off() {
    let mut phone = std::collections::BTreeMap::new();
    super::remote_origin_answer(&mut phone, true);
    assert_eq!(phone.get(super::TOOLS_ANSWER_ENV).map(String::as_str), Some("off"));
    let mut peer =
        std::collections::BTreeMap::from([(super::TOOLS_ANSWER_ENV.to_owned(), "on".to_owned())]);
    super::remote_origin_answer(&mut peer, true);
    assert_eq!(peer.get(super::TOOLS_ANSWER_ENV).map(String::as_str), Some("on"));
    let mut local = std::collections::BTreeMap::new();
    super::remote_origin_answer(&mut local, false);
    assert!(local.is_empty());
}

/// A fake `codex` named so its launch is a Codex app-server launch: it answers `mcp get cmux
/// --json` with the contents of `<dir>/answer` (as Codex prints them), or Codex's "No MCP server
/// named 'cmux' found." with exit 1 when there is none, and logs each call's arguments.
pub(crate) fn fake_codex(dir: &std::path::Path) -> std::path::PathBuf {
    let bin = dir.join("fake-bin");
    std::fs::create_dir_all(&bin).unwrap();
    let path = bin.join("codex");
    let (answer, log) = (dir.join("answer"), dir.join("calls"));
    crate::test_exec::write_executable(
        &path,
        format!(
            "#!/bin/sh\necho \"$*\" >> {log:?}\nif [ -f {answer:?} ]; then cat {answer:?}; else echo \"Error: No MCP server named 'cmux' found.\" >&2; exit 1; fi\n"
        ),
    );
    path
}

/// What the fake Codex answers next: a stdio entry, an HTTP one, or none (`None`).
pub(crate) fn codex_answers(dir: &std::path::Path, answer: Option<&str>) {
    match answer {
        Some("http") => std::fs::write(
            dir.join("answer"),
            r#"{"transport":{"type":"streamable_http","url":"http://127.0.0.1:1/mcp"}}"#,
        )
        .unwrap(),
        Some(command) => std::fs::write(
            dir.join("answer"),
            serde_json::json!({"transport": {"type": "stdio", "command": command, "args": ["mcp", "serve"]}})
                .to_string(),
        )
        .unwrap(),
        None => {
            let _ = std::fs::remove_file(dir.join("answer"));
        }
    }
}

/// Codex is asked once per launch that keeps its answer (one chat start, fork, pool spec), and
/// asked again by the next launch, so a config the person changes between two chat starts counts.
#[test]
fn codex_is_asked_once_per_launch_and_again_by_the_next() {
    let root = tempfile::tempdir().unwrap();
    let work = root.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let codex = fake_codex(root.path());
    let argv = vec![codex.to_string_lossy().into_owned(), "app-server".to_owned()];
    let env = std::collections::BTreeMap::new();
    let calls =
        || std::fs::read_to_string(root.path().join("calls")).unwrap_or_default().lines().count();
    codex_answers(root.path(), Some("/opt/x"));
    let first = super::CodexAnswer::default();
    let launch = super::CodexLaunch { cwd: &work, argv: &argv, answer: Some(&first) };
    for _ in 0..3 {
        assert!(matches!(
            super::persons_cmux_entry(launch, &env),
            crate::codex_cmux_entry::CmuxEntry::Stdio { .. }
        ));
    }
    assert_eq!(calls(), 1, "one launch, one question");
    codex_answers(root.path(), Some("http"));
    let next = super::CodexAnswer::default();
    let launch = super::CodexLaunch { cwd: &work, argv: &argv, answer: Some(&next) };
    assert!(super::persons_cmux_entry(launch, &env).is_http(), "the next launch asks again");
    assert_eq!(calls(), 2);
}

/// One start asks Codex once, off the runtime (`warm_codex_answer`), and everything the start
/// reads shares that answer: its tool rows, its `mcpServers`, the person's entry env keys.
#[tokio::test(flavor = "multi_thread")]
async fn one_start_asks_codex_once_off_the_runtime_for_everything_it_reads() {
    let root = tempfile::tempdir().unwrap();
    let work = root.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let codex = fake_codex(root.path());
    let argv = vec![codex.to_string_lossy().into_owned(), "app-server".to_owned()];
    let env = std::collections::BTreeMap::new();
    codex_answers(root.path(), Some("/opt/x"));
    let answer = super::CodexAnswer::default();
    super::warm_codex_answer(&work, &argv, &env, &answer).await;
    assert!(matches!(answer.get(), Some(crate::codex_cmux_entry::CmuxEntry::Stdio { .. })));
    super::warm_codex_answer(&work, &argv, &env, &answer).await;
    let launch = super::CodexLaunch { cwd: &work, argv: &argv, answer: Some(&answer) };
    let tools = super::AgentTools::default();
    let _ = tools.clone().without_cmux_beside_an_http_entry(launch, &env);
    let servers = super::acp_servers_with(tools, &env, "s-1", false, Some(launch));
    assert!(super::person_entry_env(&servers, launch, &env, "s-1").is_some());
    let calls = std::fs::read_to_string(root.path().join("calls")).unwrap();
    assert_eq!(calls.lines().count(), 1, "{calls}");
}

/// A start's answer is reused only for the launch it was asked for: another folder, argv or env
/// (a pool spec for another shape) asks again. Nothing is cached across starts.
#[test]
fn an_asked_answer_is_reused_only_for_its_own_launch() {
    let env: std::collections::BTreeMap<String, String> = [("A".to_owned(), "1".to_owned())].into();
    let argv = vec!["codex".to_owned(), "app-server".to_owned()];
    let asked = super::AskedFor {
        cwd: "/w".into(),
        argv: argv.clone(),
        env: env.clone(),
        answer: super::CodexAnswer::default(),
    };
    let same = asked.for_launch(std::path::Path::new("/w"), &argv, &env).unwrap();
    assert!(std::sync::Arc::ptr_eq(&same, &asked.answer));
    assert!(asked.for_launch(std::path::Path::new("/x"), &argv, &env).is_none());
    assert!(asked.for_launch(std::path::Path::new("/w"), &argv[..1], &env).is_none());
    assert!(asked.for_launch(std::path::Path::new("/w"), &argv, &Default::default()).is_none());
}

/// The person's saved MCP servers reach every chat as one upstream of `cmux`
/// (`optchat-chief integrations serve`, tool `mcp_servers`), with the chat's session id so the
/// server shows only the servers the person's scope gives it; cmux.json turns it off.
/// Settings > MCP Servers' switch (schemas/settings/source/mcp-servers.json) is the key the
/// daemon reads, on unless the person turns it off.
#[test]
fn the_saved_servers_switch_is_the_settings_row() {
    const SOURCE: &str = include_str!("../../../../schemas/settings/source/mcp-servers.json");
    let doc: serde_json::Value = serde_json::from_str(SOURCE).unwrap();
    let row = &doc["lists"][0]["rows"][0];
    assert_eq!(row["key"], serde_json::json!(super::SAVED_SERVERS_SETTING));
    assert_eq!(row["kind"], serde_json::json!("toggle"));
    assert_eq!(row["default"], serde_json::json!(true));
}

#[test]
fn a_chat_gets_the_saved_mcp_servers_with_its_session() {
    let root = std::env::temp_dir().join(format!("acpmux-saved-mcp-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let chief = root.join("optchat-chief");
    crate::test_exec::write_executable(&chief, "#!/bin/sh\n");
    let name = super::SAVED_SERVERS_NAME;
    let on = resolve(&memory_inputs(&root, None)).for_session("s1");
    let server = on.servers.iter().find(|s| s.name == name).expect("the saved servers");
    assert_eq!(server.command, chief);
    assert_eq!(server.args, ["integrations", "serve"]);
    assert_eq!(server.env, [(super::AGENT_SESSION_ENV.to_owned(), "s1".to_owned())]);
    let off =
        resolve(&memory_inputs(&root, Some(r#"{"agents":{"mcpServers":{"enabled":false}}}"#)));
    assert!(off.servers.iter().all(|s| s.name != name), "{:?}", off.servers);
    let _ = std::fs::remove_dir_all(&root);
}

/// The per-agent switch (cmux#49395): a Claude Code or Codex chat the person switched off gets the
/// answer `off` (so `scoped` leaves `cmux` out under a yes); the other agent, another harness and
/// an answer the chat already carries (another Mac's) are left alone.
#[test]
fn an_agent_switched_off_gets_the_answer_off() {
    use std::collections::BTreeMap;
    let settings = Some(r#"{"agents": {"cmuxMcp": "on", "cmuxMcpCodex": false}}"#);
    assert!(super::agent_switched_off(settings, "codex"));
    assert!(!super::agent_switched_off(settings, "claude"));
    assert!(!super::agent_switched_off(settings, "gemini"));
    assert!(!super::agent_switched_off(Some(r#"{"agents.cmuxMcpClaude": "no"}"#), "claude"));
    assert!(super::agent_switched_off(Some(r#"{"agents.cmuxMcpClaude": false}"#), "claude"));
    assert!(!super::agent_switched_off(None, "claude"));
    let answer = |agent: Option<&str>, mut env: BTreeMap<String, String>| {
        super::agent_switch_answer(&mut env, settings, agent);
        env.get(super::TOOLS_ANSWER_ENV).cloned()
    };
    assert_eq!(answer(Some("codex"), BTreeMap::new()).as_deref(), Some("off"));
    assert_eq!(answer(Some("claude"), BTreeMap::new()), None);
    assert_eq!(answer(None, BTreeMap::new()), None);
    let from_another_mac = BTreeMap::from([(super::TOOLS_ANSWER_ENV.to_owned(), "on".to_owned())]);
    assert_eq!(answer(Some("codex"), from_another_mac).as_deref(), Some("on"));
    // The answer `off` leaves cmux's server out of the chat's tools, as a no does.
    let tools = super::AgentTools {
        servers: vec![super::McpServer {
            name: super::CMUX_SERVER.into(),
            command: "/bin/cmux".into(),
            args: vec![],
            env: vec![],
        }],
        cmux_for_agents: true,
        ..Default::default()
    };
    let off = BTreeMap::from([(super::TOOLS_ANSWER_ENV.to_owned(), "off".to_owned())]);
    assert!(tools.scoped(&off).servers.is_empty());
}

/// acpmux's own servers' instructions go in Claude Code's appended system prompt, the prefix
/// every chat shares in the prompt cache, and the servers leave them out of `initialize`, so a
/// chat reads them once. The text never names the session: two chats in two folders get the same
/// bytes, or the shared system prompt cache would break for every new chat.
#[test]
fn own_server_instructions_move_to_a_system_prompt_every_chat_shares() {
    let root = std::env::temp_dir().join(format!("acpmux-mcp-prompt-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let inputs = super::Inputs {
        acpmux: Some(crate::self_command::SelfCommand::new(
            std::path::PathBuf::from("/usr/local/lib/cmux/cmux-tui"),
            vec!["acp".into()],
        )),
        secrets: true,
        offers: true,
        subsessions: true,
        ..memory_inputs(&root, None)
    };
    let chat = |session: &str, cwd: &std::path::Path| {
        let mut tools = resolve(&inputs).for_session(session).folded();
        let prompt = tools.instructions_in_prompt();
        (tools.via_gateway_on(None, session, cwd), prompt)
    };
    let (tools, one) = chat("01a2-chat-one", &root.join("repo-a"));
    let (_, two) = chat("01a2-chat-two", &root.join("repo-b"));
    let one = one.expect("no instructions moved");
    assert_eq!(Some(&one), two.as_ref(), "two chats' appended prompts differ");
    assert!(!one.contains("01a2-chat") && !one.contains("repo-"), "{one}");
    assert!(one.starts_with(super::INSTRUCTIONS_HEADING), "{one}");
    let at = |name: &str| one.find(&format!("## {name}\n")).unwrap_or_else(|| panic!("{one}"));
    assert!(at("acpmux") < at("cmux-sessions") && at("cmux-sessions") < at("cmux-subsessions"));
    assert!(one.contains(crate::offer_mcp::INSTRUCTIONS), "{one}");
    assert!(one.contains(&crate::subsession_mcp::instructions()), "{one}");
    assert!(one.contains("with bg_start"), "{one}");
    // The servers with instructions are told they are in the prompt; the rest keep their env.
    let flag = |name: &str| {
        let server = tools.servers.iter().find(|s| s.name == name).unwrap();
        server
            .env
            .iter()
            .any(|(k, v)| k == crate::tools_mcp::INSTRUCTIONS_IN_PROMPT_ENV && v == "1")
    };
    assert!(flag("acpmux") && flag("cmux-sessions") && flag("cmux-subsessions"));
    assert!(!flag(crate::forum_mcp::SERVER_NAME) && !flag(crate::secret_mcp::SERVER_NAME));
    let _ = std::fs::remove_dir_all(&root);
}

/// Behind the `cmux` server (code mode) acpmux's servers are its upstreams, whose instructions
/// it relays itself: none move, and nothing is told to leave them out.
#[test]
fn folded_servers_keep_their_instructions() {
    let server = |name: &str, word: &str| super::McpServer {
        name: name.to_owned(),
        command: "x".into(),
        args: vec![word.to_owned()],
        env: vec![],
    };
    let mut tools = super::AgentTools {
        servers: vec![server("cmux", "mcp"), server(crate::offer_mcp::SERVER_NAME, "offer-mcp")],
        cmux_for_agents: true,
        ..Default::default()
    }
    .folded();
    let before = tools.clone();
    assert_eq!(tools.instructions_in_prompt(), None);
    assert_eq!(tools, before);
}

/// The moved text joins the one appended system prompt Claude Code reads (it takes only the
/// last `--append-system-prompt`), after what is there; a file or `=` form is left alone.
#[test]
fn the_moved_instructions_join_the_last_appended_prompt() {
    let words = |w: &[&str]| w.iter().map(|w| (*w).to_owned()).collect::<Vec<_>>();
    let mut args = words(&["--append-system-prompt", "rules", "--model", "m"]);
    super::append_system_prompt(&mut args, "MCP");
    assert_eq!(args, words(&["--append-system-prompt", "rules\n\nMCP", "--model", "m"]));
    let mut args = words(&["--model", "m"]);
    super::append_system_prompt(&mut args, "MCP");
    assert_eq!(args, words(&["--model", "m", "--append-system-prompt", "MCP"]));
    assert!(super::takes_appended_prompt(&words(&["--append-system-prompt", "x"])));
    assert!(!super::takes_appended_prompt(&words(&["--append-system-prompt-file", "f"])));
    assert!(!super::takes_appended_prompt(&words(&["--append-system-prompt=x"])));
}
