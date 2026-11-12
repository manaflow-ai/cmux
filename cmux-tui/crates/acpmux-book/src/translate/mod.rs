//! Harness bytes become row operations once, at append time.
//!
//! Seed: `acpmux/src/rows/fold.rs`. Unlike that reader-side fold, this state has no
//! settled-row table. The actor owns persistence and prefixes each operation's
//! input-relative raw range with its raw file and base offset. On replay it must
//! restore this entire state, never just the row counter.
#[cfg(all(test, target_os = "linux"))]
mod bench;
mod checkpoint;
mod claude;
mod json;
#[cfg(test)]
mod tests;
mod v1;

use crate::row::{Row, RowKind};
use std::collections::BTreeMap;

/// Bump when the translation changes; an old book must be rebuilt from raw.
pub const VERSION: u32 = 1;
/// Leave half the actor's checkpoint for its cursor, queue, asks and summary.
pub const MAX_STATE_BYTES: usize = 32 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Harness {
    V1,
    Claude,
}

/// A byte range within exactly the input passed to [`translate`]. No file layout here.
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
    /// A newly opened row, or the complete row as it settles (`open == false`).
    Row(OwnedRow),
    /// Only the new text, never a copy of the preceding text.
    Text { id: u64, text: String },
    /// Update only an open row's changed fields and optional replacement text.
    /// The actor applies this to its open row; no settled row is read or rewritten.
    Update { id: u64, fields: BTreeMap<String, String>, text: Option<String> },
}

/// An owned counterpart of [`Row`]. `fields` contains compact JSON per-kind metadata.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OwnedRow {
    pub id: u64,
    pub rev: u32,
    pub kind: RowKind,
    pub turn: Option<u64>,
    pub group: Option<u64>,
    pub at: u64,
    pub open: bool,
    pub text: String,
    pub fields: BTreeMap<String, String>,
}
impl OwnedRow {
    pub fn body(&self) -> String {
        let mut body = String::from("{\"text\":");
        quoted(&mut body, &self.text);
        for (key, value) in &self.fields {
            body.push(',');
            quoted(&mut body, key);
            body.push(':');
            body.push_str(value);
        }
        body.push('}');
        body
    }
    /// The caller keeps `body` alive while encoding, and writes any out-of-line body
    /// before appending the settled row. Open rows go only to subscribers/checkpoints.
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
            est: u32::try_from(self.text.lines().count().max(1)).unwrap_or(u32::MAX),
        }
    }
    fn field(&mut self, key: &str, value: &str) {
        let mut s = String::new();
        quoted(&mut s, value);
        self.fields.insert(key.into(), s);
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Stream {
    key: String,
    row: OwnedRow,
}

/// All translator state. No clock, random seed, file handles or external counters.
/// Only rows still live are retained; settled rows are owned by the actor's book.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
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

/// Translate one complete line (an optional trailing LF/CRLF is included in `raw`).
/// Unknown event types produce no ops. Malformed JSON is an error, never skipped.
/// The actor advances its raw cursor only after a successful call and persistence.
pub fn translate(state: &mut State, harness: Harness, bytes: &[u8]) -> Result<Vec<Op>, Error> {
    let record = json::Json::parse(bytes).ok_or(Error::InvalidJson)?;
    if record.fields().is_none() {
        return Err(Error::InvalidRecord("expected an object"));
    }
    // Even an input of empty blocks cannot begin more rows than its byte length.
    let allowance = u64::try_from(bytes.len()).map_err(|_| Error::CounterExhausted)?;
    state.last_id.checked_add(allowance).ok_or(Error::CounterExhausted)?;
    let mut changes = Vec::new();
    match harness {
        Harness::V1 => v1::line(state, record, &mut changes)?,
        Harness::Claude => claude::line(state, record, &mut changes)?,
    }
    Ok(changes
        .into_iter()
        .map(|change| Op { raw: RawRange { offset: 0, length: bytes.len() }, change })
        .collect())
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
    }
    fn row(&mut self, kind: RowKind, open: bool, text: String) -> OwnedRow {
        // translate checks sufficient counter space before any mutation.
        self.last_id = self.last_id.saturating_add(1);
        OwnedRow {
            id: self.last_id,
            rev: 1,
            kind,
            turn: self.turn,
            group: None,
            at: self.at,
            open,
            text,
            fields: BTreeMap::new(),
        }
    }
    fn group(&mut self, out: &mut Vec<Change>) -> u64 {
        if let Some(row) = &self.group {
            return row.id;
        }
        let mut row = self.row(RowKind::Group, true, String::new());
        row.fields.insert("toolCount".into(), "0".into());
        let id = row.id;
        out.push(Change::Row(row.clone()));
        self.group = Some(row);
        id
    }
    fn close_stream(stream: &mut Option<Stream>, out: &mut Vec<Change>) {
        if let Some(mut s) = stream.take() {
            s.row.open = false;
            out.push(Change::Row(s.row));
        }
    }
    fn close_row(row: &mut Option<OwnedRow>, out: &mut Vec<Change>) {
        if let Some(mut row) = row.take() {
            row.open = false;
            out.push(Change::Row(row));
        }
    }
    fn close_text(&mut self, out: &mut Vec<Change>) {
        Self::close_stream(&mut self.reply, out);
        Self::close_stream(&mut self.thought, out);
    }
    fn finish(&mut self, out: &mut Vec<Change>) {
        self.close_text(out);
        // A background call can finish after the prompt's turn. Its original row and
        // turn remain live until its result arrives, as in the v1 seed fold.
        Self::close_row(&mut self.plan, out);
        Self::close_row(&mut self.compaction, out);
        if let Some(group) = &mut self.group {
            group
                .fields
                .insert("durationSeconds".into(), self.at.saturating_sub(group.at).to_string());
        }
        Self::close_row(&mut self.group, out);
        // A late final chunk still belongs to this prompt. Only a new person prompt
        // changes turn ownership; notices and turn-end delivery cannot steal it.
    }
    fn prompt(
        &mut self,
        text: String,
        key: String,
        steer: bool,
        notice: bool,
        out: &mut Vec<Change>,
    ) {
        if !steer && !notice {
            self.finish(out);
        } else {
            self.close_text(out);
        }
        let mut row = self.row(if notice { RowKind::Notice } else { RowKind::User }, false, text);
        row.field("state", "sent");
        if steer {
            row.fields.insert("steer".into(), "true".into());
        }
        if !steer && !notice {
            self.turn = Some(row.id);
            self.turn_key = key;
            row.turn = self.turn;
        }
        out.push(Change::Row(row));
    }
    fn text(&mut self, text: String, key: String, thinking: bool, out: &mut Vec<Change>) {
        if text.is_empty() {
            return;
        }
        if thinking {
            Self::close_stream(&mut self.reply, out);
        } else {
            Self::close_stream(&mut self.thought, out);
        }
        let stream = if thinking { &mut self.thought } else { &mut self.reply };
        if stream.as_ref().is_some_and(|s| s.key != key) {
            Self::close_stream(stream, out);
        }
        if let Some(stream) = stream {
            stream.row.text.push_str(&text);
            out.push(Change::Text { id: stream.row.id, text });
            return;
        }
        let group = thinking.then(|| self.group(out));
        let mut row =
            self.row(if thinking { RowKind::Thinking } else { RowKind::Text }, true, text);
        row.group = group;
        out.push(Change::Row(row.clone()));
        let stream = Some(Stream { key, row });
        if thinking {
            self.thought = stream;
        } else {
            self.reply = stream;
        }
    }
    fn tool(
        &mut self,
        key: String,
        fields: BTreeMap<String, String>,
        content: Option<String>,
        delta: Option<String>,
        ended: bool,
        out: &mut Vec<Change>,
    ) {
        self.close_text(out);
        let existing = self.tools.remove(&key);
        let was_open = existing.is_some();
        let mut row = if let Some(row) = existing {
            row
        } else {
            let group = self.group(out);
            let mut row = self.row(RowKind::Tool, true, String::new());
            row.group = Some(group);
            row.field("callId", &key);
            if let Some(group) = &mut self.group {
                let count =
                    group.fields.get("toolCount").and_then(|s| s.parse::<u64>().ok()).unwrap_or(0);
                group.fields.insert("toolCount".into(), count.saturating_add(1).to_string());
            }
            row
        };
        row.fields.extend(fields.clone());
        if let Some(text) = &content {
            row.text.clone_from(text);
        }
        if let Some(delta) = &delta {
            row.text.push_str(delta);
        }
        row.open = !ended;
        if ended {
            out.push(Change::Row(row));
        } else {
            if was_open {
                if !fields.is_empty() || content.is_some() {
                    out.push(Change::Update { id: row.id, fields, text: content });
                }
                if let Some(text) = delta.filter(|s| !s.is_empty()) {
                    out.push(Change::Text { id: row.id, text });
                }
            } else {
                out.push(Change::Row(row.clone()));
            }
            self.tools.insert(key, row);
        }
    }
}

fn quoted(out: &mut String, text: &str) {
    use std::fmt::Write;
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            ch if ch < '\u{20}' => {
                let _ = write!(out, "\\u{:04x}", u32::from(ch));
            }
            ch => out.push(ch),
        }
    }
    out.push('"');
}

fn content(value: Option<json::Json<'_>>) -> String {
    fn add(v: json::Json<'_>, out: &mut String) {
        if let Some(s) = v.string() {
            out.push_str(&s);
        } else if let Some(items) = v.items() {
            for item in items {
                add(item, out);
            }
        } else {
            match v.text("type").as_deref() {
                Some("text") => {
                    if let Some(s) = v.text("text") {
                        out.push_str(&s);
                    }
                }
                Some("thinking") => {
                    if let Some(s) = v.text("thinking") {
                        out.push_str(&s);
                    }
                }
                Some("content") => {
                    if let Some(v) = v.get("content") {
                        add(v, out);
                    }
                }
                _ => {}
            }
        }
    }
    let mut text = String::new();
    if let Some(v) = value {
        add(v, &mut text);
    }
    text
}
