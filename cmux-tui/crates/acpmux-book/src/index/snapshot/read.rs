use super::{
    BufferedRow, DiskSnapshot, HEADER_BYTES, PAGE_BYTES, SnapshotPiece, TRAILER_BYTES, read_at,
    read_u32,
};
use crate::index::{ReadSide, SortKey, Summary, codec};
use std::io::{self, Read};
use std::sync::Arc;

impl DiskSnapshot {
    /// One sparse seek (at most 64 KiB of records), followed by one bounded
    /// data read. Filtering never asks this reader to fetch another piece.
    /// Backward and around pages parse from the anchor using length trailers,
    /// so byte clipping keeps the nearest rows and cannot jump over them.
    pub fn read_piece(
        &self,
        anchor: Option<&SortKey>,
        side: ReadSide,
        inclusive: bool,
        limit: usize,
        max_bytes: usize,
    ) -> io::Result<SnapshotPiece> {
        if limit == 0 || max_bytes == 0 || max_bytes > PAGE_BYTES {
            return Err(page_bound());
        }
        let Some(anchor) = anchor else {
            return self.first_rows(limit, max_bytes);
        };
        let seek_inclusive = match side {
            ReadSide::After => inclusive,
            ReadSide::Before => !inclusive,
            ReadSide::Around => true,
        };
        let position = self.seek_position(anchor, seek_inclusive)?;
        let (start, end) = match side {
            ReadSide::After => (
                position.offset,
                position.offset.saturating_add(max_bytes as u64).min(self.head.data_end),
            ),
            ReadSide::Before => (
                position.offset.saturating_sub(max_bytes as u64).max(HEADER_BYTES as u64),
                position.offset,
            ),
            ReadSide::Around => {
                let pivot = position.record_len.unwrap_or_default();
                if pivot > max_bytes {
                    return Err(page_bound());
                }
                let left = ((max_bytes - pivot) / 2) as u64;
                let start = position.offset.saturating_sub(left).max(HEADER_BYTES as u64);
                let end = start.saturating_add(max_bytes as u64).min(self.head.data_end);
                (end.saturating_sub(max_bytes as u64).max(HEADER_BYTES as u64), end)
            }
        };
        let bytes = self.read_range(start, (end - start) as usize)?;
        let (rows, first_ordinal, next_offset) = match side {
            ReadSide::After => {
                let rows = self.forward(&bytes, start, limit)?;
                let next = rows.last().map_or(position.offset, |row| row.end);
                (rows, position.ordinal, next)
            }
            ReadSide::Before => {
                let rows = self.backward(&bytes, start, position.offset, limit)?;
                let first = position.ordinal.saturating_sub(rows.len() as u64);
                (rows, first, position.offset)
            }
            ReadSide::Around => {
                let split = (position.offset - start) as usize;
                let left = bytes.get(..split).ok_or_else(|| codec::invalid("around offset"))?;
                let right = bytes.get(split..).ok_or_else(|| codec::invalid("around offset"))?;
                let mut before = self.backward(left, start, position.offset, limit)?;
                let after = self.forward(right, position.offset, limit)?;
                let mut left_count = before.len().min(limit / 2);
                let right_count = after.len().min(limit - left_count);
                left_count = before.len().min(limit - right_count);
                let first = position.ordinal.saturating_sub(left_count as u64);
                let skip = before.len().saturating_sub(left_count);
                before.drain(..skip);
                before.extend(after.into_iter().take(right_count));
                let next = before.last().map_or(position.offset, |row| row.end);
                (before, first, next)
            }
        };
        if rows.is_empty()
            && match side {
                ReadSide::After => position.ordinal < self.len(),
                ReadSide::Before => position.ordinal > 0,
                ReadSide::Around => !self.is_empty(),
            }
        {
            return Err(page_bound());
        }
        Ok(self.finish_piece(rows, first_ordinal, next_offset, position.bytes_read + bytes.len()))
    }

    pub fn first_rows(&self, rows: usize, max_bytes: usize) -> io::Result<SnapshotPiece> {
        self.rows_at(HEADER_BYTES as u64, 0, rows, max_bytes)
    }

    pub fn rows_at(
        &self,
        offset: u64,
        ordinal: u64,
        rows: usize,
        max_bytes: usize,
    ) -> io::Result<SnapshotPiece> {
        if rows == 0 || max_bytes == 0 {
            return Err(page_bound());
        }
        let remaining = self.len().saturating_sub(ordinal).min(rows as u64) as usize;
        let mut budget = max_bytes.min(PAGE_BYTES);
        if ordinal.saturating_add(remaining as u64) <= self.head.first_lengths.len() as u64 {
            budget = budget.min(
                self.head
                    .first_lengths
                    .iter()
                    .skip(ordinal as usize)
                    .take(remaining)
                    .map(|len| usize::from(*len))
                    .sum(),
            );
        }
        let bytes = self.read_range(offset, budget)?;
        let selected = self.forward(&bytes, offset, rows)?;
        if selected.is_empty() && ordinal < self.len() {
            return Err(page_bound());
        }
        let next = selected.last().map_or(offset, |row| row.end);
        Ok(self.finish_piece(selected, ordinal, next, bytes.len()))
    }

    pub fn first_page(&self, max_bytes: usize) -> io::Result<SnapshotPiece> {
        self.piece(HEADER_BYTES as u64, 0, max_bytes)
    }

    /// One bounded read. A partial final frame remains for the next request.
    pub fn piece(&self, offset: u64, ordinal: u64, max_bytes: usize) -> io::Result<SnapshotPiece> {
        let bytes = self.read_range(offset, max_bytes.min(PAGE_BYTES))?;
        let rows = self.forward(&bytes, offset, usize::MAX)?;
        if rows.is_empty() && offset < self.head.data_end {
            return Err(page_bound());
        }
        let next = rows.last().map_or(offset, |row| row.end);
        Ok(self.finish_piece(rows, ordinal, next, bytes.len()))
    }

    fn finish_piece(
        &self,
        rows: Vec<BufferedRow>,
        first_ordinal: u64,
        next_offset: u64,
        bytes_read: usize,
    ) -> SnapshotPiece {
        SnapshotPiece {
            has_before: first_ordinal > 0,
            has_after: first_ordinal.saturating_add(rows.len() as u64) < self.len(),
            rows: rows.into_iter().map(|row| row.summary).collect(),
            first_ordinal,
            next_offset,
            bytes_read,
        }
    }

    pub(super) fn read_record(&self, input: &mut &[u8]) -> io::Result<Option<(Summary, usize)>> {
        let Some((record, len)) = codec::read(input)? else {
            return Ok(None);
        };
        let mut trailer = [0; TRAILER_BYTES];
        input.read_exact(&mut trailer)?;
        if u32::from_le_bytes(trailer) as usize != len || record.seq != self.seq() || record.gone {
            return Err(codec::invalid("snapshot record"));
        }
        Ok(Some((record.summary, len + TRAILER_BYTES)))
    }

    fn forward(&self, bytes: &[u8], offset: u64, limit: usize) -> io::Result<Vec<BufferedRow>> {
        let mut input = bytes;
        let mut end = offset;
        let mut rows = Vec::new();
        while rows.len() < limit {
            match self.read_record(&mut input) {
                Ok(Some((summary, len))) => {
                    end += len as u64;
                    rows.push(BufferedRow { summary: Arc::new(summary), end });
                }
                Ok(None) => break,
                Err(error)
                    if error.kind() == io::ErrorKind::UnexpectedEof
                        && offset + (bytes.len() as u64) < self.head.data_end =>
                {
                    break;
                }
                Err(error) => return Err(error),
            }
        }
        Ok(rows)
    }

    fn backward(
        &self,
        bytes: &[u8],
        start: u64,
        end: u64,
        limit: usize,
    ) -> io::Result<Vec<BufferedRow>> {
        let mut input = bytes;
        let mut end = end;
        let mut rows = Vec::new();
        while !input.is_empty() && rows.len() < limit {
            if input.len() < TRAILER_BYTES {
                if start > HEADER_BYTES as u64 {
                    break;
                }
                return Err(codec::invalid("short snapshot trailer"));
            }
            let trailer = input
                .get(input.len() - TRAILER_BYTES..)
                .ok_or_else(|| codec::invalid("snapshot trailer"))?;
            let frame_len = read_u32(trailer)? as usize;
            if !(8..=crate::index::MAX_INDEX_RECORD_BYTES).contains(&frame_len) {
                return Err(codec::invalid("snapshot frame length"));
            }
            let len = frame_len + TRAILER_BYTES;
            if len > input.len() {
                if start > HEADER_BYTES as u64 {
                    break;
                }
                return Err(codec::invalid("short snapshot frame"));
            }
            let boundary = input.len() - len;
            let mut frame =
                input.get(boundary..).ok_or_else(|| codec::invalid("snapshot frame"))?;
            let (summary, actual) = self
                .read_record(&mut frame)?
                .ok_or_else(|| codec::invalid("empty snapshot frame"))?;
            if actual != len || !frame.is_empty() {
                return Err(codec::invalid("snapshot frame extent"));
            }
            rows.push(BufferedRow { summary: Arc::new(summary), end });
            end -= len as u64;
            input = input.get(..boundary).ok_or_else(|| codec::invalid("snapshot frame prefix"))?;
        }
        rows.reverse();
        Ok(rows)
    }

    pub(super) fn read_range(&self, offset: u64, max_bytes: usize) -> io::Result<Vec<u8>> {
        if offset < HEADER_BYTES as u64 || offset > self.head.data_end {
            return Err(codec::invalid("snapshot offset"));
        }
        let len = (self.head.data_end - offset).min(max_bytes as u64) as usize;
        let mut bytes = vec![0; len];
        read_at(&self.file, &mut bytes, offset)?;
        Ok(bytes)
    }
}

fn page_bound() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, "snapshot page bound cannot hold a record")
}
