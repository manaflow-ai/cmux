//! Per-chat hydration and eviction.
//!
//! The registry is deliberately small: it maps ids to actor mailboxes and never
//! opens a book or performs a read on the caller's runtime worker. A cold chat
//! is hydrated on its first lookup; removing an entry closes and joins only that
//! actor.

use crate::chat::{ChatActor, ChatConfig, ChatHandle};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

struct Entry {
    actor: ChatActor,
}

#[derive(Clone, Default)]
pub struct Registry {
    entries: Arc<Mutex<HashMap<String, Entry>>>,
}

impl Registry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns the existing mailbox or starts one actor for this chat.
    pub fn hydrate(&self, config: ChatConfig) -> ChatHandle {
        let id = config.id.clone();
        let mut entries = self.entries.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(entry) = entries.get(&id) {
            return entry.actor.handle.clone();
        }
        let actor = ChatActor::spawn(config);
        let handle = actor.handle.clone();
        entries.insert(id, Entry { actor });
        handle
    }

    pub fn get(&self, id: &str) -> Option<ChatHandle> {
        self.entries
            .lock()
            .ok()
            .and_then(|entries| entries.get(id).map(|entry| entry.actor.handle.clone()))
    }

    /// Closes one hydrated chat and forgets it. The next lookup hydrates it again
    /// from its checkpoint.
    pub fn evict(&self, id: &str) -> bool {
        let entry = self.entries.lock().ok().and_then(|mut entries| entries.remove(id));
        if let Some(entry) = entry {
            entry.actor.join();
            true
        } else {
            false
        }
    }

    pub fn len(&self) -> usize {
        self.entries.lock().map(|entries| entries.len()).unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[cfg(test)]
mod tests {
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
        let config = ChatConfig::new("chat", dir.path(), Harness::V1).with_source_factory(
            Arc::new(move || {
                crate::chat::source::FileSource::open(&source_path)
                    .map(|source| Box::new(source) as Box<dyn crate::chat::source::RawSource>)
            }),
        );
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
}
