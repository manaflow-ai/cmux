use super::*;
use crate::test_exec::write_executable;

#[test]
fn cli_session_resource_settings_are_config_values() {
    let mut config = Config::default();
    config.set_session_resource("session.memory_mb", "6144").unwrap();
    config.set_session_resource("session.swap_mb", "2048").unwrap();
    assert_eq!(config.session.memory_mb, Some(6144));
    assert_eq!(config.session.swap_mb, Some(2048));
    config.set_session_resource("session.memory_mb", "default").unwrap();
    assert_eq!(config.session.memory_mb, None);
}

#[test]
fn session_task_caps_are_typed_config_values() {
    let mut config = Config::default();
    config.set_session_resource("session.tasks_max", "8192").unwrap();
    config.set_session_resource("session.sessions-tasks-max", "131072").unwrap();
    assert_eq!(config.session.tasks_max, Some(8192));
    assert_eq!(config.session.sessions_tasks_max, Some(131_072));
    let json = serde_json::to_value(&config.session).unwrap();
    assert_eq!(json, serde_json::json!({"tasksMax": 8192, "sessionsTasksMax": 131072}));
    let back: SessionResourceConfig = serde_json::from_value(json).unwrap();
    assert_eq!(back, config.session);
    // 0 is no cap; `infinity` is the same.
    config.set_session_resource("session.sessions_tasks_max", "infinity").unwrap();
    assert_eq!(config.session.sessions_tasks_max, Some(0));
    config.set_session_resource("session.tasks_max", "default").unwrap();
    assert_eq!(config.session.tasks_max, None);
    assert!(config.set_session_resource("session.tasks_max", "lots").is_err());
}

#[test]
fn cli_session_cpu_class_is_a_config_value() {
    use crate::cpu_class::CpuClass;
    let mut config = Config::default();
    config.set_session_resource("session.cpu_class", "normal").unwrap();
    assert_eq!(config.session.cpu_class, Some(CpuClass::Normal));
    let saved = serde_json::to_value(&config).unwrap();
    assert_eq!(saved["session"]["cpuClass"], "normal");
    let loaded: Config = serde_json::from_value(saved).unwrap();
    assert_eq!(loaded.session.cpu_class, Some(CpuClass::Normal));
    config.set_session_resource("session.cpu-class", "Background").unwrap();
    assert_eq!(config.session.cpu_class, Some(CpuClass::Background));
    assert!(config.set_session_resource("session.cpu_class", "utility").is_err());
    config.set_session_resource("session.cpu_class", "default").unwrap();
    assert_eq!(config.session.cpu_class, None);
}

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
    let mut claude = prof(HarnessKind::ClaudeStdio, &["/opt/bin/claude"]);
    claude.fallback = Some("claude-sr".into());
    cfg.harnesses.insert("claude".into(), claude);
    verify_launchers_with(&mut cfg, Some("http://router.example:31415".into()));
    let routed = &cfg.harnesses["claude-sr"];
    assert_eq!(routed.kind, HarnessKind::ClaudeStdio);
    assert_eq!(routed.argv, vec!["/opt/bin/claude".to_owned()]);
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
fn a_failing_sr_never_becomes_an_acp_adapter_under_the_claude_sr_name() {
    // Lawrence's laptop on 2026-10-05: `claude` was the claude-acp ACP
    // adapter (from ~/.acpx) and `sr claude proxy --version` failed, so
    // claude-sr became claude-acp. claude-sr is acpmux's own Claude Code
    // adapter or nothing: the launcher is marked unavailable instead.
    let dir = std::env::temp_dir().join(format!("acpmux-route-acp-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let broken = dir.join("sr-broken");
    write_executable(
        &broken,
        "#!/bin/sh\necho 'subrouter: prepare shared Claude proxy history: file exists' >&2\nexit 0\n",
    );
    let mut cfg = Config::default();
    cfg.harnesses.insert(
        "claude-sr".into(),
        prof(HarnessKind::ClaudeStdio, &[broken.to_str().unwrap(), "claude", "proxy"]),
    );
    let mut claude = prof(HarnessKind::Acp, &["/opt/bin/claude-acp"]);
    claude.fallback = Some("claude-sr".into());
    cfg.harnesses.insert("claude".into(), claude);
    verify_launchers_with(&mut cfg, Some("http://router.example:31415".into()));
    let kept = &cfg.harnesses["claude-sr"];
    assert_eq!(kept.kind, HarnessKind::ClaudeStdio);
    assert_eq!(kept.argv[1..], ["claude".to_owned(), "proxy".to_owned()]);
    assert!(cfg.unavailable.get("claude-sr").unwrap().contains("prepare shared"));
    assert_eq!(cfg.harnesses["claude"].fallback, None);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_coderouter_without_the_configured_route_is_unavailable() {
    let dir = std::env::temp_dir().join(format!("acpmux-cr-launcher-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let old = dir.join("cr-old");
    write_executable(&old, "#!/bin/sh\necho 'error: unknown command: team-route' >&2\nexit 2\n");
    let good = dir.join("cr-good");
    write_executable(&good, "#!/bin/sh\necho '2.1.275 (Claude Code)'\n");
    let argv = |p: &std::path::Path| vec![p.to_string_lossy().into_owned(), "team-route".into()];
    let mut cfg = Config::default();
    cfg.harnesses.insert("claude".into(), prof(HarnessKind::ClaudeStdio, &["claude"]));
    let mut cr = prof(HarnessKind::ClaudeStdio, &[]);
    cr.argv = argv(&old);
    cfg.harnesses.insert("claude-cr".into(), cr.clone());
    cfg.harnesses.get_mut("claude").unwrap().fallback = Some("claude-cr".into());
    cfg.defaults.insert(
        "claude".into(),
        SessionDefaults { prefer: vec!["claude-cr".into(), "claude".into()], ..Default::default() },
    );
    // A known subrouter server never takes over a CodeRouter route.
    verify_launchers_with(&mut cfg, Some("http://router.example:31415".into()));
    assert!(cfg.unavailable.get("claude-cr").unwrap().contains("unknown command"));
    assert_eq!(cfg.harnesses["claude-cr"].argv, argv(&old));
    assert_eq!(cfg.harnesses["claude"].fallback, None);
    assert_eq!(cfg.resolve_harness("claude").unwrap(), "claude");
    let mut cfg = Config::default();
    cr.argv = argv(&good);
    cfg.harnesses.insert("claude-cr".into(), cr);
    verify_launchers_with(&mut cfg, None);
    assert!(!cfg.unavailable.contains_key("claude-cr"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[cfg(unix)]
#[test]
fn a_launcher_failure_does_not_repeat_its_full_argv() {
    const SENTINEL: &str = "launcher-private-argument";
    let error = launchers::launcher_ok(&["/usr/bin/false".into(), SENTINEL.into()]).unwrap_err();
    assert!(!error.contains(SENTINEL), "launcher failure exposed its argv: {error}");
}

#[cfg(unix)]
#[test]
fn config_load_refuses_a_symlinked_state_file() {
    use std::os::unix::fs::symlink;

    let dir = std::env::temp_dir().join(format!(
        "acpmux-config-link-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let target = dir.join("target.json");
    let config = dir.join("config.json");
    std::fs::write(&target, "{}").unwrap();
    symlink(&target, &config).unwrap();

    let error = Config::load_from_with(&config, &ProfileSources::none())
        .expect_err("a linked config loaded");
    assert!(error.to_string().contains("config.json"), "{error:#}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[cfg(unix)]
#[test]
fn writable_legacy_state_is_refused_before_it_is_narrowed_or_trusted() {
    use std::os::unix::fs::PermissionsExt;

    let root = std::env::temp_dir().join(format!(
        "acpmux-writable-state-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o777)).unwrap();
    let error = private_state_dir(&home).expect_err("a writable state directory was trusted");
    assert!(error.to_string().contains("writable"), "{error:#}");
    assert_eq!(std::fs::symlink_metadata(&home).unwrap().permissions().mode() & 0o777, 0o777);

    std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o700)).unwrap();
    let config = home.join("config.json");
    std::fs::write(&config, r#"{"permissionPolicy":"deny-all"}"#).unwrap();
    std::fs::set_permissions(&config, std::fs::Permissions::from_mode(0o666)).unwrap();
    let error = Config::load_from_with(&config, &ProfileSources::none())
        .expect_err("a writable config was trusted");
    assert!(error.to_string().contains("writable"), "{error:#}");
    assert_eq!(std::fs::symlink_metadata(&config).unwrap().permissions().mode() & 0o777, 0o666);
    let _ = std::fs::remove_dir_all(&root);
}

/// A state path another account may write is still refused, and left as it
/// is: acpmux did not make it that way (a `mkdir` or a shell redirect under
/// umask 002 did). The refusal names the exact `chmod` that fixes it
/// (ergo-walk2, 2026-10-25).
#[cfg(unix)]
#[test]
fn the_writable_state_refusal_names_the_chmod_that_fixes_it() {
    use std::os::unix::fs::PermissionsExt;

    let root = std::env::temp_dir().join(format!(
        "acpmux-writable-fix-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let mode = |p: &Path| std::fs::symlink_metadata(p).unwrap().permissions().mode() & 0o777;
    std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o775)).unwrap();
    let error = private_state_dir(&home).expect_err("a group-writable home was trusted");
    let fix = format!("`chmod 700 {}`", home.display());
    assert!(error.to_string().contains(&fix), "{error:#}");
    assert_eq!(mode(&home), 0o775, "a home acpmux did not make is not changed");

    std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o700)).unwrap();
    let log = home.join("daemon.log");
    std::fs::write(&log, "").unwrap();
    std::fs::set_permissions(&log, std::fs::Permissions::from_mode(0o664)).unwrap();
    let error = private_state_append(&log).expect_err("a group-writable log was trusted");
    let fix = format!("`chmod 600 {}`", log.display());
    assert!(error.to_string().contains(&fix), "{error:#}");
    assert_eq!(mode(&log), 0o664, "a log acpmux did not make is not changed");
    let _ = std::fs::remove_dir_all(&root);
}

#[cfg(unix)]
#[test]
fn a_state_home_below_a_non_sticky_writable_ancestor_is_refused() {
    use std::os::unix::fs::PermissionsExt;

    let root = std::env::temp_dir().join(format!(
        "acpmux-writable-parent-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    let shared = root.join("shared");
    let home = shared.join("home");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::set_permissions(&shared, std::fs::Permissions::from_mode(0o777)).unwrap();
    let error = private_state_dir(&home).expect_err("a replaceable state pathname was trusted");
    assert!(error.to_string().contains("writable ancestor"), "{error:#}");
    let _ = std::fs::remove_dir_all(&root);
}

#[cfg(target_os = "macos")]
#[test]
fn a_state_home_below_an_acl_writable_ancestor_is_refused() {
    use std::os::unix::fs::PermissionsExt;

    let root = std::env::temp_dir().join(format!(
        "acpmux-acl-parent-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    let shared = root.join("shared");
    let home = shared.join("home");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::set_permissions(&shared, std::fs::Permissions::from_mode(0o755)).unwrap();
    let status = std::process::Command::new("/bin/chmod")
        .args(["+a", "group:everyone allow add_file,delete_child", shared.to_str().unwrap()])
        .status()
        .unwrap();
    assert!(status.success());
    let error =
        private_state_dir(&home).expect_err("an ACL-replaceable state pathname was trusted");
    assert!(error.to_string().contains("ACL"), "{error:#}");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn claude_falls_back_to_the_cmux_router_on_deepseek_without_a_coderouter_route() {
    let mut cfg = Config::default();
    cfg.harnesses.insert("claude".into(), prof(HarnessKind::ClaudeStdio, &["claude"]));
    cfg.join_discovered(BTreeMap::from([(
        "cmux".to_owned(),
        prof(HarnessKind::ClaudeStdio, &["claude"]),
    )]));
    assert_eq!(cfg.harnesses["claude"].fallback.as_deref(), Some("cmux"));
    assert_eq!(cfg.auto_fallback, Some(("claude".into(), "cmux".into())));
}

#[test]
fn the_cmux_router_profile_defaults_to_deepseek_v4_1_flash_1017() {
    let mut found = BTreeMap::new();
    super::discover::add_cmux_router_with(&mut found, &|_| Some("/usr/bin/claude".into()), None);
    assert_eq!(found["cmux"].model.as_deref(), Some("deepseek/deepseek-v4.1-flash-1017"));
    // Claude Code's background calls run on the same model.
    assert_eq!(
        found["cmux"].env.get("ANTHROPIC_SMALL_FAST_MODEL").map(String::as_str),
        Some("deepseek/deepseek-v4.1-flash-1017")
    );
}

#[test]
fn the_cmux_router_profile_starts_on_the_model_router_setting() {
    let mut found = BTreeMap::new();
    super::discover::add_cmux_router_with(
        &mut found,
        &|_| Some("/usr/bin/claude".into()),
        Some("deepseek/deepseek-v4.1-flash"),
    );
    assert_eq!(found["cmux"].model.as_deref(), Some("deepseek/deepseek-v4.1-flash"));
}

#[test]
fn a_model_router_setting_the_router_does_not_serve_keeps_the_default() {
    let mut found = BTreeMap::new();
    super::discover::add_cmux_router_with(
        &mut found,
        &|_| Some("/usr/bin/claude".into()),
        Some("anthropic/claude-opus-5-5"),
    );
    assert_eq!(found["cmux"].model.as_deref(), Some("deepseek/deepseek-v4.1-flash-1017"));
}

#[test]
fn the_model_router_setting_is_read_from_the_settings_document() {
    let doc = serde_json::json!({"agents": {"modelRouter": {"model": "deepseek/deepseek-v4-pro"}}});
    assert_eq!(
        super::discover::cmux_router_model_in(&doc).as_deref(),
        Some("deepseek/deepseek-v4-pro")
    );
    assert_eq!(super::discover::cmux_router_model_in(&serde_json::json!({})), None);
}

/// Every Claude Code profile reads Claude's store, whatever family it declares (`claude-sr2`),
/// so adopt finds its chats there; other profiles keep their family.
#[test]
fn a_claude_code_profile_of_its_own_family_reads_the_claude_store() {
    let mut sr2 = prof(HarnessKind::ClaudeStdio, &["sr2", "claude2"]);
    sr2.family = Some("claude-sr2".into());
    assert_eq!(derive_family("claude-sr2", &sr2), "claude-sr2");
    assert_eq!(store_family("claude-sr2", &sr2), "claude");
    assert_eq!(store_family("claude", &prof(HarnessKind::ClaudeStdio, &["claude"])), "claude");
    let codex = prof(HarnessKind::Acp, &["codex-acp"]);
    assert_eq!(store_family("codex", &codex), "codex");
    let mut pi = prof(HarnessKind::Acp, &["pi-acp"]);
    pi.family = Some("pi".into());
    assert_eq!(store_family("pi", &pi), "pi");
}
