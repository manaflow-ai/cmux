//! An injected monotonic clock for timers that belong to a lifecycle (the
//! warm adapter idle exit). Runtime code waits on `Clock::sleep_until`, never
//! on a bare tokio sleep, so tests drive time with `ManualClock` instead of
//! waiting for it.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

/// A future a clock resolves at a deadline.
pub type Sleep = Pin<Box<dyn Future<Output = ()> + Send>>;

/// Monotonic time as the offset from the clock's own origin.
pub trait Clock: Send + Sync + 'static {
    fn now(&self) -> Duration;
    /// Resolves once `now() >= at`. Dropping it cancels the wait.
    fn sleep_until(&self, at: Duration) -> Sleep;
}

/// The runtime clock: tokio's monotonic time.
pub struct TokioClock {
    origin: tokio::time::Instant,
}

impl TokioClock {
    pub fn new() -> Arc<Self> {
        Arc::new(Self { origin: tokio::time::Instant::now() })
    }
}

impl Clock for TokioClock {
    fn now(&self) -> Duration {
        self.origin.elapsed()
    }

    fn sleep_until(&self, at: Duration) -> Sleep {
        Box::pin(tokio::time::sleep_until(self.origin + at))
    }
}

/// A clock that moves only when a test calls `advance`.
pub struct ManualClock {
    now: tokio::sync::watch::Sender<Duration>,
}

impl ManualClock {
    pub fn new() -> Arc<Self> {
        Arc::new(Self { now: tokio::sync::watch::channel(Duration::ZERO).0 })
    }

    pub fn advance(&self, by: Duration) {
        self.now.send_modify(|now| *now += by);
    }
}

impl Clock for ManualClock {
    fn now(&self) -> Duration {
        *self.now.borrow()
    }

    fn sleep_until(&self, at: Duration) -> Sleep {
        let mut rx = self.now.subscribe();
        Box::pin(async move {
            // The sender lives as long as the clock; a dropped clock never fires.
            if rx.wait_for(|now| *now >= at).await.is_err() {
                std::future::pending::<()>().await;
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn manual_clock_fires_only_when_advanced_past_the_deadline() {
        let clock = ManualClock::new();
        let mut sleep = clock.sleep_until(Duration::from_secs(10));
        clock.advance(Duration::from_secs(9));
        assert!(futures::poll!(&mut sleep).is_pending());
        clock.advance(Duration::from_secs(1));
        sleep.await;
        assert_eq!(clock.now(), Duration::from_secs(10));
    }
}
