use super::*;
use crate::wire::{ListKey, Page, PageResult};
use acpmux_book::index::MAX_INDEX_RECORD_BYTES;
use serde_json::value::RawValue;

// JSON can expand each raw key byte to a six-byte escape. The record bound
// includes all texts, keys and framing, so this also covers an escaped row.
const MAX_WIRE_ROW_BYTES: usize = 6 * MAX_INDEX_RECORD_BYTES;

impl Hub {
    pub(super) fn keyed_page(&self, request: &Page, keys: &[ListKey]) -> Result<Frame, HubError> {
        let max = request.max_bytes as usize;
        let mut reply = PageResult::<Box<RawValue>> {
            sid: request.sid.clone(),
            rows: Vec::new(),
            has_before: false,
            has_after: false,
            cold_unread: false,
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
        let mut used = Frame::json(FrameKind::Page, &reply)?.encoded_len()
            + key_sizes.iter().sum::<usize>()
            + keys.len()
            + 64;
        let index = self.snapshot();
        let provider = self.page_provider.lock().ok().and_then(|slot| slot.clone());
        for (position, (key, key_bytes)) in keys.iter().zip(&key_sizes).enumerate() {
            // Do not read a row and then put its key back in rest. Reserve the
            // largest valid row before the lookup, except the first lookup:
            // that either makes progress or returns a named invalid-page error.
            if position != 0 && used + MAX_WIRE_ROW_BYTES > max {
                reply.rest.extend(keys.iter().skip(position).cloned());
                break;
            }
            let row_key = book_key(key).row;
            let row = match index.get_row(&row_key) {
                Some(row) => Some(row),
                None => {
                    provider.as_ref().map(|provider| provider.row(&row_key)).transpose()?.flatten()
                }
            };
            if let Some(row) = row {
                let raw =
                    serde_json::value::to_raw_value(row.as_ref()).map_err(FrameError::Encode)?;
                used = used - key_bytes + raw.get().len() + 1;
                reply.rows.push(raw);
                if used > max {
                    // The conservative metadata reserve can exceed the exact
                    // frame size. Refuse only if this first answer truly fails.
                    reply.rest.extend(keys.iter().skip(position + 1).cloned());
                    let frame = Frame::json(FrameKind::Page, &reply)?;
                    return if frame.encoded_len() <= max {
                        Ok(frame)
                    } else {
                        Err(HubError::InvalidPage)
                    };
                }
            } else if key.origin == "local" {
                reply.missing.push(key.clone());
            } else {
                reply.unknown.push(key.clone());
            }
        }
        let frame = Frame::json(FrameKind::Page, &reply)?;
        if frame.encoded_len() > max {
            return Err(HubError::InvalidPage);
        }
        Ok(frame)
    }
}

#[cfg(test)]
mod tests;
