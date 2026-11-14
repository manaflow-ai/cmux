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
    pub damaged_snapshot_frames: AtomicU64,
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
    /// Damaged frames found by the active snapshot's single hydration walk.
    /// Page and seek reads do not count; a clean snapshot install resets it.
    pub fn damaged_snapshot_frames(&self) -> u64 {
        self.compaction_counters.damaged_snapshot_frames.load(Ordering::Relaxed)
    }

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
        if self.compaction.is_some()
            || self.maintenance.is_some()
            || !self.retry_log.is_empty()
            || !self.origins.retry.is_empty()
        {
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
                self.log_errors.fetch_add(result.skipped_snapshot_rows as u64, Ordering::Relaxed);
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
                self.retire_origin_sources(&current, &next);
                self.published.store(Arc::new(next));
                self.compaction_counters.damaged_snapshot_frames.store(0, Ordering::Relaxed);
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
        let mut touched = std::collections::BTreeSet::new();
        for _ in 0..256 {
            if let Some(row) = work.missing_hot.pop_front() {
                if let Some(folder) = acpmux_book::index::FolderKey::of(&row) {
                    touched.insert(folder);
                }
                next.hydrate_compacted(row);
            } else if let Some(key) = work.cold_keys.pop_front() {
                if let Some(row) = next.get_row(&key)
                    && let Some(folder) = acpmux_book::index::FolderKey::of(&row)
                {
                    touched.insert(folder);
                }
                work.evicted_rows += usize::from(next.evict_compacted(&key));
            } else {
                break;
            }
            #[cfg(test)]
            {
                self.turn_measure.maintenance_keys += 1;
            }
        }
        let folder_ops = folders::changed_folders(&current, &next, touched);
        // Publish below after releasing the maintenance borrow.
        let folder_publish = next;
        // Installation may finish startup through this captured hot-row
        // stream instead of the original snapshot iterator. Publish readiness
        // only after its last missing live row is installed.
        let waiting = *self.hydrated.borrow() != disk::HydrationState::Ready;
        let hydration_done = work.missing_hot.is_empty() && waiting;
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
                self.publish_folder_index(folder_publish, &folder_ops);
                if hydration_done {
                    self.hydrated.send_replace(disk::HydrationState::Ready);
                }
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
        self.publish_folder_index(folder_publish, &folder_ops);
        if hydration_done {
            self.hydrated.send_replace(disk::HydrationState::Ready);
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

#[cfg(test)]
mod folder_eviction_tests {
    use super::*;
    use acpmux_book::index::folders::FolderOp;
    use acpmux_book::index::{ChangedRows, SortedSnapshot};

    #[test]
    fn eviction_batch_coalesces_folders_without_advancing_durable_cursors() {
        let dir = tempfile::tempdir().unwrap();
        let (hub, mut writer) = Hub::open(dir.path(), 1, || 7).unwrap();
        for n in 0..40 {
            let mut row = Summary::new(format!("chat-{n}"));
            row.folder = Some(if n < 20 { "/a" } else { "/b" }.into());
            row.last_activity = n;
            writer.apply(row).unwrap();
        }
        let current = hub.snapshot();
        let snapshot_path = dir.path().join("index.snap");
        SortedSnapshot::write(&snapshot_path, &current).unwrap();
        let snapshot = DiskSnapshot::open(&snapshot_path).unwrap().unwrap();
        let (next, _) = current.with_compacted_snapshot(snapshot, ChangedRows::new());
        writer.publish_folder_index(next, &[]);
        let mut sub = Sub::new("folders", "list");
        sub.view = Some(crate::wire::ListView::Folders);
        let subscription = hub.subscribe(&sub).unwrap();
        let list_seq = hub.snapshot().seq();
        let log_seq = writer.log.as_ref().unwrap().next_seq();
        let last_history = writer.history.lock().unwrap().last_seq();
        writer.maintenance = Some(Maintenance {
            cold_keys: current
                .iter()
                .filter(|row| row.chat_id != "chat-39")
                .map(|row| row.key())
                .collect(),
            missing_hot: VecDeque::new(),
            retired_shadow: None,
            evicted_rows: 0,
            started: Instant::now(),
            cleanup_complete: false,
        });
        writer.maintain_compaction();
        assert_eq!(hub.snapshot().seq(), list_seq);
        assert_eq!(writer.log.as_ref().unwrap().next_seq(), log_seq);
        assert_eq!(writer.history.lock().unwrap().last_seq(), last_history);
        let Some(ListItem::Folders { seq, ops }) = subscription.receiver.try_next() else {
            panic!("one folder frame")
        };
        assert_eq!(seq, subscription.cursor + 1);
        assert_eq!(ops.len(), 2);
        assert!(
            ops.iter().any(|op| matches!(op, FolderOp::Gone(key) if key.folder.as_ref() == "/a"))
        );
        assert!(ops.iter().any(|op| matches!(op, FolderOp::Folder(row) if row.folder.as_ref() == "/b" && row.count == 1)));
        assert!(subscription.receiver.try_next().is_none());
    }
}
