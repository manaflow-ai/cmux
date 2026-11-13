//! Deterministic harness lines to book operations. The actor owns bodies and raw files.
//! Restore the entire checkpoint before replay; never restore only the row counter.
#[cfg(all(test, target_os = "linux"))]
mod bench;
mod blocks;
mod checkpoint;
mod claude;
mod fold;
mod input;
#[cfg(test)]
mod tests;
mod v1;

use crate::row::{Row, RowKind};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const VERSION: u32 = 5;
pub const MAX_STATE_BYTES: usize = 96 * 1024;
const MAX_TRANSLATOR_BYTES: usize = 32 * 1024;
const MAX_QUEUE_ENTRIES: usize = 1024;
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
    /// Create or update metadata. Keeps body contents, except a hidden settle
    /// replaces the body with `{"hidden":true}` and has estimate zero. `fields`
    /// merges into the actor-owned body; absence never removes an earlier field.
    Row(OwnedRow),
    /// Rare replacement of a settled live-message block; rev is incremented.
    Patch(OwnedRow),
    /// Add or update one bounded prompt-queue entry, or remove it by id hash.
    Queue(QueueChange),
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
    /// Text in a previously logged raw line. The actor resolves this source.
    Raw {
        place: u64,
        span: u64,
    },
}

/// A durable queue mutation. Add is an idempotent upsert: a repeated queued line does
/// not duplicate an entry, while a hold/release may change its packed state.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum QueueChange {
    Add(QueueEntry),
    Remove(u64),
}

/// The compact queue checkpoint record. Its packed representation is deliberately 32 bytes:
/// id hash (8), timestamp/state (8), raw place (8), raw span (4), decoded text length (4).
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct QueueEntry {
    pub id_hash: u64,
    at_state: u64,
    pub place: u64,
    pub span: u32,
    pub text_len: u32,
}
impl QueueEntry {
    const AT_MASK: u64 = (1 << 48) - 1;
    const STATE_SHIFT: u32 = 48;
    const HELD: u64 = 1;

    pub fn new(id_hash: u64, at_ms: u64, held: bool, place: u64, span: u64, text_len: u64) -> Self {
        let state = if held { Self::HELD } else { 0 };
        Self {
            id_hash,
            at_state: (at_ms & Self::AT_MASK) | (state << Self::STATE_SHIFT),
            place,
            span: u32::try_from(span).unwrap_or(u32::MAX),
            text_len: u32::try_from(text_len).unwrap_or(u32::MAX),
        }
    }
    pub fn at_ms(self) -> u64 {
        self.at_state & Self::AT_MASK
    }
    pub fn held(self) -> bool {
        (self.at_state >> Self::STATE_SHIFT) & Self::HELD != 0
    }
    fn with_held(self, held: bool) -> Self {
        Self::new(
            self.id_hash,
            self.at_ms(),
            held,
            self.place,
            self.span as u64,
            self.text_len as u64,
        )
    }
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
            est: if self.fields.get("hidden").is_some_and(|s| s == "true") {
                0
            } else {
                u32::try_from(self.lines.max(1)).unwrap_or(u32::MAX)
            },
        }
    }
    fn field(&mut self, key: &str, value: &str) -> bool {
        let truncated = value.len() > MAX_KEY_BYTES;
        let mut end = value.len().min(MAX_KEY_BYTES);
        while !value.is_char_boundary(end) {
            end -= 1;
        }
        self.fields.insert(
            key.into(),
            serde_json::to_string(value.get(..end).unwrap_or_default())
                .unwrap_or_else(|_| "\"\"".into()),
        );
        truncated
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Stream {
    key: String,
    message: String,
    row: OwnedRow,
    block: blocks::Block,
    facts: fold::Reply,
    deferred_cut: bool,
    plain_next: bool,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Prompt {
    row: OwnedRow,
    has_body: bool,
    read: bool,
}
struct PromptEvent<'a> {
    key: &'a str,
    prompt_key: &'a str,
    steer: bool,
    notice: bool,
    body: Option<&'a serde_json::value::RawValue>,
    images: Option<&'a serde_json::value::RawValue>,
}
fn prompt_hash(key: &str) -> u64 {
    key.bytes().fold(0xcbf29ce484222325, |h, b| (h ^ u64::from(b)).wrapping_mul(0x100000001b3))
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
    subs: BTreeMap<String, OwnedRow>,
    group: Option<OwnedRow>,
    plan: Option<OwnedRow>,
    compaction: Option<OwnedRow>,
    prompts: BTreeMap<u64, Prompt>,
    queue: BTreeMap<u64, QueueEntry>,
    queue_overflowed: u64,
    settled_prompts: Vec<u64>,
    replayed_prompts: u64,
    forced_steers: u64,
    forced_rows: u64,
    dropped_fold_steers: u64,
    fold: fold::Fold,
    ignored_supersedes: u64,
    #[serde(skip)]
    invalid_records: u64,
    dropped_tool_updates: u64,
    forced_tools: BTreeMap<u64, u64>,
    forced_order: Vec<u64>,
    #[serde(skip)]
    cut_fields: u64,
    #[serde(skip)]
    line_errors: u64,
    turn_start_ms: u64,
    at_ms: u64,
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
pub fn translate(
    state: &mut State,
    harness: Harness,
    place: u64,
    span: u64,
    bytes: &[u8],
) -> Result<Vec<Op>, Error> {
    let mut out = input::Output::new(bytes);
    let valid = match harness {
        Harness::V1 => v1::validate(bytes),
        Harness::Claude => claude::validate(bytes),
    };
    if valid.is_err() {
        state.invalid_records = state.invalid_records.saturating_add(1);
        return Ok(Vec::new());
    }
    let result = match harness {
        Harness::V1 => v1::line(state, place, span, bytes, &mut out),
        Harness::Claude => claude::line(state, bytes, &mut out),
    };
    debug_assert!(result.is_ok(), "validated harness line failed during apply");
    if result.is_err() {
        state.line_errors = state.line_errors.saturating_add(1);
        return Ok(Vec::new());
    }
    state.bound_open_rows(&mut out);
    // The queue is counted separately from the translator's 32 KiB budget. The
    // combined checkpoint remains below MAX_STATE_BYTES (96 KiB).
    Ok(out.ops)
}
fn bounded(s: &str) -> Result<(), Error> {
    if s.len() > MAX_KEY_BYTES {
        Err(Error::InvalidRecord("identity or metadata exceeds 256 bytes"))
    } else {
        Ok(())
    }
}
/// Explicit lossy-cap/late-identity outcomes, for the actor's counters.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Counters {
    pub forced_rows: u64,
    pub forced_steers: u64,
    pub dropped_fold_steers: u64,
    pub replayed_prompts: u64,
    pub ignored_supersedes: u64,
    pub invalid_records: u64,
    pub dropped_tool_updates: u64,
    pub cut_fields: u64,
    pub line_errors: u64,
    pub queue_overflowed: u64,
}
impl State {
    pub fn counters(&self) -> Counters {
        Counters {
            forced_rows: self.forced_rows,
            forced_steers: self.forced_steers,
            dropped_fold_steers: self.dropped_fold_steers.saturating_add(self.fold.dropped_steers),
            replayed_prompts: self.replayed_prompts,
            ignored_supersedes: self.ignored_supersedes,
            invalid_records: self.invalid_records,
            dropped_tool_updates: self.dropped_tool_updates,
            cut_fields: self.cut_fields,
            line_errors: self.line_errors,
            queue_overflowed: self.queue_overflowed,
        }
    }
    pub fn last_row_id(&self) -> u64 {
        self.last_id
    }
    pub fn open_rows(&self) -> impl Iterator<Item = &OwnedRow> {
        self.stored_rows().filter(|row| row.open)
    }
    fn stored_rows(&self) -> impl Iterator<Item = &OwnedRow> {
        self.reply
            .iter()
            .map(|s| &s.row)
            .chain(self.thought.iter().map(|s| &s.row))
            .chain(self.tools.values())
            .chain(self.subs.values())
            .chain(self.group.iter())
            .chain(self.plan.iter())
            .chain(self.compaction.iter())
            .chain(self.prompts.values().map(|p| &p.row))
    }
    fn row(&mut self, kind: RowKind, out: &mut input::Output<'_>) -> Result<OwnedRow, Error> {
        if !matches!(kind, RowKind::User | RowKind::Group) {
            self.bound_counted_rows(63, out);
        }
        self.last_id = self.last_id.checked_add(1).ok_or(Error::CounterExhausted)?;
        Ok(OwnedRow {
            id: self.last_id,
            rev: 1,
            kind,
            turn: self.turn,
            group: if matches!(kind, RowKind::User | RowKind::Group) {
                None
            } else {
                self.group.as_ref().map(|r| r.id)
            },
            at: self.at,
            open: true,
            bytes: 0,
            lines: 0,
            fields: BTreeMap::new(),
        })
    }
    fn queue_add(
        &mut self,
        id: &str,
        at_ms: u64,
        held: bool,
        place: u64,
        span: u64,
        text_len: u64,
        out: &mut input::Output<'_>,
    ) {
        if id.is_empty() {
            return;
        }
        let hash = prompt_hash(id);
        let entry = QueueEntry::new(hash, at_ms, held, place, span, text_len);
        if let Some(old) = self.queue.get(&hash).copied() {
            if old == entry {
                return;
            }
            self.queue.insert(hash, entry);
            out.emit(Change::Queue(QueueChange::Add(entry)));
            return;
        }
        if self.queue.len() >= MAX_QUEUE_ENTRIES {
            self.queue_overflowed = self.queue_overflowed.saturating_add(1);
            return;
        }
        self.queue.insert(hash, entry);
        out.emit(Change::Queue(QueueChange::Add(entry)));
    }
    fn queue_remove(&mut self, id: &str, out: &mut input::Output<'_>) {
        if id.is_empty() {
            return;
        }
        let hash = prompt_hash(id);
        if self.queue.remove(&hash).is_some() {
            out.emit(Change::Queue(QueueChange::Remove(hash)));
        }
    }
    fn queue_set_held(
        &mut self,
        raw: Option<&serde_json::value::RawValue>,
        held: bool,
        out: &mut input::Output<'_>,
    ) -> Result<(), Error> {
        let Some(raw) = raw else { return Ok(()) };
        input::each(raw, |id| {
            let id = input::text(id)?;
            let hash = prompt_hash(&id);
            if let Some(entry) = self.queue.get(&hash).copied() {
                let next = entry.with_held(held);
                if next != entry {
                    self.queue.insert(hash, next);
                    out.emit(Change::Queue(QueueChange::Add(next)));
                }
            }
            Ok(())
        })
    }
    fn queue_set_all_held(&mut self, held: bool, out: &mut input::Output<'_>) {
        let entries: Vec<_> = self.queue.values().copied().collect();
        for entry in entries {
            let next = entry.with_held(held);
            if next != entry {
                self.queue.insert(next.id_hash, next);
                out.emit(Change::Queue(QueueChange::Add(next)));
            }
        }
    }
    fn group(&mut self, out: &mut input::Output<'_>) -> Result<u64, Error> {
        if let Some(row) = &self.group {
            return Ok(row.id);
        }
        let mut row = self.row(RowKind::Group, out)?;
        row.fields.insert("calls".into(), "0".into());
        let id = row.id;
        out.row(&row);
        self.group = Some(row);
        Ok(id)
    }
    fn close_stream(stream: &mut Option<Stream>, out: &mut input::Output<'_>) {
        if let Some(mut stream) = stream.take()
            && stream.row.open
        {
            stream.row.open = false;
            out.row(&stream.row);
        }
    }
    fn close_row(row: &mut Option<OwnedRow>, out: &mut input::Output<'_>) {
        if let Some(mut row) = row.take() {
            row.open = false;
            out.row(&row);
        }
    }
    fn close_text(&mut self, out: &mut input::Output<'_>) {
        if let Some(reply) = &self.reply {
            self.fold.reply(&reply.facts);
        }
        Self::close_stream(&mut self.reply, out);
        Self::close_stream(&mut self.thought, out);
    }
    fn close_reply_for_work(&mut self, out: &mut input::Output<'_>) {
        if let Some(facts) = self.reply.as_ref().map(|reply| reply.facts.clone()) {
            self.fold.reply(&facts);
        }
        if let Some(reply) = &mut self.reply {
            if reply.row.open {
                reply.row.open = false;
                out.row(&reply.row);
            }
            reply.plain_next = true;
        }
    }
    fn mark_steer(&mut self) {
        if let Some(reply) = &self.reply {
            self.fold.reply(&reply.facts);
        }
        self.fold.steer();
    }
    fn finish(&mut self, out: &mut input::Output<'_>) {
        self.close_text(out);
        Self::close_row(&mut self.plan, out);
        Self::close_row(&mut self.compaction, out);
        if let Some(group) = &mut self.group {
            group
                .fields
                .insert("ms".into(), self.at_ms.saturating_sub(self.turn_start_ms).to_string());
            group.fields.insert("last".into(), self.last_id.to_string());
            if let Ok(visible) = serde_json::to_string(&self.fold.out()) {
                group.fields.insert("out".into(), visible);
            }
        }
        Self::close_row(&mut self.group, out);
        self.dropped_fold_steers =
            self.dropped_fold_steers.saturating_add(self.fold.dropped_steers);
        self.fold = fold::Fold::default();
        self.turn_key.clear();
        // Background tools may complete after this turn. Preserve their original IDs.
    }
    fn supersede(&mut self, key: &str, out: &mut input::Output<'_>) {
        if key.is_empty() || self.reply.as_ref().is_none_or(|s| s.message != key) {
            self.ignored_supersedes = self.ignored_supersedes.saturating_add(1);
            return;
        }
        if let Some(mut stream) = self.reply.take() {
            self.fold.forget(&stream.facts.runs);
            for (index, run) in stream.facts.runs.iter().enumerate() {
                // The ninth-run fallback widens the eighth range only to keep
                // the bounded fold safe. It is not an exact reply range.
                if stream.facts.wide && index == 7 {
                    continue;
                }
                for id in run.0..=run.1 {
                    if id == stream.row.id && stream.row.open {
                        continue;
                    }
                    let mut row = stream.row.clone();
                    row.id = id;
                    row.rev = 2;
                    row.at = self.at;
                    row.bytes = 0;
                    row.lines = 0;
                    row.open = false;
                    row.fields.clear();
                    row.fields.insert("hidden".into(), "true".into());
                    out.emit(Change::Patch(row));
                }
            }
            if stream.row.open {
                stream.row.fields.clear();
                stream.row.fields.insert("hidden".into(), "true".into());
                stream.row.bytes = 0;
                stream.row.lines = 0;
                stream.row.open = false;
                out.row(&stream.row);
            }
        }
    }
    fn settled_prompt(&mut self, hash: u64) {
        if self.settled_prompts.len() == 32 {
            self.settled_prompts.remove(0);
        }
        self.settled_prompts.push(hash);
    }
    fn settle_prompt(&mut self, hash: u64, hidden: bool, out: &mut input::Output<'_>) {
        if let Some(mut prompt) = self.prompts.remove(&hash) {
            prompt.row.open = false;
            if hidden || !prompt.has_body {
                prompt.row.fields.clear();
                prompt.row.fields.insert("hidden".into(), "true".into());
            }
            out.row(&prompt.row);
            if !hidden && prompt.has_body {
                self.settled_prompt(hash);
            }
        }
    }
    fn finish_steers(&mut self, except: Option<u64>, out: &mut input::Output<'_>) {
        let keys: Vec<_> = self
            .prompts
            .iter()
            .filter(|(hash, p)| {
                Some(**hash) != except
                    && p.has_body
                    && (p.read || p.row.fields.contains_key("steer"))
            })
            .map(|(hash, _)| *hash)
            .collect();
        for hash in keys {
            self.settle_prompt(hash, false, out);
        }
    }
    /// Queue/read precedes the echo and reserves the row's permanent place.
    fn reserve_prompt(
        &mut self,
        key: &str,
        body: Option<&serde_json::value::RawValue>,
        out: &mut input::Output<'_>,
    ) -> Result<(), Error> {
        bounded(key)?;
        let hash = prompt_hash(key);
        if key.is_empty() || self.prompts.contains_key(&hash) {
            return Ok(());
        }
        if self.prompts.len() == 32
            && let Some(old) =
                self.prompts.iter().min_by_key(|(_, p)| p.row.id).map(|(hash, _)| *hash)
        {
            self.settle_prompt(old, false, out);
            self.forced_steers = self.forced_steers.saturating_add(1);
        }
        let mut row = self.row(RowKind::User, out)?;
        row.field("state", "queued");
        out.row(&row);
        if let Some(raw) = body {
            out.body(row.id, BodyField::Content, false, raw);
        }
        self.prompts.insert(hash, Prompt { row, has_body: body.is_some(), read: false });
        Ok(())
    }
    fn steer_read(&mut self, key: &str, out: &mut input::Output<'_>) -> Result<(), Error> {
        if key.is_empty() {
            return Ok(());
        }
        let hash = prompt_hash(key);
        if self.settled_prompts.contains(&hash) {
            return Ok(());
        }
        if let Some(entry) = self.queue.get(&hash).copied() {
            self.mark_steer();
            self.queue_remove(key, out);
            let mut row = self.row(RowKind::User, out)?;
            row.turn = self.turn;
            debug_assert!(!row.field("state", "sent"));
            row.fields.insert("steer".into(), "true".into());
            out.row(&row);
            out.raw_body(row.id, BodyField::Content, false, entry.place, u64::from(entry.span));
            row.open = false;
            out.row(&row);
            self.fold.extra(row.id);
            self.settled_prompt(hash);
            return Ok(());
        }
        let already_steer =
            self.prompts.get(&hash).is_some_and(|p| p.row.fields.contains_key("steer"));
        if !already_steer {
            self.mark_steer();
        }
        self.reserve_prompt(key, None, out)?;
        if let Some(prompt) = self.prompts.get_mut(&hash) {
            if !prompt.read {
                prompt.row.turn = self.turn;
            }
            prompt.read = true;
            debug_assert!(!prompt.row.field("state", "sent"));
            prompt.row.fields.insert("steer".into(), "true".into());
            out.row(&prompt.row);
            // A v1 read can precede both queued and echo. It has no body to settle yet.
            if prompt.has_body {
                self.settle_prompt(hash, false, out);
            }
        }
        Ok(())
    }
    fn prompt(&mut self, event: PromptEvent<'_>, out: &mut input::Output<'_>) -> Result<(), Error> {
        let PromptEvent { key, prompt_key, steer, notice, body, images } = event;
        bounded(key)?;
        bounded(prompt_key)?;
        let hash = prompt_hash(prompt_key);
        // An echo after a queued/read pair carries no new body or placement.
        if steer && self.settled_prompts.contains(&hash) {
            return Ok(());
        }
        // A repeated raw v1 sequence is dropped before prompt(); a new event
        // reusing an old prompt id is a replayed prompt and still starts a new
        // turn, otherwise its rows would attach to the preceding turn.
        if !steer && !prompt_key.is_empty() && self.settled_prompts.contains(&hash) {
            self.replayed_prompts = self.replayed_prompts.saturating_add(1);
        }
        let already_read = self.prompts.get(&hash).is_some_and(|p| p.read);
        let steer = steer || already_read;
        if !steer {
            self.queue_remove(prompt_key, out);
        }
        if steer {
            if !already_read {
                self.mark_steer();
            }
        } else {
            self.finish(out);
            self.finish_steers(Some(hash), out);
        }
        let prior = self.prompts.remove(&hash);
        let mut row = if let Some(p) = prior { p.row } else { self.row(RowKind::User, out)? };
        debug_assert!(!row.field("state", "sent"));
        if notice {
            row.fields.insert("notice".into(), "true".into());
        }
        if steer {
            if !already_read {
                row.turn = self.turn;
            }
            row.fields.insert("steer".into(), "true".into());
            self.fold.extra(row.id);
        } else {
            row.fields.insert("steer".into(), "false".into());
            self.turn = Some(row.id);
            self.turn_key = key.into();
            self.turn_start_ms = self.at_ms;
            row.turn = self.turn;
        }
        out.row(&row);
        if let Some(body) = body {
            out.body(row.id, BodyField::Content, false, body);
        }
        if let Some(images) = images {
            out.body(row.id, BodyField::Images, false, images);
        }
        if steer && !already_read && !prompt_key.is_empty() {
            if self.prompts.len() == 32
                && let Some(old) =
                    self.prompts.iter().min_by_key(|(_, p)| p.row.id).map(|(hash, _)| *hash)
            {
                self.settle_prompt(old, false, out);
                self.forced_steers = self.forced_steers.saturating_add(1);
            }
            self.prompts.insert(hash, Prompt { row, has_body: body.is_some(), read: false });
        } else {
            row.open = false;
            out.row(&row);
            if !prompt_key.is_empty() && body.is_some() {
                self.settled_prompt(hash);
            }
        }
        if !steer {
            self.group(out)?;
        }
        Ok(())
    }
    fn text(
        &mut self,
        text: &str,
        key: &str,
        message: &str,
        thinking: bool,
        out: &mut input::Output<'_>,
    ) -> Result<(), Error> {
        if text.is_empty() {
            return Ok(());
        }
        bounded(key)?;
        bounded(message)?;
        let mut slot = if thinking { self.thought.take() } else { self.reply.take() };
        if slot.as_ref().is_some_and(|s| s.key != key) {
            if !thinking
                && !message.is_empty()
                && slot.as_ref().is_some_and(|s| s.message == message)
            {
                if let Some(stream) = &mut slot {
                    if stream.row.open {
                        stream.row.open = false;
                        out.row(&stream.row);
                    }
                    stream.key = key.into();
                }
            } else {
                if !thinking && let Some(reply) = &slot {
                    self.fold.reply(&reply.facts);
                }
                Self::close_stream(&mut slot, out);
            }
        }
        let mut stream = if let Some(s) = slot {
            s
        } else {
            let group = self.group.as_ref().map(|g| g.id);
            let mut row =
                self.row(if thinking { RowKind::Thinking } else { RowKind::Text }, out)?;
            row.group = group;
            debug_assert!(!row.field("messageId", key));
            out.row(&row);
            row.fields.clear();
            let mut facts = fold::Reply::default();
            facts.row(row.id);
            Stream {
                key: key.into(),
                message: message.into(),
                row,
                block: blocks::Block::default(),
                facts,
                deferred_cut: false,
                plain_next: false,
            }
        };
        let mut start = 0;
        for (offset, ch) in text.char_indices() {
            if stream.deferred_cut {
                stream.deferred_cut = false;
                self.continue_text(&mut stream, false, true, out)?;
            } else if !stream.row.open {
                let inside_line = stream.block.line_bytes() != 0;
                let continuation = !stream.plain_next;
                stream.plain_next = false;
                self.continue_text(&mut stream, inside_line, continuation, out)?;
            }
            // A single line cannot retain a body in the checkpoint or wait forever
            // for a newline. Split before this character if UTF-8 would cross 16 KiB.
            if stream.row.id == self.last_id
                && stream.block.line_bytes().saturating_add(ch.len_utf8() as u64) > 16 * 1024
            {
                if start < offset {
                    self.emit_text_slice(out, stream.row.id, text, start, offset);
                }
                start = offset;
                self.continue_text(&mut stream, true, true, out)?;
            }
            let boundary = stream.block.push(ch);
            // BeforeLine is decided by this line's first byte, never lookahead.
            // No byte has been appended to the old row when this cut is made.
            if stream.row.id == self.last_id
                && stream.row.bytes >= 8 * 1024
                && boundary == blocks::Event::BeforeLine
            {
                if start < offset {
                    self.emit_text_slice(out, stream.row.id, text, start, offset);
                }
                start = offset;
                self.continue_text(&mut stream, false, true, out)?;
            }
            stream.row.bytes = stream.row.bytes.saturating_add(ch.len_utf8() as u64);
            stream.facts.push(ch);
            if ch == '\n' {
                stream.row.lines = stream.row.lines.saturating_add(1);
            }
            let end = offset.saturating_add(ch.len_utf8());
            let cut = stream.row.id == self.last_id
                && ((ch == '\n' && stream.row.bytes >= 16 * 1024)
                    || stream.block.line_bytes() >= 16 * 1024);
            // Each inline body operation is bounded even when a newer row prevents cutting.
            if cut || end.saturating_sub(start) >= 16 * 1024 - 4 {
                self.emit_text_slice(out, stream.row.id, text, start, end);
                start = end;
            }
            if cut {
                if ch != '\n' || end < text.len() {
                    self.continue_text(&mut stream, ch != '\n', true, out)?;
                } else {
                    // Start the continuation when the next event supplies a byte;
                    // never emit an empty row at the end of this event.
                    stream.deferred_cut = true;
                }
            }
        }
        if start < text.len() {
            self.emit_text_slice(out, stream.row.id, text, start, text.len());
        }
        if thinking {
            self.thought = Some(stream);
        } else {
            self.reply = Some(stream);
        };
        Ok(())
    }
    fn emit_text_slice(
        &mut self,
        out: &mut input::Output<'_>,
        id: u64,
        text: &str,
        start: usize,
        end: usize,
    ) {
        let piece = match text.get(start..end) {
            Some(piece) => piece,
            None => {
                self.line_errors = self.line_errors.saturating_add(1);
                ""
            }
        };
        out.text(id, piece, start);
    }
    fn continue_text(
        &mut self,
        stream: &mut Stream,
        inside_line: bool,
        continuation: bool,
        out: &mut input::Output<'_>,
    ) -> Result<(), Error> {
        if stream.row.open {
            stream.row.open = false;
            out.row(&stream.row);
        }
        let mut row = self.row(stream.row.kind, out)?;
        row.turn = stream.row.turn;
        row.group = stream.row.group;
        if continuation {
            row.fields.insert("cont".into(), "true".into());
        } else {
            stream.block = blocks::Block::default();
        }
        if continuation && inside_line {
            stream.block.mark_cut_inside_line();
        }
        if stream.block.take_cut_inside_line() {
            row.fields.insert("insideLine".into(), "true".into());
        }
        if let Some(marker) = stream.block.fence_marker() {
            debug_assert!(!row.field("fence", &marker));
        }
        debug_assert!(!row.field("messageId", &stream.message));
        out.row(&row);
        row.fields.clear();
        stream.row = row;
        stream.facts.row(stream.row.id);
        Ok(())
    }
    fn bound_open_rows(&mut self, out: &mut input::Output<'_>) {
        self.bound_counted_rows(64, out);
    }
    fn bound_counted_rows(&mut self, limit: usize, out: &mut input::Output<'_>) {
        loop {
            let mut ids: Vec<_> = self
                .open_rows()
                .filter(|r| matches!(r.kind, RowKind::Tool | RowKind::Sub))
                .map(|r| r.id)
                .collect();
            if ids.len() <= limit {
                break;
            }
            ids.sort_unstable();
            let Some(id) = ids.first().copied() else {
                break;
            };
            if self.reply.as_ref().is_some_and(|s| s.row.id == id) {
                if let Some(reply) = &mut self.reply {
                    reply.row.open = false;
                    out.row(&reply.row);
                }
            } else if self.thought.as_ref().is_some_and(|s| s.row.id == id) {
                if let Some(thought) = &mut self.thought {
                    thought.row.open = false;
                    out.row(&thought.row);
                }
            } else if self.plan.as_ref().is_some_and(|r| r.id == id) {
                Self::close_row(&mut self.plan, out);
            } else if self.compaction.as_ref().is_some_and(|r| r.id == id) {
                Self::close_row(&mut self.compaction, out);
            } else {
                let key =
                    self.tools.iter().find(|(_, r)| r.id == id).map(|(k, _)| k.clone()).or_else(
                        || self.subs.iter().find(|(_, r)| r.id == id).map(|(k, _)| k.clone()),
                    );
                if let Some(key) = key {
                    let mut row = self.tools.remove(&key).or_else(|| self.subs.remove(&key));
                    if let Some(mut row) = row.take() {
                        row.open = false;
                        self.remember_forced(&key, row.id);
                        out.row(&row);
                    }
                }
            }
            self.forced_rows = self.forced_rows.saturating_add(1);
        }
    }
    fn remember_forced(&mut self, key: &str, row_id: u64) {
        let hash = prompt_hash(key);
        if let Some(pos) = self.forced_order.iter().position(|h| *h == hash) {
            self.forced_order.remove(pos);
        }
        if self.forced_order.len() == 64 {
            let old = self.forced_order.remove(0);
            self.forced_tools.remove(&old);
        }
        self.forced_order.push(hash);
        self.forced_tools.insert(hash, row_id);
    }
    fn end_session(&mut self, out: &mut input::Output<'_>) {
        for rows in [&mut self.tools, &mut self.subs] {
            for (_, mut row) in std::mem::take(rows) {
                row.open = false;
                row.fields.insert("status".into(), "\"stopped\"".into());
                out.row(&row);
            }
        }
        if let Some(group) = &mut self.group {
            group.fields.insert("status".into(), "\"stopped\"".into());
        }
        self.finish(out);
        let keys: Vec<_> = self.prompts.keys().copied().collect();
        for key in keys {
            self.settle_prompt(key, false, out);
        }
    }
    fn sub(&mut self, key: &str, status: &str, out: &mut input::Output<'_>) -> Result<(), Error> {
        bounded(key)?;
        if key.is_empty() {
            return Ok(());
        }
        if !self.subs.contains_key(key) && self.forced_tools.contains_key(&prompt_hash(key)) {
            self.dropped_tool_updates = self.dropped_tool_updates.saturating_add(1);
            return Ok(());
        }
        if !self.subs.contains_key(key)
            && matches!(status, "completed" | "failed" | "cancelled" | "stopped")
        {
            self.dropped_tool_updates = self.dropped_tool_updates.saturating_add(1);
            return Ok(());
        }
        let mut row = if let Some(row) = self.subs.remove(key) {
            row
        } else {
            // Background rows after a settled turn live outside that group.
            let mut row = self.row(RowKind::Sub, out)?;
            debug_assert!(!row.field("book", key));
            row
        };
        if !status.is_empty() && row.field("status", status) {
            self.cut_fields = self.cut_fields.saturating_add(1);
        }
        row.open = !matches!(status, "completed" | "failed" | "cancelled" | "stopped");
        out.row(&row);
        if row.open {
            row.fields.clear();
            self.subs.insert(key.into(), row);
        }
        Ok(())
    }
    fn tool(
        &mut self,
        key: &str,
        metadata: &[(&str, &str)],
        parts: &[(BodyField, bool, &serde_json::value::RawValue)],
        ended: bool,
        starts: bool,
        out: &mut input::Output<'_>,
    ) -> Result<(), Error> {
        bounded(key)?;
        if starts {
            // A tool call is a work boundary: the currently streaming reply
            // settles above the call and remains the candidate before it.
            self.close_reply_for_work(out);
        }
        if !starts && !self.tools.contains_key(key) {
            self.dropped_tool_updates = self.dropped_tool_updates.saturating_add(1);
            return Ok(());
        }
        if !self.tools.contains_key(key) {
            self.fold.work();
        }
        let mut row = if let Some(row) = self.tools.remove(key) {
            row
        } else {
            let mut row = self.row(RowKind::Tool, out)?;
            row.group = self.group.as_ref().map(|g| g.id);
            debug_assert!(!row.field("callId", key));
            if let Some(group) = &mut self.group {
                let n = group.fields.get("calls").and_then(|s| s.parse::<u64>().ok()).unwrap_or(0);
                group.fields.insert("calls".into(), n.saturating_add(1).to_string());
                out.row(group);
            }
            row
        };
        for (key, value) in metadata {
            if row.field(key, value) {
                self.cut_fields = self.cut_fields.saturating_add(1);
            }
        }
        out.row(&row);
        for (field, append, raw) in parts {
            out.body(row.id, *field, *append, raw);
        }
        if ended {
            row.open = false;
            out.row(&row);
        } else {
            row.fields.clear();
            self.tools.insert(key.into(), row);
        }
        Ok(())
    }
}
