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

fn on_path(found: &'static [&'static str]) -> impl Fn(&str) -> Option<String> {
    move |bin: &str| found.contains(&bin).then(|| format!("/u/bin/{bin}"))
}

const ACPX: &str = r#"{"agents": {
    "claude": {"argv": ["/u/.local/share/cmux-acp/current/bin/claude-acp"]},
    "claude-sr": {"argv": ["/u/.local/share/cmux-acp/current/bin/claude-acp"]},
    "codex": {"argv": ["/u/.local/share/cmux-acp/current/bin/codex-acp"]}
}}"#;

#[test]
fn acpx_never_takes_the_reserved_claude_names_from_acpmux_s_adapter() {
    let found = discover_harnesses_from(Some(ACPX), &on_path(&["claude", "sr", "codex-acp"]));
    assert_eq!(found["claude"].kind, HarnessKind::ClaudeStdio);
    assert_eq!(found["claude"].argv, vec!["/u/bin/claude".to_owned()]);
    assert_eq!(found["claude-sr"].kind, HarnessKind::ClaudeStdio);
    assert_eq!(
        found["claude-sr"].argv,
        vec!["/u/bin/sr".to_owned(), "claude".into(), "proxy".into()]
    );
    // Any other name keeps its ~/.acpx entry.
    assert_eq!(found["codex"].kind, HarnessKind::Acp);
    assert_eq!(found["codex"].argv[0], "/u/.local/share/cmux-acp/current/bin/codex-acp");
    // Without the binary on PATH the ~/.acpx entry stays (kind acp).
    let found = discover_harnesses_from(Some(ACPX), &on_path(&[]));
    assert_eq!(found["claude"].kind, HarnessKind::Acp);
}

#[test]
fn explicit_acpmux_config_wins_over_acpx_and_path() {
    let mut cfg = Config::default();
    cfg.harnesses.insert("claude".into(), prof(HarnessKind::Acp, &["/opt/mine/claude-acp"]));
    cfg.join_discovered(discover_harnesses_from(Some(ACPX), &on_path(&["claude", "sr"])));
    assert_eq!(cfg.harnesses["claude"].argv, vec!["/opt/mine/claude-acp".to_owned()]);
    assert!(!cfg.discovered.contains("claude"));
    assert_eq!(cfg.harnesses["claude-sr"].kind, HarnessKind::ClaudeStdio);
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

#[test]
fn grok_on_path_is_a_harness_through_its_own_acp_mode() {
    let found = discover_harnesses_from(None, &on_path(&["grok"]));
    let grok = &found["grok"];
    assert_eq!(grok.kind, HarnessKind::Acp);
    assert_eq!(grok.argv, vec!["/u/bin/grok".to_owned(), "agent".into(), "stdio".into()]);
    assert_eq!(super::derive_family("grok", grok), "grok");
}

#[test]
fn cursor_agent_on_path_is_a_harness_through_its_own_acp_mode() {
    let found = discover_harnesses_from(None, &on_path(&["cursor-agent"]));
    let cursor = &found["cursor"];
    assert_eq!(cursor.kind, HarnessKind::Acp);
    assert_eq!(cursor.argv, vec!["/u/bin/cursor-agent".to_owned(), "acp".into()]);
    assert_eq!(super::derive_family("cursor", cursor), "cursor");
    // A bare `agent` is Cursor only when it resolves into a Cursor install.
    assert!(!discover_harnesses_from(None, &on_path(&["agent"])).contains_key("cursor"));
}

#[cfg(unix)]
#[test]
fn cursor_s_agent_launcher_counts_when_it_resolves_into_cursor_agent() {
    let dir = std::env::temp_dir().join(format!("acpmux-cursor-{}", std::process::id()));
    let install = dir.join("share/cursor-agent/versions/1/cursor-agent");
    std::fs::create_dir_all(install.parent().unwrap()).unwrap();
    std::fs::write(&install, "").unwrap();
    let link = dir.join("agent");
    let _ = std::fs::remove_file(&link);
    std::os::unix::fs::symlink(&install, &link).unwrap();
    let link_text = link.to_string_lossy().into_owned();
    let found = discover_harnesses_from(None, &move |bin: &str| {
        (bin == "agent").then(|| link_text.clone())
    });
    assert_eq!(found["cursor"].argv, vec![link.to_string_lossy().into_owned(), "acp".into()]);
    let _ = std::fs::remove_dir_all(&dir);
}
