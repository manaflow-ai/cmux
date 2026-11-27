use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

#[test]
fn launcher_cache_keeps_parallel_successes_and_only_current_versions() {
    let dir = tempfile::tempdir().unwrap();
    let cache = dir.path().join("checks.json");
    let mut cfg = Config::default();
    cfg.harnesses.clear();
    for name in ["first", "second"] {
        let binary = dir.path().join(name);
        std::fs::write(&binary, "version one").unwrap();
        let profile = serde_json::from_value(serde_json::json!({
            "argv": [binary, "claude", "proxy"]
        }))
        .unwrap();
        cfg.harnesses.insert(name.into(), profile);
    }
    let calls = AtomicUsize::new(0);
    let probe = |_: &[String]| {
        calls.fetch_add(1, Ordering::Relaxed);
        Ok(())
    };
    verify_launchers_cached(&mut cfg, None, &cache, &probe);
    assert_eq!(calls.load(Ordering::Relaxed), 2);
    verify_launchers_cached(&mut cfg, None, &cache, &probe);
    assert_eq!(calls.load(Ordering::Relaxed), 2, "warm launch reran a successful probe");
    std::fs::write(dir.path().join("first"), "version two is a different size").unwrap();
    verify_launchers_cached(&mut cfg, None, &cache, &probe);
    assert_eq!(calls.load(Ordering::Relaxed), 3, "only the changed binary is reprobed");
    cfg.harnesses.remove("second");
    verify_launchers_cached(&mut cfg, None, &cache, &probe);
    let keys: std::collections::BTreeSet<String> =
        serde_json::from_slice(&std::fs::read(cache).unwrap()).unwrap();
    assert_eq!(keys.len(), 1, "old versions and removed launchers grew the cache");
    assert_eq!(calls.load(Ordering::Relaxed), 3);
}

/// A systemd user daemon's PATH lists no `~/.local/bin`, where lane VMs install `lane-gh` and
/// `cmux-ci`: the send relay's bare `lane-gh` is found there (gcp-agent-lane-13, 2026-11-21:
/// "cannot run the send relay \"lane-gh\""). PATH still wins, and a path or a missing name
/// comes back as given.
#[cfg(unix)]
#[test]
fn a_bare_relay_program_is_found_in_the_home_bins_the_daemon_path_lacks() {
    use std::os::unix::fs::PermissionsExt as _;
    let home = tempfile::tempdir().unwrap();
    let on_path = tempfile::tempdir().unwrap();
    let exe = |p: &std::path::Path| {
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o755)).unwrap();
    };
    let local = home.path().join(".local/bin/lane-gh");
    exe(&local);
    let cmux_bin = home.path().join(".cmux/bin/cmux-ci");
    exe(&cmux_bin);
    let system = std::ffi::OsString::from("/usr/bin:/bin");
    assert_eq!(user_program_in(&system, Some(home.path()), "lane-gh"), local);
    assert_eq!(user_program_in(&system, Some(home.path()), "cmux-ci"), cmux_bin);
    let earlier = on_path.path().join("lane-gh");
    exe(&earlier);
    assert_eq!(user_program_in(on_path.path().as_os_str(), Some(home.path()), "lane-gh"), earlier);
    assert_eq!(
        user_program_in(&system, Some(home.path()), "no-such-relay"),
        std::path::PathBuf::from("no-such-relay")
    );
    assert_eq!(super::user_program("/opt/x/lane-gh"), std::path::PathBuf::from("/opt/x/lane-gh"));
}
