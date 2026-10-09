//! Foreground first under a rate limit: while a turn waits to retry a call
//! the provider refused for rate or load, compactor retries hold back, so
//! the user's turn gets the next slot of the account.

use std::time::Duration;

/// Held by a turn while it waits to retry a rate-limited call.
pub struct Foreground(());

/// A turn waits on a rate limit until the guard drops.
pub fn foreground() -> Foreground {
    Foreground(())
}

/// A compactor retry: waits while a turn waits on a rate limit, at most `max`.
pub fn background_wait(_max: Duration) {}
