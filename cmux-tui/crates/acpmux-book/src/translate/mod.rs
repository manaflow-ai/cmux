//! Deterministic harness lines to book operations. The actor owns bodies and raw files.
//! Restore the entire checkpoint before replay; never restore only the row counter.
#[cfg(all(test, target_os = "linux"))]
mod bench;
mod blocks;
mod checkpoint;
mod claude;
mod input;
#[cfg(test)]
mod tests;
mod v1;

use crate::row::{Row, RowKind};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const VERSION: u32 = 2;
pub const MAX_STATE_BYTES: usize = 32 * 1024;
const MAX_KEY_BYTES: usize = 256;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Harness {
    V1,
    Claude,
}

/// Relative to exactly the bytes supplied to `translate`, never a raw-file offset.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RawRange {
    pub offset: usize,
    pub length: usize,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Op {
    pub raw: RawRange,
    pub change: Change,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Change {
    /// Create or update metadata. Never replaces an existing body's contents.
    Row(OwnedRow),
    /// Apply before the following settle. Input values are JSON, copied/decoded by
    /// the actor directly into its inline body or blob. Text pieces are <=16 KiB.
    Body { id: u64, field: BodyField, append: bool, source: BodySource },
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BodyField {
    Text,
    Content,
    Input,
    Entries,
    Source,
    Images,
    Title,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BodySource {
    Text(String),
    /// One complete JSON value within the current input, including quotes for strings.
    Input(RawRange),
}

/// Only metadata: no body, preview, tool output or arguments live in translator state.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OwnedRow {
    pub id: u64,
    pub rev: u32,
    #[serde(with = "checkpoint::kind")]
    pub kind: RowKind,
    pub turn: Option<u64>,
    pub group: Option<u64>,
    pub at: u64,
    pub open: bool,
    pub bytes: u64,
    pub lines: u64,
    pub fields: BTreeMap<String, String>,
}
impl OwnedRow {
    pub fn as_row<'a>(&self, body: &'a str) -> Row<'a> {
        Row {
            id: self.id,
            rev: self.rev,
            kind: self.kind,
            turn: self.turn,
            group: self.group,
            at: self.at,
            open: self.open,
            body,
            est: u32::try_from(self.lines.max(1)).unwrap_or(u32::MAX),
        }
    }
    fn field(&mut self, key: &str, value: &str) -> Result<(), Error> {
        bounded(value)?;
        self.fields
            .insert(key.into(), serde_json::to_string(value).map_err(|_| Error::InvalidJson)?);
        Ok(())
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Stream {
    key: String,
    row: OwnedRow,
    block: blocks::Block,
    continuation: bool,
}
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct State {
    last_id: u64,
    last_v1_seq: u64,
    at: u64,
    turn: Option<u64>,
    turn_key: String,
    reply: Option<Stream>,
    thought: Option<Stream>,
    tools: BTreeMap<String, OwnedRow>,
    group: Option<OwnedRow>,
    plan: Option<OwnedRow>,
    compaction: Option<OwnedRow>,
    prompts: BTreeMap<String, OwnedRow>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    InvalidJson,
    InvalidRecord(&'static str),
    CounterExhausted,
    CheckpointVersion,
    CheckpointInvalid,
    StateTooLarge { bytes: usize },
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "translate: {self:?}")
    }
}
impl std::error::Error for Error {}

/// A complete JSON line. Errors leave state unchanged. The actor advances its raw
/// cursor only after successfully applying the returned operations in order.
pub fn translate(state: &mut State, harness: Harness, bytes: &[u8]) -> Result<Vec<Op>, Error> {
    let mut next = state.clone();
    let mut out = input::Output::new(bytes);
    match harness {
        Harness::V1 => v1::line(&mut next, bytes, &mut out)?,
        Harness::Claude => claude::line(&mut next, bytes, &mut out)?,
    }
    // Count live state, never settled history. A capacity failure is transactional.
    next.checkpoint()?;
    *state = next;
    Ok(out.ops)
}
fn bounded(s: &str) -> Result<(), Error> {
    if s.len() > MAX_KEY_BYTES {
        Err(Error::InvalidRecord("identity or metadata exceeds 256 bytes"))
    } else {
        Ok(())
    }
}
impl State {
    pub fn last_row_id(&self) -> u64 {
        self.last_id
    }
    pub fn open_rows(&self) -> impl Iterator<Item = &OwnedRow> {
        self.reply
            .iter()
            .map(|s| &s.row)
            .chain(self.thought.iter().map(|s| &s.row))
            .chain(self.tools.values())
            .chain(self.group.iter())
            .chain(self.plan.iter())
            .chain(self.compaction.iter())
            .chain(self.prompts.values())
            .filter(|row| row.open)
    }
    fn row(&mut self, kind: RowKind) -> Result<OwnedRow, Error> {
        self.last_id = self.last_id.checked_add(1).ok_or(Error::CounterExhausted)?;
        Ok(OwnedRow {
            id: self.last_id,
            rev: 1,
            kind,
            turn: self.turn,
            group: None,
            at: self.at,
            open: true,
            bytes: 0,
            lines: 0,
            fields: BTreeMap::new(),
        })
    }
    fn group(&mut self, out: &mut input::Output<'_>) -> Result<u64, Error> {
        if let Some(row) = &self.group {
            return Ok(row.id);
        }
        let mut row = self.row(RowKind::Group)?;
        row.fields.insert("toolCount".into(), "0".into());
        let id = row.id;
        out.row(&row);
        self.group = Some(row);
        Ok(id)
    }
    fn close_stream(stream: &mut Option<Stream>, out: &mut input::Output<'_>) {
        if let Some(mut stream) = stream.take() {
            if stream.row.open {
                stream.row.open = false;
                out.row(&stream.row);
            }
        }
    }
    fn close_row(row: &mut Option<OwnedRow>, out: &mut input::Output<'_>) {
        if let Some(mut row) = row.take() {
            row.open = false;
            out.row(&row);
        }
    }
    fn close_text(&mut self, out: &mut input::Output<'_>) {
        Self::close_stream(&mut self.reply, out);
        Self::close_stream(&mut self.thought, out);
    }
    fn finish(&mut self, out: &mut input::Output<'_>) {
        self.close_text(out);
        Self::close_row(&mut self.plan, out);
        Self::close_row(&mut self.compaction, out);
        if let Some(group) = &mut self.group {
            group
                .fields
                .insert("durationSeconds".into(), self.at.saturating_sub(group.at).to_string());
        }
        Self::close_row(&mut self.group, out);
        // Background tools may complete after this turn. Preserve their original IDs.
    }
    /// Queue/read precedes the late echo, reserving the row's permanent place.
    fn reserve_prompt(
        &mut self,
        key: &str,
        body: Option<&serde_json::value::RawValue>,
        out: &mut input::Output<'_>,
    ) -> Result<(), Error> {
        bounded(key)?;
        if key.is_empty() || self.prompts.contains_key(key) {
            return Ok(());
        }
        let mut row = self.row(RowKind::User)?;
        row.field("state", "queued")?;
        out.row(&row);
        if let Some(raw) = body {
            out.body(row.id, BodyField::Content, false, raw)?;
        }
        self.prompts.insert(key.into(), row);
        Ok(())
    }
    fn steer_read(&mut self, key: &str, out: &mut input::Output<'_>) -> Result<(), Error> {
        if self.prompts.get(key).is_some_and(|row| !row.open) {
            return Ok(());
        }
        self.close_text(out);
        self.reserve_prompt(key, None, out)?;
        if let Some(row) = self.prompts.get_mut(key) {
            row.field("state", "sent")?;
            row.fields.insert("steer".into(), "true".into());
            out.row(row);
        }
        Ok(())
    }
    fn prompt(
        &mut self,
        key: &str,
        prompt_key: &str,
        steer: bool,
        notice: bool,
        body: Option<&serde_json::value::RawValue>,
        out: &mut input::Output<'_>,
    ) -> Result<(), Error> {
        bounded(key)?;
        bounded(prompt_key)?;
        if self.prompts.get(prompt_key).is_some_and(|row| !row.open) {
            return Ok(());
        }
        if steer {
            self.close_text(out);
        } else {
            self.finish(out);
        }
        let mut row = if let Some(row) = self.prompts.remove(prompt_key) {
            row
        } else {
            self.row(if notice { RowKind::Notice } else { RowKind::User })?
        };
        row.field("state", "sent")?;
        if steer {
            row.fields.insert("steer".into(), "true".into());
        }
        if !steer {
            self.turn = Some(row.id);
            self.turn_key = key.into();
            row.turn = self.turn;
            self.prompts.retain(|_, row| row.open);
        }
        out.row(&row);
        if let Some(body) = body {
            out.body(row.id, BodyField::Content, false, body)?;
        }
        row.open = false;
        out.row(&row);
        if !prompt_key.is_empty() {
            self.prompts.insert(prompt_key.into(), row);
        }
        Ok(())
    }
    fn text(
        &mut self,
        text: &str,
        key: &str,
        thinking: bool,
        out: &mut input::Output<'_>,
    ) -> Result<(), Error> {
        if text.is_empty() {
            return Ok(());
        }
        bounded(key)?;
        let mut slot = if thinking { self.thought.take() } else { self.reply.take() };
        if slot.as_ref().is_some_and(|s| s.key != key) {
            Self::close_stream(&mut slot, out);
        }
        let mut stream = if let Some(s) = slot {
            s
        } else {
            let group = if thinking { Some(self.group(out)?) } else { None };
            let mut row = self.row(if thinking { RowKind::Thinking } else { RowKind::Text })?;
            row.group = group;
            row.field("messageId", key)?;
            out.row(&row);
            Stream { key: key.into(), row, block: blocks::Block::default(), continuation: false }
        };
        let mut start = 0;
        for (offset, ch) in text.char_indices() {
            if !stream.row.open {
                let mut row = self.row(stream.row.kind)?;
                row.group = stream.row.group;
                row.fields.insert("cont".into(), "true".into());
                if let Some(marker) = stream.block.fence_marker() {
                    row.field("fence", &marker)?;
                }
                row.field("messageId", key)?;
                out.row(&row);
                stream.row = row;
                stream.continuation = true;
            }
            stream.row.bytes = stream.row.bytes.saturating_add(ch.len_utf8() as u64);
            let boundary = stream.block.push(ch);
            if ch == '\n' {
                stream.row.lines = stream.row.lines.saturating_add(1);
            }
            let end = offset.saturating_add(ch.len_utf8());
            let cut = ch == '\n'
                && (stream.row.bytes >= 16 * 1024 || (stream.row.bytes >= 8 * 1024 && boundary));
            // Bounded output chunks even for a single very long unclosed line.
            if cut || end.saturating_sub(start) >= 16 * 1024 - 4 {
                out.text(stream.row.id, &text[start..end]);
                start = end;
            }
            if cut {
                stream.row.open = false;
                out.row(&stream.row);
            }
        }
        if start < text.len() {
            out.text(stream.row.id, &text[start..]);
        }
        if thinking {
            self.thought = Some(stream)
        } else {
            self.reply = Some(stream)
        };
        Ok(())
    }
    fn tool(
        &mut self,
        key: &str,
        metadata: &[(&str, &str)],
        parts: &[(BodyField, bool, &serde_json::value::RawValue)],
        ended: bool,
        out: &mut input::Output<'_>,
    ) -> Result<(), Error> {
        bounded(key)?;
        self.close_text(out);
        let mut row = if let Some(row) = self.tools.remove(key) {
            row
        } else {
            let group = self.group(out)?;
            let mut row = self.row(RowKind::Tool)?;
            row.group = Some(group);
            row.field("callId", key)?;
            if let Some(group) = &mut self.group {
                let n =
                    group.fields.get("toolCount").and_then(|s| s.parse::<u64>().ok()).unwrap_or(0);
                group.fields.insert("toolCount".into(), n.saturating_add(1).to_string());
                out.row(group);
            }
            row
        };
        for (key, value) in metadata {
            row.field(key, value)?;
        }
        out.row(&row);
        for (field, append, raw) in parts {
            out.body(row.id, *field, *append, raw)?;
        }
        if ended {
            row.open = false;
            out.row(&row);
        } else {
            self.tools.insert(key.into(), row);
        }
        Ok(())
    }
}
