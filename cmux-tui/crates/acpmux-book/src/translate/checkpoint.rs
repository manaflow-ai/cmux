//! Versioned, bounded translator checkpoint. It is opaque to the book log.
use super::{Error, MAX_STATE_BYTES, OwnedRow, State, Stream, VERSION, json::Json};
use crate::row::RowKind;
use std::collections::BTreeMap;

impl State {
    pub fn checkpoint(&self) -> Result<Vec<u8>, Error> {
        let mut w = Writer(Vec::new());
        w.n(u64::from(VERSION));
        w.n(self.last_id);
        w.n(self.last_v1_seq);
        w.n(self.at);
        w.n(self.turn.unwrap_or(0));
        w.s(&self.turn_key);
        for stream in [&self.reply, &self.thought] {
            w.n(u64::from(stream.is_some()));
            if let Some(s) = stream {
                w.s(&s.key);
                w.row(&s.row);
            }
        }
        w.n(self.tools.len() as u64);
        for (key, row) in &self.tools {
            w.s(key);
            w.row(row);
        }
        for row in [&self.group, &self.plan, &self.compaction] {
            w.n(u64::from(row.is_some()));
            if let Some(row) = row {
                w.row(row);
            }
        }
        if w.0.len() > MAX_STATE_BYTES {
            return Err(Error::StateTooLarge { bytes: w.0.len() });
        }
        Ok(w.0)
    }
    pub fn restore(bytes: &[u8]) -> Result<Self, Error> {
        if bytes.len() > MAX_STATE_BYTES {
            return Err(Error::StateTooLarge { bytes: bytes.len() });
        }
        let mut r = Reader(bytes);
        if r.n()? != u64::from(VERSION) {
            return Err(Error::CheckpointVersion);
        }
        let mut state = State {
            last_id: r.n()?,
            last_v1_seq: r.n()?,
            at: r.n()?,
            turn: optional(r.n()?),
            turn_key: r.s()?,
            ..State::default()
        };
        state.reply = r.stream()?;
        state.thought = r.stream()?;
        let count = r.n()?;
        for _ in 0..count {
            let key = r.s()?;
            let row = r.row()?;
            if state.tools.insert(key, row).is_some() {
                return Err(Error::CheckpointInvalid);
            }
        }
        state.group = r.optional_row()?;
        state.plan = r.optional_row()?;
        state.compaction = r.optional_row()?;
        let mut ids = std::collections::BTreeSet::new();
        if !r.0.is_empty()
            || state.turn.is_some_and(|id| id > state.last_id)
            || state.open_rows().any(|row| {
                row.id > state.last_id
                    || !row.open
                    || !ids.insert(row.id)
                    || row.turn.is_some_and(|id| id > state.last_id)
                    || row.group.is_some_and(|id| id > state.last_id)
            })
        {
            return Err(Error::CheckpointInvalid);
        }
        Ok(state)
    }
}
fn optional(n: u64) -> Option<u64> {
    (n != 0).then_some(n)
}
struct Writer(Vec<u8>);
impl Writer {
    fn n(&mut self, n: u64) {
        self.0.extend_from_slice(&n.to_le_bytes());
    }
    fn s(&mut self, s: &str) {
        self.n(s.len() as u64);
        self.0.extend_from_slice(s.as_bytes());
    }
    fn row(&mut self, row: &OwnedRow) {
        self.n(row.id);
        self.n(u64::from(row.rev));
        self.s(row.kind.as_str());
        self.n(row.turn.unwrap_or(0));
        self.n(row.group.unwrap_or(0));
        self.n(row.at);
        self.s(&row.text);
        self.n(row.fields.len() as u64);
        for (k, v) in &row.fields {
            self.s(k);
            self.s(v);
        }
    }
}
struct Reader<'a>(&'a [u8]);
impl Reader<'_> {
    fn n(&mut self) -> Result<u64, Error> {
        let n = u64::from_le_bytes(
            self.0
                .get(..8)
                .ok_or(Error::CheckpointInvalid)?
                .try_into()
                .map_err(|_| Error::CheckpointInvalid)?,
        );
        self.0 = self.0.get(8..).ok_or(Error::CheckpointInvalid)?;
        Ok(n)
    }
    fn s(&mut self) -> Result<String, Error> {
        let n = usize::try_from(self.n()?).map_err(|_| Error::CheckpointInvalid)?;
        let s = std::str::from_utf8(self.0.get(..n).ok_or(Error::CheckpointInvalid)?)
            .map_err(|_| Error::CheckpointInvalid)?
            .to_owned();
        self.0 = self.0.get(n..).ok_or(Error::CheckpointInvalid)?;
        Ok(s)
    }
    fn row(&mut self) -> Result<OwnedRow, Error> {
        let id = self.n()?;
        let rev = u32::try_from(self.n()?).map_err(|_| Error::CheckpointInvalid)?;
        let kind = RowKind::parse(&self.s()?).ok_or(Error::CheckpointInvalid)?;
        let turn = optional(self.n()?);
        let group = optional(self.n()?);
        let at = self.n()?;
        let text = self.s()?;
        let count = self.n()?;
        let mut fields = BTreeMap::new();
        for _ in 0..count {
            let k = self.s()?;
            let v = self.s()?;
            if Json::parse(v.as_bytes()).is_none() || fields.insert(k, v).is_some() {
                return Err(Error::CheckpointInvalid);
            }
        }
        if id == 0 || rev == 0 {
            return Err(Error::CheckpointInvalid);
        }
        Ok(OwnedRow { id, rev, kind, turn, group, at, open: true, text, fields })
    }
    fn stream(&mut self) -> Result<Option<Stream>, Error> {
        match self.n()? {
            0 => Ok(None),
            1 => Ok(Some(Stream { key: self.s()?, row: self.row()? })),
            _ => Err(Error::CheckpointInvalid),
        }
    }
    fn optional_row(&mut self) -> Result<Option<OwnedRow>, Error> {
        match self.n()? {
            0 => Ok(None),
            1 => Ok(Some(self.row()?)),
            _ => Err(Error::CheckpointInvalid),
        }
    }
}
