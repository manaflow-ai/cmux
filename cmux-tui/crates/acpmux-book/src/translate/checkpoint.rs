//! Opaque versioned state, independent of the log's record/checkpoint layout.
use super::{
    Error, MAX_QUEUE_ENTRIES, MAX_STATE_BYTES, MAX_TRANSLATOR_BYTES, QueueEntry, State, VERSION,
};
use bincode::Options;
use std::io::Cursor;
impl State {
    pub fn checkpoint(&self) -> Result<Vec<u8>, Error> {
        let mut translator = self.clone();
        let queue = std::mem::take(&mut translator.queue);
        let mut bytes =
            codec().serialize(&(VERSION, &translator)).map_err(|_| Error::CheckpointInvalid)?;
        if bytes.len() + 4 > MAX_TRANSLATOR_BYTES {
            return Err(Error::StateTooLarge { bytes: bytes.len() });
        }
        bytes.extend_from_slice(&(queue.len() as u32).to_le_bytes());
        for entry in queue.values() {
            bytes.extend_from_slice(&entry.id_hash.to_le_bytes());
            bytes.extend_from_slice(&entry.at_state.to_le_bytes());
            bytes.extend_from_slice(&entry.place.to_le_bytes());
            bytes.extend_from_slice(&entry.span.to_le_bytes());
            bytes.extend_from_slice(&entry.text_len.to_le_bytes());
        }
        if bytes.len() > MAX_STATE_BYTES {
            return Err(Error::StateTooLarge { bytes: bytes.len() });
        }
        Ok(bytes)
    }
    pub fn restore(bytes: &[u8]) -> Result<Self, Error> {
        if bytes.len() > MAX_STATE_BYTES {
            return Err(Error::StateTooLarge { bytes: bytes.len() });
        }
        let mut cursor = Cursor::new(bytes);
        let (version, mut state): (u32, Self) =
            codec().deserialize_from(&mut cursor).map_err(|_| Error::CheckpointInvalid)?;
        if version != VERSION {
            return Err(Error::CheckpointVersion);
        }
        let pos = cursor.position() as usize;
        let count = u32::from_le_bytes(
            bytes
                .get(pos..pos + 4)
                .ok_or(Error::CheckpointInvalid)?
                .try_into()
                .map_err(|_| Error::CheckpointInvalid)?,
        ) as usize;
        let start = pos + 4;
        let end = start
            .checked_add(count.checked_mul(32).ok_or(Error::CheckpointInvalid)?)
            .ok_or(Error::CheckpointInvalid)?;
        for chunk in bytes.get(start..end).ok_or(Error::CheckpointInvalid)?.chunks_exact(32) {
            let id_hash = <[u8; 8]>::try_from(chunk.get(0..8).ok_or(Error::CheckpointInvalid)?)
                .map_err(|_| Error::CheckpointInvalid)?;
            let at_state = <[u8; 8]>::try_from(chunk.get(8..16).ok_or(Error::CheckpointInvalid)?)
                .map_err(|_| Error::CheckpointInvalid)?;
            let place = <[u8; 8]>::try_from(chunk.get(16..24).ok_or(Error::CheckpointInvalid)?)
                .map_err(|_| Error::CheckpointInvalid)?;
            let span = <[u8; 4]>::try_from(chunk.get(24..28).ok_or(Error::CheckpointInvalid)?)
                .map_err(|_| Error::CheckpointInvalid)?;
            let text_len = <[u8; 4]>::try_from(chunk.get(28..32).ok_or(Error::CheckpointInvalid)?)
                .map_err(|_| Error::CheckpointInvalid)?;
            let entry = QueueEntry {
                id_hash: u64::from_le_bytes(id_hash),
                at_state: u64::from_le_bytes(at_state),
                place: u64::from_le_bytes(place),
                span: u32::from_le_bytes(span),
                text_len: u32::from_le_bytes(text_len),
            };
            state.queue.insert(entry.id_hash, entry);
        }
        if end != bytes.len() || state.queue.len() != count {
            return Err(Error::CheckpointInvalid);
        }
        let mut ids = std::collections::BTreeSet::new();
        if state.prompts.len() > 32
            || state.queue.len() > MAX_QUEUE_ENTRIES
            || state.settled_prompts.len() > 32
            || state.forced_tools.len() > 64
            || state.forced_order.len() > 64
            || state
                .open_rows()
                .filter(|r| {
                    !matches!(r.kind, crate::row::RowKind::User | crate::row::RowKind::Group)
                })
                .count()
                > 64
            || state.reply.iter().chain(state.thought.iter()).any(|s| {
                s.facts.runs.len() > 8
                    || s.facts.runs.iter().any(|r| r.0 == 0 || r.0 > r.1 || r.1 > state.last_id)
            })
        {
            return Err(Error::CheckpointInvalid);
        }
        if pos > MAX_TRANSLATOR_BYTES - 4 {
            return Err(Error::CheckpointInvalid);
        }
        if state.turn.is_some_and(|id| id == 0 || id > state.last_id)
            || state.stored_rows().any(|r| {
                r.id == 0
                    || r.id > state.last_id
                    || r.rev != 1
                    || !ids.insert(r.id)
                    || r.turn.is_some_and(|id| id == 0 || id > state.last_id)
                    || r.group.is_some_and(|id| id == 0 || id >= r.id)
            })
        {
            return Err(Error::CheckpointInvalid);
        }
        Ok(state)
    }
}
pub(super) mod kind {
    use crate::row::RowKind;
    use serde::{Deserialize, Deserializer, Serializer};
    pub fn serialize<S: Serializer>(kind: &RowKind, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(kind.as_str())
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<RowKind, D::Error> {
        let name = String::deserialize(d)?;
        RowKind::parse(&name).ok_or_else(|| serde::de::Error::custom("row kind"))
    }
}

fn codec() -> impl Options {
    bincode::DefaultOptions::new()
        .with_varint_encoding()
        .with_limit(MAX_STATE_BYTES as u64)
        .reject_trailing_bytes()
}
