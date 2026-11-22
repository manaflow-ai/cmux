//! Deterministic harness lines to book operations. The actor owns bodies and raw files.
//! Restore the entire checkpoint before replay; never restore only the row counter.
mod asks;
#[cfg(test)]
mod asks_tests;
#[cfg(all(test, target_os = "linux"))]
mod bench;
mod blocks;
mod cards;
#[cfg(test)]
mod cards_tests;
mod checkpoint;
pub use checkpoint::Saved;
mod claude;
mod codex;
mod fold;
mod input;
mod kinds;
#[cfg(test)]
mod kinds_tests;
mod narration;
#[cfg(test)]
mod tests;
mod user;
#[cfg(test)]
mod user_tests;
mod v1;

use crate::row::{Phase, Row, RowKind};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Version 11 writes each row's phase (entering, live, settled, leaving) and takes rows back by
/// the leave op; version 10 wrote the card rows, patched by their later records (decisions 253, 254); version
/// 9 wrote what a user row says of its prompt and its sender, the ask rows and their decisions,
/// and a turn end a prompt sent now went on under (decisions 231, 235, 236). A book of any other
/// version rebuilds from raw.
pub const VERSION: u32 = 11;
/// The translator's segment and the queue's records together.
pub const MAX_STATE_BYTES: usize = MAX_TRANSLATOR_BYTES + 32 * MAX_QUEUE_ENTRIES;
/// Every held state at its cap at once, with room left for the live turn: held steers 12 KB, asks
/// 8 KB, held claims 4 KB, the continued notice and the cards (6 KB) came to about 34 KB, past the
/// 32 KB this was before cards (`every_held_state_full_at_once_fits_the_translators_segment`).
/// 40 KB leaves about 6 KB for the live turn and still fits the book checkpoint's 64 KB state with
/// every other part at its bound (`production_caps_fit_separate_checkpoint_budgets_and_roundtrip`).
/// The book's checkpoint reads this bound too, so the two cannot drift.
pub const MAX_TRANSLATOR_BYTES: usize = 40 * 1024;
const MAX_QUEUE_ENTRIES: usize = crate::checkpoint::MAX_PROMPTS;
const MAX_KEY_BYTES: usize = 256;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Harness {
    V1,
    Claude,
    Codex,
}

/// The stable identity a followed native transcript gives a prompt. The actor uses the text for
/// bounded act/echo matching and keeps the native id for diagnostics and correlation. This is a
/// parser result only: it does not reserve a row or mutate translator state.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PromptIdentity {
    pub id: String,
    pub text: String,
}

/// Extract a followed transcript's prompt identity without translating it. A host stream has no
/// native transcript identity, so callers must use its own protocol's prompt fields.
pub fn prompt_identity(harness: Harness, bytes: &[u8]) -> Result<Option<PromptIdentity>, Error> {
    match harness {
        Harness::V1 => Ok(None),
        Harness::Claude => claude::prompt_identity(bytes),
        Harness::Codex => Ok(None),
    }
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
    /// A row taken back: a reply the harness superseded, a prompt that never ran. Its body
    /// becomes `{"hidden":true}`, its estimate zero and its phase `leaving`; its id and place stay.
    /// At rev 1 the row was open and settles so; past 1 it had settled and is patched. The page
    /// plays the row's exit from this one op, never from a diff of two windows.
    Leave(OwnedRow),
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
    InlineParts,
    Pasted,
    /// An ask's request, raw (decision 245).
    Request,
    /// An ask's decision's outcome, raw.
    Outcome,
    /// A card's records: each listed line's `msg`, in order (decision 254).
    Records,
    /// A card's field read again from one logged line: its body key, from the kind table.
    Card(&'static str),
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
    /// A card's records, read again from the raw log at each write: a JSON array of each
    /// line's `msg`, in order. A line that no longer reads is left out, and the row says how
    /// many it lacks (`lacks`). The actor resolves this source.
    Records(Vec<RawLine>),
    /// One value of one logged line, `msg.<key>`, read again at each write; a string is cut at
    /// `cap` bytes on a character with [`cut`], as the translator cut it when it first read the
    /// line (and counted the cut then). `key` and `cap` come from the kind table, never from a
    /// record. Left out, and counted in `lacks`, when the line no longer reads.
    RawField {
        place: u64,
        span: u64,
        key: &'static str,
        cap: usize,
    },
}
/// A logged line by its place and span, as the actor reads it again.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RawLine {
    pub place: u64,
    pub span: u64,
}

/// A durable queue mutation. Add is an idempotent upsert: a repeated queued line does
/// not duplicate an entry, while a hold/release may change its packed state.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum QueueChange {
    Add(QueueEntry),
    Remove(u64),
    /// The entries' order changed (`queue_order`); no entry did.
    Order,
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

/// Apply one followed-chat action after its raw line is durable. The action
/// line's raw `place` and `span` become the queue entry's source coordinates;
/// the translator remains the sole owner of queue state.
#[derive(Deserialize)]
struct ActBody {
    #[serde(rename = "promptId")]
    prompt_id: String,
    #[serde(default)]
    at: u64,
    #[serde(default)]
    held: bool,
    #[serde(rename = "textLen", default)]
    text_len: u64,
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
    /// Born on the line the translator read last: an open row reads `entering` until the next
    /// line begins, then `live` ([`OwnedRow::phase`]).
    pub entering: bool,
    pub bytes: u64,
    pub lines: u64,
    pub fields: BTreeMap<String, String>,
}
impl OwnedRow {
    /// Where the row is in its life, from its own state only, so a replay writes the same text:
    /// a row taken back ([`Change::Leave`], its body `{"hidden":true}`) is leaving, a closed row
    /// settled, an open one entering on the line that bore it and live after.
    pub fn phase(&self) -> Phase {
        if !self.open {
            if self.hidden() { Phase::Leaving } else { Phase::Settled }
        } else if self.entering {
            Phase::Entering
        } else {
            Phase::Live
        }
    }
    fn hidden(&self) -> bool {
        self.fields.get("hidden").is_some_and(|s| s == "true")
    }
    pub fn as_row<'a>(&self, body: &'a str) -> Row<'a> {
        Row {
            id: self.id,
            rev: self.rev,
            kind: self.kind,
            turn: self.turn,
            group: self.group,
            at: self.at,
            open: self.open,
            phase: self.phase(),
            body,
            est: if self.hidden() {
                0
            } else {
                u32::try_from(self.lines.max(1)).unwrap_or(u32::MAX)
            },
        }
    }
    fn field(&mut self, key: &str, value: &str) -> bool {
        self.field_capped(key, value, MAX_KEY_BYTES)
    }
    /// A string field cut at `cap` bytes, on a character; true when it was cut.
    fn field_capped(&mut self, key: &str, value: &str, cap: usize) -> bool {
        self.fields.insert(
            key.into(),
            serde_json::to_string(cut(value, cap)).unwrap_or_else(|_| "\"\"".into()),
        );
        value.len() > cap
    }
}
/// Whether a user row may carry a `sentFrom`: a typed prompt, or another agent's message.
fn takes_claim(row: &OwnedRow) -> bool {
    row.fields.get("incoming").is_none_or(|incoming| incoming.starts_with("{\"kind\":\"message\""))
}
/// The bytes a row's fields hold.
fn fields_bytes(row: &OwnedRow) -> usize {
    row.fields.iter().map(|(k, v)| k.len().saturating_add(v.len())).fold(0, usize::saturating_add)
}
/// A string as a compact JSON value.
fn json_string(value: &str) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "\"\"".into())
}
/// At most `cap` bytes of `value`, cut on a character. The actor cuts a card's raw fields with
/// it too, so a field reads the same at every write.
pub fn cut(value: &str, cap: usize) -> &str {
    let mut end = value.len().min(cap);
    while !value.is_char_boundary(end) {
        end = end.saturating_sub(1);
    }
    value.get(..end).unwrap_or_default()
}

/// Parse RFC3339 seconds independently of the local timezone. Fractional seconds are ignored;
/// an absent or malformed timestamp leaves the checkpoint time unchanged.
fn timestamp(s: &str) -> Option<u64> {
    let n = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
    let y = n(0..4)?;
    let m = n(5..7)?;
    let d = n(8..10)?;
    let h = n(11..13)?;
    let min = n(14..16)?;
    let sec = n(17..19)?;
    if s.get(4..5)? != "-"
        || s.get(7..8)? != "-"
        || !matches!(s.get(10..11)?, "T" | "t")
        || s.get(13..14)? != ":"
        || s.get(16..17)? != ":"
        || !(1..=12).contains(&m)
        || !(1..=31).contains(&d)
        || !(0..=23).contains(&h)
        || !(0..=59).contains(&min)
        || !(0..=59).contains(&sec)
    {
        return None;
    }
    let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
    let month_days = [31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let month_days = *month_days.get(usize::try_from(m - 1).ok()?)?;
    if d > month_days {
        return None;
    }
    let y = y.checked_sub(i64::from(m <= 2))?;
    let era = y.div_euclid(400);
    let yo = y.checked_sub(era.checked_mul(400)?)?;
    let mp = m.checked_add(if m > 2 { -3 } else { 9 })?;
    let doy = (153i64.checked_mul(mp)?.checked_add(2)? / 5).checked_add(d)?.checked_sub(1)?;
    let doe = yo.checked_mul(365)?.checked_add(yo / 4)?.checked_sub(yo / 100)?.checked_add(doy)?;
    let days = era.checked_mul(146097)?.checked_add(doe)?.checked_sub(719468)?;
    let tail = s.get(19..)?;
    let zone = if let Some(frac) = tail.strip_prefix('.') {
        let pos = frac.find(|c: char| !c.is_ascii_digit())?;
        if pos == 0 {
            return None;
        }
        frac.get(pos..)?
    } else {
        tail
    };
    let offset = if matches!(zone, "Z" | "z") {
        0
    } else {
        if zone.len() != 6 || zone.get(3..4)? != ":" {
            return None;
        }
        let zh = zone.get(1..3)?.parse::<i64>().ok()?;
        let zm = zone.get(4..6)?.parse::<i64>().ok()?;
        if zh > 23 || zm > 59 {
            return None;
        }
        let v = zh.checked_mul(3600)?.checked_add(zm.checked_mul(60)?)?;
        match zone.get(..1)? {
            "+" => v,
            "-" => v.checked_neg()?,
            _ => return None,
        }
    };
    u64::try_from(
        days.checked_mul(86400)?
            .checked_add(h.checked_mul(3600)?)?
            .checked_add(min.checked_mul(60)?)?
            .checked_add(sec)?
            .checked_sub(offset)?,
    )
    .ok()
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
    /// Who sent it and how (`user::sender`).
    sender: user::Sender,
    inline_parts: Option<&'a serde_json::value::RawValue>,
    pasted: Option<&'a serde_json::value::RawValue>,
    /// Its record's line, which a later patch reads its bodies from again.
    place: u64,
    span: u64,
}
/// A settled user row a `sender_claim` may still name: the hub writes the claim once the prompt is
/// accepted, which for a prompt that starts at once is after its `user_message`. A patch replaces
/// the row's whole body, so the patch reads its bodies from the record's line again.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Claimable {
    prompt: u64,
    row: OwnedRow,
    place: u64,
    span: u64,
    bodies: Vec<u8>,
}
/// The most claims held for prompts not yet echoed (a queued prompt's claim comes when it is kept).
const MAX_HELD_CLAIMS: usize = 16;
/// The most bytes the held claims keep; past it the oldest goes, counted.
const MAX_HELD_CLAIM_BYTES: usize = 4 * 1024;
/// The most bytes of fields the waiting steers hold; past it the oldest settles, as past 32 rows.
const MAX_HELD_STEER_BYTES: usize = 12 * 1024;
/// A body field a claim's patch reads again, by its index in the record's line.
const CLAIM_BODIES: [BodyField; 4] =
    [BodyField::Content, BodyField::Images, BodyField::InlineParts, BodyField::Pasted];
/// The key a waiting prompt's id is kept by in the queue.
pub fn prompt_hash(key: &str) -> u64 {
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
    /// The waiting prompts in v1's order: the order its restore gives them, which runs them
    /// first to last, skipping held ones. Its records are a checkpoint's prompt section.
    #[serde(skip)]
    queue: Vec<QueueEntry>,
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
    /// A Claude turn's tokens so far, its calls counted once by message id.
    claude: ClaudeTurn,
    /// Kinds in none of the tables (`kinds.rs`), by name: 32 names, then `other`.
    #[serde(skip)]
    unknown_kinds: BTreeMap<String, u64>,
    #[serde(skip)]
    unknown_records: u64,
    /// A prompt sent now into the running turn (`queue_order` with `next`), before any Stop: the
    /// turn's end goes on under it (decision 236).
    interrupting: Option<u64>,
    /// The turn end that went on under a prompt sent now, until that prompt runs or never will.
    continued: Option<Continued>,
    /// A Stop the hub took for the running turn (`stopping`): its end is the Stop's.
    stopping: bool,
    /// Sender claims of prompts not echoed yet, by prompt hash, oldest first.
    claims: Vec<(u64, String)>,
    /// The newest settled user row, which its claim may still patch.
    claimable: Option<Claimable>,
    /// Claims that named no prompt this book holds or will hold (a steer settled before it).
    #[serde(skip)]
    unplaced_claims: u64,
    /// The asks open now, by the hash of their kind and id (`asks.rs`).
    asks: BTreeMap<u64, asks::Ask>,
    /// Asks the bound settled undecided.
    #[serde(skip)]
    forced_asks: u64,
    /// Decisions that named no open ask: one the bound settled, or one this book never saw asked.
    #[serde(skip)]
    unplaced_decisions: u64,
    /// The cards open now, oldest first (`cards.rs`, decision 254).
    cards: Vec<cards::Card>,
    /// Card records whose card is not among the keys: each wrote a notice row of its own.
    #[serde(skip)]
    orphan_records: u64,
    /// Card records their one-record parser refuses: no row.
    #[serde(skip)]
    refused_records: u64,
    /// Cards a cap or the byte budget let go, and offers past a card's list.
    #[serde(skip)]
    evicted_cards: u64,
}
/// A turn-end notice that says `continued`, held whole: a patch replaces a settled row's body, so
/// taking the mark back sends the notice again without it. Its fields are capped (the error at
/// 4 KB), and one is held at a time.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Continued {
    prompt: u64,
    notice: OwnedRow,
}
/// A turn's token split, as the view's `TurnTokenSplit` names it. `context` and `calls` are
/// absent when zero.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
struct Tokens {
    output: u64,
    input: u64,
    cache_read: u64,
    cache_write: u64,
    context: u64,
    calls: u64,
}
impl Tokens {
    /// None for a turn that spent nothing, which the view does not draw.
    fn json(self) -> Option<String> {
        use std::fmt::Write;
        if [self.output, self.input, self.cache_read, self.cache_write].iter().all(|n| *n == 0) {
            return None;
        }
        let mut out = format!(
            r#"{{"output":{},"input":{},"cacheRead":{},"cacheWrite":{}"#,
            self.output, self.input, self.cache_read, self.cache_write
        );
        if self.context > 0 {
            let _ = write!(out, r#","context":{}"#, self.context);
        }
        if self.calls > 0 {
            let _ = write!(out, r#","calls":{}"#, self.calls);
        }
        out.push('}');
        Some(out)
    }
    fn add(self, other: Self) -> Self {
        Self {
            output: self.output.saturating_add(other.output),
            input: self.input.saturating_add(other.input),
            cache_read: self.cache_read.saturating_add(other.cache_read),
            cache_write: self.cache_write.saturating_add(other.cache_write),
            context: other.context,
            calls: self.calls.saturating_add(other.calls),
        }
    }
}
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
struct ClaudeTurn {
    /// The calls before the one streaming now.
    sum: Tokens,
    /// The newest call's usage: each of its lines repeats it, the last one whole.
    call: Tokens,
    message: String,
}
const MAX_UNKNOWN_KINDS: usize = 32;
const UNKNOWN_OTHER: &str = "other";
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
        Harness::Codex => codex::validate(bytes),
    };
    if valid.is_err() {
        state.invalid_records = state.invalid_records.saturating_add(1);
        return Ok(Vec::new());
    }
    // A row born on the line before has been offered as entering: from a line that changes
    // anything on, it is live. A line that changes nothing (a duplicate) leaves it entering.
    let went_live = state.rows_went_live();
    let result = match harness {
        Harness::V1 => v1::line(state, place, span, bytes, &mut out),
        Harness::Claude => claude::line(state, bytes, &mut out),
        Harness::Codex => codex::line(state, bytes, &mut out),
    };
    debug_assert!(result.is_ok(), "validated harness line failed during apply");
    if result.is_err() {
        state.line_errors = state.line_errors.saturating_add(1);
        state.rows_entering(&went_live);
        return Ok(Vec::new());
    }
    state.bound_open_rows(&mut out);
    if out.ops.is_empty() {
        state.rows_entering(&went_live);
    }
    // The queue is counted apart from the translator's 32 KiB segment: its records go to the
    // book's prompt section.
    Ok(out.ops)
}

impl State {
    /// Whether an action prompt can be admitted before its raw line is written.
    pub fn act_queue_full(&self) -> bool {
        self.queue_len() >= MAX_QUEUE_ENTRIES
    }

    pub fn validate_act(&self, bytes: &[u8]) -> Result<(), Error> {
        #[derive(Deserialize)]
        struct Act<'a> {
            op: &'a str,
            body: ActBody,
        }
        let action: Act<'_> = serde_json::from_slice(bytes).map_err(|_| Error::InvalidJson)?;
        if !matches!(action.op, "prompt" | "retract") {
            return Err(Error::InvalidRecord("unknown act operation"));
        }
        if action.body.prompt_id.is_empty() {
            return Err(Error::InvalidRecord("act promptId"));
        }
        Ok(())
    }

    /// Apply a durable `k:"act"` line into the translator's queue. Only
    /// `prompt` and `retract` are action transitions in this row. For a
    /// followed chat, `place` and `span` are offsets in `raw/acts.ndjson`;
    /// the actor gives that file to queue readers as their `RawSource`.
    pub fn apply_act(&mut self, bytes: &[u8], place: u64, span: u64) -> Result<Vec<Op>, Error> {
        let mut out = input::Output::new(bytes);
        #[derive(Deserialize)]
        struct Act<'a> {
            op: &'a str,
            body: ActBody,
        }
        let action: Act<'_> = serde_json::from_slice(bytes).map_err(|_| Error::InvalidJson)?;
        match action.op {
            "prompt" => {
                if self.act_queue_full() {
                    self.queue_overflowed = self.queue_overflowed.saturating_add(1);
                    return Ok(out.ops);
                }
                self.queue_add(
                    &action.body.prompt_id,
                    action.body.at,
                    action.body.held,
                    place,
                    span,
                    action.body.text_len,
                    &mut out,
                );
            }
            "retract" => self.queue_remove(&action.body.prompt_id, &mut out),
            _ => return Err(Error::InvalidRecord("unknown act operation")),
        }
        Ok(out.ops)
    }
}
fn bounded(s: &str) -> Result<(), Error> {
    if s.len() > MAX_KEY_BYTES {
        Err(Error::InvalidRecord("identity or metadata exceeds 256 bytes"))
    } else {
        Ok(())
    }
}
/// Explicit lossy-cap/late-identity outcomes, for the actor's counters.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Counters {
    /// Kinds the translator has no line for, by name (`kinds.rs`); zero over every known log.
    pub unknown_kinds: BTreeMap<String, u64>,
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
    /// Sender claims no user row took (`sender_claim` after its steer settled, or past 16 held).
    pub unplaced_claims: u64,
    /// Asks the bound of 32 open settled undecided.
    pub forced_asks: u64,
    /// Decisions that named no open ask.
    pub unplaced_decisions: u64,
    /// Card records whose card had left the keys or never opened; each is a notice row.
    pub orphan_records: u64,
    /// Card records their one-record parser refuses.
    pub refused_records: u64,
    /// Cards let go past a cap or the byte budget.
    pub evicted_cards: u64,
}
impl State {
    /// Whether raw is currently inside a turn, independent of its open body rows.
    /// `turn` outlives the turn so late background rows keep its id; the key ends with it.
    pub fn in_turn(&self) -> bool {
        !self.turn_key.is_empty()
    }

    pub fn counters(&self) -> Counters {
        Counters {
            unknown_kinds: self.unknown_kinds.clone(),
            unplaced_claims: self.unplaced_claims,
            forced_asks: self.forced_asks,
            unplaced_decisions: self.unplaced_decisions,
            orphan_records: self.orphan_records,
            refused_records: self.refused_records,
            evicted_cards: self.evicted_cards,
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
    /// The waiting prompts, by id hash. A checkpoint keeps them as [`Saved::prompts`].
    pub fn queue(&self) -> impl Iterator<Item = &QueueEntry> {
        self.queue.iter()
    }
    pub fn queued(&self, id_hash: u64) -> Option<QueueEntry> {
        self.queue.iter().find(|entry| entry.id_hash == id_hash).copied()
    }
    fn queue_slot(&self, id_hash: u64) -> Option<usize> {
        self.queue.iter().position(|entry| entry.id_hash == id_hash)
    }
    pub fn queue_len(&self) -> usize {
        self.queue.len()
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
            .chain(self.asks.values().map(|ask| &ask.row))
    }
    /// Every open row the translator holds, to change in place.
    fn stored_rows_mut(&mut self) -> impl Iterator<Item = &mut OwnedRow> {
        self.reply
            .iter_mut()
            .map(|s| &mut s.row)
            .chain(self.thought.iter_mut().map(|s| &mut s.row))
            .chain(self.tools.values_mut())
            .chain(self.subs.values_mut())
            .chain(self.group.iter_mut())
            .chain(self.plan.iter_mut())
            .chain(self.compaction.iter_mut())
            .chain(self.prompts.values_mut().map(|p| &mut p.row))
            .chain(self.asks.values_mut().map(|ask| &mut ask.row))
    }
    /// The rows born on the last line are entering no more. Costs the open rows the translator
    /// holds, which its bounds keep under about 200.
    fn rows_went_live(&mut self) -> Vec<u64> {
        let mut went = Vec::new();
        for row in self.stored_rows_mut().filter(|row| row.entering) {
            row.entering = false;
            went.push(row.id);
        }
        went
    }
    /// The rows `ids` are entering again: the line that made them live changed nothing.
    fn rows_entering(&mut self, ids: &[u64]) {
        if ids.is_empty() {
            return;
        }
        for row in self.stored_rows_mut().filter(|row| ids.contains(&row.id)) {
            row.entering = true;
        }
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
            entering: true,
            bytes: 0,
            lines: 0,
            fields: BTreeMap::new(),
        })
    }
    #[allow(
        clippy::too_many_arguments,
        reason = "queue entry fields mirror the fixed raw record layout"
    )]
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
        if self.settled_prompts.contains(&hash)
            || self.prompts.get(&hash).is_some_and(|prompt| prompt.read)
        {
            return;
        }
        let entry = QueueEntry::new(hash, at_ms, held, place, span, text_len);
        // A `queued` goes to the end, as v1's restore reads it; one queued again (a requeue
        // after a failed turn) leaves its old place. The same record read again changes nothing.
        if let Some(slot) = self.queue_slot(hash) {
            if self.queue.get(slot).is_some_and(|old| old.place == place && old.span == entry.span)
            {
                return;
            }
            self.queue.remove(slot);
        } else if self.queue.len() >= MAX_QUEUE_ENTRIES {
            self.queue_overflowed = self.queue_overflowed.saturating_add(1);
            return;
        }
        self.queue.push(entry);
        out.emit(Change::Queue(QueueChange::Add(entry)));
    }
    /// `queue_order`: the entries `order` names first, in its order; the others after them in
    /// the order they had. An id that does not wait, or is not a string, is skipped. One pass
    /// over the queue and one over `order`; nothing moves unless the whole list was read.
    fn queue_order(
        &mut self,
        order: Option<&serde_json::value::RawValue>,
        out: &mut input::Output<'_>,
    ) {
        let Some(order) = order else { return };
        let slots: std::collections::HashMap<u64, usize> =
            self.queue.iter().enumerate().map(|(slot, entry)| (entry.id_hash, slot)).collect();
        let mut taken = vec![false; self.queue.len()];
        let mut placed: Vec<QueueEntry> = Vec::with_capacity(self.queue.len());
        let listed = input::each(order, |id| {
            if let Ok(id) = input::text(id)
                && let Some(&slot) = slots.get(&prompt_hash(&id))
                && let Some(seen) = taken.get_mut(slot)
                && !*seen
                && let Some(entry) = self.queue.get(slot)
            {
                *seen = true;
                placed.push(*entry);
            }
            Ok(())
        });
        if listed.is_err() || placed.is_empty() {
            return;
        }
        for (entry, seen) in self.queue.iter().zip(&taken) {
            if !*seen {
                placed.push(*entry);
            }
        }
        if placed != self.queue {
            self.queue = placed;
            out.emit(Change::Queue(QueueChange::Order));
        }
    }
    /// Sent now (`queue_order` with `next`): no longer held.
    fn queue_release(&mut self, id: &str, out: &mut input::Output<'_>) {
        let Some(slot) = self.queue_slot(prompt_hash(id)) else { return };
        if let Some(entry) = self.queue.get_mut(slot)
            && entry.held()
        {
            *entry = entry.with_held(false);
            out.emit(Change::Queue(QueueChange::Add(*entry)));
        }
    }
    fn queue_remove(&mut self, id: &str, out: &mut input::Output<'_>) {
        if id.is_empty() {
            return;
        }
        let hash = prompt_hash(id);
        if let Some(slot) = self.queue_slot(hash) {
            self.queue.remove(slot);
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
            if let Some(entry) = self.queue.iter_mut().find(|entry| entry.id_hash == hash) {
                let next = entry.with_held(held);
                if next != *entry {
                    *entry = next;
                    out.emit(Change::Queue(QueueChange::Add(next)));
                }
            }
            Ok(())
        })
    }
    fn queue_set_all_held(&mut self, held: bool, out: &mut input::Output<'_>) {
        for entry in &mut self.queue {
            let next = entry.with_held(held);
            if next != *entry {
                *entry = next;
                out.emit(Change::Queue(QueueChange::Add(next)));
            }
        }
    }
    /// The open group row, opened with `fields` when there is none.
    fn group_with(
        &mut self,
        fields: Vec<(&'static str, String)>,
        out: &mut input::Output<'_>,
    ) -> Result<u64, Error> {
        if let Some(row) = &self.group {
            return Ok(row.id);
        }
        let mut row = self.row(RowKind::Group, out)?;
        row.fields.insert("calls".into(), "0".into());
        // The turn header's clock: one start, here, and `ms` at the end (step 9 of the motion
        // model); a group born before any turn started starts at its birth.
        let start = if self.turn.is_some() { self.turn_start_ms } else { self.at_ms };
        row.fields.insert("startMs".into(), start.to_string());
        for (key, value) in fields {
            row.fields.insert(key.into(), value);
        }
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
        // A turn that ended with no notice (cut off, or no end at all) leaves no tokens to the next.
        self.claude = ClaudeTurn::default();
        // Background tools may complete after this turn. Preserve their original IDs.
    }
    /// A kind in none of the tables: counted by name, never dropped silently (`kinds.rs`).
    fn unknown(&mut self, kind: &str) {
        let named = self
            .unknown_kinds
            .len()
            .saturating_sub(usize::from(self.unknown_kinds.contains_key(UNKNOWN_OTHER)));
        let key = if self.unknown_kinds.contains_key(kind)
            || (named < MAX_UNKNOWN_KINDS && kind.len() <= 64)
        {
            kind
        } else {
            UNKNOWN_OTHER
        };
        let n = self.unknown_kinds.entry(key.to_owned()).or_insert(0);
        *n = n.saturating_add(1);
        self.unknown_records = self.unknown_records.saturating_add(1);
    }
    /// The records whose kind is on no table, all kinds together: zero over every known log.
    pub fn unknown_records(&self) -> u64 {
        self.unknown_records
    }
    /// The two counts a line that did not translate raises, read without the rest of `counters`.
    pub fn line_failures(&self) -> (u64, u64) {
        (self.invalid_records, self.line_errors)
    }
    /// Copy a table line's fields from `msg` into the row's fields, one pass over its keys.
    fn copy(
        &mut self,
        row: &mut OwnedRow,
        fields: &[kinds::Field],
        msg: &serde_json::value::RawValue,
    ) {
        let mut cut = 0u64;
        let _ = input::entries(msg, |key, value| {
            for field in fields.iter().filter(|field| field.from == key) {
                match field.ty {
                    kinds::Ty::Str(cap) => {
                        if let Ok(text) = input::text(value)
                            && !text.is_empty()
                            && row.field_capped(field.to, &text, cap)
                        {
                            cut = cut.saturating_add(1);
                        }
                    }
                    kinds::Ty::True => {
                        if value.get() == "true" {
                            row.fields.insert(field.to.into(), "true".into());
                        }
                    }
                }
            }
        });
        self.cut_fields = self.cut_fields.saturating_add(cut);
    }
    /// A row drawn from one line by its table line: the row, its fields, then its text.
    /// The row comes back open; the caller settles it.
    fn drawn(
        &mut self,
        spec: &kinds::Drawn,
        msg: &serde_json::value::RawValue,
        out: &mut input::Output<'_>,
    ) -> Result<OwnedRow, Error> {
        let mut row = self.row(spec.kind, out)?;
        if !spec.notice.is_empty() && row.field("notice", spec.notice) {
            self.cut_fields = self.cut_fields.saturating_add(1);
        }
        self.copy(&mut row, spec.fields, msg);
        out.row(&row);
        let mut text: Option<(usize, &serde_json::value::RawValue)> = None;
        input::entries(msg, |key, value| {
            if let Some(rank) = spec.text.iter().position(|name| *name == key)
                && value.get() != "null"
                && text.is_none_or(|(best, _)| rank < best)
            {
                text = Some((rank, value));
            }
        })?;
        if let Some((_, raw)) = text {
            out.body(row.id, BodyField::Content, false, raw);
        }
        Ok(row)
    }
    /// The turn-end notice settles, the group row takes its status, and the turn finishes.
    fn end_turn(&mut self, mut end: OwnedRow, status: &str, out: &mut input::Output<'_>) {
        end.open = false;
        // A prompt sent now ended the turn, not a failure: the turn goes on under that prompt.
        if let Some(prompt) = self.interrupting.take()
            && status != "failed"
        {
            end.fields.insert("continued".into(), "true".into());
            self.continued = Some(Continued { prompt, notice: end.clone() });
        }
        self.stopping = false;
        out.row(&end);
        if !status.is_empty()
            && let Some(group) = &mut self.group
            && group.field("status", status)
        {
            self.cut_fields = self.cut_fields.saturating_add(1);
        }
        self.finish(out);
    }
    /// A prompt sent now into the running turn, which its end goes on under; not after a Stop.
    fn interrupt(&mut self, prompt: &str) {
        let hash = prompt_hash(prompt);
        if self.in_turn() && !self.stopping && self.queued(hash).is_some() {
            self.interrupting = Some(hash);
        }
    }
    /// A Stop the hub took: the running turn's end is the Stop's.
    fn stop(&mut self) {
        self.stopping = self.in_turn();
    }
    /// A prompt that left the queue without running (`queue_removed`, `queue_declined`,
    /// `prompt_refused`; not `dequeued`, which runs it): a turn it ended ends as it did.
    fn withdrawn(&mut self, prompt: &str, out: &mut input::Output<'_>) {
        let hash = prompt_hash(prompt);
        if self.interrupting == Some(hash) {
            self.interrupting = None;
        }
        if self.continued.as_ref().is_some_and(|held| held.prompt == hash) {
            self.drop_continuation(out);
        }
    }
    /// The held turn end reads as ended again: its notice, sent again without `continued`.
    fn drop_continuation(&mut self, out: &mut input::Output<'_>) {
        if let Some(Continued { mut notice, .. }) = self.continued.take() {
            notice.fields.remove("continued");
            notice.rev = notice.rev.saturating_add(1);
            out.emit(Change::Patch(notice));
        }
    }
    /// One Claude model call's usage. Every line of a call repeats it; a new id is a new call.
    fn claude_call(&mut self, message: &str, call: Tokens) {
        if message != self.claude.message || message.is_empty() {
            self.claude.sum = self.claude.sum.add(self.claude.call);
            self.claude.message = message.into();
        }
        self.claude.call = Tokens { calls: 1, ..call };
    }
    /// The Claude turn's split so far: its calls added up, and the newest call's context.
    fn claude_tokens(&mut self) -> Tokens {
        let call = self.claude.call;
        let mut sum = std::mem::take(&mut self.claude).sum.add(call);
        sum.context = call.input.saturating_add(call.cache_read).saturating_add(call.cache_write);
        sum
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
                    out.emit(Change::Leave(row));
                }
            }
            if stream.row.open {
                stream.row.fields.clear();
                stream.row.fields.insert("hidden".into(), "true".into());
                stream.row.bytes = 0;
                stream.row.lines = 0;
                stream.row.open = false;
                out.emit(Change::Leave(stream.row));
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
            prompt.row.fields.remove("steerPromptId");
            if hidden || !prompt.has_body {
                prompt.row.fields.clear();
                prompt.row.fields.insert("hidden".into(), "true".into());
                out.emit(Change::Leave(prompt.row));
            } else {
                out.row(&prompt.row);
            }
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
        if let Some(entry) = self.queued(hash) {
            let already_steer = self
                .prompts
                .get(&hash)
                .is_some_and(|prompt| prompt.row.fields.contains_key("steer"));
            if !already_steer {
                self.mark_steer();
            }
            self.queue_remove(key, out);
            if let Some(mut prompt) = self.prompts.remove(&hash) {
                if !prompt.read {
                    prompt.row.turn = self.turn;
                }
                prompt.read = true;
                prompt.row.fields.remove("steerPromptId");
                if prompt.row.field("state", "sent") {
                    self.cut_fields = self.cut_fields.saturating_add(1);
                }
                prompt.row.fields.insert("steer".into(), "true".into());
                out.row(&prompt.row);
                if !prompt.has_body {
                    out.raw_body(
                        prompt.row.id,
                        BodyField::Content,
                        false,
                        entry.place,
                        u64::from(entry.span),
                    );
                }
                prompt.row.open = false;
                out.row(&prompt.row);
                self.fold.extra(prompt.row.id);
                self.settled_prompt(hash);
                return Ok(());
            }
            let mut row = self.row(RowKind::User, out)?;
            row.turn = self.turn;
            if row.field("state", "sent") {
                self.cut_fields = self.cut_fields.saturating_add(1);
            }
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
            let was_read = prompt.read;
            if !prompt.read {
                prompt.row.turn = self.turn;
            }
            prompt.read = true;
            prompt.row.fields.remove("steerPromptId");
            if !was_read {
                self.fold.extra(prompt.row.id);
            }
            if prompt.row.field("state", "sent") {
                self.cut_fields = self.cut_fields.saturating_add(1);
            }
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
        let PromptEvent {
            key,
            prompt_key,
            steer,
            notice,
            body,
            images,
            sender,
            inline_parts,
            pasted,
            place,
            span,
        } = event;
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
        // A prompt sent now that runs before its turn ended stopped nothing; one a turn's end went
        // on under continues that turn. Another prompt opening a turn first means it never ran.
        if !prompt_key.is_empty() && self.interrupting == Some(hash) {
            self.interrupting = None;
        }
        let continues = !prompt_key.is_empty()
            && self.continued.as_ref().is_some_and(|held| held.prompt == hash);
        if continues {
            self.continued = None;
        } else if !steer {
            self.drop_continuation(out);
        }
        if !steer {
            self.stopping = false;
        }
        self.queue_remove(prompt_key, out);
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
        if row.field("state", "sent") {
            self.cut_fields = self.cut_fields.saturating_add(1);
        }
        if notice {
            row.fields.insert("notice".into(), "true".into());
        }
        if continues {
            row.fields.insert("continues".into(), "true".into());
        }
        if !prompt_key.is_empty() && row.field("promptId", prompt_key) {
            self.cut_fields = self.cut_fields.saturating_add(1);
        }
        let user::Sender { fields: said, claims, cut, .. } = sender;
        self.cut_fields = self.cut_fields.saturating_add(cut);
        for (name, value) in said {
            row.fields.insert(name.into(), value);
        }
        // Where it was sent from, under a prompt or another agent's message (decision 244 c).
        if claims && let Some(from) = self.take_claim(hash) {
            row.fields.insert("sentFrom".into(), from);
        }
        let waiting = steer && !already_read && !prompt_key.is_empty();
        if waiting && row.field("steerPromptId", prompt_key) {
            self.cut_fields = self.cut_fields.saturating_add(1);
        }
        if steer {
            if !already_read {
                row.turn = self.turn;
            }
            row.fields.insert("steer".into(), "true".into());
            if !already_read {
                self.fold.extra(row.id);
            }
        } else {
            row.fields.insert("steer".into(), "false".into());
            self.turn = Some(row.id);
            self.turn_key = key.into();
            self.turn_start_ms = self.at_ms;
            row.turn = self.turn;
        }
        out.row(&row);
        let row_id = row.id;
        if let Some(body) = body {
            out.body(row.id, BodyField::Content, false, body);
        }
        if let Some(images) = images {
            out.body(row.id, BodyField::Images, false, images);
        }
        // A prompt's recorded parts and pasted blocks, as lists; the view reads each entry.
        let inline_parts = inline_parts.filter(|raw| raw.get().starts_with('['));
        let pasted = pasted.filter(|raw| raw.get().starts_with('['));
        if let Some(parts) = inline_parts {
            out.body(row.id, BodyField::InlineParts, false, parts);
        }
        if let Some(pasted) = pasted {
            out.body(row.id, BodyField::Pasted, false, pasted);
        }
        if waiting {
            let bytes = fields_bytes(&row);
            while !self.prompts.is_empty()
                && (self.prompts.len() >= 32
                    || self.held_steer_bytes().saturating_add(bytes) > MAX_HELD_STEER_BYTES)
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
            // Its claim may come next; only a row whose every body is this line's can take it.
            self.claimable = (claims
                && !prompt_key.is_empty()
                && body.is_some()
                && !row.fields.contains_key("sentFrom"))
            .then(|| Claimable {
                prompt: hash,
                bodies: CLAIM_BODIES
                    .iter()
                    .enumerate()
                    .filter(|(_, field)| match field {
                        BodyField::Content => true,
                        BodyField::Images => images.is_some(),
                        BodyField::InlineParts => inline_parts.is_some(),
                        _ => pasted.is_some(),
                    })
                    .filter_map(|(index, _)| u8::try_from(index).ok())
                    .collect(),
                row: row.clone(),
                place,
                span,
            });
        }
        if !steer {
            // Decision 235: the turn's group row names its prompt's row, id and first words.
            let mut opening = vec![("prompt", row_id.to_string())];
            if !prompt_key.is_empty() {
                opening.push(("promptId", json_string(prompt_key)));
            }
            if let Some(head) = body.and_then(|body| user::head(body, user::HEAD_BYTES))
                && !head.is_empty()
            {
                opening.push(("head", json_string(&head)));
            }
            self.group_with(opening, out)?;
        }
        Ok(())
    }
    /// The bytes the waiting steers' fields hold.
    fn held_steer_bytes(&self) -> usize {
        self.prompts.values().map(|p| fields_bytes(&p.row)).fold(0, usize::saturating_add)
    }
    /// A prompt's sender claim, held until its user row came, or else not yet known.
    fn take_claim(&mut self, prompt: u64) -> Option<String> {
        let at = self.claims.iter().position(|(hash, _)| *hash == prompt)?;
        Some(self.claims.remove(at).1)
    }
    /// A `sender_claim`: onto the prompt's user row, waiting or just settled (a patch), or held
    /// for the prompt's echo.
    fn claim(&mut self, prompt: &str, from: String, out: &mut input::Output<'_>) {
        let hash = prompt_hash(prompt);
        if let Some(waiting) = self.prompts.get_mut(&hash) {
            // A queued prompt not echoed yet is not read yet: its echo takes the claim.
            if waiting.read || waiting.row.fields.contains_key("steer") {
                if takes_claim(&waiting.row) {
                    waiting.row.fields.insert("sentFrom".into(), from);
                    out.row(&waiting.row);
                }
                return;
            }
        }
        if self.claimable.as_ref().is_some_and(|row| row.prompt == hash)
            && let Some(Claimable { mut row, place, span, bodies, .. }) = self.claimable.take()
        {
            row.fields.insert("sentFrom".into(), from);
            row.rev = row.rev.saturating_add(1);
            for index in bodies {
                if let Some(field) = CLAIM_BODIES.get(usize::from(index)) {
                    out.raw_body(row.id, *field, false, place, span);
                }
            }
            out.emit(Change::Patch(row));
            return;
        }
        if self.settled_prompts.contains(&hash) {
            self.unplaced_claims = self.unplaced_claims.saturating_add(1);
            return;
        }
        self.claims.retain(|(held, _)| *held != hash);
        let held = |claims: &[(u64, String)]| {
            claims.iter().map(|(_, from)| from.len()).fold(from.len(), usize::saturating_add)
        };
        while !self.claims.is_empty()
            && (self.claims.len() >= MAX_HELD_CLAIMS || held(&self.claims) > MAX_HELD_CLAIM_BYTES)
        {
            self.claims.remove(0);
            self.unplaced_claims = self.unplaced_claims.saturating_add(1);
        }
        self.claims.push((hash, from));
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
            if row.field("messageId", key) {
                self.cut_fields = self.cut_fields.saturating_add(1);
            }
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
        if let Some(marker) = stream.block.fence_marker()
            && row.field("fence", &marker)
        {
            self.cut_fields = self.cut_fields.saturating_add(1);
        }
        if row.field("messageId", &stream.message) {
            self.cut_fields = self.cut_fields.saturating_add(1);
        }
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
            if row.field("book", key) {
                self.cut_fields = self.cut_fields.saturating_add(1);
            }
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
            if row.field("callId", key) {
                self.cut_fields = self.cut_fields.saturating_add(1);
            }
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
