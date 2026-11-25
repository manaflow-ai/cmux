//! The holder loop's clock: the wall time in milliseconds, which the state machine is stepped
//! with, and a wait until a wall time.
//!
//! It is the wall clock on purpose. A laptop's sleep stops the monotonic clock, so a timer set
//! before the sleep fires late and the wall time it then reads has jumped: that jump is how the
//! daemon sees a wake by itself.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::watch;

/// A wait that ends at a wall time.
pub type Wait = Pin<Box<dyn Future<Output = ()> + Send>>;

/// The time the holder loop runs on.
pub trait WallClock: Send + Sync + 'static {
    /// Now, in milliseconds since the epoch.
    fn now_ms(&self) -> u64;

    /// Ends once [`WallClock::now_ms`] is `at_ms` or later.
    fn wait_until(&self, at_ms: u64) -> Wait;
}

/// The system's clock.
#[derive(Debug, Default)]
pub struct SystemClock;

impl WallClock for SystemClock {
    fn now_ms(&self) -> u64 {
        crate::store::now_ms()
    }

    fn wait_until(&self, at_ms: u64) -> Wait {
        let wait = Duration::from_millis(at_ms.saturating_sub(self.now_ms()));
        Box::pin(tokio::time::sleep(wait))
    }
}

/// A clock a test moves by hand. Time passes only in [`ManualClock::set`] and
/// [`ManualClock::advance`]; every wait that became due ends then.
#[derive(Debug)]
pub struct ManualClock {
    now: watch::Sender<u64>,
}

impl ManualClock {
    pub fn new(now_ms: u64) -> Arc<ManualClock> {
        Arc::new(ManualClock { now: watch::channel(now_ms).0 })
    }

    /// The time is `now_ms`. It may go back, as a system clock may.
    pub fn set(&self, now_ms: u64) {
        self.now.send_replace(now_ms);
    }

    pub fn advance(&self, ms: u64) {
        self.now.send_modify(|now| *now = now.saturating_add(ms));
    }
}

impl WallClock for ManualClock {
    fn now_ms(&self) -> u64 {
        *self.now.borrow()
    }

    fn wait_until(&self, at_ms: u64) -> Wait {
        let mut now = self.now.subscribe();
        Box::pin(async move {
            // A dropped clock never becomes due.
            if now.wait_for(|now| *now >= at_ms).await.is_err() {
                std::future::pending::<()>().await;
            }
        })
    }
}
