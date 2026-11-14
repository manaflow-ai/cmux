//! A chat's subscribers, and the reads the actor answers for them: a `window`, a `page`, a
//! `blob` and a resume. The actor is the only reader of its log and writes to no socket: every
//! frame here is offered to a connection, which takes it or says it did not.
//!
//! - A subscriber is not live until its window or its resume's state frame is taken, and
//!   nothing is held for it before that: the first live op it gets is about something later.
//! - A delta's ops are encoded once per change and offered to each live subscriber.
//! - Text appended to an open row waits here, one piece a row, for at most 16 ms. It is offered
//!   before any frame that would hold it (a window, a state frame, a `blob` of the row), so no
//!   client applies it twice.

use super::queue::{self, MAX_HEADS, PromptError, Token};
use super::{ActorState, ChatError};
use crate::conn::{Offer, OfferSink, Reply};
use crate::wire::{
    Anchor, AnchorSide, Blob, BlobHead, ChatPageResult, ChatWindow, Cursor, Frame, FrameKind,
    MAX_REPLAY_FRAME_BYTES, OpenRow, Page, PageSide, Position, QueueHead, QueueItem, RawJson,
    blob_frame,
};
use acpmux_book::log::{self, Log, MAX_BLOB_READ, MAX_FRAME_BYTES, MAX_PAGE_BYTES, MAX_ROWS};
use acpmux_book::translate::{QueueEntry, prompt_hash};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// A person: the first 16 bytes of the SHA-256 of the key `hello` proved. The key is kept
/// nowhere.
pub type PersonId = [u8; 16];

pub fn person_id(key: Option<&[u8]>) -> PersonId {
    use sha2::Digest;
    let digest = sha2::Sha256::digest(key.unwrap_or_default());
    let mut id = [0u8; 16];
    for (slot, byte) in id.iter_mut().zip(digest.iter()) {
        *slot = *byte;
    }
    id
}

/// Text ops for one row are offered at most once per this.
pub const COALESCE: Duration = Duration::from_millis(16);
/// A resume that would read more than this of records gets a fresh `window` instead.
pub const MISSED_LIMIT: u64 = 1024 * 1024;
/// The open bodies a window or a state frame carries inline, together.
pub const OPEN_INLINE: usize = 64 * 1024;

/// A `sub` for a chat, as its actor takes it.
#[derive(Clone, Debug)]
pub struct ChatSub {
    pub sid: String,
    pub conn: u64,
    pub cursor: Option<u64>,
    pub edition: Option<u32>,
    pub anchor: Option<Anchor>,
    pub window: u16,
    pub person: PersonId,
}

/// The sink a `sub` came with, until the actor takes it. One that is dropped untaken (an actor
/// that ended with the `sub` in its mailbox) says `dropped`, so the client resumes.
pub struct Ticket {
    sid: String,
    sink: Option<Arc<dyn OfferSink>>,
}

impl Ticket {
    pub fn new(sid: String, sink: Arc<dyn OfferSink>) -> Self {
        Self { sid, sink: Some(sink) }
    }

    fn take(mut self) -> Option<Arc<dyn OfferSink>> {
        self.sink.take()
    }

    /// The `sub` was refused before the actor had it: its caller answers the error.
    pub fn forget(self) {
        let _ = self.take();
    }
}

impl Drop for Ticket {
    fn drop(&mut self) {
        if let Some(sink) = self.sink.take() {
            sink.dropped(&self.sid);
        }
    }
}

#[derive(Clone, Debug)]
enum Phase {
    /// The chat is not ready: `not_ready` was sent and the request is kept.
    Waiting {
        sub: ChatSub,
    },
    /// A fresh window at the end replaces what it held: another edition.
    Fresh,
    /// Records after `cursor`, a frame at a time; `checked` once the backlog was measured.
    Resuming {
        cursor: u64,
        checked: bool,
    },
    Live,
    /// Past its credit window: nothing is offered until the connection resumes it.
    Stopped,
}

pub(super) struct Subscriber {
    conn: u64,
    sid: String,
    sink: Arc<dyn OfferSink>,
    person: PersonId,
    edition: u32,
    phase: Phase,
    taken: u64,
}

/// The actor's subscribers and the text it holds for them. Dropped with subscribers in it (an
/// actor that panicked or closed), each gets `dropped` and resumes.
#[derive(Default)]
pub(super) struct Subscribers {
    list: Vec<Subscriber>,
    /// Escaped text appended to each open row since it was last offered.
    text: BTreeMap<u64, Vec<u8>>,
    flush_at: Option<Instant>,
    /// Ops of the change being applied, encoded once, comma-joined.
    ops: Vec<u8>,
    /// The queue changed in the batch of lines being applied.
    queue_changed: bool,
}

impl Drop for Subscribers {
    fn drop(&mut self) {
        for sub in self.list.drain(..) {
            sub.sink.dropped(&sub.sid);
        }
    }
}

impl Subscribers {
    pub(super) fn is_empty(&self) -> bool {
        self.list.is_empty()
    }

    fn any_live(&self) -> bool {
        self.list.iter().any(|sub| matches!(sub.phase, Phase::Live))
    }

    /// When the actor must wake to offer held text.
    pub(super) fn flush_at(&self) -> Option<Instant> {
        self.flush_at
    }

    /// A subscriber with a step to take: a resume frame or a fresh window.
    pub(super) fn busy(&self) -> bool {
        self.list.iter().any(|sub| matches!(sub.phase, Phase::Resuming { .. } | Phase::Fresh))
    }

    /// The actor reopened its book: a subscriber of another edition gets a fresh window, one of
    /// the same edition is resumed from its last taken seq by the slow reader's path.
    pub(super) fn reopened(&mut self, edition: u32) {
        self.text.clear();
        self.flush_at = None;
        self.ops.clear();
        for sub in &mut self.list {
            sub.phase = match &sub.phase {
                Phase::Waiting { sub } => Phase::Waiting { sub: sub.clone() },
                _ if sub.edition != edition => Phase::Fresh,
                Phase::Stopped => Phase::Stopped,
                _ => Phase::Resuming { cursor: sub.taken, checked: false },
            };
        }
    }
}

// ---- requests ----

pub(super) fn subscribe(state: &mut ActorState, sub: ChatSub, ticket: Ticket) {
    let Some(sink) = ticket.take() else { return };
    let subscriber = Subscriber {
        conn: sub.conn,
        sid: sub.sid.clone(),
        sink,
        person: sub.person,
        edition: state.edition,
        phase: Phase::Waiting { sub },
        taken: 0,
    };
    state.subs.list.retain(|old| !(old.conn == subscriber.conn && old.sid == subscriber.sid));
    state.subs.list.push(subscriber);
    let at = state.subs.list.len() - 1;
    if state.ready {
        start(state, at);
    } else {
        not_ready(state, at);
    }
}

/// `not_ready`: an `error` on the `sid` that leaves it held, with the cursor and the hint.
fn not_ready(state: &mut ActorState, at: usize) {
    let hint = state.source.hint().unwrap_or_default();
    let Some(sub) = state.subs.list.get(at) else { return };
    let cursor = match &sub.phase {
        Phase::Waiting { sub } => sub.cursor.unwrap_or_default(),
        _ => 0,
    };
    let frame = Frame::json(
        FrameKind::Error,
        &serde_json::json!({
            "method": "sub", "sid": sub.sid, "code": "not_ready",
            "message": "the chat's book is catching up", "cursor": cursor, "hint": hint,
        }),
    );
    let keep = match frame {
        Ok(frame) => !matches!(
            sub.sink.offer(&sub.sid, frame, Cursor(cursor)),
            Offer::Dropped { .. } | Offer::UnknownSubscription
        ),
        Err(_) => true,
    };
    if !keep {
        state.subs.list.remove(at);
    }
}

/// The chat became ready: every waiting `sub` gets its window or its resume.
pub(super) fn ready(state: &mut ActorState) {
    let mut at = 0;
    while at < state.subs.list.len() {
        let before = state.subs.list.len();
        if matches!(state.subs.list.get(at).map(|sub| &sub.phase), Some(Phase::Waiting { .. })) {
            start(state, at);
        }
        if state.subs.list.len() == before {
            at += 1;
        }
    }
}

fn start(state: &mut ActorState, at: usize) {
    let Some(Subscriber { phase: Phase::Waiting { sub }, .. }) = state.subs.list.get(at) else {
        return;
    };
    let sub = sub.clone();
    match (sub.cursor, sub.edition) {
        (Some(cursor), Some(edition)) if edition == state.edition => {
            if let Some(subscriber) = state.subs.list.get_mut(at) {
                subscriber.phase = Phase::Resuming { cursor, checked: false };
            }
        }
        // A cursor of another edition, or one that names none: a fresh window at the end.
        (Some(_), _) => send_window(state, at, log::Anchor::End, usize::from(sub.window)),
        (None, _) => {
            let anchor = match sub.anchor {
                Some(Anchor::Row { row_id, side }) => log::Anchor::Row {
                    id: row_id,
                    side: match side {
                        AnchorSide::Before => log::Side::Before,
                        AnchorSide::After => log::Side::After,
                        AnchorSide::Around => log::Side::Around,
                    },
                },
                _ => log::Anchor::End,
            };
            send_window(state, at, anchor, usize::from(sub.window));
        }
    }
}

pub(super) fn resume(state: &mut ActorState, conn: u64, sid: &str, cursor: u64) {
    if let Some(sub) = state.subs.list.iter_mut().find(|sub| sub.conn == conn && sub.sid == sid)
        && matches!(sub.phase, Phase::Stopped | Phase::Live)
    {
        sub.phase = Phase::Resuming { cursor, checked: false };
    }
}

pub(super) fn end(state: &mut ActorState, conn: u64, sid: &str) {
    state.subs.list.retain(|sub| !(sub.conn == conn && sub.sid == sid));
}

/// One step for each subscriber with one to take, and the held text when its time came.
pub(super) fn step(state: &mut ActorState) -> Result<(), ChatError> {
    if state.subs.flush_at.is_some_and(|at| at <= Instant::now()) {
        flush_text(state, None);
    }
    if !state.ready {
        return Ok(());
    }
    let mut at = 0;
    while at < state.subs.list.len() {
        let before = state.subs.list.len();
        match state.subs.list.get(at).map(|sub| sub.phase.clone()) {
            Some(Phase::Fresh) => send_window(state, at, log::Anchor::End, MAX_ROWS),
            Some(Phase::Resuming { cursor, checked }) => resume_step(state, at, cursor, checked)?,
            _ => {}
        }
        if state.subs.list.len() == before {
            at += 1;
        }
    }
    Ok(())
}

// ---- windows ----

/// Offers `frame` exact at `cursor`; whether the subscriber stays. `NotFed` stops it.
fn offer(sub: &mut Subscriber, frame: Frame, cursor: u64) -> bool {
    match sub.sink.offer(&sub.sid, frame, Cursor(cursor)) {
        Offer::Taken => {
            sub.taken = cursor;
            true
        }
        Offer::NotFed => {
            sub.phase = Phase::Stopped;
            true
        }
        Offer::Dropped { .. } | Offer::UnknownSubscription => false,
    }
}

/// A read that failed ends the subscription with an error: never an empty window.
fn fail(state: &mut ActorState, at: usize) {
    if at < state.subs.list.len() {
        let sub = state.subs.list.remove(at);
        sub.sink.fail(&sub.sid);
    }
}

fn send_window(state: &mut ActorState, at: usize, anchor: log::Anchor, rows: usize) {
    // Text held for live subscribers goes out first: this window holds it.
    flush_text(state, None);
    let Some(sub) = state.subs.list.get(at) else { return };
    let (sid, person) = (sub.sid.clone(), sub.person);
    match window(state, &sid, &person, anchor, rows) {
        Ok((frame, cursor)) => {
            let edition = state.edition;
            let Some(sub) = state.subs.list.get_mut(at) else { return };
            sub.edition = edition;
            sub.phase = Phase::Live;
            if !offer(sub, frame, cursor) {
                state.subs.list.remove(at);
            }
        }
        Err(_) => fail(state, at),
    }
}

/// The settled rows around `anchor` (the bound is the first PR's one), the open rows, the
/// queue's head, and the person's seen row and open folds, exact at the last seq.
pub(super) fn window(
    state: &mut ActorState,
    sid: &str,
    person: &PersonId,
    anchor: log::Anchor,
    rows: usize,
) -> Result<(Frame, u64), ChatError> {
    let (seen, folds) = person_state(state, person);
    let read = state.log.read_window(
        anchor,
        Log::bound(if rows == 0 { MAX_ROWS } else { rows }, MAX_ROWS),
        MAX_FRAME_BYTES,
        Some(&state.folds),
        &folds,
    )?;
    let rows = row_texts(&read)?;
    let open = open_rows(state)?;
    let queue = queue_head(state);
    let cursor = state.log.last_seq();
    let window = ChatWindow {
        sid: sid.to_owned(),
        cursor,
        edition: state.edition,
        rows,
        has_before: read.has_before,
        has_after: read.has_after,
        open,
        queue,
        seen,
        folds,
        refused: read.refused,
    };
    Ok((Frame::json(FrameKind::Window, &window).map_err(|_| ChatError::Response)?, cursor))
}

fn person_state(state: &ActorState, person: &PersonId) -> (Option<u64>, Vec<u64>) {
    state
        .people
        .iter()
        .find(|known| known.id == *person)
        .map_or((None, Vec::new()), |known| (Some(known.seen), known.folds.clone()))
}

/// The rows a read gave, from the bytes its one checked read holds.
fn row_texts(read: &log::Window) -> Result<Vec<RawJson>, ChatError> {
    read.at
        .iter()
        .map(|range| {
            let bytes = read.bytes.get(range.clone()).ok_or(ChatError::Response)?;
            RawJson::from_bytes(bytes).map_err(|_| ChatError::Response)
        })
        .collect()
}

/// The open rows as a checkpoint holds them: bodies inline while they fit in 64 KB together,
/// the rest as a length read by `blob`.
fn open_rows(state: &mut ActorState) -> Result<Vec<OpenRow>, ChatError> {
    let ids: Vec<u64> = state.translate.open_rows().map(|row| row.id).collect();
    let mut left = OPEN_INLINE;
    let mut out = Vec::with_capacity(ids.len());
    for id in ids {
        if let Some((row, body_len)) = open_row(state, id, &mut left)? {
            out.push(OpenRow {
                row: RawJson::from_bytes(&row).map_err(|_| ChatError::Response)?,
                body_len,
            });
        }
    }
    Ok(out)
}

/// One open row's text: its body inline when it fits `left`, else `{}` and the body's length.
fn open_row(
    state: &ActorState,
    id: u64,
    left: &mut usize,
) -> Result<Option<(Vec<u8>, Option<u64>)>, ChatError> {
    let Some(row) = state.translate.open_rows().find(|row| row.id == id) else {
        return Ok(None);
    };
    let len = state.bodies.get(&id).map_or(2, |body| body.len());
    let mut encoded = Vec::new();
    if len <= *left as u64 {
        let mut body = Vec::with_capacity(len as usize);
        match state.bodies.get(&id) {
            Some(stored) => state.blobs.write_body(stored, &mut body)?,
            None => body.extend_from_slice(b"{}"),
        }
        let text = std::str::from_utf8(&body).map_err(|_| ChatError::Response)?;
        if row.as_row(text).encode(None, &mut encoded).is_ok() {
            *left -= len as usize;
            return Ok(Some((encoded, None)));
        }
        encoded.clear();
    }
    row.as_row("{}").encode(None, &mut encoded).map_err(|_| ChatError::Response)?;
    Ok(Some((encoded, Some(len))))
}

/// The queue's first 64 entries in its order (held ones in their place, with their flag), 1 KB
/// of each text, and the count of all that wait. A source that cannot read a piece of a line
/// (a v1 chat, until its source can) gives the count alone.
fn queue_head(state: &mut ActorState) -> QueueHead {
    let count = u32::try_from(state.translate.queue_len()).unwrap_or(u32::MAX);
    let entries: Vec<QueueEntry> = state.translate.queue().take(MAX_HEADS).copied().collect();
    let mut items = Vec::with_capacity(entries.len());
    for entry in &entries {
        match queue_item(state, entry) {
            Some(item) => items.push(item),
            None => return QueueHead { entries: Vec::new(), count },
        }
    }
    // Only the head's own are kept: at most 64 ids and texts of a kilobyte.
    state.queue_heads.retain(|id_hash, _| entries.iter().any(|entry| entry.id_hash == *id_hash));
    QueueHead { entries: items, count }
}

/// One entry's head, read once for its record, or `None` when the source cannot read a piece
/// of its line. A line that cannot be read gives the entry with no text.
fn queue_item(state: &mut ActorState, entry: &QueueEntry) -> Option<QueueItem> {
    let item = |id: &str, text: &str| QueueItem {
        id: id.to_owned(),
        text: text.to_owned(),
        len: u64::from(entry.text_len),
        held: entry.held(),
        at: entry.at_ms(),
    };
    if let Some((place, id, text)) = state.queue_heads.get(&entry.id_hash)
        && *place == entry.place
    {
        return Some(item(id, text));
    }
    let read = match queue::head(&mut *state.source, entry) {
        Ok(read) => read,
        Err(error) if error.kind() == std::io::ErrorKind::Unsupported => return None,
        Err(_) => item(&format!("#{:016x}", entry.id_hash), ""),
    };
    state.queue_heads.insert(entry.id_hash, (entry.place, read.id.clone(), read.text.clone()));
    Some(read)
}

// ---- the resume ----

fn resume_step(
    state: &mut ActorState,
    at: usize,
    cursor: u64,
    checked: bool,
) -> Result<(), ChatError> {
    if !checked {
        // Missed too much: one fresh window at the end, with no record read to decide it.
        match state.log.resume_size(cursor, MISSED_LIMIT) {
            Ok(log::ResumeSize::Over) => {
                send_window(state, at, log::Anchor::End, MAX_ROWS);
                return Ok(());
            }
            Ok(log::ResumeSize::Within(_)) => {}
            Err(_) => {
                fail(state, at);
                return Ok(());
            }
        }
    }
    let since = match state.log.since(cursor, Log::bound(MAX_FRAME_BYTES, MAX_FRAME_BYTES)) {
        Ok(since) => since,
        Err(_) => {
            fail(state, at);
            return Ok(());
        }
    };
    let mut buffer = Vec::new();
    let mut ranges = Vec::new();
    let mut refused = Vec::new();
    if state.log.fill_checked(&since.rows, &mut buffer, &mut ranges, &mut refused).is_err() {
        fail(state, at);
        return Ok(());
    }
    // A refused record ends the resume: the rows before it go out, then a window, no `end`.
    let stop = since.stopped_on_refusal || !refused.is_empty();
    let mut ops = Vec::new();
    let mut last = cursor;
    let mut ranges = ranges.into_iter();
    for row in &since.rows {
        if refused.contains(&row.row_id) {
            break;
        }
        let Some(range) = ranges.next() else { break };
        let text = buffer.get(range).ok_or(ChatError::Response)?;
        op_row(&mut ops, if row.rev > 1 { "patch" } else { "row" }, row.seq, text, None);
        last = row.seq;
    }
    if !ops.is_empty() {
        let Some(sub) = state.subs.list.get_mut(at) else { return Ok(()) };
        let frame = delta(&sub.sid, Some("replay"), &ops)?;
        if !offer(sub, frame, last) {
            state.subs.list.remove(at);
            return Ok(());
        }
        if matches!(sub.phase, Phase::Stopped) {
            return Ok(());
        }
    }
    if stop {
        send_window(state, at, log::Anchor::End, MAX_ROWS);
        return Ok(());
    }
    if since.more {
        if let Some(sub) = state.subs.list.get_mut(at) {
            sub.phase = Phase::Resuming { cursor: since.cursor, checked: true };
        }
        return Ok(());
    }
    // The log's end: the state frame, and live, in this same step.
    flush_text(state, None);
    let mut ops = Vec::new();
    let seq = state.log.last_seq();
    let ids: Vec<u64> = state.translate.open_rows().map(|row| row.id).collect();
    let mut left = OPEN_INLINE;
    for id in ids {
        if let Some((row, body_len)) = open_row(state, id, &mut left)? {
            op_row(&mut ops, "row", seq, &row, body_len);
        }
    }
    let head = queue_head(state);
    op_queue(&mut ops, seq, None, None, head.count, Some(&head))?;
    let edition = state.edition;
    let Some(sub) = state.subs.list.get_mut(at) else { return Ok(()) };
    let frame = delta(&sub.sid, Some("end"), &ops)?;
    sub.phase = Phase::Live;
    sub.edition = edition;
    if !offer(sub, frame, seq) {
        state.subs.list.remove(at);
    }
    Ok(())
}

// ---- live ops ----

/// A change's ops go out in frames of at most 256 KB: a change that holds more is offered in
/// more than one, in order.
fn room(state: &mut ActorState) {
    if state.subs.ops.len() >= MAX_REPLAY_FRAME_BYTES {
        publish(state);
    }
}

/// A settled row, or a patch: an op with its own seq.
pub(super) fn settled(state: &mut ActorState, kind: &str, seq: u64, text: &[u8], row_id: u64) {
    state.subs.text.remove(&row_id);
    if state.subs.any_live() {
        room(state);
        op_row(&mut state.subs.ops, kind, seq, text, None);
    }
}

/// An open row that began or was set again: offered as it is now, with the last record's seq.
pub(super) fn opened(state: &mut ActorState, row_id: u64) -> Result<(), ChatError> {
    state.subs.text.remove(&row_id);
    if !state.subs.any_live() {
        return Ok(());
    }
    room(state);
    let mut left = OPEN_INLINE;
    if let Some((row, body_len)) = open_row(state, row_id, &mut left)? {
        let seq = state.log.last_seq();
        op_row(&mut state.subs.ops, "row", seq, &row, body_len);
    }
    Ok(())
}

/// Text appended to an open row: held, one piece a row, and offered within 16 ms.
pub(super) fn text(state: &mut ActorState, row_id: u64, value: &str) {
    if !state.subs.any_live() {
        return;
    }
    let inner = value.strip_prefix('"').and_then(|v| v.strip_suffix('"')).unwrap_or(value);
    state.subs.text.entry(row_id).or_default().extend_from_slice(inner.as_bytes());
    state.subs.flush_at.get_or_insert_with(|| Instant::now() + COALESCE);
}

/// The queue changed: its head goes out once, after the batch of lines that changed it, so a
/// `queued` and the `queue_order` behind it are one op.
pub(super) fn queue_changed(state: &mut ActorState) {
    state.subs.queue_changed = true;
}

pub(super) fn queue_publish(state: &mut ActorState) -> Result<(), ChatError> {
    if !std::mem::take(&mut state.subs.queue_changed) || !state.subs.any_live() {
        return Ok(());
    }
    room(state);
    let seq = state.log.last_seq();
    let head = queue_head(state);
    op_queue(&mut state.subs.ops, seq, None, None, head.count, Some(&head))?;
    publish(state);
    Ok(())
}

/// Offers the ops of the change just applied to every live subscriber, encoded once.
pub(super) fn publish(state: &mut ActorState) {
    if state.subs.ops.is_empty() {
        return;
    }
    let ops = std::mem::take(&mut state.subs.ops);
    let seq = state.log.last_seq();
    offer_live(state, &ops, seq);
}

/// Offers the held text, of one row or of all, to every live subscriber.
pub(super) fn flush_text(state: &mut ActorState, row: Option<u64>) {
    let pieces: Vec<(u64, Vec<u8>)> = match row {
        Some(row) => state.subs.text.remove(&row).map(|text| (row, text)).into_iter().collect(),
        None => std::mem::take(&mut state.subs.text).into_iter().collect(),
    };
    if state.subs.text.is_empty() {
        state.subs.flush_at = None;
    }
    if pieces.is_empty() {
        return;
    }
    let seq = state.log.last_seq();
    let mut ops = Vec::new();
    for (row, text) in pieces {
        op_text(&mut ops, seq, row, &text);
    }
    offer_live(state, &ops, seq);
}

fn offer_live(state: &mut ActorState, ops: &[u8], seq: u64) {
    let edition = state.edition;
    let mut at = 0;
    while at < state.subs.list.len() {
        let Some(sub) = state.subs.list.get_mut(at) else { break };
        if !matches!(sub.phase, Phase::Live) {
            at += 1;
            continue;
        }
        if sub.edition != edition {
            sub.phase = Phase::Fresh;
            at += 1;
            continue;
        }
        let keep = match delta(&sub.sid, None, ops) {
            Ok(frame) => offer(sub, frame, seq),
            Err(_) => true,
        };
        if keep {
            at += 1;
        } else {
            state.subs.list.remove(at);
        }
    }
}

// ---- pages and blobs ----

pub(super) fn page(state: &mut ActorState, page: Page, person: PersonId, reply: Reply) {
    if page.edition != Some(state.edition) {
        return reply.error("stale_edition", "the rowId is from another edition of the book");
    }
    let edge = match page.side() {
        Some((PageSide::Before, Position::Row(id))) => log::Edge::Before(*id),
        Some((PageSide::After, Position::Row(id))) => log::Edge::After(*id),
        _ => return reply.error("invalid_params", "a chat page is before or after a rowId"),
    };
    let (_, folds) = person_state(state, &person);
    let max = Log::bound(page.max_bytes as usize, MAX_PAGE_BYTES);
    let read = match state.log.read_page(edge, max, page.fold, Some(&state.folds), &folds) {
        Ok(read) => read,
        Err(error) => return reply.error("read_failed", &error.to_string()),
    };
    let rows = match row_texts(&read) {
        Ok(rows) => rows,
        Err(error) => return reply.error("read_failed", &error.to_string()),
    };
    let result = ChatPageResult {
        sid: page.sid,
        edition: state.edition,
        rows,
        has_before: read.has_before,
        has_after: read.has_after,
        refused: read.refused,
    };
    match Frame::json(FrameKind::Page, &result) {
        Ok(frame) => reply.answer(frame),
        Err(error) => reply.error("read_failed", &error.to_string()),
    }
}

pub(super) fn blob(state: &mut ActorState, blob: Blob, reply: Reply) {
    if blob.edition != state.edition {
        return reply.error("stale_edition", "the blob is from another edition of the book");
    }
    let answer = match (&blob.row_id, &blob.prompt) {
        (Some(row), None) => row_blob(state, &blob, *row),
        (None, Some(prompt)) => prompt_blob(state, &blob, prompt),
        _ => Err(("invalid_params", "a blob names a rowId or a prompt".to_owned())),
    };
    match answer {
        Ok(frame) => reply.answer(frame),
        Err((code, message)) => reply.error(code, &message),
    }
}

type BlobAnswer = Result<Frame, (&'static str, String)>;

fn read_failed(error: impl std::fmt::Display) -> (&'static str, String) {
    ("read_failed", error.to_string())
}

/// A row's range over its body as stored: the body's JSON, `text` escaped once. An open row's
/// reply says how long it holds (`gen`, `fixed`); the text held for the row is offered first.
fn row_blob(state: &mut ActorState, blob: &Blob, row: u64) -> BlobAnswer {
    let start = blob.start.unwrap_or(0);
    let len = Log::bound(usize::try_from(blob.len).unwrap_or(usize::MAX), MAX_BLOB_READ);
    let mut bytes = Vec::new();
    let open = state.translate.open_rows().any(|open| open.id == row);
    let head = if open {
        flush_text(state, Some(row));
        let (total, fixed) = match state.bodies.get(&row) {
            Some(body) => {
                let range = state
                    .blobs
                    .read_open_range(body, start, len, &mut bytes)
                    .map_err(read_failed)?;
                (range.total, range.fixed)
            }
            None => {
                let empty = b"{}";
                let from = usize::try_from(start.min(2)).unwrap_or(2);
                bytes.extend(empty.iter().skip(from).take(len));
                (2, 2)
            }
        };
        BlobHead {
            id: blob.id.clone(),
            start: start.min(total),
            len: bytes.len() as u64,
            total,
            next: None,
            open: true,
            generation: Some(format!("{:016x}", state.generation(row))),
            fixed: Some(fixed),
        }
    } else {
        let total = settled_body(state, row, start, len, &mut bytes)?;
        BlobHead {
            id: blob.id.clone(),
            start: start.min(total),
            len: bytes.len() as u64,
            total,
            next: None,
            open: false,
            generation: None,
            fixed: None,
        }
    };
    blob_frame(&head, &bytes).map_err(read_failed)
}

/// A settled row's body bytes in `[start, start + len)`: one read of `blobs/<rowId>` when the
/// body is out of line, else the body inside the row's record, read and checked once.
fn settled_body(
    state: &mut ActorState,
    row: u64,
    start: u64,
    len: usize,
    out: &mut Vec<u8>,
) -> Result<u64, (&'static str, String)> {
    let Some(reference) = state.log.row(row) else {
        return Err(("unknown_row", format!("row {row} is not in the book")));
    };
    match state.log.read_blob_range(row, start, len, out) {
        Ok(range) => return Ok(range.total),
        Err(log::Error::Io(error)) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(read_failed(error)),
    }
    let mut buffer = Vec::new();
    let mut ranges = Vec::new();
    let mut refused = Vec::new();
    state
        .log
        .fill_checked(&[reference], &mut buffer, &mut ranges, &mut refused)
        .map_err(read_failed)?;
    let text = ranges
        .first()
        .and_then(|range| buffer.get(range.clone()))
        .ok_or_else(|| ("refused", format!("row {row}'s record was refused")))?;
    let body = stored_body(text).ok_or_else(|| read_failed("a row's text has no body"))?;
    let total = body.len() as u64;
    out.clear();
    let from = usize::try_from(start.min(total)).unwrap_or(body.len());
    out.extend(body.iter().skip(from).take(len));
    Ok(total)
}

/// The body's JSON inside a row text written by `Row::encode`: from `"body":` to `,"est":`.
pub(super) fn stored_body(text: &[u8]) -> Option<&[u8]> {
    let head = acpmux_book::row::RowHead::parse(text)?;
    let rest = text.get(head.body_at..)?;
    let end = rest.windows(7).rposition(|window| window == b",\"est\":")?;
    rest.get(..end)
}

fn prompt_blob(state: &mut ActorState, blob: &Blob, prompt: &str) -> BlobAnswer {
    let Some(entry) = state.translate.queued(prompt_hash(prompt)) else {
        return Err(("unknown_prompt", format!("prompt {prompt:?} does not wait")));
    };
    let from = match &blob.from {
        Some(token) => match Token::decode(token) {
            Some(token) => Some(token),
            None => return Err(("invalid_params", "a token is 32 hex digits".into())),
        },
        None => None,
    };
    let len = Log::bound(usize::try_from(blob.len).unwrap_or(usize::MAX), MAX_BLOB_READ) as u64;
    let read = match queue::read_prompt(&mut *state.source, &entry, blob.start, len, from) {
        Ok(Ok(read)) => read,
        Ok(Err(PromptError::BeforeToken)) => {
            return Err(("invalid_params", "the range starts before its token".into()));
        }
        Ok(Err(PromptError::TokenOutside)) => {
            return Err(("invalid_params", "the token is not inside the prompt's line".into()));
        }
        Ok(Err(error)) => return Err(read_failed(format!("{error:?}"))),
        Err(error) => return Err(read_failed(error)),
    };
    let head = BlobHead {
        id: blob.id.clone(),
        start: read.start,
        len: read.bytes.len() as u64,
        total: read.total,
        next: read.next.map(Token::encode),
        open: false,
        generation: None,
        fixed: None,
    };
    blob_frame(&head, &read.bytes).map_err(read_failed)
}

// ---- encoding ----

fn comma(ops: &mut Vec<u8>) {
    if !ops.is_empty() {
        ops.push(b',');
    }
}

fn op_row(ops: &mut Vec<u8>, kind: &str, seq: u64, row: &[u8], body_len: Option<u64>) {
    comma(ops);
    ops.extend_from_slice(b"{\"op\":\"");
    ops.extend_from_slice(kind.as_bytes());
    ops.extend_from_slice(format!("\",\"seq\":{seq},\"row\":").as_bytes());
    ops.extend_from_slice(row);
    if let Some(len) = body_len {
        ops.extend_from_slice(format!(",\"bodyLen\":{len}").as_bytes());
    }
    ops.push(b'}');
}

fn op_text(ops: &mut Vec<u8>, seq: u64, row: u64, escaped: &[u8]) {
    comma(ops);
    ops.extend_from_slice(
        format!("{{\"op\":\"text\",\"seq\":{seq},\"rowId\":{row},\"text\":\"").as_bytes(),
    );
    ops.extend_from_slice(escaped);
    ops.extend_from_slice(b"\"}");
}

fn op_queue(
    ops: &mut Vec<u8>,
    seq: u64,
    entry: Option<&QueueItem>,
    removed: Option<&str>,
    count: u32,
    head: Option<&QueueHead>,
) -> Result<(), ChatError> {
    #[derive(serde::Serialize)]
    struct QueueOp<'a> {
        op: &'static str,
        seq: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        entry: Option<&'a QueueItem>,
        #[serde(skip_serializing_if = "Option::is_none")]
        removed: Option<&'a str>,
        count: u32,
        #[serde(skip_serializing_if = "Option::is_none")]
        head: Option<&'a QueueHead>,
    }
    comma(ops);
    serde_json::to_writer(&mut *ops, &QueueOp { op: "queue", seq, entry, removed, count, head })
        .map_err(|_| ChatError::Response)
}

/// `{sid, replay?, ops}` around ops encoded once.
fn delta(sid: &str, replay: Option<&str>, ops: &[u8]) -> Result<Frame, ChatError> {
    let mut payload = Vec::with_capacity(ops.len() + sid.len() + 48);
    payload.extend_from_slice(b"{\"sid\":");
    serde_json::to_writer(&mut payload, sid).map_err(|_| ChatError::Response)?;
    if let Some(replay) = replay {
        payload.extend_from_slice(b",\"replay\":\"");
        payload.extend_from_slice(replay.as_bytes());
        payload.push(b'"');
    }
    payload.extend_from_slice(b",\"ops\":[");
    payload.extend_from_slice(ops);
    payload.extend_from_slice(b"]}");
    Frame::new(FrameKind::Delta, payload).map_err(|_| ChatError::Response)
}

#[cfg(test)]
mod tests;
