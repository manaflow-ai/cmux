use super::{SortKey, Summary, SummaryIndex};
use serde::{Deserialize, Serialize};
use std::io;
use std::sync::Arc;

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct ListFilter {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
}

impl ListFilter {
    fn matches(&self, summary: &Summary) -> bool {
        self.workspace.as_ref().is_none_or(|value| summary.workspace.as_ref() == Some(value))
            && self.origin.as_ref().is_none_or(|value| &summary.origin == value)
            && self.state.as_ref().is_none_or(|value| &summary.state == value)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReadSide {
    Before,
    After,
    Around,
}

pub struct IndexPage {
    pub rows: Vec<Arc<Summary>>,
    pub has_before: bool,
    pub has_after: bool,
    pub before_key: Option<SortKey>,
    pub after_key: Option<SortKey>,
    pub bytes_read: usize,
}

impl SummaryIndex {
    /// One physical piece. Flags and continuation name remaining candidates,
    /// including rows a filter or a newer summary will hide (decision 93).
    pub fn read_page(
        &self,
        anchor: Option<&SortKey>,
        side: ReadSide,
        inclusive: bool,
        limit: usize,
        max_bytes: usize,
        filter: Option<&ListFilter>,
    ) -> io::Result<IndexPage> {
        if limit == 0 || limit > 400 || max_bytes == 0 || max_bytes > super::snapshot::PAGE_BYTES {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid index page bound"));
        }
        let inclusive = inclusive || side == ReadSide::Around;
        let side = if anchor.is_none() { ReadSide::After } else { side };
        let mut candidates: Vec<(SortKey, Option<Arc<Summary>>)> = Vec::new();
        let mut disk_before = false;
        let mut disk_after = false;
        let mut bytes_read = 0;
        if let Some(disk) = self.disk() {
            // `max_bytes` is the encoded response budget, while a disk record
            // also carries index framing and a trailer. Read one bounded
            // physical piece with enough room to decode a record whose
            // summary itself fits the response budget; selection below still
            // enforces `max_bytes` on returned rows.
            let physical_bytes = max_bytes
                .saturating_add(super::MAX_INDEX_RECORD_BYTES)
                .min(super::snapshot::PAGE_BYTES);
            let piece = disk.read_piece(anchor, side, inclusive, limit, physical_bytes)?;
            bytes_read = piece.bytes_read;
            disk_before = piece.has_before;
            disk_after = piece.has_after;
            for row in piece.rows {
                let key = SortKey::of(&row);
                let visible = SummaryIndex::contributes_to_index(&row)
                    && !self.is_shadowed(&row.key())
                    && !self.is_origin_removed(row.origin.as_str())
                    && !self.is_snapshot_origin_hidden(row.origin.as_str())
                    && self.get_row(&row.key()).is_none();
                candidates.push((key, visible.then_some(row)));
            }
        }
        let mut hot: Vec<(SortKey, Option<Arc<Summary>>)> = match (anchor, side) {
            (None, _) => self.after_candidates(None, limit + 1),
            (Some(key), ReadSide::After) => self.after_candidates(Some(key), limit + 1),
            (Some(key), ReadSide::Before) => self.before_candidates(key, limit + 1),
            (Some(key), ReadSide::Around) => {
                let mut rows = self.before_candidates(key, limit + 1);
                rows.extend(self.after_candidates(Some(key), limit + 1));
                rows
            }
        };
        if inclusive
            && let Some(anchor) = anchor
            && let Some(row) = self.get_row(&anchor.row)
            && SortKey::of(&row) == *anchor
        {
            hot.push((SortKey::of(&row), Some(row)));
        }
        let disk_first = candidates.first().map(|(key, _)| {
            if side == ReadSide::Around {
                anchor.map_or(key, |anchor| anchor.min(key)).clone()
            } else {
                key.clone()
            }
        });
        let disk_last = candidates.last().map(|(key, _)| {
            if side == ReadSide::Around {
                anchor.map_or(key, |anchor| anchor.max(key)).clone()
            } else {
                key.clone()
            }
        });
        for (key, row) in hot {
            if side != ReadSide::Before
                && disk_after
                && disk_last.as_ref().is_some_and(|last| &key > last)
            {
                continue;
            }
            if side != ReadSide::After
                && disk_before
                && disk_first.as_ref().is_some_and(|first| &key < first)
            {
                continue;
            }
            candidates.push((key, row));
        }
        candidates.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| b.1.is_some().cmp(&a.1.is_some())));
        candidates.dedup_by(|a, b| a.0 == b.0);
        let end = match (anchor, side) {
            (Some(key), ReadSide::Before) => candidates.partition_point(|(candidate, _)| {
                candidate < key || (inclusive && candidate == key)
            }),
            _ => candidates.len(),
        };
        let begin = match (anchor, side) {
            (Some(key), ReadSide::After) => candidates.partition_point(|(candidate, _)| {
                candidate < key || (!inclusive && candidate == key)
            }),
            _ => 0,
        };
        // Consume a contiguous interval in the direction requested. In
        // particular, a byte cap on `before` retains the nearest rows, and
        // `around` starts at its anchor before spending bytes on either side.
        let pivot = match (anchor, side) {
            (Some(_), ReadSide::Before) => end,
            (Some(key), ReadSide::Around) => candidates
                .partition_point(|(candidate, _)| candidate < key)
                .min(end.saturating_sub(1)),
            _ => begin,
        };
        let mut left = pivot;
        let mut right = pivot;
        let mut bytes = 0usize;
        let mut consumed = 0;
        while consumed < limit && (left > begin || right < end) {
            let take_left = match side {
                ReadSide::Before => true,
                ReadSide::After => false,
                ReadSide::Around => right >= end || (left > begin && consumed % 2 == 1),
            };
            let position = if take_left { left.saturating_sub(1) } else { right };
            let Some((_, row)) = candidates.get(position) else { break };
            let row = row.as_ref().filter(|row| filter.is_none_or(|filter| filter.matches(row)));
            let size = row.map_or(0, |row| row.encoded_len() + 1);
            if bytes + size > max_bytes {
                if consumed == 0 {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "page byte budget cannot fit the next row",
                    ));
                }
                break;
            }
            bytes += size;
            consumed += 1;
            if take_left {
                left = position;
            } else {
                right += 1;
            }
        }
        let piece = candidates.get(left..right).unwrap_or_default();
        let selected = piece
            .iter()
            .filter_map(|(_, row)| row.as_ref())
            .filter(|row| filter.is_none_or(|filter| filter.matches(row)))
            .cloned()
            .collect();
        let first = piece.first().map(|(key, _)| key.clone());
        let last = piece.last().map(|(key, _)| key.clone());
        // The extra hot candidate already proves whether the requested side
        // continues. Only the opposite side of a directional anchor needs a
        // lookup; querying both selected endpoints repeated tree walks even
        // for an unanchored first window.
        let has_before = disk_before
            || left > 0
            || (side == ReadSide::After
                && anchor.is_some_and(|key| {
                    !self.before_candidates(key, 1).is_empty()
                        || (!inclusive
                            && self.get_row(&key.row).is_some_and(|row| SortKey::of(&row) == *key))
                }));
        let has_after = disk_after
            || right < candidates.len()
            || (side == ReadSide::Before
                && anchor.is_some_and(|key| {
                    !self.after_candidates(Some(key), 1).is_empty()
                        || (!inclusive
                            && self.get_row(&key.row).is_some_and(|row| SortKey::of(&row) == *key))
                }));
        Ok(IndexPage {
            rows: selected,
            has_before,
            has_after,
            before_key: first,
            after_key: last,
            bytes_read,
        })
    }
}
