//! Folder reads and view-specific delivery share the published index roots.
use super::*;
use crate::wire::{
    Anchor, FolderPageResult, FolderPosition, FolderWindow, ListView, PageKey, PageSide, Position,
};
use acpmux_book::index::folders::{FolderCursor, FolderKey, FolderOp, FolderReadSide, FolderRow};

pub(super) fn is_folders(view: Option<ListView>) -> bool {
    view == Some(ListView::Folders)
}

fn position(key: FolderCursor) -> FolderPosition {
    FolderPosition {
        at: key.at,
        origin: key.key.origin.to_string(),
        folder: key.key.folder.to_string(),
    }
}

fn cursor(key: &FolderPosition) -> Result<FolderCursor, HubError> {
    let key_value = FolderKey::new(key.origin.as_str(), key.folder.as_str());
    key_value.validate().map_err(HubError::page_error)?;
    Ok(FolderCursor::new(key.at, key_value))
}

fn validate_filter(filter: Option<&crate::wire::ListFilter>) -> Result<(), HubError> {
    if filter.is_some_and(|f| {
        f.family.is_some()
            || f.forks.is_some()
            || f.folder.is_some()
            || f.cold
            || f.workspace.is_some()
            || f.state.is_some()
    }) {
        return Err(HubError::InvalidParams("folders supports only the origin filter".into()));
    }
    Ok(())
}

fn visible(index: &SummaryIndex, row: &FolderRow) -> bool {
    !index.is_origin_removed(&row.origin) && !index.is_origin_leaving(&row.origin)
}

impl Hub {
    pub(super) fn folder_window(&self, sub: &Sub) -> Result<Frame, HubError> {
        if sub.filter.is_some() || !matches!(sub.anchor, None | Some(Anchor::End)) {
            return Err(HubError::InvalidParams(
                "folders subscriptions read an unfiltered head".into(),
            ));
        }
        self.require_folders_ready()?;
        let state = self.folder_state.lock().map_err(|_| HubError::WriterGone)?;
        let seq = state.seq;
        let index = self.snapshot();
        let anchor = None;
        let side = FolderReadSide::After;
        let page = index
            .folders()
            .read_page_visible(
                anchor.as_ref(),
                side,
                true,
                validate_window(sub)?,
                crate::wire::MAX_PAGE_BYTES.saturating_sub(8192 + sub.sid.len()),
                sub.filter.as_ref(),
                |row| visible(&index, row),
            )
            .map_err(HubError::page_error)?;
        let window = FolderWindow {
            sid: sub.sid.clone(),
            cursor: seq,
            edition: index.edition(),
            rows: page.rows.iter().map(|row| row.as_ref().clone()).collect(),
            has_before: page.has_before,
            has_after: page.has_after,
            before_key: page.before_key.map(position),
            after_key: page.after_key.map(position),
            origins: index
                .origins()
                .map(|origin| Origin {
                    id: origin.id.clone(),
                    state: origin.state,
                    since: origin.since,
                    extra: origin
                        .extra
                        .as_ref()
                        .and_then(|extra| serde_json::from_str(extra.get()).ok()),
                })
                .collect(),
        };
        let frame = Frame::json(FrameKind::Window, &window)?;
        if frame.encoded_len() > crate::wire::MAX_PAGE_BYTES {
            return Err(HubError::InvalidWindow);
        }
        Ok(frame)
    }

    pub(super) fn folder_page(&self, request: &crate::wire::Page) -> Result<Frame, HubError> {
        self.require_folders_ready()?;
        validate_filter(request.filter.as_ref())?;
        let index = self.snapshot();
        let max = request.max_bytes as usize;
        let budget = max.saturating_sub(8192 + request.sid.len());
        acpmux_book::index::folders::Folders::validate_page_bound(MAX_WINDOW_ROWS, budget)
            .map_err(HubError::page_error)?;
        let mut reply = FolderPageResult {
            sid: request.sid.clone(),
            rows: Vec::new(),
            has_before: false,
            has_after: false,
            cold_unread: false,
            before_key: None,
            after_key: None,
            missing: Vec::new(),
            rest: Vec::new(),
        };
        if let Some(keys) = &request.keys {
            if keys.is_empty()
                || keys.len() > 100
                || request.before.is_some()
                || request.after.is_some()
            {
                return Err(HubError::InvalidPage);
            }
            // Validate the complete request before reading any row.
            let keys = keys
                .iter()
                .map(|key| match key {
                    PageKey::Folder(key) => {
                        FolderKey::new(key.origin.as_str(), key.folder.as_str())
                            .validate()
                            .map(|_| key)
                            .map_err(HubError::page_error)
                    }
                    _ => Err(HubError::InvalidPage),
                })
                .collect::<Result<Vec<_>, _>>()?;
            // Every unanswered identity travels in `rest`. Reserve those
            // bytes before admitting rows, so a legal prefix never turns into
            // an oversized frame merely by attaching its continuation.
            let key_costs = keys
                .iter()
                .map(|key| serde_json::to_vec(key).map(|bytes| bytes.len() + 1))
                .collect::<Result<Vec<_>, _>>()
                .map_err(FrameError::Encode)?;
            let mut used = key_costs.iter().copied().sum::<usize>();
            if used > budget {
                return Err(HubError::InvalidPage);
            }
            for (n, (key, key_cost)) in keys.iter().zip(key_costs).enumerate() {
                let row = index
                    .folders()
                    .get(&FolderKey::new(key.origin.as_str(), key.folder.as_str()))
                    .filter(|row| visible(&index, row));
                let cost = row.as_ref().map_or(key_cost, |row| row.encoded_len() + 1);
                let next_used = used.saturating_sub(key_cost).saturating_add(cost);
                if next_used > budget {
                    if n == 0 {
                        return Err(HubError::InvalidPage);
                    }
                    reply.rest = keys.iter().skip(n).map(|key| (*key).clone()).collect();
                    break;
                }
                used = next_used;
                if let Some(row) = row {
                    if request
                        .filter
                        .as_ref()
                        .and_then(|f| f.origin.as_deref())
                        .is_none_or(|origin| row.origin.as_ref() == origin)
                    {
                        reply.rows.push(row.as_ref().clone());
                    }
                } else {
                    reply.missing.push((*key).clone());
                }
            }
        } else {
            let (anchor, side) = match request.side() {
                Some((PageSide::Before, Position::Folder(key))) => {
                    (Some(cursor(key)?), FolderReadSide::Before)
                }
                Some((PageSide::After, Position::Folder(key))) => {
                    (Some(cursor(key)?), FolderReadSide::After)
                }
                None if request.before.is_none() && request.after.is_none() => {
                    (None, FolderReadSide::After)
                }
                _ => return Err(HubError::InvalidPage),
            };
            let page = index
                .folders()
                .read_page_visible(
                    anchor.as_ref(),
                    side,
                    false,
                    MAX_WINDOW_ROWS,
                    budget,
                    request.filter.as_ref(),
                    |row| visible(&index, row),
                )
                .map_err(HubError::page_error)?;
            reply.rows = page.rows.iter().map(|row| row.as_ref().clone()).collect();
            reply.has_before = page.has_before;
            reply.has_after = page.has_after;
            reply.before_key = page.before_key.map(position);
            reply.after_key = page.after_key.map(position);
        }
        let frame = Frame::json(FrameKind::Page, &reply)?;
        if frame.encoded_len() > max {
            return Err(HubError::InvalidPage);
        }
        Ok(frame)
    }
}

pub(super) fn decode_item(bytes: Vec<u8>, seq: u64) -> Option<ListItem> {
    let mut array = Vec::with_capacity(bytes.len() + 2);
    array.push(b'[');
    array.extend_from_slice(&bytes);
    array.push(b']');
    let ops = serde_json::from_slice::<Vec<crate::wire::DeltaOp<Summary>>>(&array).ok()?;
    let mut changes = Vec::new();
    for op in ops {
        match op {
            crate::wire::DeltaOp::Folder { row, .. } => {
                changes.push(FolderOp::Folder(Arc::new(row)))
            }
            crate::wire::DeltaOp::FolderGone { origin, folder, .. } => {
                changes.push(FolderOp::Gone(FolderKey::new(origin, folder)))
            }
            crate::wire::DeltaOp::Origin { origin, seq } => {
                return Some(ListItem::Origin { seq, origin });
            }
            _ => return None,
        }
    }
    Some(ListItem::Folders { seq, ops: changes })
}

/// Only the latest bounded delivery is retained, never a replay history.
/// A reader that misses it receives a fresh window from the published view.
pub(super) struct FolderState {
    pub(super) seq: u64,
    latest: Option<Arc<Vec<u8>>>,
}
impl Default for FolderState {
    fn default() -> Self {
        Self { seq: 1, latest: None }
    }
}

impl Hub {
    fn require_folders_ready(&self) -> Result<(), HubError> {
        if *self.hydrated.borrow() == disk::HydrationState::Ready {
            Ok(())
        } else {
            Err(HubError::HydrationFailed)
        }
    }
}

impl ListReceiver {
    pub(super) fn next_folders(&self, max_bytes: usize) -> Option<RawRead> {
        let mut subscriber = self.subscriber.state.lock().ok()?;
        if subscriber.ended {
            return None;
        }
        let latest = self.folder_state.lock().ok()?;
        if subscriber.cursor == latest.seq {
            return None;
        }
        if subscriber.cursor.saturating_add(1) != latest.seq {
            subscriber.ended = true;
            return Some(RawRead::Lagged);
        }
        let Some(bytes) = latest.latest.as_ref().filter(|bytes| bytes.len() <= max_bytes) else {
            subscriber.ended = true;
            return Some(RawRead::Lagged);
        };
        subscriber.cursor = latest.seq;
        Some(RawRead::Span(history::RawSpan::folder(bytes.as_ref().clone(), latest.seq)))
    }
}

pub(super) fn changed_folders(
    before: &SummaryIndex,
    next: &SummaryIndex,
    touched: impl IntoIterator<Item = acpmux_book::index::FolderKey>,
) -> Vec<FolderOp> {
    touched
        .into_iter()
        .filter_map(|folder| {
            let key = FolderKey::new(folder.origin, folder.folder);
            let old = before.folders().get(&key).filter(|row| visible(before, row));
            let new = next.folders().get(&key).filter(|row| visible(next, row));
            if old == new {
                return None;
            }
            new.map(FolderOp::Folder).or_else(|| old.map(|_| FolderOp::Gone(key)))
        })
        .collect()
}

impl HubWriter {
    pub(super) fn publish_folder_index(&self, next: SummaryIndex, ops: &[FolderOp]) {
        self.publish_folder_update(next, ops, None);
    }

    pub(super) fn publish_folder_origin(&self, next: SummaryIndex, origin: Origin) {
        self.publish_folder_update(next, &[], Some(origin));
    }

    fn publish_folder_update(&self, next: SummaryIndex, ops: &[FolderOp], origin: Option<Origin>) {
        let mut state = match self.folder_state.lock() {
            Ok(state) => state,
            Err(_) => {
                self.published.store(Arc::new(next));
                return;
            }
        };
        let changed = (!ops.is_empty() || origin.is_some())
            && *self.hydrated.borrow() == disk::HydrationState::Ready;
        if changed {
            state.seq = state.seq.saturating_add(1);
            let mut bytes = Vec::new();
            let mut valid = true;
            for (n, op) in ops.iter().enumerate() {
                if n != 0 {
                    bytes.push(b',');
                }
                let op: crate::wire::DeltaOp<Summary> = match op {
                    FolderOp::Folder(row) => {
                        crate::wire::DeltaOp::Folder { seq: state.seq, row: row.as_ref().clone() }
                    }
                    FolderOp::Gone(key) => crate::wire::DeltaOp::FolderGone {
                        seq: state.seq,
                        origin: key.origin.to_string(),
                        folder: key.folder.to_string(),
                    },
                };
                if serde_json::to_writer(&mut bytes, &op).is_err()
                    || bytes.len() > crate::wire::MAX_PAGE_BYTES.saturating_sub(8192)
                {
                    valid = false;
                    break;
                }
            }
            if let Some(origin) = origin {
                if !bytes.is_empty() {
                    bytes.push(b',');
                }
                let op: crate::wire::DeltaOp<Summary> =
                    crate::wire::DeltaOp::Origin { seq: state.seq, origin };
                valid &= serde_json::to_writer(&mut bytes, &op).is_ok();
            }
            state.latest = valid.then(|| Arc::new(bytes));
        }
        self.published.store(Arc::new(next));
        drop(state);
        if changed {
            // This notification is independent of the durable summary cursor.
            if let Ok(subscribers) = self.subscribers.lock() {
                for subscriber in subscribers.iter() {
                    subscriber.notify.notify_one();
                }
            }
        }
    }
}
