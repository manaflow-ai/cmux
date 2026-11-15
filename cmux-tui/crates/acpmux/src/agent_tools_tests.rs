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

/// Every session gets the Computer Use bridge, whether or not a worker runs:
/// nothing on disk decides it, only `computerUse.mode: "off"` in cmux.json
/// (and no acpmux binary to run it, in a test without one).
#[test]
fn every_session_gets_computer_use_unless_the_mode_is_off() {
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
    ] {
        assert!(has(json), "{json:?}");
    }
    assert!(!has(Some(r#"{"computerUse":{"mode":"off"}}"#)));
    assert!(!has(Some("{\n// mine\n\"computerUse.mode\": \"off\",\n}")));
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
        let tools = super::resolve(&inputs(prefix));
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
    // Per-workspace displays (a Linux cloud machine) drop the Computer Use
    // bridge, which drives the machine's one desktop, under the prefix too.
    let mut tools = super::resolve(&inputs(&["acp"]));
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
        servers: vec![
            server(crate::acpmux_mcp::SERVER_NAME),
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
    // Whatever the patterns, a started binary never blocks: here every call starts it.
    let every = ["*".to_owned()];
    let old =
        words(script("cmux", r#"echo 'cmux: unknown resource scope "__bg-hook".' >&2; exit 2"#));
    let bare: Vec<String> = old.iter().map(|w| format!("'{w}'")).collect();
    assert_eq!(run(&bare.join(" ")).status.code(), Some(2), "the skew this guards against");
    let out = run(&super::hook_command(&old, &every));
    assert!(out.status.success(), "a refusing hook binary blocked the call: {out:?}");
    // A binary that is gone does not block either.
    let gone = words(root.join("gone").to_string_lossy().into_owned());
    assert!(run(&super::hook_command(&gone, &every)).status.success());
    // The hook's own answer still gets through.
    let deny = words(script("acpmux", r#"echo '{"deny":true}'"#));
    let out = run(&super::hook_command(&deny, &every));
    assert!(out.status.success());
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), r#"{"deny":true}"#);
    let _ = std::fs::remove_dir_all(&root);
}

/// The hook of a subagent's calls (`PostToolUse`, `SubagentStop`, the acpmux MCP calls) starts
/// the binary only when Claude Code's input names an `agent_id`, which it does only for a
/// subagent's call: the lead's calls never start it, and a subagent's input reaches it whole. A
/// binary that refuses blocks no call.
#[test]
fn the_subagent_hook_starts_the_binary_only_for_a_subagents_call() {
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;
    let root = std::env::temp_dir().join(format!("acpmux-hook-sub-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let seen = root.join("seen");
    let script = |name: &str, body: &str| {
        let path = root.join(name);
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        let words = [path.to_string_lossy().into_owned(), crate::bg_hook::HOOK_ARG.to_owned()];
        super::hook_command(&words, &[crate::bg_hook::SUBAGENT_PATTERN.to_owned()])
    };
    let run = |command: &str, input: &str| {
        let mut child = std::process::Command::new("sh")
            .arg("-c")
            .arg(command)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
        child.wait_with_output().unwrap()
    };
    let hook = script("acpmux", &format!("cat > '{}'\necho answer", seen.display()));
    // The lead's call: its input names `agent_id` only inside a command's own text.
    let lead = r#"{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo agent_id"}}"#;
    let out = run(&hook, lead);
    assert!(out.status.success() && out.stdout.is_empty(), "{out:?}");
    assert!(!seen.exists(), "the lead's call started the binary");
    let subagent = r#"{"hook_event_name":"PostToolUse","tool_name":"Bash","agent_id":"a0","agent_type":"Explore"}"#;
    let out = run(&hook, subagent);
    assert!(out.status.success(), "{out:?}");
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "answer");
    assert_eq!(std::fs::read_to_string(&seen).unwrap(), subagent);
    let refusing = script("refusing", "cat >/dev/null; exit 2");
    assert!(run(&refusing, subagent).status.success(), "a refusing binary blocked the call");
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
    assert!(fit.join("hooks/hooks.json").is_file());
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
    use std::os::unix::fs::PermissionsExt;
    let root = std::env::temp_dir().join(format!("acpmux-hosted-mcp-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let cmux = root.join("cmux");
    std::fs::write(&cmux, "#!/bin/sh\n").unwrap();
    std::fs::set_permissions(&cmux, std::fs::Permissions::from_mode(0o755)).unwrap();
    let inputs = |hosted: bool| super::Inputs {
        acpmux: Some(crate::self_command::SelfCommand::new(
            std::path::PathBuf::from("/usr/local/bin/acpmux"),
            vec![],
        )),
        hosted,
        ..memory_inputs(&root, None)
    };
    let name = crate::hosted_mcp::SERVER_NAME;
    let off = super::resolve(&inputs(false));
    assert!(off.servers.iter().all(|s| s.name != name), "{:?}", off.servers);
    let on = super::resolve(&inputs(true)).for_session("s1");
    let server = on.servers.iter().find(|s| s.name == name).expect("the hosted server");
    assert_eq!(server.args, ["hosted-mcp"]);
    assert_eq!(
        server.env,
        [(crate::hosted_mcp::CMUX_BIN_ENV.to_owned(), cmux.to_string_lossy().into_owned())]
    );
    let folded = super::resolve(&inputs(true)).for_session("s1").folded();
    let upstreams: serde_json::Value = serde_json::from_str(
        &folded.servers[0].env.iter().find(|(k, _)| k == super::UPSTREAMS_ENV).unwrap().1,
    )
    .unwrap();
    let spec = upstreams.as_array().unwrap().iter().find(|s| s["name"] == name).unwrap();
    assert_eq!(spec["args"], serde_json::json!(["hosted-mcp"]));
    assert_eq!(spec["env"], serde_json::json!({"CMUX_BIN": cmux.to_string_lossy()}));
    // No `cmux` CLI to ask the app for a token: no server.
    std::fs::remove_file(&cmux).unwrap();
    assert!(super::resolve(&inputs(true)).servers.iter().all(|s| s.name != name));
    let _ = std::fs::remove_dir_all(&root);
}

/// Every agent cmux starts gets the one `cmux` server ([`super::cmux_server`]): this CLI's `mcp
/// serve` with the app's settings file, and only with the person's yes (`agents.cmuxMcp` on).
/// Unanswered, `off` or a file that does not parse: the session's other servers, standalone. A
/// Chief turn (a preset naming its cmux tools) keeps it either way.
#[test]
fn the_cmux_server_goes_only_with_the_persons_yes() {
    use std::os::unix::fs::PermissionsExt;
    let root = tempfile::tempdir().unwrap();
    let cmux = root.path().join("cmux");
    std::fs::write(&cmux, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&cmux, std::fs::Permissions::from_mode(0o755)).unwrap();
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
    for json in [
        None,
        Some("{}"),
        Some(r#"{"agents": {"cmuxMcp": "ask"}}"#),
        Some(r#"{"agents": {"cmuxMcp": "off"}}"#),
        Some(r#"{"agents.cmuxMcp": "yes"}"#),
        Some("{"),
    ] {
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
    for json in [r#"{"agents": {"cmuxMcp": "on"}}"#, "{\n// mine\n\"agents.cmuxMcp\": \"on\",\n}"] {
        let tools = super::resolve(&inputs(Some(json))).scoped(&none);
        let server =
            tools.servers.iter().find(|s| s.name == "cmux").unwrap_or_else(|| panic!("{json}"));
        assert_eq!(server.command, cmux);
        assert_eq!(server.args, ["mcp", "serve"]);
        // Folded: one server, `cmux`, the others behind it.
        let folded = tools.for_session("s-1").folded();
        assert_eq!(folded.servers.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(), ["cmux"]);
    }
    // MCP off in the settings file: no `cmux` server even with the yes.
    let off = r#"{"agents": {"cmuxMcp": "on"}, "mcp": {"enabled": false}}"#;
    assert!(!names(Some(off), &none).contains(&"cmux".to_owned()));
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

/// A Codex chat whose config layers hold the person's own HTTP server named `cmux` gets no `cmux`
/// server (Codex would refuse the merged entry), the rule the `codex` terminal shim follows; its
/// other servers stay. The session's own `CODEX_HOME` is the one read.
#[test]
fn a_codex_chat_beside_an_http_cmux_entry_gets_no_cmux_server() {
    let root = tempfile::tempdir().unwrap();
    let (codex_home, work) = (root.path().join("codex-home"), root.path().join("work"));
    std::fs::create_dir_all(&codex_home).unwrap();
    std::fs::create_dir_all(&work).unwrap();
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
    let env = std::collections::BTreeMap::from([(
        "CODEX_HOME".to_owned(),
        codex_home.to_string_lossy().into_owned(),
    )]);
    let names = |t: super::AgentTools| t.servers.into_iter().map(|s| s.name).collect::<Vec<_>>();
    let codex = vec!["codex".to_owned(), "app-server".to_owned()];
    let at = |cwd| super::CodexLaunch { cwd, argv: &codex };
    // A stdio entry of the person's: no conflict, `cmux` stays.
    std::fs::write(codex_home.join("config.toml"), "[mcp_servers.cmux]\ncommand = \"/opt/x\"\n")
        .unwrap();
    assert_eq!(
        names(tools.clone().without_cmux_beside_an_http_entry(at(&work), &env)),
        ["cmux", "acpmux"]
    );
    // An HTTP one: `cmux` goes, the rest stays.
    std::fs::write(
        codex_home.join("config.toml"),
        "[mcp_servers.cmux]\nurl = \"http://127.0.0.1:1/mcp\"\n",
    )
    .unwrap();
    assert_eq!(names(tools.clone().without_cmux_beside_an_http_entry(at(&work), &env)), ["acpmux"]);
    // In a project's own config above the chat's folder too.
    std::fs::write(codex_home.join("config.toml"), "").unwrap();
    std::fs::create_dir_all(root.path().join(".codex")).unwrap();
    std::fs::write(
        root.path().join(".codex/config.toml"),
        "[mcp_servers.cmux]\nbearer_token_env_var = \"T\"\n",
    )
    .unwrap();
    assert_eq!(names(tools.clone().without_cmux_beside_an_http_entry(at(&work), &env)), ["acpmux"]);
    // In the profile's own arguments, with no entry in any config file.
    std::fs::remove_file(root.path().join(".codex/config.toml")).unwrap();
    assert_eq!(
        names(tools.clone().without_cmux_beside_an_http_entry(at(&work), &env)),
        ["cmux", "acpmux"]
    );
    let with_url: Vec<String> =
        ["codex", "-c", "mcp_servers.cmux.url=\"http://127.0.0.1:1/mcp\"", "app-server"]
            .map(str::to_owned)
            .to_vec();
    let launch = super::CodexLaunch { cwd: &work, argv: &with_url };
    assert_eq!(names(tools.without_cmux_beside_an_http_entry(launch, &env)), ["acpmux"]);
}

/// The servers a Codex chat's session start and fork send (`acp_servers_with`, which
/// `hub/spawn.rs` `acp_params` and `hub/fork.rs` use): no `cmux` beside the person's own HTTP
/// `cmux` entry, the others standalone; another harness, or no such entry, keeps `cmux` with the
/// others folded behind it.
#[test]
fn a_codex_session_start_or_fork_beside_an_http_cmux_entry_sends_no_cmux() {
    let root = tempfile::tempdir().unwrap();
    let (codex_home, work) = (root.path().join("codex-home"), root.path().join("work"));
    std::fs::create_dir_all(&codex_home).unwrap();
    std::fs::create_dir_all(&work).unwrap();
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
    let env = std::collections::BTreeMap::from([(
        "CODEX_HOME".to_owned(),
        codex_home.to_string_lossy().into_owned(),
    )]);
    let argv = vec!["codex".to_owned(), "app-server".to_owned()];
    let names = |cwd: Option<&std::path::Path>| {
        let codex = cwd.map(|cwd| super::CodexLaunch { cwd, argv: &argv });
        super::acp_servers_with(tools.clone(), &env, "s-1", false, codex)
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s["name"].as_str().unwrap().to_owned())
            .collect::<Vec<_>>()
    };
    assert_eq!(names(Some(&work)), ["cmux"]);
    std::fs::write(
        codex_home.join("config.toml"),
        "[mcp_servers.cmux]\nurl = \"http://127.0.0.1:1/mcp\"\n",
    )
    .unwrap();
    assert_eq!(names(Some(&work)), ["acpmux"]);
    assert_eq!(names(None), ["cmux"], "not Codex: the person's Codex config does not matter");
}

/// A chat started from another Mac follows that Mac's answer (`hub/cmux_tools_answer.rs`), as
/// its session env carries it, over this machine's settings file either way.
#[test]
fn a_chat_started_from_another_mac_gets_cmux_by_that_macs_answer() {
    use std::os::unix::fs::PermissionsExt;
    let root = tempfile::tempdir().unwrap();
    let cmux = root.path().join("cmux");
    std::fs::write(&cmux, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&cmux, std::fs::Permissions::from_mode(0o755)).unwrap();
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
    assert!(!has_cmux(on, Some("ask")), "anything but on is no");
    // Started here: this machine's answer.
    assert!(has_cmux(on, None));
    assert!(!has_cmux(off, None));
}
