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
