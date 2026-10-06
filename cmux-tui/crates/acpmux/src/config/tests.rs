use super::*;

fn prof(kind: HarnessKind, argv: &[&str]) -> HarnessProfile {
    HarnessProfile {
        kind,
        argv: argv.iter().map(|s| s.to_string()).collect(),
        env: BTreeMap::new(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    }
}

#[test]
fn families_are_derived_and_resolved() {
    let mut cfg = Config::default();
    cfg.harnesses
        .insert("claude".into(), prof(HarnessKind::ClaudeStdio, &["/usr/local/bin/claude"]));
    cfg.harnesses.insert(
        "claude-sr".into(),
        prof(HarnessKind::ClaudeStdio, &["/Users/x/bin/sr", "claude", "proxy"]),
    );
    cfg.harnesses.insert("codex".into(), prof(HarnessKind::Acp, &["/opt/homebrew/bin/codex-acp"]));
    cfg.harnesses.insert("oc".into(), prof(HarnessKind::Acp, &["opencode", "acp"]));
    cfg.harnesses.insert("pi".into(), prof(HarnessKind::Acp, &["/x/pi-acp"]));
    cfg.harnesses.insert("omp".into(), prof(HarnessKind::Acp, &["/x/omp", "acp"]));
    cfg.harnesses
        .insert("prime".into(), prof(HarnessKind::Acp, &["/x/prime-agent", "--mode", "acp"]));
    let mut tagged = prof(HarnessKind::Acp, &["python3", "agent.py"]);
    tagged.family = Some("codex".into());
    cfg.harnesses.insert("router-codex".into(), tagged);
    assert_eq!(cfg.family("claude-sr").as_deref(), Some("claude"));
    assert_eq!(cfg.family("oc").as_deref(), Some("opencode"));
    // Forks are their own families.
    assert_eq!(cfg.family("omp").as_deref(), Some("omp"));
    assert_eq!(cfg.family("prime").as_deref(), Some("prime"));
    assert_eq!(cfg.families()["codex"], vec!["codex".to_owned(), "router-codex".to_owned()]);
    // A family with one profile, or a profile named like the family, resolves.
    assert_eq!(cfg.resolve_harness("opencode").unwrap(), "oc");
    assert_eq!(cfg.resolve_harness("pi").unwrap(), "pi");
    assert_eq!(cfg.resolve_harness("codex").unwrap(), "codex");
    assert_eq!(cfg.resolve_harness("claude").unwrap(), "claude");
    assert_eq!(cfg.resolve_harness("claude-sr").unwrap(), "claude-sr");
    // Unknown names and model ids are errors that name what exists.
    let err = cfg.resolve_harness("gpt-5.5").unwrap_err();
    assert!(err.contains("families:") && err.contains("profiles:"), "{err}");
    // Several profiles, no preference, no exact name: refused, never guessed.
    let mut two = Config::default();
    two.harnesses.insert("omp-a".into(), prof(HarnessKind::Acp, &["/x/omp", "acp"]));
    two.harnesses.insert("omp-b".into(), prof(HarnessKind::Acp, &["/y/omp", "acp"]));
    assert!(two.resolve_harness("omp").unwrap_err().contains("no preference"));
    // prefer decides, skipping profiles that are not installed.
    cfg.defaults.insert(
        "claude".into(),
        SessionDefaults {
            model: Some("claude-opus-5".into()),
            effort: Some("high".into()),
            policy: Some(PermissionPolicy::ApproveEdits),
            prefer: vec!["missing".into(), "claude-sr".into()],
            env: BTreeMap::from([("A".to_owned(), "1".to_owned())]),
        },
    );
    cfg.defaults.insert(
        "claude-sr".into(),
        SessionDefaults { effort: Some("max".into()), ..Default::default() },
    );
    assert_eq!(cfg.resolve_harness("claude").unwrap(), "claude-sr");
    // A preference outside the family is ignored.
    cfg.defaults.get_mut("claude").unwrap().prefer = vec!["codex".into(), "claude-sr".into()];
    assert_eq!(cfg.resolve_harness("claude").unwrap(), "claude-sr");
    // Defaults chain: family, then the profile entry, then inline profile fields.
    cfg.harnesses.get_mut("claude-sr").unwrap().policy = Some(PermissionPolicy::Ask);
    let d = cfg.defaults_for("claude-sr");
    assert_eq!(d.model.as_deref(), Some("claude-opus-5"));
    assert_eq!(d.effort.as_deref(), Some("max"));
    assert_eq!(d.policy, Some(PermissionPolicy::Ask));
    assert_eq!(d.env["A"], "1");
    assert!(cfg.defaults_for("codex").is_empty());
    // Presets and declared models round-trip as camelCase JSON.
    cfg.presets.insert(
        "deepseek".into(),
        Preset {
            harness: "opencode".into(),
            model: Some("opencode-go/deepseek-v4-pro".into()),
            effort: Some("low".into()),
            policy: None,
            env: BTreeMap::new(),
            args: Vec::new(),
            system_prompt_sha256: None,
            description: None,
        },
    );
    cfg.harnesses.get_mut("prime").unwrap().models = vec![
        DeclaredModel::Id("subrouter/gpt-5.6-sol".into()),
        DeclaredModel::Full { id: "x".into(), name: Some("X".into()) },
    ];
    let text = serde_json::to_string(&cfg).unwrap();
    assert!(text.contains("\"presets\":{\"deepseek\":{\"harness\":\"opencode\""), "{text}");
    let back: Config = serde_json::from_str(&text).unwrap();
    assert_eq!(back.presets, cfg.presets);
    assert_eq!(back.harnesses["prime"].models[1].name(), "X");
    assert_eq!(back.defaults, cfg.defaults);
}

#[test]
fn save_leaves_discovered_profiles_out() {
    let dir = std::env::temp_dir().join(format!("acpmux-save-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let mut cfg = Config { path: Some(dir.join("config.json")), ..Config::default() };
    let mut claude = prof(HarnessKind::ClaudeStdio, &["claude"]);
    claude.fallback = Some("claude-sr".into());
    cfg.harnesses.insert("claude".into(), claude);
    cfg.harnesses
        .insert("claude-sr".into(), prof(HarnessKind::ClaudeStdio, &["sr", "claude", "proxy"]));
    cfg.harnesses.insert("pi".into(), prof(HarnessKind::Acp, &["pi-acp"]));
    cfg.discovered = ["claude-sr".to_owned(), "pi".to_owned()].into_iter().collect();
    cfg.auto_fallback = Some(("claude".into(), "claude-sr".into()));
    cfg.default_harness = Some("pi".into());
    cfg.auto_default = true;
    cfg.defaults
        .insert("claude".into(), SessionDefaults { model: Some("m".into()), ..Default::default() });
    cfg.save().unwrap();
    let text = std::fs::read_to_string(dir.join("config.json")).unwrap();
    let v: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(
        v["harnesses"].as_object().unwrap().keys().cloned().collect::<Vec<_>>(),
        vec!["claude".to_owned()]
    );
    assert!(v["harnesses"]["claude"].get("fallback").is_none(), "{text}");
    assert!(v.get("defaultHarness").map(|d| d.is_null()).unwrap_or(true), "{text}");
    assert_eq!(v["defaults"]["claude"]["model"], "m");
    assert!(!text.contains("composerMaxRows"), "{text}");
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(dir.join("config.json")).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
    // A generated prefer list is left out; one the user changed is kept.
    cfg.auto_prefer = Some(vec!["claude-sr".into(), "claude".into()]);
    cfg.defaults.get_mut("claude").unwrap().prefer = vec!["claude".into()];
    cfg.save().unwrap();
    let text = std::fs::read_to_string(dir.join("config.json")).unwrap();
    let v: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(v["defaults"]["claude"]["prefer"][0], "claude", "{text}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn launcher_check_rejects_old_subrouter() {
    let dir = std::env::temp_dir().join(format!("acpmux-launcher-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    // Written out of process: executing a script this process just wrote
    // flaked with ETXTBSY under parallel tests (`write_executable` below).
    let old = dir.join("sr-old");
    write_executable(
        &old,
        "#!/bin/sh\necho 'subrouter: unknown command: sr claude proxy' >&2\nexit 1\n",
    );
    let broken = dir.join("sr-broken");
    write_executable(
        &broken,
        "#!/bin/sh\necho 'subrouter: prepare shared Claude proxy history: file exists' >&2\nexit 0\n",
    );
    let good = dir.join("sr-good");
    write_executable(&good, "#!/bin/sh\necho '2.1.275 (Claude Code)'\n");
    let argv = |p: &std::path::Path| {
        vec![p.to_string_lossy().into_owned(), "claude".into(), "proxy".into()]
    };
    assert!(launcher_ok(&argv(&old)).unwrap_err().contains("unknown command"));
    assert!(launcher_ok(&argv(&broken)).unwrap_err().contains("prepare shared"));
    assert!(launcher_ok(&argv(&good)).is_ok());
    let mut cfg = Config::default();
    cfg.harnesses.insert(
        "claude-sr".into(),
        HarnessProfile {
            kind: HarnessKind::ClaudeStdio,
            argv: argv(&old),
            env: BTreeMap::new(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    cfg.harnesses.insert(
        "claude".into(),
        HarnessProfile {
            kind: HarnessKind::ClaudeStdio,
            argv: vec!["claude".into()],
            env: BTreeMap::new(),
            description: None,
            fallback: Some("claude-sr".into()),
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    verify_launchers_with(&mut cfg, None);
    // The profile stays (sessions on it keep working or fail with the
    // reason); nothing routes new work to it.
    assert!(cfg.harnesses.contains_key("claude-sr"));
    assert!(cfg.unavailable.get("claude-sr").unwrap().contains("unknown command"));
    assert_eq!(cfg.harnesses["claude"].fallback, None);
    cfg.defaults.insert(
        "claude".into(),
        SessionDefaults { prefer: vec!["claude-sr".into(), "claude".into()], ..Default::default() },
    );
    assert_eq!(cfg.resolve_harness("claude").unwrap(), "claude");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_subrouter_route_is_the_sr_default_server() {
    let dir = std::env::temp_dir().join(format!("acpmux-route-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let servers = dir.join("servers.json");
    std::fs::write(
        &servers,
        r#"{"servers":[{"name":"cloud","url":"https://sr.example"},{"name":"mine","url":"http://router.example:31415/"}],"default":"mine"}"#,
    )
    .unwrap();
    assert_eq!(subrouter_route(None, &servers).as_deref(), Some("http://router.example:31415"));
    // SUBROUTER_URL wins over the file.
    assert_eq!(
        subrouter_route(Some("http://env.example:1"), &servers).as_deref(),
        Some("http://env.example:1")
    );
    std::fs::write(&servers, r#"{"servers":[{"name":"a","url":"ftp://x"}],"default":"a"}"#)
        .unwrap();
    assert_eq!(subrouter_route(None, &servers), None);
    assert_eq!(subrouter_route(None, &dir.join("missing.json")), None);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn an_sr_without_claude_proxy_routes_claude_sr_through_the_subrouter_server() {
    let dir = std::env::temp_dir().join(format!("acpmux-route-old-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let old = dir.join("sr-old");
    write_executable(
        &old,
        "#!/bin/sh\necho 'subrouter: unknown command: sr claude proxy' >&2\nexit 1\n",
    );
    let mut cfg = Config::default();
    cfg.harnesses.insert(
        "claude-sr".into(),
        prof(HarnessKind::ClaudeStdio, &[old.to_str().unwrap(), "claude", "proxy"]),
    );
    let mut claude = prof(HarnessKind::Acp, &["/opt/bin/claude-acp"]);
    claude.fallback = Some("claude-sr".into());
    cfg.harnesses.insert("claude".into(), claude);
    verify_launchers_with(&mut cfg, Some("http://router.example:31415".into()));
    let routed = &cfg.harnesses["claude-sr"];
    assert_eq!(routed.kind, HarnessKind::Acp);
    assert_eq!(routed.argv, vec!["/opt/bin/claude-acp".to_owned()]);
    assert_eq!(routed.env["ANTHROPIC_BASE_URL"], "http://router.example:31415");
    assert_eq!(routed.env["ANTHROPIC_CUSTOM_HEADERS"], "X-Subrouter-Agent: claude");
    assert!(routed.env.contains_key("ANTHROPIC_AUTH_TOKEN"));
    assert_eq!(routed.fallback, None);
    assert!(!cfg.unavailable.contains_key("claude-sr"));
    // A direct Claude still falls over to the routed profile.
    assert_eq!(cfg.harnesses["claude"].fallback.as_deref(), Some("claude-sr"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn codex_without_its_acp_adapter_runs_through_the_pinned_adapter_package() {
    let profile =
        codex_through_adapter_package(Some("/u/.local/bin/codex"), Some("/opt/bin/npx")).unwrap();
    assert_eq!(profile.kind, HarnessKind::Acp);
    assert_eq!(profile.argv[0], "/opt/bin/npx");
    assert_eq!(profile.argv[1], "-y");
    assert!(profile.argv[2].starts_with("@agentclientprotocol/codex-acp@"));
    // The adapter finds the installed codex binary through CODEX_PATH.
    assert_eq!(profile.env["CODEX_PATH"], "/u/.local/bin/codex");
    assert!(codex_through_adapter_package(None, Some("/opt/bin/npx")).is_none());
    assert!(codex_through_adapter_package(Some("/u/.local/bin/codex"), None).is_none());
}

#[test]
fn websocket_allow_lists_read_in_either_spelling() {
    let camel: WebSocketConfig = serde_json::from_str(
        r#"{"listen":"127.0.0.1:0","allowedOrigins":["http://127.0.0.1:5173"],"allowedHosts":["box.local"]}"#,
    )
    .unwrap();
    // The spelling the docs and scripts use (websocket.allowed_origins).
    let snake: WebSocketConfig = serde_json::from_str(
        r#"{"listen":"127.0.0.1:0","allowed_origins":["http://127.0.0.1:5173"],"allowed_hosts":["box.local"]}"#,
    )
    .unwrap();
    assert_eq!(camel, snake);
    assert_eq!(snake.allowed_origins, vec!["http://127.0.0.1:5173".to_owned()]);
    assert_eq!(snake.allowed_hosts, vec!["box.local".to_owned()]);
}

/// Creates an executable (0755) script without this process ever holding a
/// write descriptor for it.
///
/// Tests run on many threads. A sibling test that forks while this process
/// holds such a descriptor hands a copy to its child until that child execs,
/// and executing the script in that window fails with ETXTBSY ("Text file
/// busy"). `O_CLOEXEC` does not close that window, and a temp file plus a
/// rename does not either (the child holds the same inode). A short-lived
/// `sh` opens, writes, and closes the file in its own process, so no fork of
/// this process can inherit it. (The same helper as cmux-tui's `test_exec`.)
fn write_executable(path: impl AsRef<std::path::Path>, contents: impl AsRef<[u8]>) {
    use std::io::Write as _;
    use std::process::{Command, Stdio};
    let path = path.as_ref();
    let mut child = Command::new("/bin/sh")
        .args(["-c", "cat >\"$1\" && chmod 755 \"$1\"", "sh"])
        .arg(path)
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(contents.as_ref()).unwrap();
    assert!(child.wait().unwrap().success(), "could not write {}", path.display());
}
