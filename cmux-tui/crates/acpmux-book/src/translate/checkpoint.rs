//! Opaque versioned state, independent of the log's record/checkpoint layout.
use super::{Error, MAX_QUEUE_ENTRIES, MAX_STATE_BYTES, MAX_TRANSLATOR_BYTES, State, VERSION};
use bincode::Options;
impl State {
    pub fn checkpoint(&self) -> Result<Vec<u8>, Error> {
        let bytes = codec().serialize(&(VERSION, self)).map_err(|_| Error::CheckpointInvalid)?;
        if bytes.len() > MAX_STATE_BYTES {
            return Err(Error::StateTooLarge { bytes: bytes.len() });
        }
        if self.queue.len().saturating_mul(32) > MAX_STATE_BYTES - MAX_TRANSLATOR_BYTES {
            return Err(Error::StateTooLarge { bytes: bytes.len() });
        }
        let mut translator = self.clone();
        translator.queue.clear();
        let translator_bytes =
            codec().serialize(&(VERSION, &translator)).map_err(|_| Error::CheckpointInvalid)?;
        if translator_bytes.len() > MAX_TRANSLATOR_BYTES {
            return Err(Error::StateTooLarge { bytes: translator_bytes.len() });
        }
        Ok(bytes)
    }
    pub fn restore(bytes: &[u8]) -> Result<Self, Error> {
        if bytes.len() > MAX_STATE_BYTES {
            return Err(Error::StateTooLarge { bytes: bytes.len() });
        }
        let (version, state): (u32, Self) =
            codec().deserialize(bytes).map_err(|_| Error::CheckpointInvalid)?;
        if version != VERSION {
            return Err(Error::CheckpointVersion);
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
        if state.queue.len().saturating_mul(32) > MAX_STATE_BYTES - MAX_TRANSLATOR_BYTES {
            return Err(Error::CheckpointInvalid);
        }
        let mut translator = state.clone();
        translator.queue.clear();
        let translator_bytes =
            codec().serialize(&(VERSION, &translator)).map_err(|_| Error::CheckpointInvalid)?;
        if translator_bytes.len() > MAX_TRANSLATOR_BYTES {
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
