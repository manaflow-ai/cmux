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
mod tests;
