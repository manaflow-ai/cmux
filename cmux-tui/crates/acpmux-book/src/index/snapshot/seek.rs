use super::{
    CHECKPOINT_BYTES, Checkpoint, DiskSnapshot, HEADER_BYTES, Position, SEEK_BYTES, TRAILER_BYTES,
    read_at,
};
use crate::index::{SortKey, codec};
use std::io;

impl DiskSnapshot {
    fn checkpoint(&self, index: usize, bytes_read: &mut usize) -> io::Result<Checkpoint> {
        if index >= self.head.directory_bytes / CHECKPOINT_BYTES {
            return Err(codec::invalid("snapshot checkpoint index"));
        }
        let mut bytes = [0; CHECKPOINT_BYTES];
        read_at(&self.file, &mut bytes, self.head.data_end + (index * CHECKPOINT_BYTES) as u64)?;
        *bytes_read += bytes.len();
        let checkpoint = Checkpoint::decode(&bytes)?;
        if checkpoint.offset < HEADER_BYTES as u64
            || checkpoint.offset >= self.head.data_end
            || checkpoint.ordinal >= self.head.count
            || checkpoint.first_len < 12
            || checkpoint.first_len > crate::index::MAX_INDEX_RECORD_BYTES + TRAILER_BYTES
            || checkpoint.offset + checkpoint.first_len as u64 > self.head.data_end
            || (index == 0 && (checkpoint.offset != HEADER_BYTES as u64 || checkpoint.ordinal != 0))
        {
            return Err(codec::invalid("snapshot checkpoint extent"));
        }
        Ok(checkpoint)
    }

    /// A disk binary search holds only its current entry, never the directory.
    fn checkpoint_for(
        &self,
        mut at_or_before: impl FnMut(&Checkpoint) -> bool,
        bytes_read: &mut usize,
    ) -> io::Result<Option<(usize, Checkpoint)>> {
        let mut left = 0;
        let mut right = self.head.directory_bytes / CHECKPOINT_BYTES;
        if right == 0 {
            return Ok(None);
        }
        let mut answer = None;
        while left < right {
            let middle = left + (right - left) / 2;
            let entry = self.checkpoint(middle, bytes_read)?;
            if at_or_before(&entry) {
                answer = Some((middle, entry));
                left = middle + 1;
            } else {
                right = middle;
            }
        }
        match answer {
            Some(answer) => Ok(Some(answer)),
            None => Ok(Some((0, self.checkpoint(0, bytes_read)?))),
        }
    }

    fn block(
        &self,
        index: usize,
        entry: &Checkpoint,
        bytes_read: &mut usize,
    ) -> io::Result<(Vec<u8>, Option<Checkpoint>)> {
        let next = if index + 1 < self.head.directory_bytes / CHECKPOINT_BYTES {
            Some(self.checkpoint(index + 1, bytes_read)?)
        } else {
            None
        };
        let end = next.as_ref().map_or(self.head.data_end, |next| next.offset);
        let end_ordinal = next.as_ref().map_or(self.head.count, |next| next.ordinal);
        if end <= entry.offset
            || end - entry.offset > SEEK_BYTES as u64
            || end_ordinal <= entry.ordinal
            || end_ordinal - entry.ordinal > 256
            || next.as_ref().is_some_and(|next| entry.key >= next.key)
        {
            return Err(codec::invalid("snapshot checkpoint order"));
        }
        let bytes = self.read_range(entry.offset, (end - entry.offset) as usize)?;
        *bytes_read += bytes.len();
        Ok((bytes, next))
    }

    pub(super) fn seek_position(&self, key: &SortKey, inclusive: bool) -> io::Result<Position> {
        let mut bytes_read = 0;
        let Some((index, entry)) =
            self.checkpoint_for(|entry| entry.key <= *key, &mut bytes_read)?
        else {
            return Ok(Position {
                offset: HEADER_BYTES as u64,
                ordinal: 0,
                record_len: None,
                bytes_read,
            });
        };
        let (bytes, next) = self.block(index, &entry, &mut bytes_read)?;
        let mut input = bytes.as_slice();
        let mut offset = entry.offset;
        let mut ordinal = entry.ordinal;
        while let Some((summary, len)) = self.read_record(&mut input)? {
            let candidate = SortKey::of(&summary);
            if candidate > *key || (inclusive && candidate == *key) {
                return Ok(Position { offset, ordinal, record_len: Some(len), bytes_read });
            }
            ordinal += 1;
            offset += len as u64;
        }
        Ok(Position {
            offset,
            ordinal,
            record_len: next.as_ref().map(|entry| entry.first_len),
            bytes_read,
        })
    }

    /// Compatibility helper. Paging uses `read_piece`, which accounts for this I/O.
    pub fn seek(&self, key: &SortKey, inclusive: bool) -> io::Result<(u64, u64)> {
        let position = self.seek_position(key, inclusive)?;
        Ok((position.offset, position.ordinal))
    }

    pub fn position_at(&self, ordinal: u64) -> io::Result<(u64, u64)> {
        let ordinal = ordinal.min(self.len());
        if ordinal == self.len() {
            return Ok((self.head.data_end, ordinal));
        }
        if ordinal <= self.head.first_lengths.len() as u64 {
            let bytes = self
                .head
                .first_lengths
                .iter()
                .take(ordinal as usize)
                .map(|len| u64::from(*len))
                .sum::<u64>();
            return Ok((HEADER_BYTES as u64 + bytes, ordinal));
        }
        let mut bytes_read = 0;
        let Some((index, entry)) =
            self.checkpoint_for(|entry| entry.ordinal <= ordinal, &mut bytes_read)?
        else {
            return Err(codec::invalid("snapshot ordinal"));
        };
        let (bytes, _) = self.block(index, &entry, &mut bytes_read)?;
        let mut input = bytes.as_slice();
        let mut offset = entry.offset;
        let mut current = entry.ordinal;
        while current < ordinal {
            let (_, len) =
                self.read_record(&mut input)?.ok_or_else(|| codec::invalid("snapshot ordinal"))?;
            offset += len as u64;
            current += 1;
        }
        Ok((offset, ordinal))
    }

    pub fn checkpoint_before(&self, offset: u64) -> io::Result<(u64, u64)> {
        let mut bytes_read = 0;
        Ok(self
            .checkpoint_for(|entry| entry.offset <= offset, &mut bytes_read)?
            .map_or((HEADER_BYTES as u64, 0), |(_, entry)| (entry.offset, entry.ordinal)))
    }
}
