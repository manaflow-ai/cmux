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
    let old = dir.join("sr-old");
    std::fs::write(
        &old,
        "#!/bin/sh\necho 'subrouter: unknown command: sr claude proxy' >&2\nexit 1\n",
    )
    .unwrap();
    let broken = dir.join("sr-broken");
    std::fs::write(&broken, "#!/bin/sh\necho 'subrouter: prepare shared Claude proxy history: file exists' >&2\nexit 0\n").unwrap();
    let good = dir.join("sr-good");
    std::fs::write(&good, "#!/bin/sh\necho '2.1.275 (Claude Code)'\n").unwrap();
    for p in [&old, &broken, &good] {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
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
    verify_launchers(&mut cfg);
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
fn the_launch_credential_never_reaches_the_daemon_or_an_agent() {
    let mut cmd = std::process::Command::new("true");
    cmd.env(LAUNCH_CREDENTIAL_ENV, "cmuxlc1.k.c.m").env("KEPT", "1");
    scrub_launch_credential(&mut cmd);
    let envs: std::collections::HashMap<_, _> =
        cmd.get_envs().map(|(k, v)| (k.to_owned(), v.map(|v| v.to_owned()))).collect();
    assert_eq!(envs.get(std::ffi::OsStr::new(LAUNCH_CREDENTIAL_ENV)), Some(&None));
    assert_eq!(envs.get(std::ffi::OsStr::new("KEPT")), Some(&Some(std::ffi::OsString::from("1"))));
}
