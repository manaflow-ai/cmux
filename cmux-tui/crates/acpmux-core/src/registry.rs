//! Per-chat hydration and eviction.
//!
//! The registry is deliberately small: it maps ids to actor mailboxes and never
//! opens a book or performs a read on the caller's runtime worker. A cold chat
//! is hydrated on its first lookup; removing an entry closes and joins only that
//! actor.
//!
//! - **A request for chat X waits only on chat X.** The map's lock is held for a lookup and
//!   nothing else: each chat has a slot of its own, and its actor is started and joined under
//!   the slot's lock, never the map's. So the tee's drain and the background pass hydrate many
//!   chats at once and none waits behind another's start.
//! - **A purge forgets a chat** ([`Registry::forget`]): its actor is closed and joined, and no
//!   hydrate starts one again until [`Registry::unforget`], which the purge calls once the chat's
//!   directory is gone. So no actor writes into a directory a purge removed.
//! - **Two permits for history** ([`HistoryPermits`]): every actor this registry starts shares
//!   them.

use crate::chat::{ChatActor, ChatConfig, ChatHandle, HistoryPermits};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard};

/// How many actors read history at once.
pub const HISTORY_PERMITS: usize = 2;

#[derive(Default)]
struct Slot {
    state: Mutex<SlotState>,
}

#[derive(Default)]
struct SlotState {
    actor: Option<ChatActor>,
    /// Taken out of the map (an evict, a forget): a hydrate that found it goes to the map again.
    removed: bool,
}

impl Slot {
    fn lock(&self) -> MutexGuard<'_, SlotState> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

#[derive(Default)]
struct Entries {
    slots: HashMap<String, Arc<Slot>>,
    /// Chats a purge is removing: none is hydrated.
    forgotten: HashSet<String>,
}

#[derive(Clone)]
pub struct Registry {
    entries: Arc<Mutex<Entries>>,
    history: Arc<HistoryPermits>,
}

impl Default for Registry {
    fn default() -> Self {
        Self::new()
    }
}

impl Registry {
    pub fn new() -> Self {
        Self { entries: Arc::default(), history: Arc::new(HistoryPermits::new(HISTORY_PERMITS)) }
    }

    /// The permits every actor this registry starts takes to read history.
    pub fn history(&self) -> &Arc<HistoryPermits> {
        &self.history
    }

    fn entries(&self) -> MutexGuard<'_, Entries> {
        self.entries.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Returns the existing mailbox or starts one actor for this chat; None for a chat a purge
    /// forgot.
    pub fn hydrate(&self, config: ChatConfig) -> Option<ChatHandle> {
        self.start(config).map(|(handle, _)| handle)
    }

    /// [`Self::hydrate`], and whether this call started the actor.
    pub fn start(&self, mut config: ChatConfig) -> Option<(ChatHandle, bool)> {
        if config.history.is_none() {
            config.history = Some(self.history.clone());
        }
        loop {
            let slot = {
                let mut entries = self.entries();
                if entries.forgotten.contains(&config.id) {
                    return None;
                }
                entries.slots.entry(config.id.clone()).or_default().clone()
            };
            let mut state = slot.lock();
            if state.removed {
                continue;
            }
            if let Some(actor) = &state.actor
                && !actor.is_finished()
            {
                return Some((actor.handle.clone(), false));
            }
            let dead = state.actor.take();
            // Spawning only starts a worker; the book is opened on its thread.
            let actor = ChatActor::spawn(config);
            let handle = actor.handle.clone();
            state.actor = Some(actor);
            drop(state);
            if let Some(dead) = dead {
                dead.join();
            }
            return Some((handle, true));
        }
    }

    pub fn get(&self, id: &str) -> Option<ChatHandle> {
        let slot = self.entries().slots.get(id).cloned()?;
        let mut state = slot.lock();
        if state.actor.as_ref().is_some_and(ChatActor::is_finished) {
            let dead = state.actor.take();
            drop(state);
            if let Some(dead) = dead {
                dead.join();
            }
            return None;
        }
        state.actor.as_ref().map(|actor| actor.handle.clone())
    }

    /// Takes the chat's slot out of the map and joins its actor, if one runs.
    fn remove(&self, slot: Option<Arc<Slot>>) -> bool {
        let Some(slot) = slot else { return false };
        let actor = {
            let mut state = slot.lock();
            state.removed = true;
            state.actor.take()
        };
        match actor {
            Some(actor) => {
                actor.join();
                true
            }
            None => false,
        }
    }

    /// Closes one hydrated chat and forgets it. The next lookup hydrates it again
    /// from its checkpoint.
    pub fn evict(&self, id: &str) -> bool {
        let slot = self.entries().slots.remove(id);
        self.remove(slot)
    }

    /// A purge's first step: closes and joins the chat's actor, and no hydrate starts one until
    /// [`Self::unforget`]. Blocking: it waits for the actor's thread.
    pub fn forget(&self, id: &str) -> bool {
        let slot = {
            let mut entries = self.entries();
            entries.forgotten.insert(id.to_owned());
            entries.slots.remove(id)
        };
        self.remove(slot)
    }

    /// A purge's last step, once the chat's directory is gone: a chat that comes back under the
    /// id hydrates again.
    pub fn unforget(&self, id: &str) {
        self.entries().forgotten.remove(id);
    }

    pub fn len(&self) -> usize {
        self.entries().slots.len()
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
}
