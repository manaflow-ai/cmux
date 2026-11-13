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
    pub(super) fn view_history(&self, view: Option<ListView>) -> &Arc<Mutex<History>> {
        if is_folders(view) { &self.folder_history } else { &self.history }
    }

    pub(super) fn folder_window(
        &self,
        sub: &Sub,
        index: &SummaryIndex,
        seq: u64,
    ) -> Result<Frame, HubError> {
        if sub.filter.is_some() || !matches!(sub.anchor, None | Some(Anchor::End)) {
            return Err(HubError::InvalidParams(
                "folders subscriptions read an unfiltered head".into(),
            ));
        }
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
                |row| visible(index, row),
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
        validate_filter(request.filter.as_ref())?;
        let index = self.snapshot();
        let max = request.max_bytes as usize;
        let budget = max.saturating_sub(8192 + request.sid.len());
        acpmux_book::index::folders::validate_page_bound(MAX_WINDOW_ROWS, budget)
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
            let mut used = 0usize;
            for (n, key) in keys.iter().enumerate() {
                let row = index
                    .folders()
                    .get(&FolderKey::new(key.origin.as_str(), key.folder.as_str()))
                    .filter(|row| visible(&index, row));
                let cost = row.as_ref().map_or_else(
                    || serde_json::to_vec(key).map_or(usize::MAX, |bytes| bytes.len() + 1),
                    |row| row.encoded_len() + 1,
                );
                if used.saturating_add(cost) > budget {
                    if n == 0 {
                        return Err(HubError::InvalidPage);
                    }
                    reply.rest = keys.iter().skip(n).map(|key| (*key).clone()).collect();
                    break;
                }
                used += cost;
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

/// Hydration and cold eviction change the hot projection without a log write.
/// Give those changes ordinary stream positions, so an already open window or
/// a disconnected reader observes them through the same bounded replay ring.
pub(super) fn projection_change(
    before: &SummaryIndex,
    next: &mut SummaryIndex,
    key: &RowKey,
    events: &mut Vec<(u64, Vec<FolderOp>)>,
) {
    let ops =
        next.folder_changes(before, before.get_row(key).as_deref(), next.get_row(key).as_deref());
    if !ops.is_empty() {
        let seq = next.seq().saturating_add(1);
        *next = next.advance_seq(seq);
        events.push((seq, ops));
    }
}

impl HubWriter {
    pub(super) fn publish_folder_events(&self, events: Vec<(u64, Vec<FolderOp>)>) {
        for (seq, ops) in events {
            self.record_history_with_folders(ListItem::Folders { seq, ops: Vec::new() }, &ops);
            self.publish_gone(seq, &RowKey::new("", ""));
        }
    }
}
