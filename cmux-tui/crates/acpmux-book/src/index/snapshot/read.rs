use super::{
    BufferedRow, DiskSnapshot, HEADER_BYTES, PAGE_BYTES, SnapshotPiece, TRAILER_BYTES, read_at,
    read_u32,
};
use crate::index::{ReadSide, SortKey, Summary, codec};
use std::io;
use std::sync::Arc;

pub(super) enum Frame {
    Row(Summary, usize),
    Skipped(usize),
    End,
}

struct Forward {
    rows: Vec<BufferedRow>,
    next_offset: u64,
    skipped: usize,
    scanned: usize,
    first_ordinal: Option<u64>,
}

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
        // Start with the expected frame span to preserve the bounded seek
        // cost. A caller that encounters complete corrupt frames extends the
        // same request within this original byte budget.
        let minimum = match side {
            ReadSide::After => 0,
            ReadSide::Before | ReadSide::Around => {
                crate::index::MAX_INDEX_RECORD_BYTES + TRAILER_BYTES
            }
        };
        let physical_bytes = position
            .record_len
            .map(|length| length.saturating_mul(limit).max(minimum).min(max_bytes))
            .filter(|bytes| *bytes > 0)
            .unwrap_or(max_bytes);
        let (start, end) = match side {
            ReadSide::After => (
                position.offset,
                position.offset.saturating_add(physical_bytes as u64).min(self.head.data_end),
            ),
            ReadSide::Before => (
                position.offset.saturating_sub(physical_bytes as u64).max(HEADER_BYTES as u64),
                position.offset,
            ),
            ReadSide::Around => {
                let pivot = position.record_len.unwrap_or_default();
                if pivot > physical_bytes {
                    return Err(page_bound());
                }
                let left = ((physical_bytes - pivot) / 2) as u64;
                let start = position.offset.saturating_sub(left).max(HEADER_BYTES as u64);
                let end = start.saturating_add(physical_bytes as u64).min(self.head.data_end);
                (end.saturating_sub(physical_bytes as u64).max(HEADER_BYTES as u64), end)
            }
        };
        let bytes = self.read_range(start, (end - start) as usize)?;
        let mut bytes_read = bytes.len();
        let (rows, first_ordinal, next_offset, physical_count, next_ordinal) = match side {
            ReadSide::After => {
                let mut forward = self.forward(&bytes, start, position.ordinal, limit)?;
                self.extend_forward(
                    &mut forward,
                    position.ordinal,
                    limit,
                    max_bytes,
                    &mut bytes_read,
                )?;
                let next = forward.next_offset.max(position.offset);
                let first =
                    forward.first_ordinal.unwrap_or(position.ordinal + forward.scanned as u64);
                (
                    forward.rows,
                    first,
                    next,
                    forward.scanned,
                    position.ordinal + forward.scanned as u64,
                )
            }
            ReadSide::Before => {
                let mut backward =
                    self.backward(&bytes, start, position.offset, position.ordinal, limit)?;
                self.extend_backward(
                    &mut backward,
                    position.ordinal,
                    limit,
                    max_bytes,
                    &mut bytes_read,
                )?;
                let first = backward
                    .first_ordinal
                    .unwrap_or(position.ordinal.saturating_sub(backward.scanned as u64));
                (backward.rows, first, position.offset, backward.scanned, position.ordinal)
            }
            ReadSide::Around => {
                let split = (position.offset - start) as usize;
                let left = bytes.get(..split).ok_or_else(|| super::fatal("around offset"))?;
                let right = bytes.get(split..).ok_or_else(|| super::fatal("around offset"))?;
                let mut before =
                    self.backward(left, start, position.offset, position.ordinal, limit)?;
                let mut after = self.forward(right, position.offset, position.ordinal, limit)?;
                self.extend_forward(
                    &mut after,
                    position.ordinal,
                    limit,
                    max_bytes,
                    &mut bytes_read,
                )?;
                self.extend_backward(
                    &mut before,
                    position.ordinal,
                    limit,
                    max_bytes,
                    &mut bytes_read,
                )?;
                let mut left_rows = before.rows;
                let mut left_count = left_rows.len().min(limit / 2);
                let right_count = after.rows.len().min(limit - left_count);
                left_count = left_rows.len().min(limit - right_count);
                let skip = left_rows.len().saturating_sub(left_count);
                left_rows.drain(..skip);
                left_rows.extend(after.rows.into_iter().take(right_count));
                let first = left_rows
                    .first()
                    .map_or(position.ordinal.saturating_sub(before.scanned as u64), |row| {
                        row.ordinal
                    });
                let next = left_rows.last().map_or(position.offset, |row| row.end);
                let next_ordinal = left_rows
                    .last()
                    .map_or(position.ordinal + after.scanned as u64, |row| row.ordinal + 1);
                (left_rows, first, next, before.scanned + after.scanned, next_ordinal)
            }
        };
        if rows.is_empty()
            && match side {
                ReadSide::After => next_ordinal < self.len(),
                ReadSide::Before => first_ordinal > 0,
                ReadSide::Around => first_ordinal > 0 || next_ordinal < self.len(),
            }
        {
            return Err(if physical_count == 0 {
                page_bound()
            } else {
                super::fatal("damaged snapshot span exceeds page read bound")
            });
        }
        // Count the complete request, including locating the bounded piece.
        Ok(self.finish_piece(
            rows,
            first_ordinal,
            next_offset,
            physical_count,
            next_ordinal,
            position.bytes_read + bytes_read,
        ))
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
        let max_bytes = max_bytes.min(PAGE_BYTES);
        let remaining = self.len().saturating_sub(ordinal).min(rows as u64) as usize;
        let mut initial = max_bytes;
        if ordinal.saturating_add(remaining as u64) <= self.head.first_lengths.len() as u64 {
            initial = initial.min(
                self.head
                    .first_lengths
                    .iter()
                    .skip(ordinal as usize)
                    .take(remaining)
                    .map(|length| usize::from(*length))
                    .sum(),
            );
        }
        let bytes = self.read_range(offset, initial)?;
        let mut bytes_read = bytes.len();
        let mut selected = self.forward(&bytes, offset, ordinal, rows)?;
        self.extend_forward(&mut selected, ordinal, rows, max_bytes, &mut bytes_read)?;
        if selected.rows.is_empty() && selected.next_offset < self.head.data_end {
            return Err(if selected.skipped == 0 {
                page_bound()
            } else {
                super::fatal("damaged snapshot span exceeds page read bound")
            });
        }
        Ok(self.finish_piece(
            selected.rows,
            selected.first_ordinal.unwrap_or(ordinal + selected.scanned as u64),
            selected.next_offset,
            selected.scanned,
            ordinal + selected.scanned as u64,
            bytes_read,
        ))
    }

    /// Read a bounded stream piece while recovering past complete but
    /// unreadable records. The frame length is checked before decoding, so a
    /// CRC or payload error can advance to the following record without
    /// retaining a partial row. Structural truncation still returns an error.
    pub(super) fn rows_at_tolerant(
        &self,
        offset: u64,
        ordinal: u64,
        rows: usize,
        max_bytes: usize,
    ) -> io::Result<(SnapshotPiece, usize, usize, usize)> {
        if rows == 0 || max_bytes == 0 {
            return Err(page_bound());
        }
        let bytes = self.read_range(offset, max_bytes.min(PAGE_BYTES))?;
        let forward = self.forward(&bytes, offset, ordinal, rows)?;
        if forward.scanned == 0 && offset < self.head.data_end {
            return Err(page_bound());
        }
        let leading = forward
            .rows
            .first()
            .map_or(forward.next_offset, |row| row.start)
            .saturating_sub(offset) as usize;
        let trailing =
            forward.next_offset.saturating_sub(forward.rows.last().map_or(offset, |row| row.end))
                as usize;
        let piece = self.finish_piece(
            forward.rows,
            forward.first_ordinal.unwrap_or(ordinal + forward.scanned as u64),
            forward.next_offset,
            forward.scanned,
            ordinal + forward.scanned as u64,
            bytes.len(),
        );
        Ok((piece, forward.skipped, leading, trailing))
    }

    pub fn first_page(&self, max_bytes: usize) -> io::Result<SnapshotPiece> {
        self.piece(HEADER_BYTES as u64, 0, max_bytes)
    }

    /// One bounded read. A partial final frame remains for the next request.
    pub fn piece(&self, offset: u64, ordinal: u64, max_bytes: usize) -> io::Result<SnapshotPiece> {
        let bytes = self.read_range(offset, max_bytes.min(PAGE_BYTES))?;
        let rows = self.forward(&bytes, offset, ordinal, usize::MAX)?;
        if rows.rows.is_empty() && rows.next_offset < self.head.data_end {
            return Err(if rows.skipped == 0 {
                page_bound()
            } else {
                super::fatal("damaged snapshot span exceeds page read bound")
            });
        }
        Ok(self.finish_piece(
            rows.rows,
            rows.first_ordinal.unwrap_or(ordinal + rows.scanned as u64),
            rows.next_offset,
            rows.scanned,
            ordinal + rows.scanned as u64,
            bytes.len(),
        ))
    }

    fn finish_piece(
        &self,
        rows: Vec<BufferedRow>,
        first_ordinal: u64,
        next_offset: u64,
        physical_count: usize,
        next_ordinal: u64,
        bytes_read: usize,
    ) -> SnapshotPiece {
        // A piece that skipped only damaged frames has no row from which to
        // continue. An ordinary empty seek past the end retains its direction
        // flags; its caller already supplied an anchor on the sound snapshot.
        let only_damage = rows.is_empty() && physical_count > 0;
        SnapshotPiece {
            has_before: !only_damage && first_ordinal > 0,
            has_after: !only_damage && next_ordinal < self.len(),
            rows: rows.into_iter().map(|row| row.summary).collect(),
            physical_count,
            next_ordinal,
            first_ordinal,
            next_offset,
            bytes_read,
        }
    }

    pub(super) fn read_frame(&self, input: &mut &[u8]) -> io::Result<Frame> {
        if input.is_empty() {
            return Ok(Frame::End);
        }
        let available = input.len();
        if available < 4 {
            return Err(super::fatal("short snapshot frame length"));
        }
        let body_len =
            read_u32(input.get(..4).ok_or_else(|| super::fatal("snapshot frame length"))?)?
                as usize;
        if body_len > crate::index::MAX_INDEX_RECORD_BYTES - 8 {
            return Err(super::fatal("snapshot frame length"));
        }
        let frame_len =
            body_len.checked_add(12).ok_or_else(|| super::fatal("snapshot frame length"))?;
        if frame_len > available {
            return Err(super::fatal("short snapshot frame"));
        }
        let (frame, rest) = input.split_at(frame_len);
        *input = rest;
        let body_len = frame_len - TRAILER_BYTES;
        let trailer =
            read_u32(frame.get(body_len..).ok_or_else(|| super::fatal("snapshot frame trailer"))?)?
                as usize;
        if trailer != body_len {
            return Err(super::fatal("snapshot frame extent"));
        }
        let mut record =
            frame.get(..body_len).ok_or_else(|| super::fatal("snapshot frame body"))?;
        match codec::read(&mut record) {
            Ok(Some((record_value, len)))
                if len == body_len
                    && record.is_empty()
                    && record_value.seq == self.seq()
                    && !record_value.gone =>
            {
                Ok(Frame::Row(record_value.summary, frame_len))
            }
            Ok(Some(_)) | Ok(None) | Err(_) => Ok(Frame::Skipped(frame_len)),
        }
    }

    fn forward(
        &self,
        bytes: &[u8],
        offset: u64,
        ordinal: u64,
        limit: usize,
    ) -> io::Result<Forward> {
        let mut input = bytes;
        let mut end = offset;
        let mut rows = Vec::new();
        let mut skipped = 0;
        let mut scanned = 0;
        while rows.len() < limit && !input.is_empty() {
            let Some(frame_len) =
                frame_len(input, offset + (bytes.len() as u64) >= self.head.data_end)?
            else {
                break;
            };
            let (frame, rest) = input.split_at(frame_len);
            let mut frame = frame;
            let frame_ordinal = ordinal + scanned as u64;
            match self.read_frame(&mut frame)? {
                Frame::Row(summary, len) => {
                    end += len as u64;
                    rows.push(BufferedRow {
                        summary: Arc::new(summary),
                        start: end - len as u64,
                        end,
                        ordinal: frame_ordinal,
                    });
                }
                Frame::Skipped(len) => {
                    end += len as u64;
                    skipped += 1;
                }
                Frame::End => return Err(super::fatal("snapshot frame ended")),
            }
            scanned += 1;
            input = rest;
        }
        let first_ordinal = rows.first().map(|row| row.ordinal);
        Ok(Forward { rows, next_offset: end, skipped, scanned, first_ordinal })
    }

    fn backward(
        &self,
        bytes: &[u8],
        start: u64,
        end: u64,
        ordinal: u64,
        limit: usize,
    ) -> io::Result<Forward> {
        let mut input = bytes;
        let mut end = end;
        let mut rows = Vec::new();
        let mut skipped = 0;
        let mut scanned = 0;
        while !input.is_empty() && rows.len() < limit {
            if input.len() < TRAILER_BYTES {
                if start > HEADER_BYTES as u64 {
                    break;
                }
                return Err(super::fatal("short snapshot trailer"));
            }
            let trailer = input
                .get(input.len() - TRAILER_BYTES..)
                .ok_or_else(|| super::fatal("snapshot trailer"))?;
            let frame_len = read_u32(trailer)? as usize;
            if !(8..=crate::index::MAX_INDEX_RECORD_BYTES).contains(&frame_len) {
                return Err(super::fatal("snapshot frame length"));
            }
            let len = frame_len + TRAILER_BYTES;
            if len > input.len() {
                if start > HEADER_BYTES as u64 {
                    break;
                }
                return Err(super::fatal("short snapshot frame"));
            }
            let boundary = input.len() - len;
            let mut frame = input.get(boundary..).ok_or_else(|| super::fatal("snapshot frame"))?;
            let frame_ordinal = ordinal.saturating_sub(scanned as u64 + 1);
            match self.read_frame(&mut frame)? {
                Frame::Row(summary, actual) if actual == len && frame.is_empty() => {
                    rows.push(BufferedRow {
                        summary: Arc::new(summary),
                        start: end - len as u64,
                        end,
                        ordinal: frame_ordinal,
                    });
                }
                Frame::Skipped(actual) if actual == len && frame.is_empty() => skipped += 1,
                Frame::Skipped(_) => return Err(super::fatal("snapshot frame extent")),
                Frame::End => return Err(super::fatal("empty snapshot frame")),
                Frame::Row(_, _) => return Err(super::fatal("snapshot frame extent")),
            }
            end -= len as u64;
            scanned += 1;
            input = input.get(..boundary).ok_or_else(|| super::fatal("snapshot frame prefix"))?;
        }
        rows.reverse();
        let first_ordinal = rows.first().map(|row| row.ordinal);
        Ok(Forward { rows, next_offset: end, skipped, scanned, first_ordinal })
    }

    // Sound reads retain their small-read accelerator. Only a skipped frame
    // can extend the physical read, and every additional byte is charged to
    // the original page budget. Complete frames are never decoded twice.
    fn extend_forward(
        &self,
        scan: &mut Forward,
        ordinal: u64,
        limit: usize,
        max_bytes: usize,
        bytes_read: &mut usize,
    ) -> io::Result<()> {
        if scan.skipped == 0 || scan.rows.len() >= limit || scan.next_offset == self.head.data_end {
            return Ok(());
        }
        let remaining = max_bytes.saturating_sub(*bytes_read);
        if remaining == 0 {
            return Ok(());
        }
        let bytes = self.read_range(scan.next_offset, remaining)?;
        *bytes_read += bytes.len();
        let next = self.forward(
            &bytes,
            scan.next_offset,
            ordinal + scan.scanned as u64,
            limit - scan.rows.len(),
        )?;
        scan.next_offset = next.next_offset;
        scan.skipped += next.skipped;
        scan.scanned += next.scanned;
        scan.first_ordinal = scan.first_ordinal.or(next.first_ordinal);
        scan.rows.extend(next.rows);
        Ok(())
    }

    fn extend_backward(
        &self,
        scan: &mut Forward,
        ordinal: u64,
        limit: usize,
        max_bytes: usize,
        bytes_read: &mut usize,
    ) -> io::Result<()> {
        if scan.skipped == 0 || scan.rows.len() >= limit || scan.next_offset == HEADER_BYTES as u64
        {
            return Ok(());
        }
        let remaining = max_bytes.saturating_sub(*bytes_read);
        if remaining == 0 {
            return Ok(());
        }
        let end = scan.next_offset;
        let start = end.saturating_sub(remaining as u64).max(HEADER_BYTES as u64);
        let bytes = self.read_range(start, (end - start) as usize)?;
        *bytes_read += bytes.len();
        let mut next = self.backward(
            &bytes,
            start,
            end,
            ordinal.saturating_sub(scan.scanned as u64),
            limit - scan.rows.len(),
        )?;
        scan.next_offset = next.next_offset;
        scan.skipped += next.skipped;
        scan.scanned += next.scanned;
        scan.first_ordinal = next.first_ordinal.or(scan.first_ordinal);
        next.rows.append(&mut scan.rows);
        scan.rows = next.rows;
        Ok(())
    }

    pub(super) fn read_range(&self, offset: u64, max_bytes: usize) -> io::Result<Vec<u8>> {
        if offset < HEADER_BYTES as u64 || offset > self.head.data_end {
            return Err(super::fatal("snapshot offset"));
        }
        let len = (self.head.data_end - offset).min(max_bytes as u64) as usize;
        let mut bytes = vec![0; len];
        read_at(&self.file, &mut bytes, offset)?;
        Ok(bytes)
    }
}

fn frame_len(input: &[u8], at_end: bool) -> io::Result<Option<usize>> {
    if input.len() < 4 {
        return if at_end { Err(super::fatal("short snapshot frame length")) } else { Ok(None) };
    }
    let body_len =
        read_u32(input.get(..4).ok_or_else(|| super::fatal("snapshot frame length"))?)? as usize;
    if body_len > crate::index::MAX_INDEX_RECORD_BYTES - 8 {
        return Err(super::fatal("snapshot frame length"));
    }
    let total = body_len.checked_add(12).ok_or_else(|| super::fatal("snapshot frame length"))?;
    if total > input.len() {
        return if at_end { Err(super::fatal("short snapshot frame")) } else { Ok(None) };
    }
    Ok(Some(total))
}

fn page_bound() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, "snapshot page bound cannot hold a record")
}
