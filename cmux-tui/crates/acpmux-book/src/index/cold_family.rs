//! Snapshot kin membership, resolved against the current in-memory rows.

use super::snapshot::{KinRead, KinRequest, KinResult};
use super::{IndexPage, ListFilter, MAX_KIN_DEPTH, RowKey, SortKey, Summary, SummaryIndex};
use std::io;

impl SummaryIndex {
    /// A missing cold ancestor leaves the capture's edge authoritative. A hot
    /// ancestor can prove that this captured descendant has since moved away.
    fn captured_descendant(&self, row: &Summary, root: &RowKey, steps: &mut usize) -> bool {
        if row.key() == *root {
            return false;
        }
        let Some(mut parent) = row.parent.clone() else { return false };
        for _ in 0..MAX_KIN_DEPTH {
            if &parent == root {
                return true;
            }
            *steps += 1;
            let Some(ancestor) = self.get_row(&parent) else { return true };
            let Some(next) = ancestor.parent.clone() else { return false };
            parent = next;
        }
        false
    }

    /// Called only at the last hot page. An absent or disabled table retains
    /// the pager's conservative indication, including its false positives.
    pub(super) fn family_cold_unread(&self, root: &RowKey) -> (bool, usize) {
        let Some(disk) = self.disk() else { return (false, 0) };
        let read = disk.has_cold_family(root, self.cold_before());
        let unread = match read.result {
            KinResult::Ready(unread) => unread,
            KinResult::Unavailable | KinResult::BudgetExhausted => !disk.is_empty(),
        };
        (unread, read.io.bytes)
    }

    pub(super) fn read_cold_family_page(
        &self,
        anchor: Option<&SortKey>,
        inclusive: bool,
        limit: usize,
        max_bytes: usize,
        filter: &ListFilter,
    ) -> io::Result<KinRead<IndexPage>> {
        let root = filter.family.as_ref().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "missing cold family root")
        })?;
        let Some(disk) = self.disk() else {
            return Ok(KinRead {
                result: KinResult::Unavailable,
                io: Default::default(),
                position: None,
            });
        };
        let position = anchor.map(|anchor| disk.seek_position(anchor, inclusive)).transpose()?;
        let read = disk.read_cold_family(KinRequest {
            root,
            cold_before: self.cold_before(),
            after: anchor,
            limit,
            physical_bytes: super::snapshot::PAGE_BYTES,
            position,
        });
        let read_position = read.position;
        let piece = match read.result {
            KinResult::Ready(piece) => piece,
            KinResult::Unavailable => {
                return Ok(KinRead {
                    result: KinResult::Unavailable,
                    io: read.io,
                    position: read_position,
                });
            }
            KinResult::BudgetExhausted => {
                return Ok(KinRead {
                    result: KinResult::BudgetExhausted,
                    io: read.io,
                    position: read_position,
                });
            }
        };
        let mut page = IndexPage {
            rows: Vec::new(),
            has_before: piece.has_before,
            has_after: piece.has_after,
            before_key: None,
            after_key: None,
            bytes_read: read.io.bytes,
            cold_unread: false,
            closure: piece.closure,
            rows_read: read.io.frames,
            parent_steps: 0,
            lookups: 0,
            deeper: Vec::new(),
        };
        let mut bytes = 0usize;
        for candidate in piece.rows {
            let row = candidate.row;
            let key = row.key();
            // Frames for excluded rows are rows that aged or changed since
            // the capture. Their I/O still counts toward the physical bound.
            let visible = Self::contributes_to_index(&row)
                && !self.is_shadowed(&key)
                && !self.is_origin_removed(row.origin.as_str())
                && !self.is_snapshot_origin_hidden(row.origin.as_str())
                && self.get_row(&key).is_none()
                && self.captured_descendant(&row, root, &mut page.parent_steps)
                && filter.matches(&row);
            let size = if visible { row.encoded_len() + 1 } else { 0 };
            if bytes.saturating_add(size) > max_bytes {
                if page.after_key.is_none() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "page byte budget cannot fit the next row",
                    ));
                }
                page.has_after = true;
                break;
            }
            bytes += size;
            let sort = SortKey::of(&row);
            page.before_key.get_or_insert_with(|| sort.clone());
            page.after_key = Some(sort.clone());
            if visible {
                page.lookups += 1;
                if usize::from(candidate.depth) == MAX_KIN_DEPTH
                    || self.kin().children(&key).is_some_and(|children| !children.is_empty())
                {
                    page.deeper.push(sort);
                }
                page.rows.push(row);
            }
        }
        Ok(KinRead { result: KinResult::Ready(page), io: read.io, position: read_position })
    }
}
