//! Foreground first under a rate limit: while a turn waits to retry a call
//! the provider refused for rate or load, compactor retries hold back, so
//! the user's turn gets the next slot of the account.

use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

static WAITING: Mutex<usize> = Mutex::new(0);
static DONE: Condvar = Condvar::new();

/// Held by a turn while it waits to retry a rate-limited call.
pub struct Foreground(());

/// A turn waits on a rate limit until the guard drops.
pub fn foreground() -> Foreground {
    *WAITING
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) += 1;
    Foreground(())
}

impl Drop for Foreground {
    fn drop(&mut self) {
        let mut n = WAITING
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        *n = n.saturating_sub(1);
        drop(n);
        DONE.notify_all();
    }
}

/// A compactor retry: waits while a turn waits on a rate limit, at most `max`.
pub fn background_wait(max: Duration) {
    let end = Instant::now() + max;
    let mut n = WAITING
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    while *n > 0 {
        let left = end.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return;
        }
        n = DONE
            .wait_timeout(n, left)
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .0;
    }
}
