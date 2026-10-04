//! Bounded waits on agent hosts.

use super::*;
use std::time::Duration;

/// A wait on an agent host ran past its deadline.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostTimeout {
    /// What the daemon waited for.
    pub what: &'static str,
    pub after: Duration,
}

impl std::fmt::Display for HostTimeout {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "agent host {} did not finish within {:?}", self.what, self.after)
    }
}

impl std::error::Error for HostTimeout {}

static WATCHES: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Threads waiting for a host's death right now.
pub fn death_watches() -> usize {
    WATCHES.load(std::sync::atomic::Ordering::SeqCst)
}

/// Whether this incarnation's host is dead within `budget`. Blocks: call it
/// off the async runtime.
pub fn wait_dead_within(dir: &Path, session_id: &str, start_nonce: &str, budget: Duration) -> bool {
    let (tx, rx) = std::sync::mpsc::channel();
    let (dir, session_id, start_nonce) = (dir.to_owned(), session_id.to_owned(), start_nonce.to_owned());
    WATCHES.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    std::thread::spawn(move || {
        wait_dead(&dir, &session_id, &start_nonce);
        WATCHES.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
        let _ = tx.send(());
    });
    rx.recv_timeout(budget).is_ok()
}
