//! Origin ownership and the bounded end of an origin's life.
use super::*;
use std::collections::VecDeque;

const MAX_ORIGINS: usize = 256;
const MAX_HELD_ROWS: usize = 16_384;
static REFUSED_HELD_ROWS: AtomicU64 = AtomicU64::new(0);

/// The producer, not a machine name. No source string is allocated per row.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum Source {
    Local,
    V1,
    Mirror,
}

impl Source {
    pub(super) fn default_for(origin: &str) -> Self {
        if origin == "local" { Self::Local } else { Self::V1 }
    }
}

pub fn refused_held_rows() -> u64 {
    REFUSED_HELD_ROWS.load(Ordering::Relaxed)
}

pub(super) fn validate_id(id: &str) -> Result<(), HubError> {
    if id.is_empty() || id.len() > 256 {
        return Err(HubError::Log(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "origin id must contain 1..=256 bytes",
        )));
    }
    Ok(())
}

pub(super) fn validate_takeover(id: &str, source: Source) -> Result<(), HubError> {
    validate_id(id)?;
    if id == "local" || source == Source::Local {
        REFUSED_SOURCE_SUBMITS.fetch_add(1, Ordering::Relaxed);
        return Err(HubError::SourceRefused {
            origin: id.to_owned(),
            incoming: source,
            owner: Source::default_for(id),
        });
    }
    Ok(())
}

#[derive(Default)]
struct Held {
    record: Option<OriginRecord>,
    source: Option<Source>,
    rows: HashMap<RowKey, PendingUpdate>,
    order: VecDeque<RowKey>,
}

impl Held {
    fn insert(&mut self, key: UpdateKey, update: PendingUpdate) -> Result<(), HubError> {
        match (key, update) {
            (UpdateKey::Origin(_), PendingUpdate::Origin { record }) => self.record = Some(record),
            (UpdateKey::Source(_), PendingUpdate::Takeover { source, .. }) => {
                self.source = Some(source);
            }
            (UpdateKey::Row(key), update) => {
                if !self.rows.contains_key(&key) {
                    if self.rows.len() == MAX_HELD_ROWS {
                        REFUSED_HELD_ROWS.fetch_add(1, Ordering::Relaxed);
                        return Err(HubError::HeldRowLimit);
                    }
                    self.order.push_back(key.clone());
                }
                self.rows.insert(key, update);
            }
            _ => return Err(HubError::WriterGone),
        }
        Ok(())
    }

    fn pop(&mut self, origin: &str) -> Option<(UpdateKey, PendingUpdate)> {
        // A returned origin's metadata precedes its rows, even if the input
        // HashMap happened to deliver the row first. Ownership changes first.
        if let Some(source) = self.source.take() {
            return Some((
                UpdateKey::Source(origin.into()),
                PendingUpdate::Takeover { origin: origin.into(), source },
            ));
        }
        if let Some(record) = self.record.take() {
            return Some((UpdateKey::Origin(origin.into()), PendingUpdate::Origin { record }));
        }
        let key = self.order.pop_front()?;
        self.rows.remove(&key).map(|update| (UpdateKey::Row(key), update))
    }

    fn is_empty(&self) -> bool {
        self.source.is_none() && self.record.is_none() && self.rows.is_empty()
    }
}

#[derive(Default)]
pub(super) struct WriterOrigins {
    leaving: VecDeque<String>,
    held: HashMap<String, Held>,
    ready: VecDeque<String>,
    pub retry: HashMap<String, OriginRecord>,
    releasing: bool,
    pub ended: HashMap<String, u64>,
}

impl UpdateKey {
    pub(super) fn origin(&self) -> &str {
        match self {
            Self::Row(key) => &key.origin,
            Self::Origin(id) | Self::Source(id) => id,
        }
    }
}

impl HubWriter {
    pub(super) fn holds_origin(&self, id: &str) -> bool {
        !self.origins.releasing
            && (self.published.load().is_origin_leaving(id)
                || self.origins.held.contains_key(id)
                || self.origins.retry.contains_key(id))
    }

    pub(super) fn hold_update(
        &mut self,
        key: UpdateKey,
        update: PendingUpdate,
    ) -> Result<(), HubError> {
        if let PendingUpdate::Summary { source, .. } | PendingUpdate::Gone { source } = &update {
            let owner = self
                .origins
                .held
                .get(key.origin())
                .and_then(|held| held.source)
                .or_else(|| self.sources.load().get(key.origin()).copied());
            if let Some(owner) = owner
                && owner != *source
            {
                REFUSED_SOURCE_SUBMITS.fetch_add(1, Ordering::Relaxed);
                return Err(HubError::SourceRefused {
                    origin: key.origin().into(),
                    incoming: *source,
                    owner,
                });
            }
        }
        let row_key = match &key {
            UpdateKey::Row(key) => Some(key.clone()),
            _ => None,
        };
        self.origins.held.entry(key.origin().to_owned()).or_default().insert(key, update)?;
        // A newly accepted value wins even if the previous append failed.
        // Invalidate here, before retry dispatch could put the old value back
        // into this held slot while the remaining backlog is released.
        if let Some(key) = row_key {
            self.retry_log.remove(&key);
        }
        Ok(())
    }

    pub(super) fn origin_work_pending(&self) -> bool {
        !self.origins.leaving.is_empty() || !self.origins.ready.is_empty()
    }

    /// Checks the union of the record and source maps only for a new id. An
    /// existing row takes a source lookup, never a walk of peers or chats.
    fn admit_origin(&self, id: &str) -> Result<(), HubError> {
        let index = self.published.load();
        let sources = self.sources.load();
        if index.origin(id).is_some()
            || sources.contains_key(id)
            || self.origins.retry.contains_key(id)
        {
            return Ok(());
        }
        let count = index.origins().count()
            + sources.keys().filter(|id| index.origin(id).is_none()).count()
            + self
                .origins
                .retry
                .keys()
                .filter(|id| index.origin(id).is_none() && !sources.contains_key(*id))
                .count();
        if count < MAX_ORIGINS {
            return Ok(());
        }
        REFUSED_ORIGINS.fetch_add(1, Ordering::Relaxed);
        Err(HubError::OriginLimit)
    }

    pub(super) fn check_source(&mut self, source: Source, origin: &str) -> Result<(), HubError> {
        let owner = if origin == "local" {
            Source::Local
        } else {
            if source == Source::Local {
                REFUSED_SOURCE_SUBMITS.fetch_add(1, Ordering::Relaxed);
                return Err(HubError::SourceRefused {
                    origin: origin.into(),
                    incoming: source,
                    owner: Source::V1,
                });
            }
            let existing = self.sources.load().get(origin).copied();
            if let Some(owner) = existing {
                owner
            } else {
                validate_id(origin)?;
                self.admit_origin(origin)?;
                let mut sources = self.sources.load_full().as_ref().clone();
                sources.insert(origin.into(), source);
                self.sources.store(Arc::new(sources));
                source
            }
        };
        if owner == source {
            return Ok(());
        }
        REFUSED_SOURCE_SUBMITS.fetch_add(1, Ordering::Relaxed);
        Err(HubError::SourceRefused { origin: origin.into(), incoming: source, owner })
    }

    pub fn takeover(&mut self, origin: &str, source: Source) -> Result<(), HubError> {
        validate_takeover(origin, source)?;
        self.admit_origin(origin)?;
        if self.holds_origin(origin) {
            return self.hold_update(
                UpdateKey::Source(origin.into()),
                PendingUpdate::Takeover { origin: origin.into(), source },
            );
        }
        if self.sources.load().get(origin) == Some(&source) {
            return Ok(());
        }
        let mut sources = self.sources.load_full().as_ref().clone();
        sources.insert(origin.into(), source);
        self.sources.store(Arc::new(sources));
        Ok(())
    }

    pub fn origin(&mut self, id: &str, state: OriginState, since: u64) -> Result<bool, HubError> {
        if id == "local" {
            return Ok(false);
        }
        validate_id(id)?;
        let current = self.published.load_full();
        let record = OriginRecord {
            seq: current.seq().saturating_add(1),
            id: id.into(),
            state,
            since,
            extra: None,
        };
        if self.holds_origin(id) {
            self.hold_update(UpdateKey::Origin(id.into()), PendingUpdate::Origin { record })?;
            return Ok(false);
        }
        self.origins.retry.remove(id);
        if current.origin(id).is_some_and(|old| old.state == state)
            || (state == OriginState::Removed
                && current.origin(id).is_none()
                && !current.has_origin_rows(id))
        {
            return Ok(false);
        }
        self.admit_origin(id)?;
        self.persist_origin(&record)?;
        self.published.store(Arc::new(current.apply_origin(record.seq, record.clone())));
        let wire = Origin { id: id.into(), state, since, extra: None };
        self.record_history(ListItem::Origin { seq: record.seq, origin: wire.clone() });
        self.publish_origin(record.seq, wire);
        if state == OriginState::Removed {
            self.origins.ended.insert(id.into(), record.seq);
            self.origins.leaving.push_back(id.into());
        }
        Ok(true)
    }

    pub(super) fn dispatch_update(
        &mut self,
        key: UpdateKey,
        update: PendingUpdate,
    ) -> Result<(), HubError> {
        match update {
            PendingUpdate::Summary { source, summary } => {
                self.apply_from(source, *summary).map(|_| ())
            }
            PendingUpdate::Gone { source } => match key {
                UpdateKey::Row(key) => {
                    self.remove_from(source, &key.origin, &key.chat_id).map(|_| ())
                }
                _ => Err(HubError::WriterGone),
            },
            PendingUpdate::Origin { record } => {
                self.origin(&record.id, record.state, record.since).map(|_| ())
            }
            PendingUpdate::Takeover { origin, source } => self.takeover(&origin, source),
        }
    }

    /// All cleanup and released arrivals share the writer's 256-item budget.
    pub(super) fn advance_origins(&mut self, limit: usize) -> usize {
        let mut used = 0;
        if let Some(id) = self.origins.leaving.front().cloned() {
            let current = self.published.load_full();
            let (next, removed) = current.remove_origin_batch(current.seq(), &id, limit);
            let finished = !next.is_origin_leaving(&id);
            self.published.store(Arc::new(next));
            used += removed.max(1);
            if finished {
                self.origins.leaving.pop_front();
                if self.origins.held.contains_key(&id) {
                    self.origins.ready.push_back(id);
                } else {
                    self.retire_finished_source(&id);
                }
            }
        }
        while used < limit {
            let Some(id) = self.origins.ready.front().cloned() else { break };
            if self.published.load().is_origin_leaving(&id) || self.origins.retry.contains_key(&id)
            {
                self.origins.ready.pop_front();
                continue;
            }
            let update = self.origins.held.get_mut(&id).and_then(|held| held.pop(&id));
            if let Some((key, update)) = update {
                self.origins.releasing = true;
                let result = self.dispatch_update(key, update);
                self.origins.releasing = false;
                if result.is_err() {
                    self.log_errors.fetch_add(1, Ordering::Relaxed);
                }
                used += 1;
            }
            if self.origins.held.get(&id).is_none_or(Held::is_empty) {
                self.origins.held.remove(&id);
                self.origins.ready.pop_front();
            }
        }
        used
    }

    pub(super) fn retry_origins(&mut self, limit: usize) -> Result<(), HubError> {
        let ids: Vec<_> = self.origins.retry.keys().take(limit).cloned().collect();
        let mut error = None;
        for id in ids {
            let Some(record) = self.origins.retry.remove(&id) else { continue };
            self.origins.releasing = true;
            let result = self.origin(&id, record.state, record.since);
            self.origins.releasing = false;
            if let Err(failure) = result {
                error.get_or_insert(failure);
            } else if !self.published.load().is_origin_leaving(&id)
                && self.origins.held.contains_key(&id)
            {
                self.origins.ready.push_back(id);
            }
        }
        error.map_or(Ok(()), Err)
    }

    fn retire_finished_source(&mut self, id: &str) {
        let index = self.published.load();
        if index.origin(id).is_none()
            && index.last_removed_seq(id).is_none()
            && !index.has_origin_rows(id)
            && !self.origins.held.contains_key(id)
        {
            let mut sources = self.sources.load_full().as_ref().clone();
            sources.remove(id);
            self.sources.store(Arc::new(sources));
            self.origins.ended.remove(id);
        }
    }

    pub(super) fn retire_origin_sources(&mut self, old: &SummaryIndex, next: &SummaryIndex) {
        let mut sources = None;
        for origin in old.origins() {
            if origin.state == OriginState::Removed
                && next.origin(&origin.id).is_none()
                && !next.has_origin_rows(&origin.id)
                && !self.origins.held.contains_key(&origin.id)
            {
                self.origins.ended.remove(&origin.id);
                sources
                    .get_or_insert_with(|| self.sources.load_full().as_ref().clone())
                    .remove(&origin.id);
            }
        }
        if let Some(sources) = sources {
            self.sources.store(Arc::new(sources));
        }
    }
}
