//! Rotation and an owned blocking compactor; the writer never awaits its I/O.
use super::*;
use acpmux_book::index::{ChangedRows, CompactionResult};
use std::collections::VecDeque;
use std::time::{Duration, Instant};
use tokio::task::JoinHandle;

const PAGE_RETURN_MIN_EVICTED_ROWS: usize = 1024;

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

/// One snapshot epoch owns maintenance until every candidate has been visited.
/// Arrivals keep using the normal writer batch and shadow this epoch's rows.
pub(super) struct Maintenance {
    cold_keys: VecDeque<RowKey>,
    missing_hot: VecDeque<Arc<Summary>>,
    retired_shadow: Option<ChangedRows>,
    evicted_rows: usize,
    started: Instant,
    #[cfg(test)]
    cleanup_complete: bool,
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
        if self.retirement.is_some() {
            if self.next_compaction.is_none() && log.retained_bytes() >= trigger {
                self.next_compaction = Some(Instant::now());
            }
            return;
        }
        if self.compaction.is_some() || self.maintenance.is_some() || !self.retry_log.is_empty() {
            return;
        }
        if let Some(retry) = self.next_compaction {
            if Instant::now() < retry {
                return;
            }
        } else if log.retained_bytes() < trigger {
            return;
        }
        // A directly driven writer is useful to deterministic tests; asynchronous
        // compaction belongs to run(), whose blocking turns carry its runtime.
        if tokio::runtime::Handle::try_current().is_err() {
            return;
        }
        #[cfg(test)]
        let rotation_began = Instant::now();
        let plan = match log.rotate(index.seq()) {
            Ok(plan) => plan,
            Err(_) => {
                self.compaction_failed();
                return;
            }
        };
        #[cfg(test)]
        {
            self.turn_measure.rotate_ns = rotation_began.elapsed().as_nanos();
        }
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
        self.compaction_backoff = self.compaction_backoff.saturating_mul(2).clamp(1, 64);
        self.next_compaction = Some(Instant::now() + Duration::from_secs(self.compaction_backoff));
    }

    pub(super) async fn finish_compaction(&mut self, join: bool) {
        if self.retirement.as_ref().is_some_and(|handle| join || handle.is_finished())
            && let Some(handle) = self.retirement.take()
        {
            let _ = handle.await;
        }
        let ready = self.compaction.as_ref().is_some_and(|job| {
            join || job.ready.is_some() || job.handle.as_ref().is_some_and(JoinHandle::is_finished)
        });
        if !ready {
            return;
        }
        if let Some(job) = self.compaction.as_mut() {
            job.wait_ready().await;
        }
    }

    /// Installation swaps roots only; at most 256 maintenance keys are then
    /// handled by each ordinary writer turn, including idle turns.
    pub(super) fn install_compaction(&mut self) {
        if self.compaction.as_ref().is_none_or(|job| job.ready.is_none()) {
            return;
        }
        let Some(mut job) = self.compaction.take() else { return };
        let Some(result) = job.ready.take() else { return };
        match result {
            Ok(Ok(result)) => {
                if result.cleanup_errors == 0 {
                    self.compaction_backoff = 0;
                    self.next_compaction = None;
                }
                if let Some(log) = self.log.as_mut() {
                    if result.cleanup_errors == 0 {
                        log.compacted(result.covered_generation, result.seq);
                    }
                    self.compaction_counters.oldest_seq.store(log.oldest_seq(), Ordering::Release);
                }
                if result.cleanup_errors != 0 {
                    // Keep retained-byte accounting until a durable install
                    // has cleaned the covered generations; back off on error.
                    self.compaction_failed();
                }
                let current = self.published.load_full();
                #[cfg(test)]
                let overlay_began = Instant::now();
                #[cfg(test)]
                {
                    self.turn_measure.changed = job.changed.len();
                }
                let (next, retired_shadow) = current
                    .with_compacted_snapshot(result.snapshot, std::mem::take(&mut job.changed));
                #[cfg(test)]
                {
                    self.turn_measure.overlay_ns = overlay_began.elapsed().as_nanos();
                }
                self.published.store(Arc::new(next));
                self.hydration = None;
                // Only the obsolete shadow root is retired, never rebuilt maps.
                // Its last drop can visit every key, so it stays off the turn.
                // Release this last writer-local owner before handing the
                // shadow root away; otherwise the worker can finish first.
                drop(current);
                self.maintenance = Some(Maintenance {
                    cold_keys: result.cold_keys,
                    missing_hot: result.missing_hot,
                    retired_shadow: Some(retired_shadow),
                    evicted_rows: 0,
                    started: job.started,
                    #[cfg(test)]
                    cleanup_complete: result.cleanup_errors == 0,
                });
            }
            _ => self.compaction_failed(),
        }
    }
    pub(super) fn maintenance_needs_turn(&self) -> bool {
        self.maintenance.as_ref().is_some_and(|work| {
            !work.missing_hot.is_empty() || !work.cold_keys.is_empty() || self.retirement.is_none()
        })
    }

    pub(super) fn maintain_compaction(&mut self) {
        let Some(work) = self.maintenance.as_mut() else { return };
        let current = self.published.load_full();
        let mut next = current.as_ref().clone();
        for _ in 0..256 {
            if let Some(row) = work.missing_hot.pop_front() {
                next.hydrate_compacted(row);
            } else if let Some(key) = work.cold_keys.pop_front() {
                work.evicted_rows += usize::from(next.evict_compacted(&key));
            } else {
                break;
            }
            #[cfg(test)]
            {
                self.turn_measure.maintenance_keys += 1;
            }
        }
        self.published.store(Arc::new(next));
        // The current root can still own paths removed by this batch. Drop it
        // before the worker returns free pages, so the measurement includes them.
        drop(current);
        if work.missing_hot.is_empty() && work.cold_keys.is_empty() && self.retirement.is_none() {
            if let Some(shadow) = work.retired_shadow.take() {
                let evicted = work.evicted_rows;
                let cold_keys = std::mem::take(&mut work.cold_keys);
                let missing_hot = std::mem::take(&mut work.missing_hot);
                self.retirement = Some(tokio::task::spawn_blocking(move || {
                    drop((cold_keys, missing_hot));
                    retire_shadow(shadow, evicted);
                }));
                return;
            }
            self.compaction_counters.duration_ns.store(
                work.started.elapsed().as_nanos().min(u64::MAX as u128) as u64,
                Ordering::Relaxed,
            );
            #[cfg(test)]
            if work.cleanup_complete
                && let Some(log) = self.log.as_ref()
            {
                assert_eq!(log.retained_bytes(), log.offset());
                self.turn_measure.completed_log_bytes = Some(log.offset());
            }
            self.compaction_counters.completed.fetch_add(1, Ordering::Relaxed);
            self.maintenance = None;
        }
    }
}

fn retire_shadow(shadow: ChangedRows, evicted: usize) {
    drop(shadow);
    #[cfg(test)]
    let before = std::env::var("V2_GATE_MODE")
        .ok()
        .filter(|mode| mode.starts_with("evict-") || mode.starts_with("attrib-"))
        .map(|_| disk_gates::rss_fields_kb());
    #[cfg(test)]
    let began = Instant::now();
    let trimmed = evicted >= PAGE_RETURN_MIN_EVICTED_ROWS;
    if trimmed {
        crate::memory::release_free_pages();
    }
    #[cfg(test)]
    if let Some((before_anon, _, before_rss)) = before {
        let elapsed = if trimmed { began.elapsed().as_nanos() } else { 0 };
        let (after_anon, _, after_rss) = disk_gates::rss_fields_kb();
        eprintln!(
            "PR5b trim rows_evicted={evicted} called={trimmed} wall_ns={elapsed} before_rss_kb={before_rss} after_rss_kb={after_rss} before_anon_kb={before_anon} after_anon_kb={after_anon}"
        );
    }
}
