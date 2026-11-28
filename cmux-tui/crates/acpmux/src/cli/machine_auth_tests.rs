use super::*;

fn plane() -> BTreeMap<String, String> {
    BTreeMap::from([
        ("OPENAI_BASE_URL".into(), "https://coderouter.cmux.internal/v1".into()),
        ("OPENAI_API_KEY".into(), PLACEHOLDER.into()),
        ("CMUX_CODEROUTER_URL".into(), "https://coderouter.cmux.internal".into()),
        ("ANTHROPIC_BASE_URL".into(), "https://coderouter.cmux.internal".into()),
        ("ANTHROPIC_API_KEY".into(), PLACEHOLDER.into()),
    ])
}

fn temp_home() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-machine-auth-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn the_daemon_record_keeps_no_key_value_and_belongs_to_its_pid() {
    let env = BTreeMap::from([
        ("ANTHROPIC_BASE_URL", "https://user:pw@coderouter.cmux.internal/v1?x=1"),
        ("ANTHROPIC_API_KEY", PLACEHOLDER),
        ("OPENAI_API_KEY", "sk-real-secret"),
        ("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat-secret"),
        ("CODEX_API_KEY", ""),
    ]);
    let v = record_json(42, &|k| env.get(k).map(|v| (*v).to_owned()));
    let text = v.to_string();
    assert!(!text.contains("secret") && !text.contains("pw@"), "{text}");
    assert_eq!(v["env"]["ANTHROPIC_BASE_URL"], "https://coderouter.cmux.internal/v1");
    assert_eq!(v["env"]["ANTHROPIC_API_KEY"], PLACEHOLDER);
    assert_eq!(v["env"]["OPENAI_API_KEY"], SET);
    assert_eq!(v["env"]["CLAUDE_CODE_OAUTH_TOKEN"], SET);
    assert!(v["env"].get("CODEX_API_KEY").is_none());

    let home = temp_home();
    std::fs::write(home.join(ENV_FILE), v.to_string()).unwrap();
    std::fs::write(home.join("daemon.lock"), "42\n").unwrap();
    let (pid, read) = read_daemon_env(&home).unwrap();
    assert_eq!(pid, 42);
    let r = report(true, Ok(plane()), Some((pid, read)), &home, Vec::new());
    assert_eq!(r["agents"]["codex"]["key"], "other");
    assert_eq!(r["holds_credential"], true);
    // An earlier daemon's record is not this daemon's.
    std::fs::write(home.join("daemon.lock"), "43\n").unwrap();
    assert!(read_daemon_env(&home).is_none());
    let _ = std::fs::remove_dir_all(&home);
}

/// Lane F's finding: a daemon with no route in its env still gives its agents the edge.
#[test]
fn a_bare_daemon_env_reports_the_machine_route() {
    let home = temp_home();
    let v = report(true, Ok(plane()), Some((7, BTreeMap::new())), &home, Vec::new());
    assert_eq!(v["agents"]["claude"]["base_url"], "https://coderouter.cmux.internal");
    assert_eq!(v["agents"]["claude"]["base_url_source"], "model_plane");
    assert_eq!(v["agents"]["claude"]["key"], "placeholder");
    assert_eq!(v["agents"]["codex"]["edge_routed"], true);
    assert_eq!(v["holds_credential"], false);
    assert_eq!(v["ok"], true);
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn a_login_file_or_a_real_key_is_reported_by_name_only() {
    let home = temp_home();
    std::fs::create_dir_all(home.join(".codex")).unwrap();
    std::fs::write(home.join(".codex/auth.json"), "{\"tokens\":{\"refresh_token\":\"rt-secret\"}}")
        .unwrap();
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    std::fs::write(
        home.join(".claude/settings.json"),
        "{\"env\":{\"CLAUDE_CODE_OAUTH_TOKEN\":\"sk-ant-oat-secret\"}}",
    )
    .unwrap();
    let daemon = BTreeMap::from([("ANTHROPIC_API_KEY".to_owned(), "sk-ant-api-secret".to_owned())]);
    let v = report(true, Ok(plane()), Some((7, daemon)), &home, Vec::new());
    let text = v.to_string();
    for secret in ["rt-secret", "sk-ant-oat-secret", "sk-ant-api-secret"] {
        assert!(!text.contains(secret), "{text}");
    }
    assert_eq!(v["agents"]["claude"]["key"], "other");
    assert_eq!(v["holds_credential"], true);
    assert_eq!(v["login_files"].as_array().unwrap().len(), 2);
    assert_eq!(v["ok"], false);
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn no_daemon_no_file_or_another_endpoint_is_not_ok() {
    let home = temp_home();
    assert_eq!(report(true, Ok(plane()), None, &home, Vec::new())["ok"], false);
    let missing = report(
        true,
        Err(cloud_model_plane::Problem::Missing),
        Some((7, BTreeMap::new())),
        &home,
        Vec::new(),
    );
    assert_eq!(missing["model_plane"]["state"], "missing");
    assert_eq!(missing["agents"]["claude"]["base_url_source"], "missing");
    let own = BTreeMap::from([(
        "ANTHROPIC_BASE_URL".to_owned(),
        "https://user:pw@api.example.com/x?k=1".to_owned(),
    )]);
    let v = report(true, Ok(plane()), Some((7, own)), &home, Vec::new());
    assert_eq!(v["agents"]["claude"]["base_url"], "https://api.example.com/x");
    assert_eq!(v["agents"]["claude"]["edge_routed"], false);
    assert_eq!(v["ok"], false);
    let _ = std::fs::remove_dir_all(&home);
}
