//! Rotation and an owned blocking compactor; the writer never awaits its I/O.
use super::*;
use acpmux_book::index::{ChangedRows, CompactionResult};
use std::time::{Duration, Instant};
use tokio::task::JoinHandle;

#[derive(Default)]
pub(super) struct Counters {
    pub failed: AtomicU64,
    pub completed: AtomicU64,
    pub duration_ns: AtomicU64,
    pub peak_active_bytes: AtomicU64,
    pub peak_excess_bytes: AtomicU64,
    pub oldest_seq: AtomicU64,
}

#[derive(Clone, Copy, Debug)]
pub struct CompactionStats {
    pub failed: u64,
    pub completed: u64,
    pub duration_ns: u64,
    pub peak_active_bytes: u64,
    pub peak_excess_bytes: u64,
}

pub(super) struct Job {
    pub handle: Option<JoinHandle<std::io::Result<CompactionResult>>>,
    pub changed: ChangedRows,
    ready: Option<Result<std::io::Result<CompactionResult>, tokio::task::JoinError>>,
    started: Instant,
    cancelled: Arc<AtomicBool>,
}

impl Job {
    pub(super) async fn wait_ready(&mut self) {
        if self.ready.is_none()
            && let Some(handle) = self.handle.as_mut()
        {
            self.ready = Some(handle.await);
            self.handle = None;
        }
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        self.cancelled.store(true, Ordering::Release);
    }
}

impl Hub {
    pub fn compaction_stats(&self) -> CompactionStats {
        let stats = &self.compaction_counters;
        CompactionStats {
            failed: stats.failed.load(Ordering::Relaxed),
            completed: stats.completed.load(Ordering::Relaxed),
            duration_ns: stats.duration_ns.load(Ordering::Relaxed),
            peak_active_bytes: stats.peak_active_bytes.load(Ordering::Relaxed),
            peak_excess_bytes: stats.peak_excess_bytes.load(Ordering::Relaxed),
        }
    }

    /// A cursor before this retained tail needs a fresh window.
    pub fn oldest_log_seq(&self) -> u64 {
        self.compaction_counters.oldest_seq.load(Ordering::Acquire)
    }
}

impl HubWriter {
    /// Called on the blocking worker after a drained batch and its group sync.
    pub(super) fn maybe_compact(&mut self) {
        let index = self.published.load_full();
        let trigger = index.disk().map_or(1024 * 1024, |disk| disk.bytes().max(1024 * 1024));
        let Some(log) = self.log.as_mut() else { return };
        self.compaction_counters.peak_active_bytes.fetch_max(log.offset(), Ordering::Relaxed);
        self.compaction_counters
            .peak_excess_bytes
            .fetch_max(log.retained_bytes().saturating_sub(trigger), Ordering::Relaxed);
        if self.compaction.is_some() || !self.retry_log.is_empty() {
            return;
        }
        if let Some(retry) = self.next_compaction {
            if Instant::now() < retry {
                return;
            }
        } else if log.offset() < trigger {
            return;
        }
        // A directly driven writer is useful to deterministic tests; asynchronous
        // compaction belongs to run(), whose blocking turns carry its runtime.
        if tokio::runtime::Handle::try_current().is_err() {
            return;
        }
        let plan = match log.rotate(index.seq()) {
            Ok(plan) => plan,
            Err(_) => {
                self.compaction_failed();
                return;
            }
        };
        let cancelled = Arc::new(AtomicBool::new(false));
        let stop = cancelled.clone();
        let handle = tokio::task::spawn_blocking(move || plan.run_cancellable(index, stop));
        self.compaction = Some(Job {
            handle: Some(handle),
            ready: None,
            changed: ChangedRows::new(),
            started: Instant::now(),
            cancelled,
        });
        self.next_compaction = None;
    }

    fn compaction_failed(&mut self) {
        self.compaction_counters.failed.fetch_add(1, Ordering::Relaxed);
        self.next_compaction = Some(Instant::now() + Duration::from_secs(1));
    }

    pub(super) async fn finish_compaction(&mut self, join: bool) {
        let ready = self.compaction.as_ref().is_some_and(|job| {
            join || job.ready.is_some() || job.handle.as_ref().is_some_and(JoinHandle::is_finished)
        });
        if !ready {
            return;
        }
        let Some(mut job) = self.compaction.take() else { return };
        job.wait_ready().await;
        let Some(result) = job.ready.take() else { return };
        match result {
            Ok(Ok(result)) => {
                self.compaction_counters.duration_ns.store(
                    job.started.elapsed().as_nanos().min(u64::MAX as u128) as u64,
                    Ordering::Relaxed,
                );
                self.compaction_counters.completed.fetch_add(1, Ordering::Relaxed);
                self.compaction_counters.failed.fetch_add(result.cleanup_errors, Ordering::Relaxed);
                if let Some(log) = self.log.as_mut() {
                    log.compacted(result.covered_generation, result.seq);
                    self.compaction_counters.oldest_seq.store(log.oldest_seq(), Ordering::Release);
                }
                let current = self.published.load_full();
                let next = current
                    .with_compacted_snapshot(result.snapshot, std::mem::take(&mut job.changed));
                self.published.store(Arc::new(next));
                self.start_hydration();
            }
            _ => self.compaction_failed(),
        }
    }
}
