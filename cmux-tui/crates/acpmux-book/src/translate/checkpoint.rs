//! Opaque versioned state, independent of the log's record/checkpoint layout.
use super::{Error, MAX_STATE_BYTES, State, VERSION};
impl State {
    pub fn checkpoint(&self) -> Result<Vec<u8>, Error> {
        let bytes = serde_json::to_vec(&(VERSION, self)).map_err(|_| Error::CheckpointInvalid)?;
        if bytes.len() > MAX_STATE_BYTES {
            return Err(Error::StateTooLarge { bytes: bytes.len() });
        }
        Ok(bytes)
    }
    pub fn restore(bytes: &[u8]) -> Result<Self, Error> {
        if bytes.len() > MAX_STATE_BYTES {
            return Err(Error::StateTooLarge { bytes: bytes.len() });
        }
        let (version, state): (u32, Self) =
            serde_json::from_slice(bytes).map_err(|_| Error::CheckpointInvalid)?;
        if version != VERSION {
            return Err(Error::CheckpointVersion);
        }
        let mut ids = std::collections::BTreeSet::new();
        if state.turn.is_some_and(|id| id == 0 || id > state.last_id)
            || state.open_rows().any(|r| {
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
