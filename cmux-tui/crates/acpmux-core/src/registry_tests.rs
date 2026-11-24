use super::*;
use acpmux_book::translate::Harness;
use std::sync::Arc;
use std::time::{Duration, Instant};

fn config(dir: &std::path::Path, id: &str) -> ChatConfig {
    let source_path = dir.join(format!("{id}.ndjson"));
    std::fs::write(
        &source_path,
        br#"{"kind":"prompt","id":"p1","text":"hello"}
"#,
    )
    .unwrap();
    let source_path = Arc::new(source_path);
    ChatConfig::new(id, dir.join(id), Harness::V1).with_source_factory(Arc::new(move || {
        crate::chat::source::FileSource::open(&source_path)
            .map(|source| Box::new(source) as Box<dyn crate::chat::source::RawSource>)
    }))
}

#[test]
fn hydrate_reuses_one_actor_and_evicts_it() {
    let dir = tempfile::tempdir().unwrap();
    let registry = Registry::new();
    let config = config(dir.path(), "chat");
    let first = registry.hydrate(config.clone()).unwrap();
    let (second, started) = registry.start(config).unwrap();
    assert!(!started, "the second hydrate finds the first actor");
    assert_eq!(registry.len(), 1);
    assert!(registry.get("chat").is_some());
    assert!(first.wake().is_ok());
    drop(second);
    assert!(registry.evict("chat"));
    assert!(registry.is_empty());
    assert!(registry.get("chat").is_none());
}

#[test]
fn a_forgotten_chat_is_not_hydrated_until_its_purge_ends() {
    let dir = tempfile::tempdir().unwrap();
    let registry = Registry::new();
    let config = config(dir.path(), "chat");
    let handle = registry.hydrate(config.clone()).unwrap();
    assert!(registry.forget("chat"), "the running actor is closed");
    assert!(registry.get("chat").is_none());
    assert!(registry.hydrate(config.clone()).is_none());
    assert!(handle.wake().is_err(), "the closed actor takes no notice");
    registry.unforget("chat");
    assert!(registry.hydrate(config).is_some());
    assert!(registry.evict("chat"));
}

#[test]
fn a_hydrate_of_one_chat_never_waits_on_another_chats_slot() {
    let dir = tempfile::tempdir().unwrap();
    let registry = Registry::new();
    // Chat a's slot is held, as a start or a join holds it.
    let slot = registry.entries().slots.entry("a".into()).or_default().clone();
    let held = slot.lock();
    let (tx, rx) = std::sync::mpsc::channel();
    let other = registry.clone();
    let b = config(dir.path(), "b");
    std::thread::spawn(move || {
        let started = Instant::now();
        let handle = other.hydrate(b);
        let _ = tx.send((handle.is_some(), started.elapsed()));
    });
    let (hydrated, took) = rx.recv_timeout(Duration::from_secs(10)).unwrap();
    assert!(hydrated && took < Duration::from_secs(5));
    drop(held);
    assert!(registry.evict("b"));
}
