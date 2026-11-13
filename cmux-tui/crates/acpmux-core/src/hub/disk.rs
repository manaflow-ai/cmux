//! Blocking storage work owned by the one writer, and bounded background load.
use super::*;
use acpmux_book::index::IndexRecord;
use acpmux_book::index::SnapshotRows;
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
    pub completed_log_bytes: Option<u64>,
}

pub(super) struct Hydration {
    snapshot: Arc<DiskSnapshot>,
    rows: SnapshotRows,
}

impl HubWriter {
    pub(super) fn persist_origin(&mut self, record: &OriginRecord) -> Result<(), HubError> {
        if let Some(log) = self.log.as_mut() {
            log.append_origin(record)?;
            self.log_dirty = true;
        }
        Ok(())
    }

    pub(super) fn start_hydration(&mut self) {
        let Some(snapshot) = self.published.load().disk().cloned() else { return };
        self.hydration = Some(Hydration { rows: snapshot.rows(), snapshot });
    }

    // Advance a bounded number of physical rows on the writer's blocking
    // worker. No detached loader survives the writer or its snapshot.
    fn hydrate_batch(&mut self) {
        let Some(load) = self.hydration.as_mut() else { return };
        let current = self.published.load_full();
        if !current.disk().is_some_and(|disk| Arc::ptr_eq(disk, &load.snapshot)) {
            self.hydration = None;
            return;
        }
        let now = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |time| time.as_secs());
        let mut next = current.as_ref().clone();
        let mut finished = false;
        for _ in 0..256 {
            match load.rows.next() {
                Some(Ok(row)) => next = next.hydrate(row, now),
                Some(Err(_)) => {
                    self.log_errors.fetch_add(1, Ordering::Relaxed);
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
        }
    }

    pub(super) fn defer_record(
        &mut self,
        source: &str,
        record: &IndexRecord,
        error: std::io::Error,
    ) -> HubError {
        self.log_errors.fetch_add(1, Ordering::Relaxed);
        self.retry_log.insert(
            RowKey::new(record.origin.as_str(), record.chat_id.as_str()),
            (source.to_owned(), record.clone()),
        );
        self.storage_retry = Some(std::time::Instant::now() + std::time::Duration::from_secs(1));
        HubError::Log(error)
    }

    pub(super) fn persist(
        &mut self,
        source: &str,
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

    pub(super) fn sync_batch(&mut self) -> Result<(), HubError> {
        // Retried changes get their seq when written, never when queued. This
        // keeps published cursors in the log even across same-boot restarts.
        let keys: Vec<_> = self.retry_log.keys().take(256).cloned().collect();
        let mut first_error = None;
        for key in keys {
            let Some((source, record)) = self.retry_log.remove(&key) else { continue };
            let result = if record.gone {
                self.apply_remove(&source, &key).map(|_| ())
            } else {
                self.apply_from(&source, record.summary).map(|_| ())
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
        // Installation and releasing the old maps stay off runtime workers.
        self.install_compaction();
        self.maintain_compaction();
        self.hydrate_batch();
        if let Some(origin) = self.leaving.iter().next().cloned() {
            let current = self.published.load_full();
            let (next, removed) = current.remove_origin_batch(current.seq(), &origin, 256);
            self.published.store(Arc::new(next));
            if removed == 0 {
                self.leaving.remove(&origin);
            }
        }
        for (key, update) in self.updates.take_batch() {
            let update_origin = match (&key, &update) {
                (UpdateKey::Row(key), _) => Some(key.origin.to_string()),
                (UpdateKey::Origin(id), _) => Some(id.to_string()),
            };
            if update_origin.as_ref().is_some_and(|origin| self.leaving.contains(origin)) {
                self.held.insert(key, update);
                continue;
            }
            let result = match update {
                PendingUpdate::Summary { source, summary } => {
                    self.apply_from(&source, *summary).map(|_| ())
                }
                PendingUpdate::Gone { source } => match key {
                    UpdateKey::Row(key) => self
                        .remove_from(&source, key.origin.as_ref(), key.chat_id.as_ref())
                        .map(|_| ()),
                    UpdateKey::Origin(_) => Err(HubError::WriterGone),
                },
                PendingUpdate::Origin { record } => {
                    self.origin(&record.id, record.state, record.since).map(|_| ())
                }
                PendingUpdate::Takeover { origin, source } => self.takeover(&origin, &source),
            };
            if result.is_err() {
                self.log_errors.fetch_add(1, Ordering::Relaxed);
            }
        }
        if self.leaving.is_empty() {
            let held = std::mem::take(&mut self.held);
            for (key, update) in held.into_iter().take(256) {
                let result = match update {
                    PendingUpdate::Summary { source, summary } => {
                        self.apply_from(&source, *summary).map(|_| ())
                    }
                    PendingUpdate::Gone { source } => match key {
                        UpdateKey::Row(key) => self
                            .remove_from(&source, key.origin.as_ref(), key.chat_id.as_ref())
                            .map(|_| ()),
                        UpdateKey::Origin(_) => Err(HubError::WriterGone),
                    },
                    PendingUpdate::Origin { record } => {
                        self.origin(&record.id, record.state, record.since).map(|_| ())
                    }
                    PendingUpdate::Takeover { origin, source } => self.takeover(&origin, &source),
                };
                if result.is_err() {
                    self.log_errors.fetch_add(1, Ordering::Relaxed);
                }
            }
        }
        if self.sync_batch().is_err() {
            self.log_errors.fetch_add(1, Ordering::Relaxed);
            self.storage_retry =
                Some(std::time::Instant::now() + std::time::Duration::from_secs(1));
        } else {
            self.storage_retry = (!self.retry_log.is_empty()).then(std::time::Instant::now);
            self.maybe_compact();
        }
    }
}
