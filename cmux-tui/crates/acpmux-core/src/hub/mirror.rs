//! The mirror's unit: one source frame's changes for an origin and the mark
//! after them, written in one log append with the mark last.
//!
//! A unit never enters the per-row keyed slots. It waits in its origin's
//! `UpdateKey::Source` slot, the slot takeovers use, so units and takeovers
//! for one origin leave the queue in the order they came. Rows of another
//! source for the same origin wait in the row slots and are refused by
//! ownership when the writer reaches them, so no row slot can carry a change
//! the mark claims. At most two units per origin are unapplied: one in the
//! writer's storage retry and one the slot took meanwhile, joined into one
//! append; another is refused as full.
use super::*;
use acpmux_book::index::{IndexRecord, MarkRecord, MirrorMark};
use std::collections::HashSet;

/// At most this many changes in one unit, the bound on rows held per origin.
pub const MAX_UNIT_CHANGES: usize = 16_384;

pub enum UnitChange {
    Summary(Box<Summary>),
    Gone { chat_id: String },
}

pub struct MirrorUnit {
    pub origin: String,
    pub changes: Vec<UnitChange>,
    pub mark: MirrorMark,
}

#[derive(Default)]
pub struct Counters {
    forged: AtomicU64,
    rows_over_bound: AtomicU64,
    applied: AtomicU64,
    full: AtomicU64,
    not_owner: AtomicU64,
    held: AtomicU64,
    storage: AtomicU64,
    mark_bytes: AtomicU64,
}

/// One read of the mirror's counters.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MirrorCounts {
    /// Units refused whole because a change named another origin.
    pub forged: u64,
    /// Changes refused because their unit was over [`MAX_UNIT_CHANGES`].
    pub rows_over_bound: u64,
    /// Units written with their mark.
    pub applied: u64,
    /// Units refused because one was already unapplied for the origin.
    pub full: u64,
    /// Units refused whole because their source does not own the origin.
    pub not_owner: u64,
    /// Units refused whole because the origin was leaving.
    pub held: u64,
    /// Unit appends that failed and wait for the storage retry.
    pub storage: u64,
    /// Bytes the marks added to their appends.
    pub mark_bytes: u64,
}

impl Counters {
    fn read(&self) -> MirrorCounts {
        MirrorCounts {
            forged: self.forged.load(Ordering::Relaxed),
            rows_over_bound: self.rows_over_bound.load(Ordering::Relaxed),
            applied: self.applied.load(Ordering::Relaxed),
            full: self.full.load(Ordering::Relaxed),
            not_owner: self.not_owner.load(Ordering::Relaxed),
            held: self.held.load(Ordering::Relaxed),
            storage: self.storage.load(Ordering::Relaxed),
            mark_bytes: self.mark_bytes.load(Ordering::Relaxed),
        }
    }
}

/// A unit whose append failed. A takeover after it clears its mark, so the
/// retry writes its rows with the mark off.
pub(super) struct RetryUnit {
    source: Source,
    changes: Vec<UnitChange>,
    mark: Option<MirrorMark>,
}

#[derive(Default)]
pub(super) struct WriterMirror {
    pub counters: Arc<Counters>,
    units: HashMap<String, RetryUnit>,
    off: HashSet<String>,
    /// Unit appends a test makes fail before they write.
    #[cfg(test)]
    pub fail_appends: usize,
}

impl WriterMirror {
    pub(super) fn new(counters: Arc<Counters>) -> Self {
        Self {
            counters,
            units: HashMap::new(),
            off: HashSet::new(),
            #[cfg(test)]
            fail_appends: 0,
        }
    }

    pub(super) fn retry_pending(&self) -> bool {
        !self.units.is_empty() || !self.off.is_empty()
    }
}

impl Hub {
    /// Queues one frame's unit. The unit is checked whole here: every change
    /// must name the unit's origin and the count must be in bound. Ownership
    /// is checked whole by the writer. Nothing is applied if this refuses.
    pub fn submit_unit(&self, source: Source, unit: MirrorUnit) -> Result<(), HubError> {
        let counters = &self.mirror;
        if let Err(error) = origins::validate_takeover(&unit.origin, source) {
            counters.forged.fetch_add(1, Ordering::Relaxed);
            return Err(error);
        }
        if unit.changes.len() > MAX_UNIT_CHANGES {
            counters.rows_over_bound.fetch_add(unit.changes.len() as u64, Ordering::Relaxed);
            return Err(HubError::UnitRowLimit);
        }
        let mut changes = Vec::with_capacity(unit.changes.len());
        for change in unit.changes {
            match change {
                UnitChange::Summary(summary) => {
                    if summary.origin != unit.origin {
                        counters.forged.fetch_add(1, Ordering::Relaxed);
                        return Err(HubError::ForgedOrigin(summary.origin));
                    }
                    changes.push(UnitChange::Summary(Box::new(summary.prepare()?)));
                }
                UnitChange::Gone { chat_id } => {
                    RowKey::new(unit.origin.as_str(), chat_id.as_str()).validate()?;
                    changes.push(UnitChange::Gone { chat_id });
                }
            }
        }
        let origin = unit.origin;
        let unit = MirrorUnit { origin: origin.clone(), changes, mark: unit.mark };
        let result = self.updates.enqueue(
            UpdateKey::Source(origin.into()),
            PendingUpdate::Unit { source, unit: Box::new(unit) },
        );
        if matches!(result, Err(HubError::UnitQueueFull)) {
            counters.full.fetch_add(1, Ordering::Relaxed);
        }
        result
    }

    /// The mark of the last unit written for `origin`, if no takeover wrote
    /// it off since.
    pub fn mirror_mark(&self, origin: &str) -> Option<MirrorMark> {
        self.published.load().mirror_mark(origin)
    }

    pub fn mirror_counts(&self) -> MirrorCounts {
        self.mirror.read()
    }
}

impl UnitChange {
    fn chat_id(&self) -> &str {
        match self {
            Self::Summary(summary) => &summary.chat_id,
            Self::Gone { chat_id } => chat_id,
        }
    }
}

impl HubWriter {
    pub(super) fn apply_unit(&mut self, source: Source, unit: MirrorUnit) -> Result<(), HubError> {
        let MirrorUnit { origin, changes, mark } = unit;
        let mut retry = RetryUnit { source, changes, mark: Some(mark) };
        // A unit queued before an earlier one's append failed goes after it:
        // the two are written as one, in order, with the newer mark.
        if let Some(mut earlier) = self.mirror.units.remove(&origin) {
            earlier.changes.append(&mut retry.changes);
            earlier.mark = retry.mark;
            earlier.source = source;
            retry = earlier;
        }
        self.write_unit(&origin, retry)
    }

    fn write_unit(&mut self, origin: &str, unit: RetryUnit) -> Result<(), HubError> {
        let counters = self.mirror.counters.clone();
        let current = self.published.load_full();
        if self.holds_origin(origin)
            || (self.origins.ended.contains_key(origin)
                && current
                    .origin(origin)
                    .is_some_and(|record| record.state == OriginState::Removed))
        {
            counters.held.fetch_add(1, Ordering::Relaxed);
            self.release_unit_slot(origin);
            return Err(HubError::UnitHeld);
        }
        if let Err(error) = self.check_source(unit.source, origin) {
            counters.not_owner.fetch_add(1, Ordering::Relaxed);
            self.release_unit_slot(origin);
            return Err(error);
        }
        // The last change for a chat in the unit wins; each chat is written once.
        #[cfg(test)]
        let began = std::time::Instant::now();
        let mut seen = HashSet::with_capacity(unit.changes.len());
        let mut keep = vec![false; unit.changes.len()];
        for (slot, change) in keep.iter_mut().zip(unit.changes.iter()).rev() {
            *slot = seen.insert(change.chat_id());
        }
        drop(seen);
        let mut seq = current.seq();
        let mut records = Vec::with_capacity(unit.changes.len());
        for (change, keep) in unit.changes.iter().zip(keep) {
            if !keep {
                continue;
            }
            let record = match change {
                UnitChange::Summary(summary) => {
                    let key = summary.key();
                    let existing = current.get_row(&key);
                    // As for every remote row: a closed one with no live row
                    // to close is not kept, and an unchanged one is not written.
                    if (!summary.is_live() && existing.is_none())
                        || existing.is_some_and(|row| row.same_content(summary))
                    {
                        continue;
                    }
                    IndexRecord {
                        seq: seq + 1,
                        origin: origin.to_owned(),
                        chat_id: summary.chat_id.clone(),
                        summary: (**summary).clone(),
                        gone: false,
                    }
                }
                UnitChange::Gone { chat_id } => {
                    let key = RowKey::new(origin, chat_id.as_str());
                    if current.get_row(&key).is_none()
                        && (current.disk().is_none()
                            || current.is_shadowed(&key)
                            || current.is_snapshot_origin_hidden(origin))
                    {
                        continue;
                    }
                    IndexRecord {
                        seq: seq + 1,
                        origin: origin.to_owned(),
                        chat_id: chat_id.clone(),
                        summary: Summary::new(chat_id.clone()),
                        gone: true,
                    }
                }
            };
            seq += 1;
            records.push(record);
        }
        let mark = MarkRecord { seq, origin: origin.to_owned(), mark: unit.mark };
        #[cfg(test)]
        let built = std::time::Instant::now();
        #[cfg(test)]
        {
            self.turn_measure.unit_ns[0] += built.duration_since(began).as_nanos();
        }
        #[cfg(test)]
        let injected = self.mirror.fail_appends.checked_sub(1).map(|left| {
            self.mirror.fail_appends = left;
        });
        #[cfg(not(test))]
        let injected: Option<()> = None;
        if let Some(log) = self.log.as_mut() {
            let appended = match injected {
                Some(()) => Err(std::io::Error::other("injected append failure")),
                None => log.append_unit(&records, &mark),
            };
            match appended {
                Ok(_) => {
                    counters.mark_bytes.fetch_add(mark.encoded_len(), Ordering::Relaxed);
                    self.log_dirty = true;
                }
                Err(error) => {
                    counters.storage.fetch_add(1, Ordering::Relaxed);
                    self.log_errors.fetch_add(1, Ordering::Relaxed);
                    self.storage_retry =
                        Some(std::time::Instant::now() + std::time::Duration::from_secs(1));
                    // Only the changes that were to be written are kept;
                    // the rest were already no-ops against the index.
                    let changes = records
                        .into_iter()
                        .map(|record| {
                            if record.gone {
                                UnitChange::Gone { chat_id: record.chat_id }
                            } else {
                                UnitChange::Summary(Box::new(record.summary))
                            }
                        })
                        .collect();
                    self.hold_unit_slot(origin);
                    self.mirror.units.insert(
                        origin.to_owned(),
                        RetryUnit { source: unit.source, changes, mark: unit.mark },
                    );
                    return Err(HubError::Log(error));
                }
            }
        }
        #[cfg(test)]
        {
            self.turn_measure.unit_ns[1] += built.elapsed().as_nanos();
        }
        self.mirror.off.remove(origin);
        self.release_unit_slot(origin);
        if let Some(job) = self.compaction.as_mut() {
            for record in &records {
                job.changed.insert(RowKey::new(origin, record.chat_id.as_str()));
            }
        }
        for record in records {
            self.retry_log.remove(&RowKey::new(origin, record.chat_id.as_str()));
            self.publish_written(record);
        }
        let next = self.published.load().apply_mark(&mark);
        self.published.store(Arc::new(next));
        counters.applied.fetch_add(1, Ordering::Relaxed);
        Ok(())
    }

    /// Publishes one row record already in the log, as a single apply does.
    fn publish_written(&mut self, record: IndexRecord) {
        let current = self.published.load_full();
        let key = RowKey::new(record.origin.as_str(), record.chat_id.as_str());
        #[cfg(test)]
        let began = std::time::Instant::now();
        if record.gone {
            let Some(next) = current.remove_row(record.seq, &key) else {
                self.published.store(Arc::new(current.advance_seq(record.seq)));
                return;
            };
            let folder_ops = next.folder_changes(&current, current.get_row(&key).as_deref(), None);
            self.publish_folder_index(next, &folder_ops);
            self.record_history(ListItem::Gone {
                seq: record.seq,
                chat_id: record.chat_id,
                origin: record.origin,
            });
            self.publish_gone(record.seq, &key);
        } else {
            let next = current.apply_summary(record.seq, record.summary.clone());
            let folder_ops = next.folder_changes(
                &current,
                current.get_row(&key).as_deref(),
                next.get_row(&key).as_deref(),
            );
            let event = SummaryEvent { seq: record.seq, summary: Arc::new(record.summary) };
            #[cfg(test)]
            let applied = std::time::Instant::now();
            #[cfg(test)]
            {
                self.turn_measure.unit_ns[2] += applied.duration_since(began).as_nanos();
            }
            self.publish_folder_index(next, &folder_ops);
            self.record_history(ListItem::Summary(event.clone()));
            self.publish(event);
            #[cfg(test)]
            {
                self.turn_measure.unit_ns[3] += applied.elapsed().as_nanos();
            }
        }
    }

    /// A takeover writes the origin's mark off in its own turn, so a replay
    /// after it gives no cursor and the new source walks.
    pub(super) fn write_mark_off(&mut self, origin: &str) {
        if let Some(unit) = self.mirror.units.get_mut(origin) {
            unit.mark = None;
        }
        if self.published.load().mirror_mark(origin).is_none() && !self.mirror.off.contains(origin)
        {
            return;
        }
        let current = self.published.load_full();
        let record = MarkRecord { seq: current.seq(), origin: origin.to_owned(), mark: None };
        self.published.store(Arc::new(current.apply_mark(&record)));
        if let Some(log) = self.log.as_mut() {
            match log.append_mark(&record) {
                Ok(_) => {
                    self.log_dirty = true;
                    self.mirror.off.remove(origin);
                }
                Err(_) => {
                    self.log_errors.fetch_add(1, Ordering::Relaxed);
                    self.storage_retry =
                        Some(std::time::Instant::now() + std::time::Duration::from_secs(1));
                    self.mirror.off.insert(origin.to_owned());
                }
            }
        }
    }

    /// Retries failed unit appends and mark-offs in the storage retry turn.
    pub(super) fn retry_mirror(&mut self) -> Option<HubError> {
        let mut first = None;
        let off: Vec<_> = self.mirror.off.iter().cloned().collect();
        for origin in off {
            self.write_mark_off(&origin);
        }
        let origins: Vec<_> = self.mirror.units.keys().cloned().collect();
        for origin in origins {
            let Some(unit) = self.mirror.units.remove(&origin) else { continue };
            if let Err(error) = self.write_unit(&origin, unit) {
                first.get_or_insert(error);
            }
        }
        first
    }

    fn hold_unit_slot(&self, origin: &str) {
        if let Ok(mut pending) = self.updates.pending.lock() {
            pending.retrying.insert(origin.into());
        }
    }

    fn release_unit_slot(&self, origin: &str) {
        if let Ok(mut pending) = self.updates.pending.lock() {
            pending.retrying.remove(origin);
        }
    }
}
