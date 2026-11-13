use super::{FolderKey, RowKey, SortKey, Summary, SummaryIndex};
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
    /// Return the hot family rooted at this row key.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub family: Option<RowKey>,
    /// Return hot rows in one origin/folder.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<FolderKey>,
}

impl ListFilter {
    pub fn family(root: RowKey) -> Self {
        Self { family: Some(root), ..Self::default() }
    }

    pub fn folder(folder: FolderKey) -> Self {
        Self { folder: Some(folder), ..Self::default() }
    }

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
    /// Read a bounded family page directly from the kin table. The table walk
    /// never inspects unrelated summaries; only selected hot rows are cloned.
    #[allow(clippy::too_many_arguments)]
    fn read_family_page(
        &self,
        root: &RowKey,
        side: ReadSide,
        inclusive: bool,
        limit: usize,
        max_bytes: usize,
        anchor: Option<&SortKey>,
        filter: &ListFilter,
    ) -> io::Result<IndexPage> {
        let items = self.kin().family(root);
        let mut bytes_read = 0;
        let mut cold_before = false;
        let mut cold_after = false;
        if let Some(disk) = self.disk()
            && !disk.is_empty()
        {
            let piece = disk.read_piece(anchor, side, inclusive, limit, max_bytes)?;
            bytes_read = piece.bytes_read;
            cold_before = piece.has_before;
            cold_after = piece.has_after;
            // The snapshot piece supplies bounded progress flags; the hot
            // answer remains sourced exclusively from the kin table.
        }
        let mut rows = Vec::new();
        let mut start = 0;
        let mut end = items.len();
        if let Some(anchor) = anchor
            && let Some(position) = items.iter().position(|item| {
                self.get_row(&item.key).is_some_and(|row| SortKey::of(&row) == *anchor)
            })
        {
            match side {
                ReadSide::After => start = position + usize::from(!inclusive),
                ReadSide::Before => end = position + usize::from(inclusive),
                ReadSide::Around => {
                    start = position;
                    end = (position + limit).min(items.len());
                }
            }
        }
        let mut bytes: usize = 0;
        let mut selected = 0;
        let positions: Box<dyn Iterator<Item = usize>> = match side {
            ReadSide::Before => Box::new((start..end).rev()),
            _ => Box::new(start..end),
        };
        for position in positions {
            let Some(item) = items.get(position) else { continue };
            let Some(row) = self.get_row(&item.key) else { continue };
            if !filter.matches(&row) {
                continue;
            }
            let mut row = row.as_ref().clone();
            row.depth = Some(item.depth);
            let size = row.encoded_len() + 1;
            if selected == limit || bytes.saturating_add(size) > max_bytes {
                break;
            }
            bytes += size;
            selected += 1;
            rows.push(Arc::new(row));
        }
        let truncated = selected < items.len().saturating_sub(start.min(items.len()));
        let before = start > 0 || cold_before;
        let after = truncated || cold_after;
        Ok(IndexPage {
            before_key: rows.first().map(|row| SortKey::of(row)),
            after_key: rows.last().map(|row| SortKey::of(row)),
            rows,
            has_before: before,
            has_after: after,
            bytes_read: bytes.max(bytes_read),
        })
    }

    /// Read a bounded folder page from the folder tree. Folder rows use the
    /// same activity key as `all`, so existing list anchors remain stable.
    #[allow(clippy::too_many_arguments)]
    fn read_folder_page(
        &self,
        folder: &FolderKey,
        side: ReadSide,
        inclusive: bool,
        limit: usize,
        max_bytes: usize,
        anchor: Option<&SortKey>,
        filter: &ListFilter,
    ) -> io::Result<IndexPage> {
        let indexed = self.kin().folder_rows(folder);
        let mut rows = Vec::new();
        let before = false;
        let mut after = false;
        let mut bytes_read = 0;
        let mut cold_before = false;
        let mut cold_after = false;
        if let Some(disk) = self.disk()
            && !disk.is_empty()
        {
            let piece = disk.read_piece(anchor, side, inclusive, limit, max_bytes)?;
            bytes_read = piece.bytes_read;
            cold_before = piece.has_before;
            cold_after = piece.has_after;
            for row in piece.rows {
                let key = row.key();
                if self.get_row(&key).is_none()
                    && FolderKey::of(&row).as_ref() == Some(folder)
                    && filter.matches(&row)
                {
                    rows.push(row);
                }
            }
        }
        let mut hot_rows = Vec::new();
        let mut bytes: usize = 0;
        if let Some(indexed) = indexed {
            for (key, row_key) in indexed {
                let Some(row) = self.get_row(row_key) else { continue };
                if !filter.matches(&row) {
                    continue;
                }
                hot_rows.push((key.clone(), row));
            }
        }
        rows.extend(hot_rows.into_iter().map(|(_, row)| row));
        rows.sort_by_key(|row| SortKey::of(row));
        rows.dedup_by_key(|row| row.key());
        let mut start = 0;
        let mut end = rows.len();
        if let Some(anchor) = anchor
            && let Some(position) = rows.iter().position(|row| SortKey::of(row) == *anchor)
        {
            match side {
                ReadSide::After => start = position + usize::from(!inclusive),
                ReadSide::Before => end = position + usize::from(inclusive),
                ReadSide::Around => {
                    start = position;
                    end = (position + limit).min(rows.len());
                }
            }
        }
        let positions: Box<dyn Iterator<Item = usize>> = match side {
            ReadSide::Before => Box::new((start..end).rev()),
            _ => Box::new(start..end),
        };
        let mut selected_positions = Vec::new();
        for position in positions {
            let Some(row) = rows.get(position) else { continue };
            let size = row.encoded_len() + 1;
            if selected_positions.len() == limit || bytes.saturating_add(size) > max_bytes {
                after = true;
                break;
            }
            bytes += size;
            selected_positions.push(position);
        }
        let mut selected_rows = selected_positions
            .into_iter()
            .filter_map(|position| rows.get(position).cloned())
            .collect::<Vec<_>>();
        if side == ReadSide::Before {
            selected_rows.reverse();
        }
        Ok(IndexPage {
            before_key: selected_rows.first().map(|row| SortKey::of(row)),
            after_key: selected_rows.last().map(|row| SortKey::of(row)),
            rows: selected_rows,
            has_before: before || start > 0 || cold_before,
            has_after: after || end < rows.len() || cold_after,
            bytes_read: bytes.max(bytes_read),
        })
    }

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
        if let Some(filter) = filter
            && let Some(root) = filter.family.as_ref()
        {
            return self.read_family_page(root, side, inclusive, limit, max_bytes, anchor, filter);
        }
        if let Some(filter) = filter
            && let Some(folder) = filter.folder.as_ref()
        {
            return self
                .read_folder_page(folder, side, inclusive, limit, max_bytes, anchor, filter);
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
                let visible = !self.is_shadowed(&row.key()) && self.get_row(&row.key()).is_none();
                candidates.push((key, visible.then_some(row)));
            }
        }
        let mut hot = match (anchor, side) {
            (None, _) => self.after(None, limit + 1),
            (Some(key), ReadSide::After) => self.after(Some(key), limit + 1),
            (Some(key), ReadSide::Before) => self.before(key, limit + 1),
            (Some(key), ReadSide::Around) => {
                let mut rows = self.before(key, limit + 1);
                rows.extend(self.after(Some(key), limit + 1));
                rows
            }
        };
        if inclusive
            && let Some(anchor) = anchor
            && let Some(row) = self.get_row(&anchor.row)
            && SortKey::of(&row) == *anchor
        {
            hot.push(row);
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
        for row in hot {
            let key = SortKey::of(&row);
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
            candidates.push((key, Some(row)));
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
                    !self.before(key, 1).is_empty()
                        || (!inclusive
                            && self.get_row(&key.row).is_some_and(|row| SortKey::of(&row) == *key))
                }));
        let has_after = disk_after
            || right < candidates.len()
            || (side == ReadSide::Before
                && anchor.is_some_and(|key| {
                    !self.after(Some(key), 1).is_empty()
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

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: &str, at: u64) -> Summary {
        let mut row = Summary::new(id);
        row.last_activity = at;
        row
    }

    #[test]
    fn family_page_is_breadth_first_and_sets_depth() {
        let root = row("root", 5);
        let mut child = row("child", 4);
        child.parent = Some(root.key());
        let mut grandchild = row("grandchild", 3);
        grandchild.parent = Some(child.key());
        let index = SummaryIndex::new().apply(1, root.clone()).apply(2, child).apply(3, grandchild);
        let page = index
            .read_page(
                None,
                ReadSide::After,
                false,
                10,
                64 * 1024,
                Some(&ListFilter::family(root.key())),
            )
            .unwrap();
        assert_eq!(
            page.rows.iter().map(|row| row.chat_id.as_str()).collect::<Vec<_>>(),
            ["child", "grandchild"]
        );
        assert_eq!(page.rows[0].depth, Some(1));
        assert_eq!(page.rows[1].depth, Some(2));
    }

    #[test]
    fn folder_page_is_newest_first_and_does_not_read_other_folders() {
        let mut first = row("first", 1);
        first.folder = Some("one".to_owned());
        let mut newest = row("newest", 3);
        newest.folder = Some("one".to_owned());
        let mut other = row("other", 4);
        other.folder = Some("two".to_owned());
        let index = SummaryIndex::new().apply(1, first).apply(2, newest).apply(3, other);
        let page = index
            .read_page(
                None,
                ReadSide::After,
                false,
                10,
                64 * 1024,
                Some(&ListFilter::folder(FolderKey::new("local", "one"))),
            )
            .unwrap();
        assert_eq!(
            page.rows.iter().map(|row| row.chat_id.as_str()).collect::<Vec<_>>(),
            ["newest", "first"]
        );
    }
}
