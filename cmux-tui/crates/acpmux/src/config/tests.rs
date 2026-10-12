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
