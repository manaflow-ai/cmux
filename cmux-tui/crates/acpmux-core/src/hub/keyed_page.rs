use super::*;
use crate::wire::{ListKey, Page, PageKey, PageResult};
use acpmux_book::index::MAX_INDEX_RECORD_BYTES;
use serde_json::value::RawValue;

// JSON can expand each raw key byte to a six-byte escape. The record bound
// includes all texts, keys and framing, so this also covers an escaped row.
const MAX_WIRE_ROW_BYTES: usize = 6 * MAX_INDEX_RECORD_BYTES;

/// What one asked key comes to, in the order asked.
pub(super) enum Entry {
    Row(Box<RawValue>),
    Missing(ListKey),
    Unknown(ListKey),
    Rest(ListKey),
    /// Its origin's relay is asked for it (row 8b). Its key's room is held; the origin's
    /// answer gets the room the plan leaves.
    Ask(ListKey),
}

/// A keyed page's answer before it is framed: what each key came to, and the reply's room.
pub(super) struct KeyedPlan {
    sid: String,
    max: usize,
    /// The reply's bytes so far: its frame, every key, and each row read here.
    pub(super) used: usize,
    pub(super) entries: Vec<Entry>,
}

impl KeyedPlan {
    /// Rows in the order asked, then `missing`, `unknown` and `rest`, each in that order.
    pub(super) fn finish(self) -> Result<Frame, HubError> {
        let mut reply = PageResult::<Box<RawValue>> {
            sid: self.sid,
            rows: Vec::new(),
            has_before: false,
            has_after: false,
            cold_unread: false,
            deeper: Vec::new(),
            before_key: None,
            after_key: None,
            missing: Vec::new(),
            unknown: Vec::new(),
            rest: Vec::new(),
        };
        for entry in self.entries {
            match entry {
                Entry::Row(row) => reply.rows.push(row),
                Entry::Missing(key) => reply.missing.push(key),
                Entry::Unknown(key) | Entry::Ask(key) => reply.unknown.push(key),
                Entry::Rest(key) => reply.rest.push(key),
            }
        }
        let frame = Frame::json(FrameKind::Page, &reply)?;
        if frame.encoded_len() > self.max {
            return Err(HubError::InvalidPage);
        }
        Ok(frame)
    }
}

impl Hub {
    /// `peer`: the rows go out in peer form, and only this machine's rows are read (a peer's
    /// keys are all `local`: `peer_page_shape`), so the provider never reads another machine's.
    pub(super) fn keyed_page(
        &self,
        request: &Page,
        keys: &[PageKey],
        peer: bool,
    ) -> Result<Frame, HubError> {
        self.keyed_plan(request, keys, peer, None)?.finish()
    }

    /// What each key comes to. A key the index lacks whose origin `relays` takes is an
    /// [`Entry::Ask`] and holds a row's room; any other miss asks the provider, as before.
    pub(super) fn keyed_plan(
        &self,
        request: &Page,
        keys: &[PageKey],
        peer: bool,
        relays: Option<&dyn Fn(&str) -> bool>,
    ) -> Result<KeyedPlan, HubError> {
        let keys = keys
            .iter()
            .map(|key| {
                let PageKey::Summary(key) = key else { return Err(HubError::InvalidPage) };
                // A `past` key is a position, not a row (decision 290): no keyed page takes one.
                if key.past {
                    return Err(HubError::InvalidPage);
                }
                Ok(key)
            })
            .collect::<Result<Vec<_>, _>>()?;
        let max = request.max_bytes as usize;
        let empty = PageResult::<Box<RawValue>> {
            sid: request.sid.clone(),
            rows: Vec::new(),
            has_before: false,
            has_after: false,
            cold_unread: false,
            deeper: Vec::new(),
            before_key: None,
            after_key: None,
            missing: Vec::new(),
            unknown: Vec::new(),
            rest: Vec::new(),
        };
        let key_sizes = keys
            .iter()
            .map(|key| serde_json::to_vec(key).map(|bytes| bytes.len()).map_err(FrameError::Encode))
            .collect::<Result<Vec<_>, _>>()?;
        // Charge every key up front: it may end in missing, unknown or rest.
        // 64 covers all three optional array names, brackets and separators.
        let mut used = Frame::json(FrameKind::Page, &empty)?.encoded_len()
            + key_sizes.iter().sum::<usize>()
            + keys.len()
            + 64;
        let mut plan = KeyedPlan { sid: request.sid.clone(), max, used: 0, entries: Vec::new() };
        let index = self.snapshot();
        let provider = self.page_provider.lock().ok().and_then(|slot| slot.clone());
        for (position, (key, key_bytes)) in keys.iter().copied().zip(&key_sizes).enumerate() {
            // Do not read a row and then put its key back in rest. Reserve the
            // largest valid row before the lookup, except the first lookup:
            // that either makes progress or returns a named invalid-page error.
            if position != 0 && used + MAX_WIRE_ROW_BYTES > max {
                plan.entries
                    .extend(keys.iter().skip(position).map(|key| Entry::Rest((*key).clone())));
                break;
            }
            if peer && key.origin != "local" {
                return Err(HubError::InvalidPage);
            }
            let row_key = book_key(key)?.row;
            let row = match index.get_row(&row_key) {
                Some(row) => Some(row),
                None if key.origin != "local"
                    && relays.is_some_and(|relays| relays(&key.origin)) =>
                {
                    plan.entries.push(Entry::Ask(key.clone()));
                    continue;
                }
                None => {
                    provider.as_ref().map(|provider| provider.row(&row_key)).transpose()?.flatten()
                }
            };
            if let Some(row) = row {
                let raw = if peer {
                    serde_json::value::to_raw_value(&PeerRow(row.as_ref()))
                } else {
                    serde_json::value::to_raw_value(row.as_ref())
                }
                .map_err(FrameError::Encode)?;
                used = used - key_bytes + raw.get().len() + 1;
                plan.entries.push(Entry::Row(raw));
                if used > max {
                    // The conservative metadata reserve can exceed the exact
                    // frame size. Refuse only if this first answer truly fails.
                    plan.entries.extend(
                        keys.iter().skip(position + 1).map(|key| Entry::Rest((*key).clone())),
                    );
                    break;
                }
            } else if key.origin == "local" {
                plan.entries.push(Entry::Missing(key.clone()));
            } else {
                plan.entries.push(Entry::Unknown(key.clone()));
            }
        }
        plan.used = used;
        Ok(plan)
    }
}

#[cfg(test)]
mod tests;
