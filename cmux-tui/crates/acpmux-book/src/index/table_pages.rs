//! Hot folder/fork ranges. Cold requests use the physical snapshot pager.

use super::{IndexPage, ListFilter, ReadSide, RowKey, SortKey, SummaryIndex};
use std::cmp::Ordering;
use std::io;
use std::ops::Bound::{Excluded, Included, Unbounded};

fn compare(filter: &ListFilter, a: &SortKey, b: &SortKey) -> Ordering {
    if filter.forks.is_some() { a.row.cmp(&b.row) } else { a.cmp(b) }
}

impl SummaryIndex {
    fn hot_table_keys(
        &self,
        filter: &ListFilter,
        anchor: Option<&SortKey>,
        side: ReadSide,
        inclusive: bool,
        limit: usize,
    ) -> Vec<SortKey> {
        if side == ReadSide::Around {
            let mut keys = self.hot_table_keys(filter, anchor, ReadSide::Before, false, limit);
            keys.extend(self.hot_table_keys(filter, anchor, ReadSide::After, true, limit));
            let pivot = anchor
                .map_or(0, |anchor| {
                    keys.partition_point(|key| compare(filter, key, anchor).is_lt())
                })
                .min(keys.len().saturating_sub(1));
            let (mut left, mut right) = (pivot, pivot);
            for n in 0..limit {
                if right >= keys.len() && left == 0 {
                    break;
                }
                if right >= keys.len() || (left > 0 && n % 2 == 1) {
                    left -= 1;
                } else {
                    right += 1;
                }
            }
            return keys.get(left..right).unwrap_or_default().to_vec();
        }
        let mut keys = Vec::new();
        if let Some(folder) = &filter.folder
            && let Some(table) = self.kin().folder_rows(folder)
        {
            let bound = anchor
                .map_or(Unbounded, |key| if inclusive { Included(key) } else { Excluded(key) });
            if side == ReadSide::Before {
                keys.extend(
                    table
                        .range::<_, SortKey>((Unbounded, bound))
                        .rev()
                        .take(limit)
                        .map(|(key, _)| key.clone()),
                );
                keys.reverse();
            } else {
                keys.extend(
                    table
                        .range::<_, SortKey>((bound, Unbounded))
                        .take(limit)
                        .map(|(key, _)| key.clone()),
                );
            }
        } else if let Some(root) = &filter.forks
            && let Some(table) = self.kin().forks(root)
        {
            let bound = anchor.map_or(Unbounded, |key| {
                if inclusive { Included(&key.row) } else { Excluded(&key.row) }
            });
            if side == ReadSide::Before {
                keys.extend(
                    table
                        .range::<_, RowKey>((Unbounded, bound))
                        .rev()
                        .take(limit)
                        .map(|(key, _)| SortKey { last_activity: 0, row: key.clone() }),
                );
                keys.reverse();
            } else {
                keys.extend(
                    table
                        .range::<_, RowKey>((bound, Unbounded))
                        .take(limit)
                        .map(|(key, _)| SortKey { last_activity: 0, row: key.clone() }),
                );
            }
        }
        keys
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn read_hot_table_page(
        &self,
        anchor: Option<&SortKey>,
        side: ReadSide,
        inclusive: bool,
        limit: usize,
        max_bytes: usize,
        filter: &ListFilter,
    ) -> io::Result<IndexPage> {
        let side = if anchor.is_none() { ReadSide::After } else { side };
        let inclusive = inclusive || side == ReadSide::Around;
        let keys = self.hot_table_keys(filter, anchor, side, inclusive, limit + 1);
        let rows_read = keys.len();
        let mut candidates = Vec::with_capacity(keys.len());
        for key in keys {
            let row = self.get_row(&key.row).ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidData, "table names a missing hot row")
            })?;
            candidates.push((SortKey::of(&row), row));
        }
        let pivot = match side {
            ReadSide::Before => candidates.len(),
            ReadSide::After => 0,
            ReadSide::Around => anchor
                .map_or(0, |anchor| {
                    candidates.partition_point(|(key, _)| compare(filter, key, anchor).is_lt())
                })
                .min(candidates.len().saturating_sub(1)),
        };
        let (mut left, mut right) = (pivot, pivot);
        let mut bytes = 0usize;
        let mut consumed = 0;
        while consumed < limit && (left > 0 || right < candidates.len()) {
            let take_left = side == ReadSide::Before
                || (side == ReadSide::Around
                    && (right >= candidates.len() || (left > 0 && consumed % 2 == 1)));
            let position = if take_left { left.saturating_sub(1) } else { right };
            let Some((_, row)) = candidates.get(position) else {
                break;
            };
            let size = if filter.matches(row) { row.encoded_len() + 1 } else { 0 };
            if bytes.saturating_add(size) > max_bytes {
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
        let before_key = piece.first().map(|(key, _)| key.clone());
        let after_key = piece.last().map(|(key, _)| key.clone());
        let has_before = before_key.as_ref().or(anchor).is_some_and(|key| {
            !self
                .hot_table_keys(
                    filter,
                    Some(key),
                    ReadSide::Before,
                    before_key.is_none() && side == ReadSide::After && !inclusive,
                    1,
                )
                .is_empty()
        });
        let has_after = after_key.as_ref().or(anchor).is_some_and(|key| {
            !self
                .hot_table_keys(
                    filter,
                    Some(key),
                    ReadSide::After,
                    after_key.is_none() && side == ReadSide::Before && !inclusive,
                    1,
                )
                .is_empty()
        });
        Ok(IndexPage {
            rows: piece
                .iter()
                .filter(|(_, row)| filter.matches(row))
                .map(|(_, row)| row.clone())
                .collect(),
            has_before,
            has_after,
            before_key,
            after_key,
            bytes_read: 0,
            cold_unread: !has_after && self.disk().is_some_and(|disk| !disk.is_empty()),
            rows_read,
            parent_steps: 0,
        })
    }
}
