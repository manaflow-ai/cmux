use super::{
    CHECKPOINT_BYTES, Checkpoint, DiskSnapshot, HEADER_BYTES, Position, SEEK_BYTES, TRAILER_BYTES,
};
use crate::index::{SortKey, codec};
use std::io;

impl DiskSnapshot {
    fn directory(&self) -> io::Result<&[Checkpoint]> {
        if let Some(directory) = self.directory.get() {
            return Ok(directory);
        }
        let count = self.head.directory_bytes / CHECKPOINT_BYTES;
        let mut bytes = vec![0; self.head.directory_bytes];
        if !bytes.is_empty() {
            super::read_at(&self.file, &mut bytes, self.head.data_end)?;
        }
        let mut directory = Vec::with_capacity(count);
        for index in 0..count {
            let start = index * CHECKPOINT_BYTES;
            let end = start + CHECKPOINT_BYTES;
            directory.push(Checkpoint::decode(
                bytes.get(start..end).ok_or_else(|| codec::invalid("snapshot directory"))?,
            )?);
        }
        let _ = self.directory.set(directory);
        Ok(self.directory.get().map_or(&[], Vec::as_slice))
    }

    fn checkpoint(&self, index: usize) -> io::Result<Checkpoint> {
        let directory = self.directory()?;
        let checkpoint = directory
            .get(index)
            .cloned()
            .ok_or_else(|| codec::invalid("snapshot checkpoint index"))?;
        if index >= self.head.directory_bytes / CHECKPOINT_BYTES {
            return Err(codec::invalid("snapshot checkpoint index"));
        }
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

    /// The directory is loaded once on the first seek, then binary searched in memory.
    fn checkpoint_for(
        &self,
        mut at_or_before: impl FnMut(&Checkpoint) -> bool,
    ) -> io::Result<Option<(usize, Checkpoint)>> {
        let mut left = 0;
        let directory = self.directory()?;
        let mut right = directory.len();
        if right == 0 {
            return Ok(None);
        }
        let mut answer = None;
        while left < right {
            let middle = left + (right - left) / 2;
            let entry =
                directory.get(middle).ok_or_else(|| codec::invalid("snapshot checkpoint index"))?;
            if at_or_before(&entry) {
                answer = Some((middle, entry.clone()));
                left = middle + 1;
            } else {
                right = middle;
            }
        }
        match answer {
            Some(answer) => Ok(Some(answer)),
            None => Ok(Some((0, self.checkpoint(0)?))),
        }
    }

    fn block(&self, index: usize, entry: &Checkpoint) -> io::Result<(Vec<u8>, Option<Checkpoint>)> {
        let next = if index + 1 < self.head.directory_bytes / CHECKPOINT_BYTES {
            Some(self.checkpoint(index + 1)?)
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
        Ok((bytes, next))
    }

    pub(super) fn seek_position(&self, key: &SortKey, inclusive: bool) -> io::Result<Position> {
        if let Some(last) = self.head.last_key.as_ref()
            && (key > last || (!inclusive && key == last))
        {
            return Ok(Position {
                offset: self.head.data_end,
                ordinal: self.head.count,
                record_len: None,
            });
        }
        if inclusive && self.head.last_len > 0 && self.head.last_key.as_ref() == Some(key) {
            return Ok(Position {
                offset: self.head.data_end.saturating_sub(self.head.last_len as u64),
                ordinal: self.head.count.saturating_sub(1),
                record_len: Some(self.head.last_len),
            });
        }
        let Some((index, entry)) = self.checkpoint_for(|entry| entry.key <= *key)? else {
            return Ok(Position { offset: HEADER_BYTES as u64, ordinal: 0, record_len: None });
        };
        let (bytes, next) = self.block(index, &entry)?;
        let mut input = bytes.as_slice();
        let mut offset = entry.offset;
        let mut ordinal = entry.ordinal;
        while let Some((summary, len)) = self.read_record(&mut input)? {
            let candidate = SortKey::of(&summary);
            if candidate > *key || (inclusive && candidate == *key) {
                return Ok(Position { offset, ordinal, record_len: Some(len) });
            }
            ordinal += 1;
            offset += len as u64;
        }
        Ok(Position { offset, ordinal, record_len: next.as_ref().map(|entry| entry.first_len) })
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
        let Some((index, entry)) = self.checkpoint_for(|entry| entry.ordinal <= ordinal)? else {
            return Err(codec::invalid("snapshot ordinal"));
        };
        let (bytes, _) = self.block(index, &entry)?;
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
        Ok(self
            .checkpoint_for(|entry| entry.offset <= offset)?
            .map_or((HEADER_BYTES as u64, 0), |(_, entry)| (entry.offset, entry.ordinal)))
    }
}
