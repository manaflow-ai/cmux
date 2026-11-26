//! A state write the daemon can serve without: a failure (a full disk, an
//! I/O error) is logged and the write is tried again in the background,
//! never an exit. On huge-blue (2026-10-25) a full disk failed the
//! `daemon.pid` write while the daemon loaded (`write .../daemon.tmp-N-0: No
//! space left on device`); the daemon exited, systemd hit its start limit
//! and left acpmux down for 33 minutes. Losing one write is acceptable;
//! exiting is not.

use anyhow::Result;
use std::time::Duration;

/// The first retry's delay; each later one doubles, up to [`RETRY_MAX`].
pub(super) const RETRY_FIRST: Duration = Duration::from_secs(1);
/// The longest wait between two retries.
pub(super) const RETRY_MAX: Duration = Duration::from_secs(60);

/// Runs `write` now. When it fails, logs a warning and tries again after
/// [`RETRY_FIRST`], doubling to at most [`RETRY_MAX`], until a write
/// succeeds. Returns the retry task, None when the first write succeeded.
/// Stop condition: the first successful write; the caller aborts the task
/// at shutdown (so a late write never puts back a file the shutdown
/// removed), and the runtime ends it with the daemon. An idle daemon on a
/// healthy disk never starts one, so it adds no wakeup.
pub(super) fn write_or_retry<F>(
    what: &'static str,
    mut write: F,
) -> Option<tokio::task::JoinHandle<()>>
where
    F: FnMut() -> Result<()> + Send + 'static,
{
    let first = match write() {
        Ok(()) => return None,
        Err(e) => e,
    };
    tracing::warn!("could not write {what} ({first:#}); serving without it and trying again");
    Some(tokio::spawn(async move {
        let mut delay = RETRY_FIRST;
        let mut failures: u64 = 1;
        // A slow disk blocks this worker alone: the others take its tasks.
        // Synchronous within the task, so an abort (at the sleep) never
        // leaves a write running after the caller's join.
        let multi_thread = tokio::runtime::Handle::current().runtime_flavor()
            == tokio::runtime::RuntimeFlavor::MultiThread;
        loop {
            tokio::time::sleep(delay).await;
            let written =
                if multi_thread { tokio::task::block_in_place(&mut write) } else { write() };
            match written {
                Ok(()) => {
                    tracing::info!("wrote {what} after {failures} failed write(s)");
                    return;
                }
                Err(e) => {
                    failures += 1;
                    // One warning a minute at most once the delay is capped.
                    if delay >= RETRY_MAX || failures.is_power_of_two() {
                        tracing::warn!("still cannot write {what} ({e:#}); trying again");
                    }
                }
            }
            delay = (delay * 2).min(RETRY_MAX);
        }
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU32, Ordering};

    /// A writer that fails (ENOSPC) its first `fails` calls, counting calls.
    fn flaky(fails: u32) -> (Arc<AtomicU32>, impl FnMut() -> Result<()> + Send + 'static) {
        let calls = Arc::new(AtomicU32::new(0));
        let seen = calls.clone();
        let write = move || {
            let n = seen.fetch_add(1, Ordering::SeqCst);
            if n < fails {
                Err(anyhow::Error::new(std::io::Error::from_raw_os_error(libc::ENOSPC))
                    .context("write daemon.tmp-1-0"))
            } else {
                Ok(())
            }
        };
        (calls, write)
    }

    #[tokio::test(start_paused = true)]
    async fn a_good_write_starts_no_retry() {
        let (calls, write) = flaky(0);
        assert!(write_or_retry("daemon.pid", write).is_none());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn a_failed_write_returns_at_once_and_is_retried_until_it_succeeds() {
        // Full for the first write and the next four retries.
        let (calls, write) = flaky(5);
        let t0 = tokio::time::Instant::now();
        let task = write_or_retry("daemon.pid", write).expect("a retry task");
        // The caller got control back at once: the daemon goes on serving.
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        // Retries at 1, 3, 7, 15 and 31 s (1 + 2 + 4 + 8 + 16).
        for (at, want) in [(1, 2), (3, 3), (7, 4), (15, 5)] {
            tokio::time::sleep_until(t0 + Duration::from_secs(at) + EPS).await;
            assert_eq!(calls.load(Ordering::SeqCst), want, "at {at} s");
        }
        tokio::time::sleep_until(t0 + Duration::from_secs(31) + EPS).await;
        assert_eq!(calls.load(Ordering::SeqCst), 6, "the sixth write succeeded");
        assert!(task.is_finished(), "a success ends the retries");
    }

    #[tokio::test(start_paused = true)]
    async fn the_delay_stops_growing_at_a_minute() {
        let (calls, write) = flaky(u32::MAX);
        let t0 = tokio::time::Instant::now();
        let task = write_or_retry("daemon.pid", write).expect("a retry task");
        // 1 + 2 + 4 + 8 + 16 + 32 = 63 s, then every 60 s.
        tokio::time::sleep_until(t0 + Duration::from_secs(63) + EPS).await;
        assert_eq!(calls.load(Ordering::SeqCst), 7);
        tokio::time::sleep_until(t0 + Duration::from_secs(123) + EPS).await;
        assert_eq!(calls.load(Ordering::SeqCst), 8);
        tokio::time::sleep_until(t0 + Duration::from_secs(183) + EPS).await;
        assert_eq!(calls.load(Ordering::SeqCst), 9);
        // An aborted task (the daemon's shutdown) writes nothing more.
        task.abort();
        tokio::time::sleep_until(t0 + Duration::from_secs(600)).await;
        assert_eq!(calls.load(Ordering::SeqCst), 9);
    }

    const EPS: Duration = Duration::from_millis(10);
}
