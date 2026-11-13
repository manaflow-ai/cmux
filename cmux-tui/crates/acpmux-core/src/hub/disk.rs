//! Blocking storage work owned by the one writer, and bounded background load.
use super::*;
use acpmux_book::index::IndexRecord;
use acpmux_book::index::SnapshotRows;
use std::time::{SystemTime, UNIX_EPOCH};

pub(super) struct Hydration {
    snapshot: Arc<DiskSnapshot>,
    rows: SnapshotRows,
}

impl HubWriter {
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

    pub(super) fn persist(&mut self, record: &IndexRecord) {
        if let Some(job) = self.compaction.as_mut() {
            job.changed.insert(RowKey::new(record.origin.as_str(), record.chat_id.as_str()));
        }
        let Some(log) = self.log.as_mut() else { return };
        if !self.retry_log.is_empty() || log.append_record(record).is_err() {
            self.log_errors.fetch_add(1, Ordering::Relaxed);
            self.retry_log.insert(
                RowKey::new(record.origin.as_str(), record.chat_id.as_str()),
                record.clone(),
            );
        }
    }

    pub(super) fn sync_batch(&mut self) -> Result<(), HubError> {
        let Some(log) = self.log.as_mut() else { return Ok(()) };
        let mut records: Vec<_> = self.retry_log.values().cloned().collect();
        records.sort_by_key(|record| record.seq);
        for record in records {
            log.append_record(&record)?;
            self.retry_log.remove(&RowKey::new(record.origin, record.chat_id));
        }
        log.sync()?;
        Ok(())
    }

    pub(super) fn process_batch(&mut self) {
        self.hydrate_batch();
        for (key, update) in self.updates.take_batch() {
            let result = match update {
                PendingUpdate::Summary(summary) => self.apply(*summary).map(|_| ()),
                PendingUpdate::Gone => self.apply_remove(&key).map(|_| ()),
            };
            if result.is_err() {
                self.log_errors.fetch_add(1, Ordering::Relaxed);
            }
        }
        if self.sync_batch().is_err() {
            self.log_errors.fetch_add(1, Ordering::Relaxed);
            self.storage_retry =
                Some(std::time::Instant::now() + std::time::Duration::from_secs(1));
        } else {
            self.storage_retry = None;
            self.maybe_compact();
        }
    }
}
