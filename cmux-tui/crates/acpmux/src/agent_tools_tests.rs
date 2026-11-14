/// `super::resolve` with this machine's answers left out: no installed helper is looked up and
/// control is granted, so a test never depends on (or writes) the account's machine consent. A
/// cloud-joined fleet Mac has `~/.acpmux/machine-consent/enrolled.json` and no control grant,
/// which took `cmux-cua` out of every list there.
fn resolve(inputs: &super::Inputs) -> super::AgentTools {
    super::resolve_gated(inputs, super::cua_helper::installed, || true)
}

/// A machine whose control consent is not granted (a cloud-joined machine before the person
/// allows control) gets no `cmux-cua` server; every other server stays.
#[test]
fn a_machine_without_control_consent_gets_no_computer_use_server() {
    use std::os::unix::fs::PermissionsExt;
    let root = std::env::temp_dir().join(format!("acpmux-no-control-{}", uuid::Uuid::now_v7()));
    let bin = root.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    for name in ["cmux-cua", "optchat-chief"] {
        std::fs::write(bin.join(name), "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(bin.join(name), std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let inputs = memory_inputs(&bin, Some(r#"{"agents":{"memory":{"enabled":true}}}"#));
    let names = |granted: bool| -> Vec<String> {
        super::resolve_gated(&inputs, |_| None, || granted)
            .servers
            .into_iter()
            .map(|s| s.name)
            .collect()
    };
    let granted = names(true);
    assert!(granted.iter().any(|n| n == "cmux-cua"), "{granted:?}");
    let refused = names(false);
    assert!(!refused.iter().any(|n| n == "cmux-cua"), "{refused:?}");
    let others: Vec<String> = granted.into_iter().filter(|n| n != "cmux-cua").collect();
    assert!(!others.is_empty(), "the test needs another server to see it kept");
    assert_eq!(refused, others);
    let _ = std::fs::remove_dir_all(&root);
}

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
        hosted: false,
        github: false,
        desktop_lease: None,
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
    let tools = resolve(&memory_inputs(&bin, None));
    assert_eq!(cua(&tools), Some(helper.clone()), "the nested helper stands in");
    // A bin copy (a DEV build) wins over the helper.
    let bin_cua = bin.join("cmux-cua");
    std::fs::write(&bin_cua, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&bin_cua, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert_eq!(cua(&resolve(&memory_inputs(&bin, None))), Some(bin_cua.clone()));
    // Neither: no server.
    std::fs::remove_file(&bin_cua).unwrap();
    std::fs::remove_file(&helper).unwrap();
    assert_eq!(cua(&resolve(&memory_inputs(&bin, None))), None);
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
        let tools = resolve(&inputs(prefix));
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
    let mut tools = resolve(&inputs(&["acp"]));
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
        servers: vec![server("cmux"), server(crate::acpmux_mcp::SERVER_NAME)],
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
        .find(|s| s["name"] == crate::acpmux_mcp::SERVER_NAME)
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
    let tools = resolve(&inputs).for_session("s1");
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
    let folded = resolve(&inputs).for_session("s1").folded();
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
/// fitted plugin leaves out `cmux-cua` and `cmux-sudo`, keeps the rest (the chat skill
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
        servers: vec![server("cmux"), server("cmux-cua"), server(crate::secret_mcp::SERVER_NAME)],
        plugin_dir: Some(full.clone()),
        ..Default::default()
    };
    assert_eq!(with.clone().fit_skills().plugin_dir, Some(full.clone()), "nothing to leave out");
    let without = super::AgentTools { servers: vec![server("cmux")], ..with }.fit_skills();
    let fit = without.plugin_dir.clone().unwrap();
    assert_ne!(fit, full);
    assert_eq!(fit.parent(), full.parent());
    for gone in ["cmux-cua", "cmux-sudo"] {
        assert!(!fit.join("skills").join(gone).exists(), "{gone} is listed");
    }
    for kept in ["cmux-browser", "cmux-chat", "acpmux", "cmux-live"] {
        assert!(fit.join("skills").join(kept).join("SKILL.md").is_file(), "{kept} is gone");
    }
    assert!(fit.join("hooks/hooks.json").is_file());
    let rows: Vec<_> = without.tool_rows(true, true).into_iter().map(|r| r.id).collect();
    assert!(rows.contains(&"skill:cmux:cmux-browser".to_owned()), "{rows:?}");
    assert!(!rows.iter().any(|r| r.ends_with("cmux-cua") || r.ends_with("cmux-sudo")), "{rows:?}");
    let parts: Vec<_> = without.context_parts(true).into_iter().map(|p| p.id).collect();
    assert!(!parts.iter().any(|p| p == "cmux-source-skill-cmux-cmux-cua"), "{parts:?}");
    // A plugin without the chat skill (`agents.guidance.claude` off) stays without it.
    let no_chat = super::materialize(state.path(), |skill| skill != "cmux-chat").unwrap();
    let fit = super::AgentTools { plugin_dir: Some(no_chat), ..without }.fit_skills();
    let fit = fit.plugin_dir.unwrap();
    assert!(!fit.join("skills/cmux-chat").exists() && !fit.join("skills/cmux-cua").exists());
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
    use std::os::unix::fs::PermissionsExt;
    let root = std::env::temp_dir().join(format!("acpmux-one-helper-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let cmux = root.join("cmux");
    std::fs::write(&cmux, "#!/bin/sh\n").unwrap();
    std::fs::set_permissions(&cmux, std::fs::Permissions::from_mode(0o755)).unwrap();
    let exe = std::path::PathBuf::from("/usr/local/lib/cmux/cmux-tui");
    let inputs = super::Inputs {
        acpmux: Some(crate::self_command::SelfCommand::new(exe.clone(), vec!["acp".into()])),
        cua_v2: Some(root.join("cua-v2")),
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
        ["cmux-cua", "cmux-secrets", "cmux-sessions", "cmux-subsessions", "cmux-forum", "acpmux"]
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
    use std::os::unix::fs::PermissionsExt;
    let root = std::env::temp_dir().join(format!("acpmux-github-mcp-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    // The `cmux` CLI, so the `cmux` server exists to fold the github server under.
    let cmux = root.join("cmux");
    std::fs::write(&cmux, "#!/bin/sh\n").unwrap();
    std::fs::set_permissions(&cmux, std::fs::Permissions::from_mode(0o755)).unwrap();
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
