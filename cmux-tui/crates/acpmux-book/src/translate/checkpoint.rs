//! Opaque versioned state, independent of the log's record/checkpoint layout.
use super::{Error, MAX_QUEUE_ENTRIES, MAX_TRANSLATOR_BYTES, QueueEntry, State, VERSION};
use bincode::Options;
use std::io::Cursor;
/// The translator's checkpoint: its serde segment, at most 32 KiB, and one fixed-width record
/// per waiting prompt, which the book keeps in its own section (`Checkpoint::prompts`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Saved {
    pub translator: Vec<u8>,
    pub prompts: Vec<[u8; 32]>,
}
impl Saved {
    pub fn restore(&self) -> Result<State, Error> {
        State::restore(&self.translator, &self.prompts)
    }
}

impl QueueEntry {
    fn to_bytes(self) -> [u8; 32] {
        let mut bytes = [0; 32];
        for (to, from) in bytes.iter_mut().zip(
            self.id_hash
                .to_le_bytes()
                .into_iter()
                .chain(self.at_state.to_le_bytes())
                .chain(self.place.to_le_bytes())
                .chain(self.span.to_le_bytes())
                .chain(self.text_len.to_le_bytes()),
        ) {
            *to = from;
        }
        bytes
    }
    fn from_bytes(bytes: &[u8; 32]) -> Self {
        let u64_at = |at: usize| {
            u64::from_le_bytes(
                bytes.get(at..at + 8).and_then(|b| b.try_into().ok()).unwrap_or([0; 8]),
            )
        };
        let u32_at = |at: usize| {
            u32::from_le_bytes(
                bytes.get(at..at + 4).and_then(|b| b.try_into().ok()).unwrap_or([0; 4]),
            )
        };
        Self {
            id_hash: u64_at(0),
            at_state: u64_at(8),
            place: u64_at(16),
            span: u32_at(24),
            text_len: u32_at(28),
        }
    }
}

impl State {
    pub fn checkpoint(&self) -> Result<Saved, Error> {
        let translator =
            codec().serialize(&(VERSION, self)).map_err(|_| Error::CheckpointInvalid)?;
        if translator.len() > MAX_TRANSLATOR_BYTES {
            return Err(Error::StateTooLarge { bytes: translator.len() });
        }
        let prompts = self.queue.values().map(|entry| entry.to_bytes()).collect();
        Ok(Saved { translator, prompts })
    }
    pub fn restore(translator: &[u8], prompts: &[[u8; 32]]) -> Result<Self, Error> {
        if translator.len() > MAX_TRANSLATOR_BYTES {
            return Err(Error::StateTooLarge { bytes: translator.len() });
        }
        if prompts.len() > MAX_QUEUE_ENTRIES {
            return Err(Error::CheckpointInvalid);
        }
        let mut cursor = Cursor::new(translator);
        let version: u32 =
            codec().deserialize_from(&mut cursor).map_err(|_| Error::CheckpointInvalid)?;
        if version != VERSION {
            return Err(Error::CheckpointVersion);
        }
        let mut state: Self =
            codec().deserialize_from(&mut cursor).map_err(|_| Error::CheckpointInvalid)?;
        if cursor.position() as usize != translator.len() {
            return Err(Error::CheckpointInvalid);
        }
        for record in prompts {
            let entry = QueueEntry::from_bytes(record);
            state.queue.insert(entry.id_hash, entry);
        }
        if state.queue.len() != prompts.len() {
            return Err(Error::CheckpointInvalid);
        }
        let mut ids = std::collections::BTreeSet::new();
        if state.prompts.len() > 32
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
        .with_limit(MAX_TRANSLATOR_BYTES as u64)
        .reject_trailing_bytes()
}
