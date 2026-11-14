use super::*;
use acpmux_book::translate::Harness;
use std::sync::Arc;

#[test]
fn hydrate_reuses_one_actor_and_evicts_it() {
    let dir = tempfile::tempdir().unwrap();
    let registry = Registry::new();
    let source_path = dir.path().join("source.ndjson");
    std::fs::write(
        &source_path,
        br#"{"kind":"prompt","id":"p1","text":"hello"}
"#,
    )
    .unwrap();
    let source_path = Arc::new(source_path);
    let config =
        ChatConfig::new("chat", dir.path(), Harness::V1).with_source_factory(Arc::new(move || {
            crate::chat::source::FileSource::open(&source_path)
                .map(|source| Box::new(source) as Box<dyn crate::chat::source::RawSource>)
        }));
    let first = registry.hydrate(config.clone());
    let second = registry.hydrate(config);
    assert_eq!(registry.len(), 1);
    assert!(registry.get("chat").is_some());
    assert!(first.wake().is_ok());
    drop(second);
    assert!(registry.evict("chat"));
    assert!(registry.is_empty());
    assert!(registry.get("chat").is_none());
}
