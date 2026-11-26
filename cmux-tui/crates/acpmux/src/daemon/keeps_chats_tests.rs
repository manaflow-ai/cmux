use super::*;
use crate::config::StoreMode;

fn hub(mode: StoreMode, dir: &std::path::Path) -> std::sync::Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = mode;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    let hub = Hub::new(cfg, store);
    // What `run` does with the default environment (no `ACPMUX_AGENT_HOSTS=0`).
    hub.enable_agent_hosts();
    hub
}

#[test]
fn a_memory_daemon_with_the_default_env_keeps_no_chats_across_a_stop() {
    let dir = tempfile::tempdir().unwrap();
    // `--memory`, default env: agent hosts asked for, but a memory store never runs them,
    // so the app-orphan watch must never stop it (its chats would be lost).
    let memory = hub(StoreMode::Memory, dir.path());
    assert!(!memory.agent_hosts_enabled());
    assert!(!keeps_chats_across_stop(&memory, true));
    let local = hub(StoreMode::Local, dir.path());
    assert!(keeps_chats_across_stop(&local, false));
}
