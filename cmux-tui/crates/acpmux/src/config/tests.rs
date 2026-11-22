use super::*;
use crate::test_exec::write_executable;

#[test]
fn v2_surfaces_are_opt_in_and_default_empty() {
    let config = Config::default();
    assert!(config.acpmux_v2.is_empty());
    assert!(config.acpmux_v2.enabled().is_empty());

    let config: Config = serde_json::from_value(serde_json::json!({
        "acpmux.v2": ["list", "chat", "unknown", "start"]
    }))
    .unwrap();
    let enabled = config.acpmux_v2.enabled();
    assert!(enabled.contains("list"));
    assert!(enabled.contains("chat"));
    assert!(enabled.contains("start"));
    assert!(enabled.contains("books"), "chat/start imply the books surface");
    assert!(!enabled.contains("unknown"));
}

#[test]
fn v2_surfaces_round_trip_without_writing_the_empty_default() {
    let empty = serde_json::to_value(Config::default()).unwrap();
    assert!(empty.get("acpmux.v2").is_none());

    let config = Config { acpmux_v2: V2Surfaces(vec!["peers".into()]), ..Config::default() };
    let saved = serde_json::to_value(&config).unwrap();
    assert_eq!(saved["acpmux.v2"], serde_json::json!(["peers"]));
    let parsed: Config = serde_json::from_value(saved).unwrap();
    assert_eq!(parsed.acpmux_v2, config.acpmux_v2);
}

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
fn cli_permission_settings_are_config_values() {
    let mut config = Config::default();
    config.set("permissions.default", "yolo").unwrap();
    assert_eq!(config.default_permission_mode.as_deref(), Some("fullAccess"));
    config.set("defaultPermissionMode", "ask").unwrap();
    assert_eq!(config.default_permission_mode.as_deref(), Some("ask"));
    config.set("permissions.codex", "standard").unwrap();
    assert_eq!(config.defaults["codex"].permission_mode.as_deref(), Some("standard"));
    config.set("defaults.claude.permissionMode", "full-access").unwrap();
    assert_eq!(config.defaults["claude"].permission_mode.as_deref(), Some("fullAccess"));
    assert!(config.set("permissions.default", "sometimes").is_err());
    config.set("permissions.codex", "default").unwrap();
    assert!(!config.defaults.contains_key("codex"), "an emptied entry is dropped");
    config.set("permissions.default", "default").unwrap();
    assert_eq!(config.default_permission_mode, None);
    // The resource keys still go through the same verb.
    config.set("session.memory_mb", "6144").unwrap();
    assert_eq!(config.session.memory_mb, Some(6144));
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
fn the_cmux_router_profile_offers_gemini_4_neon_from_our_vertex() {
    let mut found = BTreeMap::new();
    super::discover::add_cmux_router_with(
        &mut found,
        &|_| Some("/usr/bin/claude".into()),
        Some("google/gemini-4-neon"),
    );
    assert_eq!(found["cmux"].model.as_deref(), Some("google/gemini-4-neon"));
    let neon = |m: &super::DeclaredModel| matches!(m, super::DeclaredModel::Full { id, .. } if id == "google/gemini-4-neon");
    assert!(found["cmux"].models.iter().any(neon));
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

/// A permission policy this build does not know (one a newer build added and saved, read again
/// after a rollback) never stops the daemon: `Config::load` failed on it, so no chat could be
/// reached until someone edited config.json by hand. It loads as `ask`, the default: a person
/// is asked, nothing is approved that was not. Every known value, and every alias, reads as
/// before, and what this build writes is unchanged.
#[test]
fn a_permission_policy_from_a_newer_build_loads_as_ask() {
    let dir = std::env::temp_dir().join(format!(
        "acpmux-config-policy-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("config.json");
    std::fs::write(
        &path,
        r#"{"permissionPolicy": "a-policy-from-a-newer-build",
            "defaults": {"claude": {"policy": "another-new-one"}}}"#,
    )
    .unwrap();
    let loaded = Config::load_from_with(&path, &ProfileSources::none());
    let _ = std::fs::remove_dir_all(&dir);
    let config = loaded.expect("a config with a newer build's policy did not load");
    assert_eq!(config.permission_policy, PermissionPolicy::Ask);
    assert_eq!(config.defaults.get("claude").and_then(|d| d.policy), Some(PermissionPolicy::Ask));
    for (text, policy) in [
        ("ask", PermissionPolicy::Ask),
        ("approve-all", PermissionPolicy::ApproveAll),
        ("yolo", PermissionPolicy::ApproveAll),
        ("approve-reads", PermissionPolicy::ApproveReads),
        ("approve-edits", PermissionPolicy::ApproveEdits),
        ("accept-edits", PermissionPolicy::ApproveEdits),
        ("deny-all", PermissionPolicy::DenyAll),
        ("review", PermissionPolicy::Review),
    ] {
        let read: PermissionPolicy = serde_json::from_value(serde_json::json!(text)).unwrap();
        assert_eq!(read, policy, "{text}");
    }
    for policy in [
        PermissionPolicy::Ask,
        PermissionPolicy::ApproveAll,
        PermissionPolicy::ApproveReads,
        PermissionPolicy::ApproveEdits,
        PermissionPolicy::DenyAll,
        PermissionPolicy::Review,
    ] {
        assert_eq!(serde_json::to_value(policy).unwrap(), serde_json::json!(policy.to_string()));
    }
    // A value that is not a string is still an error: that is a damaged file, not a newer one.
    assert!(serde_json::from_value::<PermissionPolicy>(serde_json::json!(3)).is_err());
}

#[test]
fn ordinary_atomic_writes_still_sync_file_and_directory() {
    let home = tempfile::tempdir().unwrap();
    let path = home.path().join("session.json");
    let syncs = startup_seams::Count::syncs(home.path());
    write_atomic(&path, b"old").unwrap();
    assert_eq!(syncs.get(), 2);
    write_atomic(&path, b"new").unwrap();
    assert_eq!(syncs.get(), 4);
    assert_eq!(std::fs::read(&path).unwrap(), b"new");
}

#[cfg(unix)]
#[test]
fn an_unsynced_atomic_write_keeps_the_old_copy_until_rename() {
    use std::os::unix::fs::MetadataExt;
    let home = tempfile::tempdir().unwrap();
    let path = home.path().join("copy");
    std::fs::write(&path, b"old").unwrap();
    let before = std::fs::metadata(&path).unwrap().ino();
    let called = std::rc::Rc::new(std::cell::Cell::new(0));
    let seen = called.clone();
    let target = path.clone();
    let _guard = seams::on_before_rename(move |path| {
        assert_eq!(path, target.as_path());
        assert_eq!(std::fs::read(path).unwrap(), b"old");
        seen.set(seen.get() + 1);
    });
    let syncs = startup_seams::Count::syncs(home.path());
    write_atomic_unsynced(&path, b"new").unwrap();
    assert_eq!(called.get(), 1);
    assert_ne!(std::fs::metadata(&path).unwrap().ino(), before);
    assert_eq!(std::fs::read(&path).unwrap(), b"new");
    assert_eq!(syncs.get(), 0);
}

/// fseventsd keeps every path it is told of until it restarts: a peer snapshot rewritten every
/// few seconds through a `.tmp-<pid>-<n>` copy minted a new name each time, about 400 a minute on
/// a Mac with a few dozen peer chats streaming. Every write of a file in one process uses one
/// name, and writers of it on several threads still each put a whole copy in place.
#[cfg(unix)]
#[test]
fn atomic_writes_of_a_file_reuse_one_temporary_name() {
    let home = tempfile::tempdir().unwrap();
    let path = home.path().join("copy.json");
    let names = std::rc::Rc::new(std::cell::RefCell::new(std::collections::BTreeSet::new()));
    let seen = names.clone();
    let dir = home.path().to_path_buf();
    let guard = seams::on_before_rename(move |_| {
        for entry in std::fs::read_dir(&dir).unwrap() {
            let name = entry.unwrap().file_name().to_string_lossy().into_owned();
            if name.contains(".tmp-") {
                seen.borrow_mut().insert(name);
            }
        }
    });
    for n in 0..5 {
        write_atomic(&path, format!("{n}").as_bytes()).unwrap();
        write_atomic_unsynced(&path, format!("u{n}").as_bytes()).unwrap();
    }
    drop(guard);
    let want = format!("copy.tmp-{}", std::process::id());
    assert_eq!(*names.borrow(), std::collections::BTreeSet::from([want]));

    let whole: Vec<Vec<u8>> = (0..8u8).map(|n| vec![b'a' + n; 64 << 10]).collect();
    std::thread::scope(|scope| {
        for bytes in &whole {
            let path = &path;
            scope.spawn(move || {
                for _ in 0..20 {
                    write_atomic_unsynced(path, bytes).unwrap();
                }
            });
        }
    });
    let left = std::fs::read(&path).unwrap();
    assert!(whole.contains(&left), "a copy two writers filled together was put in place");
    let temps = std::fs::read_dir(home.path())
        .unwrap()
        .filter(|e| e.as_ref().unwrap().file_name().to_string_lossy().contains(".tmp-"))
        .count();
    assert_eq!(temps, 0, "a temporary copy stayed");
}

/// A joined Mac's `machine-consent/` held `refusal.json` and 8 `refusal.tmp-<pid>-<n>` files: the
/// daemon writing the refusal was stopped between the temporary copy's open and its rename, and
/// nothing removed the copy after. The next write to the same file removes the copies of
/// processes no longer running; a running process's copy, and a copy made in the last minute,
/// stay.
#[cfg(unix)]
#[test]
fn an_atomic_write_removes_the_temporary_copies_dead_processes_left() {
    let home = tempfile::tempdir().unwrap();
    let path = home.path().join("refusal.json");
    let mut exited = std::process::Command::new("true").spawn().unwrap();
    let dead = exited.id();
    exited.wait().unwrap();
    let mut running = std::process::Command::new("sleep").arg("60").spawn().unwrap();
    let live = running.id();
    let hour_ago = std::time::SystemTime::now() - std::time::Duration::from_secs(3600);
    let left = |name: String, old: bool| {
        let tmp = home.path().join(name);
        let file = std::fs::File::create(&tmp).unwrap();
        if old {
            file.set_modified(hour_ago).unwrap();
        }
        tmp
    };
    let stale = left(format!("refusal.tmp-{dead}-3"), true);
    let stale_bare = left(format!("refusal.tmp-{dead}"), true);
    let fresh = left(format!("refusal.tmp-{dead}-4"), false);
    let alive = left(format!("refusal.tmp-{live}-0"), true);
    let other = left(format!("consent.tmp-{dead}-0"), true);
    let not_a_pid = left("refusal.tmp-notes".to_owned(), true);

    write_atomic(&path, b"{}").unwrap();

    let _ = running.kill();
    let _ = running.wait();
    assert_eq!(std::fs::read(&path).unwrap(), b"{}");
    assert!(!stale.exists(), "a dead process's copy stays: {}", stale.display());
    assert!(!stale_bare.exists(), "a dead process's copy stays: {}", stale_bare.display());
    assert!(fresh.exists(), "a copy made in the last minute was removed");
    assert!(alive.exists(), "a running process's copy was removed");
    assert!(other.exists(), "another file's copy was removed");
    assert!(not_a_pid.exists(), "a name with no pid was removed");
}

/// `acpmux config --set transport.wireguard=true` with no `wireguardStatic` block (cmux#43305's
/// carrier step, 2026-11-15): the daemon then refused to start. What the CLI does (load, set,
/// save) either refuses and leaves config.json as it was, or writes a config the daemon's own
/// startup accepts: `Config::load` and the WireGuard transport's start.
#[tokio::test]
async fn config_set_never_writes_a_config_the_daemon_refuses() {
    let home = tempfile::tempdir().unwrap();
    let path = home.path().join("config.json");
    std::fs::write(&path, "{}\n").unwrap();
    let before = std::fs::read(&path).unwrap();
    let mut cfg = Config::load_from_with(&path, &ProfileSources::none()).unwrap();
    match cfg.set("transport.wireguard", "true") {
        Err(refused) => {
            let refused = format!("{refused:#}");
            for field in ["wireguardStatic.listen", "wireguardStatic.address"] {
                assert!(refused.contains(field), "the refusal names {field}: {refused}");
            }
            assert!(!cfg.transport.wireguard, "a refused set left the value in place");
            assert_eq!(std::fs::read(&path).unwrap(), before, "a refused set wrote config.json");
        }
        Ok(()) => {
            cfg.save().unwrap();
            let loaded = Config::load_from_with(&path, &ProfileSources::none()).unwrap();
            let started = crate::wireguard::Transport::start_with_link(
                &loaded,
                home.path(),
                None,
                "127.0.0.1:1".parse().unwrap(),
            )
            .await;
            if let Err(refused) = started {
                panic!("the daemon refuses what config --set wrote: {refused:#}");
            }
        }
    }
}

/// Every start-time check of config.json goes through `Config::start_refusal`, so `config --set`
/// refuses what any of them refuses, not only the WireGuard settings: here a saved network
/// `websocket.listen` without its opt-in, which the start refuses (`server::check_listen_address`).
#[test]
fn config_set_refuses_what_any_start_check_refuses() {
    use base64::Engine as _;
    let home = tempfile::tempdir().unwrap();
    let path = home.path().join("config.json");
    std::fs::write(&path, r#"{"websocket": {"listen": "0.0.0.0:47999"}}"#).unwrap();
    let mut cfg = Config::load_from_with(&path, &ProfileSources::none()).unwrap();
    let refused = format!("{:#}", cfg.set("session.memory_mb", "6144").unwrap_err());
    assert!(refused.contains("refusing websocket.listen 0.0.0.0:47999"), "{refused}");
    assert_eq!(cfg.session.memory_mb, None, "a refused set left the value in place");
    // With the opt-in the start takes it, and so does config --set.
    cfg.websocket.as_mut().unwrap().allow_insecure_network = true;
    cfg.set("session.memory_mb", "6144").unwrap();
    assert_eq!(cfg.session.memory_mb, Some(6144));
    // WireGuard with its static settings and a well-formed peer passes; a malformed peer key,
    // which the transport's start refuses, is refused here first, naming the peer.
    cfg.transport.wireguard_static = Some(crate::wireguard::StaticConfig {
        listen: "127.0.0.1:0".parse().unwrap(),
        address: "10.77.0.1:4100".parse().unwrap(),
    });
    cfg.set("transport.wireguard", "true").unwrap();
    let mut peer: PeerConfig = serde_json::from_value(serde_json::json!({
        "url": "ssh://workstation",
        "wireguard": {"publicKey": "not-a-key", "endpoint": "127.0.0.1:51820",
                      "address": "10.77.0.2:4100"}
    }))
    .unwrap();
    cfg.peers.insert("workstation".into(), peer.clone());
    let refused = format!("{:#}", cfg.set("session.memory_mb", "8192").unwrap_err());
    assert!(refused.contains("peers.workstation.wireguard"), "{refused}");
    peer.wireguard.as_mut().unwrap().public_key =
        base64::engine::general_purpose::STANDARD.encode([7u8; 32]);
    cfg.peers.insert("workstation".into(), peer);
    cfg.set("session.memory_mb", "8192").unwrap();
}
