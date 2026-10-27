//! Single flight for requests that share a cached prefix (the Unii
//! baseline's `AskAI.wait`/`lead`): while one request (the leader) still
//! writes a prefix to the prompt cache, a parallel request with the same
//! prefix waits until the leader's response begins (the entry is written
//! then), and reads it instead of writing it a second time.
//!
//! A request's keys chain a hash over its seed (route, model, system text)
//! and each of its blocks up to its last cache mark, so a request also
//! waits for a leader that writes a shorter prefix of its own.

use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

use serde_json::Value;

/// The longest a request waits for a leader: a leader whose response never
/// begins (a stuck harness) does not hold the others longer.
pub const MAX_WAIT: Duration = Duration::from_secs(60);

#[derive(Clone, Copy, Debug)]
enum Entry {
    /// A leader writes this prefix now.
    Pending,
    /// The prefix is cached until then.
    Cached(Instant),
}

/// The prefixes being written and the ones cached, by key.
#[derive(Debug, Default)]
pub struct SingleFlight {
    entries: Mutex<HashMap<u64, Entry>>,
    changed: Condvar,
}

/// A request's place in the flight: the leader of its prefix (call
/// [`Flight::begun`] once its response begins) or a reader of a cached one.
/// Dropping a leader before it began (the request failed) lets the next
/// request lead.
#[derive(Debug)]
pub struct Flight<'a> {
    flight: &'a SingleFlight,
    lead: Option<u64>,
    life: Duration,
    begun: std::sync::atomic::AtomicBool,
}

/// The chained keys of a request: one per block up to and including the
/// last block with a `cache_control` mark, each over the seed and every
/// block before it. Empty when no block is marked (nothing is cached).
pub fn keys(seed: &str, blocks: &[Value]) -> Vec<u64> {
    let Some(last) = blocks
        .iter()
        .rposition(|b| b.get("cache_control").is_some())
    else {
        return Vec::new();
    };
    let mut h = std::collections::hash_map::DefaultHasher::new();
    seed.hash(&mut h);
    blocks
        .iter()
        .take(last + 1)
        .map(|b| {
            // The text alone: the mark's own shape does not change the prefix.
            b.get("text")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .hash(&mut h);
            h.finish()
        })
        .collect()
}

impl SingleFlight {
    pub fn new() -> SingleFlight {
        SingleFlight::default()
    }

    /// Waits while a leader writes any prefix in `keys` (at most `max_wait`),
    /// then joins: a reader when the whole prefix is cached, else the leader
    /// of `keys`' last key. A cache entry lives `life` after its response
    /// began.
    pub fn wait(&self, keys: &[u64], life: Duration, max_wait: Duration) -> Flight<'_> {
        let deadline = Instant::now() + max_wait;
        let mut entries = self
            .entries
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let now = Instant::now();
        entries.retain(|_, e| match e {
            Entry::Pending => true,
            Entry::Cached(until) => *until > now,
        });
        loop {
            let pending = keys
                .iter()
                .any(|k| matches!(entries.get(k), Some(Entry::Pending)));
            let left = deadline.saturating_duration_since(Instant::now());
            if !pending || left.is_zero() {
                break;
            }
            entries = self
                .changed
                .wait_timeout(entries, left)
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .0;
        }
        let lead = keys.last().copied().filter(|last| {
            !matches!(entries.get(last), Some(Entry::Cached(until)) if *until > Instant::now())
        });
        if let Some(key) = lead {
            entries.insert(key, Entry::Pending);
        }
        Flight {
            flight: self,
            lead,
            life,
            begun: Default::default(),
        }
    }

    fn settle(&self, key: u64, entry: Option<Entry>) {
        let mut entries = self
            .entries
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        match entry {
            Some(e) => entries.insert(key, e),
            None => entries.remove(&key),
        };
        drop(entries);
        self.changed.notify_all();
    }
}

impl Flight<'_> {
    /// The response began: the prefix is cached, and the requests waiting
    /// for it go on. Once; later calls do nothing.
    pub fn begun(&self) {
        if let Some(key) = self.lead
            && !self.begun.swap(true, std::sync::atomic::Ordering::SeqCst)
        {
            self.flight
                .settle(key, Some(Entry::Cached(Instant::now() + self.life)));
        }
    }
}

impl Drop for Flight<'_> {
    fn drop(&mut self) {
        if let Some(key) = self.lead
            && !self.begun.load(std::sync::atomic::Ordering::SeqCst)
        {
            self.flight.settle(key, None);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn marked(texts: &[&str]) -> Vec<Value> {
        let mut blocks: Vec<Value> = texts
            .iter()
            .map(|t| json!({"type": "text", "text": t}))
            .collect();
        if let Some(last) = blocks.last_mut() {
            last["cache_control"] = json!({"type": "ephemeral"});
        }
        blocks
    }

    #[test]
    fn keys_chain_up_to_the_last_mark_and_none_without_one() {
        let a = keys("s", &marked(&["x", "y"]));
        let b = keys("s", &marked(&["x", "y", "z"]));
        assert_eq!(a.len(), 2);
        assert_eq!(&b[..2], &a[..]);
        assert!(keys("s", &[json!({"type": "text", "text": "x"})]).is_empty());
        assert_ne!(keys("t", &marked(&["x"])), keys("s", &marked(&["x"])));
    }

    #[test]
    fn a_cached_prefix_is_read_and_a_dropped_leader_frees_it() {
        let f = SingleFlight::new();
        let k = keys("s", &marked(&["x"]));
        let lead = f.wait(&k, Duration::from_secs(60), Duration::ZERO);
        assert!(lead.lead.is_some());
        drop(lead);
        let lead = f.wait(&k, Duration::from_secs(60), Duration::ZERO);
        assert!(lead.lead.is_some(), "a failed leader left the key pending");
        lead.begun();
        drop(lead);
        assert!(
            f.wait(&k, Duration::from_secs(60), Duration::ZERO)
                .lead
                .is_none()
        );
    }
}
