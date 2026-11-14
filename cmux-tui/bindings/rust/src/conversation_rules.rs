//! The conversation client rules every client of the daemon follows the
//! same way (the CLI, and the macOS app through the SDK's C ABI), as pure
//! functions over JSON values. Golden vectors:
//! `tests/cases/conversation_rules.json` (each names the Swift source it
//! encodes).
//!
//! - The run summary pagers: the reply-key lookups in batches, the local and
//!   Cloud `before_started_at` cursors, and the run steps' `after` cursor.
//! - The chunked attachment transfer: which pieces an upload sends, in which
//!   chunks, with what progress (each chunk computed on demand, so a plan
//!   takes constant memory); when a chunked read ends or fails.
//! - A run step's tool, normalized (the Chief's `tell` and `spawn` envelopes,
//!   `_meta.cmux.sender`), and a message part's plain text.
//! - The inbox op values (`inbox.pin`, `inbox.mark_unread`, `inbox.mute`).
//!
//! [`call`] runs one rule by name on a JSON request, the shape a C ABI
//! entry takes. The conversation state itself (messages, runs, the intent
//! log) is the daemon's; no client keeps a mirror of it.

use serde_json::{Map, Value, json};

/// Decoded bytes per attachment chunk and per read: the daemon's limit
/// (4 MiB, about 5.6 MiB of base64 inside a 16 MiB request line).
pub const ATTACHMENT_CHUNK_BYTES: u64 = 4 << 20;
/// A local chunk's deadline: 4 MiB over a local socket takes milliseconds;
/// this bounds a stalled daemon, not a slow disk.
pub const ATTACHMENT_CHUNK_TIMEOUT_MS: u64 = 30_000;
/// A Cloud command's deadline (a Worker round trip through the daemon).
pub const CLOUD_NETWORK_TIMEOUT_MS: u64 = 30_000;
/// The most messages one snapshot, history or thread page asks for.
pub const MAX_PAGE: u64 = 500;
/// The most reply keys (turns or answers) one `conversation-runs` asks for.
pub const RUNS_KEY_BATCH: usize = 200;
/// `conversation-runs`' page size.
pub const RUNS_PAGE_LIMIT: u64 = 200;
/// `cloud-conversation-runs`' page size.
pub const CLOUD_RUNS_PAGE_LIMIT: u64 = 100;
/// An upload's reported progress stays below this until the commit answers.
pub const UPLOAD_PROGRESS_CAP: f64 = 0.99;

/// Why a rule refused its input ([`call`]'s `{"error": code}`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuleReject {
    /// The input is not the shape the op takes.
    Invalid,
    /// `begin` asked for a poster the attachment or the caller does not have.
    PosterNeeded,
    /// `begin` asked for a preview the attachment or the caller does not have.
    PreviewNeeded,
    /// `begin` named a piece this build does not know.
    UnknownPiece,
    /// A read moved no bytes before the owner's eof.
    NoProgress,
}

impl RuleReject {
    pub fn code(self) -> &'static str {
        match self {
            Self::Invalid => "invalid",
            Self::PosterNeeded => "poster_needed",
            Self::PreviewNeeded => "preview_needed",
            Self::UnknownPiece => "unknown_piece",
            Self::NoProgress => "no_progress",
        }
    }
}

/// The constants a client reads once (the `policy` rule).
pub fn policy() -> Value {
    json!({
        "attachment_chunk_bytes": ATTACHMENT_CHUNK_BYTES,
        "attachment_chunk_timeout_ms": ATTACHMENT_CHUNK_TIMEOUT_MS,
        "cloud_network_timeout_ms": CLOUD_NETWORK_TIMEOUT_MS,
        "max_page": MAX_PAGE,
        "runs_key_batch": RUNS_KEY_BATCH,
        "runs_page_limit": RUNS_PAGE_LIMIT,
        "cloud_runs_page_limit": CLOUD_RUNS_PAGE_LIMIT,
    })
}

/// A page size the owner accepts: `limit` clamped to 1...[`MAX_PAGE`].
pub fn clamp_page(limit: i64) -> u64 {
    limit.clamp(1, MAX_PAGE as i64) as u64
}

// ---- Run summaries ----

/// The reply-key lookups of a local `conversation-runs` read, in order: the
/// turns in batches of [`RUNS_KEY_BATCH`], then (when the daemon serves
/// `conversation-run-answers-v1`) the answered message ids likewise.
pub fn runs_key_batches(turns: &[String], answers: &[String], answers_served: bool) -> Vec<Value> {
    let mut batches: Vec<Value> =
        turns.chunks(RUNS_KEY_BATCH).map(|keys| json!({ "turns": keys })).collect();
    if answers_served {
        batches.extend(answers.chunks(RUNS_KEY_BATCH).map(|ids| json!({ "answers": ids })));
    }
    batches
}

/// The smallest start time of a page, as Swift's `[Double].min()` (the
/// first value, replaced by any smaller one).
fn oldest(started_at: &[f64]) -> Option<f64> {
    let (first, rest) = started_at.split_first()?;
    Some(rest.iter().fold(*first, |low, &value| if value < low { value } else { low }))
}

/// A start time as the next strict `before_started_at` cursor: a finite,
/// whole, non-negative number below `u64::MAX` that moves below `before`.
fn strict_cursor(oldest: f64, before: Option<u64>) -> Option<u64> {
    if !oldest.is_finite() || oldest < 0.0 || oldest >= u64::MAX as f64 || oldest.fract() != 0.0 {
        return None;
    }
    let next = oldest as u64;
    before.is_none_or(|before| next < before).then_some(next)
}

/// The Cloud summary pager's cursor: Cloud pagination has no composite
/// cursor yet, so a non-advancing or invalid boundary ends the read rather
/// than spin or repeat a page.
pub fn cloud_runs_cursor(has_more: bool, started_at: &[f64], before: Option<u64>) -> Option<u64> {
    if !has_more {
        return None;
    }
    strict_cursor(oldest(started_at)?, before)
}

/// The local summary pager's cursor: newest first, ending at the visible
/// transcript's oldest message (`oldest_started_at`), at the owner's end, or
/// on a cursor that does not move.
pub fn local_runs_cursor(
    has_more: bool,
    started_at: &[f64],
    before: Option<u64>,
    oldest_started_at: f64,
) -> Option<u64> {
    if !has_more {
        return None;
    }
    let oldest = oldest(started_at)?;
    // NaN compares false, so it ends the read too.
    (oldest > oldest_started_at.max(0.0)).then(|| strict_cursor(oldest, before)).flatten()
}

/// One page of a summary read: what the next page asks for.
#[derive(Debug, Clone, PartialEq)]
pub struct RunsPage<'a> {
    /// `local` (`conversation-runs`) or `cloud` (`cloud-conversation-runs`).
    pub cloud: bool,
    pub has_more: bool,
    /// The page's runs' `started_at` values (runs without one left out).
    pub started_at: &'a [f64],
    /// The page's runs' `turn` values (runs without one left out).
    pub turns: &'a [String],
    /// The cursor this page was read with.
    pub before: Option<u64>,
    /// The visible transcript's oldest message time (ms).
    pub oldest_started_at: f64,
    /// Cloud: the loaded reply keys no run was found for yet.
    pub unresolved: &'a [String],
}

/// The next page's cursor (None: the read ends) and the reply keys still
/// unresolved. Cloud: a run can start before the visible window and still
/// answer a loaded question, so the read goes on past the window until every
/// loaded reply key found its run (a manual reply with no run reads the
/// endpoint's finite history).
pub fn runs_next(page: &RunsPage<'_>) -> (Option<u64>, Vec<String>) {
    if !page.cloud {
        let next =
            local_runs_cursor(page.has_more, page.started_at, page.before, page.oldest_started_at);
        return (next, Vec::new());
    }
    let unresolved: Vec<String> =
        page.unresolved.iter().filter(|key| !page.turns.contains(key)).cloned().collect();
    if unresolved.is_empty()
        && let Some(oldest) = oldest(page.started_at)
        && oldest <= page.oldest_started_at
    {
        return (None, unresolved);
    }
    (cloud_runs_cursor(page.has_more, page.started_at, page.before), unresolved)
}

/// A run's steps pager: the next `after` cursor (the page's newest step
/// key) while the owner has more and the cursor moves.
pub fn run_steps_next(has_more: bool, cursor: u64, keys: &[u64]) -> Option<u64> {
    let last = keys.iter().copied().max()?;
    (has_more && last > cursor).then_some(last)
}

// ---- Attachments ----

/// One piece of an upload: the variant, its declared size, and the bytes
/// of the pieces before it (its chunks' progress counts them). Its chunks
/// are computed on demand ([`UploadPiece::chunk`]), so a plan takes the same
/// memory for any size.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UploadPiece {
    pub variant: &'static str,
    pub size: u64,
    pub sent_before: u64,
}

/// One chunk of a piece: where it starts, how long it is, and the upload's
/// progress once it is sent.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct UploadChunk {
    pub offset: u64,
    pub length: u64,
    pub progress: f64,
}

/// An upload's pieces and the bytes of all of them (`total`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UploadPlan {
    pub total: u64,
    pub pieces: Vec<UploadPiece>,
}

impl UploadPiece {
    /// How many chunks of [`ATTACHMENT_CHUNK_BYTES`] the piece sends.
    pub fn chunk_count(&self) -> u64 {
        self.size.div_ceil(ATTACHMENT_CHUNK_BYTES)
    }

    /// Chunk `index` of the piece, or `None` past its last one. Progress is
    /// the fraction of `total` sent once this chunk is, capped below 1 until
    /// the commit answers.
    pub fn chunk(&self, index: u64, total: u64) -> Option<UploadChunk> {
        if index >= self.chunk_count() {
            return None;
        }
        // index < chunk_count, so offset < size and nothing overflows.
        let offset = index * ATTACHMENT_CHUNK_BYTES;
        let length = ATTACHMENT_CHUNK_BYTES.min(self.size - offset);
        let sent = self.sent_before.saturating_add(offset + length);
        let progress = UPLOAD_PROGRESS_CAP.min(sent as f64 / total.max(1) as f64);
        Some(UploadChunk { offset, length, progress })
    }

    /// Every chunk of the piece, in order, one at a time.
    pub fn chunks(&self, total: u64) -> impl Iterator<Item = UploadChunk> + '_ {
        (0..self.chunk_count()).filter_map(move |index| self.chunk(index, total))
    }
}

fn byte_count(value: Option<&Value>) -> Option<u64> {
    value?.get("byte_count")?.as_u64()
}

/// The pieces an upload sends after `begin`: `needs` (absent: the original
/// only), each from its own file, in chunks of [`ATTACHMENT_CHUNK_BYTES`] up
/// to its declared size. A piece read shorter than its declared size ends at
/// its EOF and the commit refuses it (`incomplete`). Sizes whose sum does not
/// fit in a `u64` are refused as invalid; any size up to that plans in
/// constant memory.
pub fn upload_plan(
    attachment: &Value,
    needs: Option<&[String]>,
    has_poster_file: bool,
    has_preview_file: bool,
) -> Result<UploadPlan, RuleReject> {
    let original = ["original".to_string()];
    let needs = needs.unwrap_or(&original);
    let mut pieces = Vec::with_capacity(needs.len());
    let mut total = 0u64;
    for variant in needs {
        let (variant, size) = match variant.as_str() {
            "original" => ("original", byte_count(Some(attachment)).ok_or(RuleReject::Invalid)?),
            "poster" => {
                let size = byte_count(attachment.get("poster")).filter(|_| has_poster_file);
                ("poster", size.ok_or(RuleReject::PosterNeeded)?)
            }
            "preview" => {
                let size = byte_count(attachment.get("preview")).filter(|_| has_preview_file);
                ("preview", size.ok_or(RuleReject::PreviewNeeded)?)
            }
            _ => return Err(RuleReject::UnknownPiece),
        };
        pieces.push(UploadPiece { variant, size, sent_before: total });
        total = total.checked_add(size).ok_or(RuleReject::Invalid)?;
    }
    Ok(UploadPlan { total, pieces })
}

/// After one chunked read reply: the next offset, or None when the owner's
/// eof ended the read. A reply that moves no bytes before eof is an error,
/// and so is one whose next offset would not fit in a `u64`.
pub fn read_next(offset: u64, received: u64, eof: bool) -> Result<Option<u64>, RuleReject> {
    if eof {
        return Ok(None);
    }
    if received == 0 {
        return Err(RuleReject::NoProgress);
    }
    offset.checked_add(received).map(Some).ok_or(RuleReject::Invalid)
}

// ---- Run steps and parts ----

fn string(object: &Map<String, Value>, key: &str) -> Option<String> {
    object.get(key)?.as_str().map(str::to_owned)
}

fn strings(object: &Map<String, Value>, key: &str) -> Option<Vec<String>> {
    object.get(key)?.as_array()?.iter().map(|v| v.as_str().map(str::to_owned)).collect()
}

/// `_meta.cmux.sender` when it is a string.
fn sender(object: &Map<String, Value>) -> Option<String> {
    object.get("_meta")?.get("cmux")?.get("sender")?.as_str().map(str::to_owned)
}

/// A tool step's input. Other tools take any JSON, so an unfamiliar shape
/// is an input with nothing set, never an error. A Codex `mcp_tool_call`
/// envelope (`{server, tool, arguments}`) reads its fields from `arguments`
/// and says whether it carries optchat's `tell` or `spawn`.
pub fn tool_input(input: &Value) -> Value {
    let mut out = Map::new();
    let mut tell = false;
    let mut spawn = false;
    if let Some(fields) = input.as_object() {
        if fields.contains_key("arguments") {
            if let Some(arguments) = fields.get("arguments").and_then(Value::as_object) {
                let server = string(fields, "server");
                let tool = string(fields, "tool");
                tell = server.as_deref() == Some("optchat") && tool.as_deref() == Some("tell");
                spawn = server.as_deref() == Some("optchat") && tool.as_deref() == Some("spawn");
                insert(&mut out, "id", string(arguments, "id"));
                insert(&mut out, "message", string(arguments, "message"));
                insert(&mut out, "tasks", strings(arguments, "tasks"));
                insert(&mut out, "sender", sender(arguments).or_else(|| sender(fields)));
            }
        } else {
            insert(&mut out, "id", string(fields, "id"));
            insert(&mut out, "message", string(fields, "message"));
            insert(&mut out, "tasks", strings(fields, "tasks"));
            insert(&mut out, "sender", sender(fields));
        }
    }
    out.insert("is_tell_envelope".into(), Value::Bool(tell));
    out.insert("is_spawn_envelope".into(), Value::Bool(spawn));
    Value::Object(out)
}

fn insert<T: Into<Value>>(out: &mut Map<String, Value>, key: &str, value: Option<T>) {
    if let Some(value) = value {
        out.insert(key.into(), value.into());
    }
}

/// A run step's `tool`, normalized: `name` (or `tool`, else ""), `input`
/// (from `input`, else `arguments`; absent when neither key is there),
/// `status`, `output` and `started_at` when they have their type. Only the
/// fields Chief messages need; any other shape still decodes.
pub fn run_tool(tool: &Value) -> Value {
    let mut out = Map::new();
    let Some(fields) = tool.as_object() else {
        out.insert("name".into(), Value::String(String::new()));
        return Value::Object(out);
    };
    let name = string(fields, "name").or_else(|| string(fields, "tool")).unwrap_or_default();
    out.insert("name".into(), Value::String(name));
    if let Some(input) = fields.get("input").or_else(|| fields.get("arguments")) {
        out.insert("input".into(), tool_input(input));
    }
    insert(&mut out, "status", string(fields, "status"));
    insert(&mut out, "output", string(fields, "output"));
    if let Some(started) = fields.get("started_at").and_then(Value::as_f64) {
        out.insert("started_at".into(), json!(started));
    }
    Value::Object(out)
}

/// A message part's plain text, for previews and fallbacks: a text's text,
/// a work part's preview (else `<session> <status>`), an attachment's name,
/// a link preview's title (else its url); a part type this build does not
/// know reads as its `url` when it carries a non-empty one (a newer part
/// with a link, as `link_preview` was), else as its type.
pub fn plain_text(part: &Value) -> String {
    let text = |key: &str| part.get(key).and_then(Value::as_str);
    let kind = text("type").unwrap_or_default();
    match kind {
        "text" => text("text").unwrap_or_default().to_owned(),
        "work" => text("preview").map(str::to_owned).unwrap_or_else(|| {
            format!(
                "{} {}",
                text("session").unwrap_or_default(),
                text("status").unwrap_or_default()
            )
        }),
        "attachment" => text("name").unwrap_or_default().to_owned(),
        "link_preview" => text("title").or_else(|| text("url")).unwrap_or_default().to_owned(),
        _ => match text("url") {
            Some(url) if !url.is_empty() => url.to_owned(),
            _ => kind.to_owned(),
        },
    }
}

// ---- Inbox ops ----

/// An inbox op value (`conversation-inbox-op`, `cloud-inbox-op`). Values are
/// absolute, so a retry writes the same state. `pin`: a pin without
/// `position` goes after the caller's last pin, an unpin has none. `mute`
/// (Cloud rows only): until `until` (Unix ms) when set, an unmute has none.
pub fn inbox_op(kind: &str, on: bool, position: Option<u64>, until: Option<u64>) -> Option<Value> {
    let mut op = Map::new();
    match kind {
        "pin" => {
            op.insert("kind".into(), json!("inbox.pin"));
            op.insert("pinned".into(), json!(on));
            insert(&mut op, "position", position.filter(|_| on));
        }
        "mark_unread" => {
            op.insert("kind".into(), json!("inbox.mark_unread"));
            op.insert("unread".into(), json!(on));
        }
        "mute" => {
            op.insert("kind".into(), json!("inbox.mute"));
            op.insert("muted".into(), json!(on));
            insert(&mut op, "until", until.filter(|_| on));
        }
        _ => return None,
    }
    Some(Value::Object(op))
}

// ---- The JSON ops ----

fn field<'a>(request: &'a Value, key: &str) -> Option<&'a Value> {
    request.get(key).filter(|v| !v.is_null())
}

fn string_list(request: &Value, key: &str) -> Result<Vec<String>, RuleReject> {
    match field(request, key) {
        None => Ok(Vec::new()),
        Some(value) => serde_json::from_value(value.clone()).map_err(|_| RuleReject::Invalid),
    }
}

fn number_list<T: serde::de::DeserializeOwned>(
    request: &Value,
    key: &str,
) -> Result<Vec<T>, RuleReject> {
    match field(request, key) {
        None => Ok(Vec::new()),
        Some(value) => serde_json::from_value(value.clone()).map_err(|_| RuleReject::Invalid),
    }
}

fn optional_u64(request: &Value, key: &str) -> Result<Option<u64>, RuleReject> {
    field(request, key).map(|v| v.as_u64().ok_or(RuleReject::Invalid)).transpose()
}

fn flag(request: &Value, key: &str) -> bool {
    request.get(key).and_then(Value::as_bool).unwrap_or(false)
}

/// One rule by name on a JSON request; `None` for a rule this build does
/// not know. A refusal is `Err` (a C ABI answers it as `{"error": code}`).
/// The requests and replies are the golden vectors'
/// (`tests/cases/conversation_rules.json`).
pub fn call(op: &str, request: &Value) -> Option<Result<Value, RuleReject>> {
    Some(match op {
        "policy" => Ok(policy()),
        "clamp_page" => request
            .get("limit")
            .and_then(Value::as_i64)
            .map(|limit| json!({ "limit": clamp_page(limit) }))
            .ok_or(RuleReject::Invalid),
        "runs_key_batches" => (|| {
            let turns = string_list(request, "turns")?;
            let answers = string_list(request, "answers")?;
            Ok(
                json!({ "batches": runs_key_batches(&turns, &answers, flag(request, "answers_served")) }),
            )
        })(),
        "runs_next" => (|| {
            let cloud = match request.get("owner").and_then(Value::as_str) {
                Some("local") => false,
                Some("cloud") => true,
                _ => return Err(RuleReject::Invalid),
            };
            let started_at: Vec<f64> = number_list(request, "started_at")?;
            let turns = string_list(request, "turns")?;
            let unresolved = string_list(request, "unresolved")?;
            let page = RunsPage {
                cloud,
                has_more: flag(request, "has_more"),
                started_at: &started_at,
                turns: &turns,
                before: optional_u64(request, "before")?,
                oldest_started_at: request
                    .get("oldest_started_at")
                    .and_then(Value::as_f64)
                    .ok_or(RuleReject::Invalid)?,
                unresolved: &unresolved,
            };
            let (before, unresolved) = runs_next(&page);
            Ok(json!({ "before": before, "unresolved": unresolved }))
        })(),
        "run_steps_next" => (|| {
            let keys: Vec<u64> = number_list(request, "keys")?;
            let cursor = optional_u64(request, "cursor")?.unwrap_or(0);
            Ok(json!({ "after": run_steps_next(flag(request, "has_more"), cursor, &keys) }))
        })(),
        "upload_plan" => (|| {
            let attachment = field(request, "attachment").ok_or(RuleReject::Invalid)?;
            let needs =
                field(request, "needs").map(|_| string_list(request, "needs")).transpose()?;
            let plan = upload_plan(
                attachment,
                needs.as_deref(),
                flag(request, "has_poster_file"),
                flag(request, "has_preview_file"),
            )?;
            let pieces: Vec<Value> = plan
                .pieces
                .iter()
                .map(|piece| {
                    json!({ "variant": piece.variant, "size": piece.size,
                            "sent_before": piece.sent_before, "chunk_count": piece.chunk_count() })
                })
                .collect();
            Ok(
                json!({ "total": plan.total, "chunk_bytes": ATTACHMENT_CHUNK_BYTES, "pieces": pieces }),
            )
        })(),
        "upload_chunk" => (|| {
            let size = optional_u64(request, "size")?.ok_or(RuleReject::Invalid)?;
            let sent_before = optional_u64(request, "sent_before")?.unwrap_or(0);
            let total = optional_u64(request, "total")?.ok_or(RuleReject::Invalid)?;
            let index = optional_u64(request, "index")?.ok_or(RuleReject::Invalid)?;
            if sent_before.checked_add(size).is_none_or(|end| end > total) {
                return Err(RuleReject::Invalid);
            }
            let piece = UploadPiece { variant: "", size, sent_before };
            let chunk = piece.chunk(index, total).ok_or(RuleReject::Invalid)?;
            Ok(
                json!({ "offset": chunk.offset, "length": chunk.length, "progress": chunk.progress }),
            )
        })(),
        "read_next" => (|| {
            let offset = optional_u64(request, "offset")?.unwrap_or(0);
            let received = optional_u64(request, "received")?.ok_or(RuleReject::Invalid)?;
            let next = read_next(offset, received, flag(request, "eof"))?;
            Ok(json!({ "offset": next }))
        })(),
        "run_tool" => Ok(run_tool(request.get("tool").unwrap_or(&Value::Null))),
        "plain_text" => field(request, "part")
            .map(|part| json!({ "text": plain_text(part) }))
            .ok_or(RuleReject::Invalid),
        "inbox_op" => (|| {
            let kind = request.get("kind").and_then(Value::as_str).ok_or(RuleReject::Invalid)?;
            let on = request.get("on").and_then(Value::as_bool).ok_or(RuleReject::Invalid)?;
            let position = optional_u64(request, "position")?;
            let until = optional_u64(request, "until")?;
            inbox_op(kind, on, position, until).ok_or(RuleReject::Invalid)
        })(),
        _ => return None,
    })
}
