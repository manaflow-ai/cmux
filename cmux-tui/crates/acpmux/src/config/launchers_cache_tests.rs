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
