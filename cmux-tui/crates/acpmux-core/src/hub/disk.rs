//! Blocking storage work owned by the one writer, and bounded background load.
use super::*;
use acpmux_book::index::IndexRecord;
use acpmux_book::index::{SnapshotRows, is_corrupt_snapshot_row};
use std::time::{SystemTime, UNIX_EPOCH};

/// Attribution only; the release gate still measures the complete turn.
#[cfg(test)]
#[derive(Clone, Copy, Default)]
pub(super) struct TurnMeasure {
    pub overlay_ns: u128,
    pub changed: usize,
    pub sync_ns: u128,
    pub rotate_ns: u128,
    pub maintenance_keys: usize,
    pub apply_snapshot_pieces: usize,
    pub completed_log_bytes: Option<u64>,
}

#[derive(Clone, Copy, Eq, PartialEq)]
pub(super) enum HydrationState {
    Loading,
    Ready,
    Failed,
}

pub(super) struct Hydration {
    snapshot: Arc<DiskSnapshot>,
    rows: SnapshotRows,
}

impl HubWriter {
    /// Quarantines the damaged derived files and leaves the hot in-memory
    /// rows as the sole published view. The next compaction writes a clean
    /// snapshot, while the rebuild counter tells each source to walk again.
    pub(super) fn rebuild_if_requested(&mut self) {
        if !self.rebuild_requested.load(Ordering::Acquire) {
            return;
        }
        // Let an already-running compaction finish its owned snapshot before
        // moving files aside. The flag remains set and this method owns the
        // next writer turn, so no second rebuild task can race the first.
        if self.compaction.is_some() || self.retirement.is_some() {
            return;
        }
        self.rebuild_requested.store(false, Ordering::Release);
        let Some(directory) = self.directory.clone() else {
            // In-memory hubs have no derived files to quarantine. Still fence
            // subscribers through the same source-walk epoch.
            self.rebuild_count.fetch_add(1, Ordering::AcqRel);
            self.mark_rebuild_ready();
            return;
        };
        let current = self.published.load_full();
        let published_seq = current.seq();
        self.hydration = None;
        self.maintenance = None;
        self.log = None;
        let quarantined = quarantine_index(&directory).is_ok();
        let mut rebuild_error = !quarantined;
        if quarantined {
            match IndexLog::open_at(directory.join("index.log"), published_seq) {
                Ok(log) => self.log = Some(log),
                Err(_) => {
                    rebuild_error = true;
                }
            }
        }
        if rebuild_error {
            // Keep the hub alive even if quarantine or opening the fresh log
            // hits a transient storage error. Never reopen old files.
            self.log_errors.fetch_add(1, Ordering::Relaxed);
        }
        let next = current.empty_for_rebuild();
        self.published.store(Arc::new(next));
        drop(current);
        self.rebuild_count.fetch_add(1, Ordering::AcqRel);
        self.next_compaction = Some(std::time::Instant::now());
        self.storage_retry = None;
        self.mark_rebuild_ready();
    }

    fn mark_rebuild_ready(&self) {
        self.hydrated.send_replace(HydrationState::Ready);
    }

    pub(super) fn persist_origin(&mut self, record: &OriginRecord) -> Result<(), HubError> {
        if let Some(log) = self.log.as_mut() {
            if let Err(error) = log.append_origin(record) {
                self.origins.retry.insert(record.id.clone(), record.clone());
                self.log_errors.fetch_add(1, Ordering::Relaxed);
                self.storage_retry =
                    Some(std::time::Instant::now() + std::time::Duration::from_secs(1));
                return Err(HubError::Log(error));
            }
            self.log_dirty = true;
        }
        Ok(())
    }

    pub(super) fn start_hydration(&mut self) {
        let Some(snapshot) = self.published.load().disk().cloned() else { return };
        self.compaction_counters.damaged_snapshot_frames.store(0, Ordering::Relaxed);
        self.hydration = Some(Hydration { rows: snapshot.rows(), snapshot });
    }

    // Advance a bounded number of physical rows on the writer's blocking
    // worker. No detached loader survives the writer or its snapshot.
    fn hydrate_batch(&mut self) {
        let Some(load) = self.hydration.as_mut() else { return };
        let current = self.published.load_full();
        if !current.disk().is_some_and(|disk| Arc::ptr_eq(disk, &load.snapshot)) {
            self.hydration = None;
            self.start_hydration();
            return;
        }
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |time| u64::try_from(time.as_millis()).unwrap_or(u64::MAX));
        let mut next = current.as_ref().clone();
        let mut finished = false;
        let mut failed = false;
        for _ in 0..256 {
            match load.rows.next() {
                Some(Ok(row)) => next = next.hydrate(row, now),
                Some(Err(error)) if is_corrupt_snapshot_row(&error) => {
                    self.compaction_counters
                        .damaged_snapshot_frames
                        .fetch_add(1, Ordering::Relaxed);
                }
                Some(Err(error)) if acpmux_book::index::is_fatal_snapshot_read(&error) => {
                    // A structural snapshot boundary is a rebuild request,
                    // not a permanent hydration failure. Keep the daemon
                    // ready while the writer quarantines the derived files.
                    self.request_rebuild();
                    finished = true;
                    break;
                }
                Some(Err(_)) => {
                    self.log_errors.fetch_add(1, Ordering::Relaxed);
                    failed = true;
                    finished = true;
                    break;
                }
                None => {
                    finished = true;
                    break;
                }
            }
        }
        self.published.store(Arc::new(next));
        if finished {
            self.hydration = None;
            self.hydrated.send_replace(if failed {
                HydrationState::Failed
            } else {
                HydrationState::Ready
            });
        }
    }

    pub(super) fn defer_record(
        &mut self,
        source: Source,
        record: &IndexRecord,
        error: std::io::Error,
    ) -> HubError {
        self.log_errors.fetch_add(1, Ordering::Relaxed);
        self.retry_log.insert(
            RowKey::new(record.origin.as_str(), record.chat_id.as_str()),
            (source, record.clone()),
        );
        self.storage_retry = Some(std::time::Instant::now() + std::time::Duration::from_secs(1));
        HubError::Log(error)
    }

    pub(super) fn persist(
        &mut self,
        source: Source,
        record: &IndexRecord,
        key: &RowKey,
    ) -> Result<(), HubError> {
        if let Some(log) = self.log.as_mut() {
            if let Err(error) = log.append_record(record) {
                return Err(self.defer_record(source, record, error));
            }
            self.log_dirty = true;
        }
        // Only written changes may replace the captured snapshot's rows.
        if let Some(job) = self.compaction.as_mut() {
            job.changed.insert(key.clone());
        }
        Ok(())
    }

    #[cfg(test)]
    pub(super) fn sync_batch(&mut self) -> Result<(), HubError> {
        self.sync_batch_limit(256)
    }

    pub(super) fn sync_batch_limit(&mut self, limit: usize) -> Result<(), HubError> {
        // Retried changes get their seq when written, never when queued. This
        // keeps published cursors in the log even across same-boot restarts.
        let origin_retries = self.origins.retry.len().min(limit);
        let keys: Vec<_> = self.retry_log.keys().take(limit - origin_retries).cloned().collect();
        let mut first_error = self.retry_origins(origin_retries).err();
        for key in keys {
            let Some((source, record)) = self.retry_log.remove(&key) else { continue };
            if self.origins.ended.get(key.origin.as_ref()).is_some_and(|seq| record.seq <= *seq) {
                continue;
            }
            let result = if record.gone {
                self.remove_from(source, &key.origin, &key.chat_id).map(|_| ())
            } else {
                self.apply_from(source, record.summary).map(|_| ())
            };
            if let Err(error) = result {
                first_error.get_or_insert(error);
            }
        }
        if self.log_dirty {
            if let Some(log) = self.log.as_mut() {
                #[cfg(test)]
                let began = std::time::Instant::now();
                log.sync()?;
                #[cfg(test)]
                {
                    self.turn_measure.sync_ns += began.elapsed().as_nanos();
                }
            }
            self.log_dirty = false;
        }
        first_error.map_or(Ok(()), Err)
    }

    pub(super) fn process_batch(&mut self) {
        #[cfg(test)]
        {
            self.turn_measure = TurnMeasure::default();
        }
        self.rebuild_if_requested();
        // Installation and releasing the old maps stay off runtime workers.
        self.install_compaction();
        self.maintain_compaction();
        self.hydrate_batch();
        // Leave half of a busy turn for independent queued work. With no
        // arrivals a removal still takes the full 256 keys per turn.
        let queued = self.updates.pending.lock().is_ok_and(|pending| !pending.is_empty());
        let retry_budget = (self.origins.retry.len() + self.retry_log.len()).min(128);
        let arrival_budget = 256 - retry_budget;
        let used = self.advance_origins(if queued { arrival_budget / 2 } else { arrival_budget });
        for (key, update) in self.updates.take_batch_limit(arrival_budget.saturating_sub(used)) {
            if self.dispatch_update(key, update).is_err() {
                self.log_errors.fetch_add(1, Ordering::Relaxed);
            }
        }
        if self.sync_batch_limit(retry_budget).is_err() {
            self.log_errors.fetch_add(1, Ordering::Relaxed);
            self.storage_retry =
                Some(std::time::Instant::now() + std::time::Duration::from_secs(1));
        } else {
            self.storage_retry = (!self.retry_log.is_empty() || !self.origins.retry.is_empty())
                .then(std::time::Instant::now);
            self.maybe_compact();
        }
    }
}
