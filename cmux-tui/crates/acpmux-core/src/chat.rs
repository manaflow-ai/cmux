//! One actor and one book for one hydrated chat.
//!
//! The actor is intentionally a blocking owner of `acpmux_book::log::Log`. Its thread is the
//! only place that opens, reads, or appends the book. Requests cross a byte-bounded synchronous
//! mailbox, so a cold page cannot take a process-wide lock and a slow reader cannot make the
//! actor await a client.

use acpmux_book::blobs::{Blobs, Body};
use acpmux_book::checkpoint::{Checkpoint, Cursor, OpenBody, next_edition};
use acpmux_book::folds::Folds;
use acpmux_book::log::{
    self, Anchor as BookAnchor, CheckpointHead, Edge, Error as BookError, Log, Options, RawRange,
    Side,
};
use acpmux_book::row::{Outline, RowKind};
use acpmux_book::translate::{self, BodyField, BodySource, Change, Harness, OwnedRow, State};
use serde_json::value::RawValue;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};
use tokio::sync::mpsc as tokio_mpsc;

use crate::wire::{
    Anchor, AnchorSide, BlobFrame, BlobRequest, ChatDelta, ChatDeltaFrame, ChatRow, ChatWindow,
    Frame, Page, Sub, chat_delta_frame, chat_page_frame, chat_window_frame,
};

pub mod source;

/// A chat mailbox is bounded in approximate encoded bytes. PR 4 adds connection credit; this
/// bound protects the actor before that connection-level budget exists.
pub const MAILBOX_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_SUBSCRIBER_BYTES: usize = 4 * 1024 * 1024;
pub const IDLE_AFTER: Duration = Duration::from_secs(5 * 60);
const TEXT_COALESCE: Duration = Duration::from_millis(16);
const REPLAY_BYTES: usize = 256 * 1024;

#[derive(Clone, Debug)]
pub struct ChatConfig {
    pub id: String,
    pub book: PathBuf,
    pub harness: Harness,
    pub log_options: Options,
    pub boot_id: u64,
    pub source_stamp: u64,
}

impl ChatConfig {
    pub fn new(id: impl Into<String>, book: impl Into<PathBuf>, harness: Harness) -> Self {
        Self {
            id: id.into(),
            book: book.into(),
            harness,
            log_options: Options::default(),
            boot_id: 0,
            source_stamp: 1,
        }
    }
}

#[derive(Debug)]
pub enum ChatError {
    MailboxFull,
    Closed,
    Book(BookError),
    Io(std::io::Error),
    Wire(crate::wire::FrameError),
    Translate(translate::Error),
    Response,
}

impl std::fmt::Display for ChatError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MailboxFull => f.write_str("chat mailbox is full"),
            Self::Closed => f.write_str("chat actor is closed"),
            Self::Book(error) => write!(f, "chat book: {error}"),
            Self::Io(error) => write!(f, "chat actor: {error}"),
            Self::Wire(error) => write!(f, "chat wire: {error}"),
            Self::Translate(error) => write!(f, "chat translate: {error}"),
            Self::Response => f.write_str("chat actor response was dropped"),
        }
    }
}
impl std::error::Error for ChatError {}
impl From<BookError> for ChatError {
    fn from(error: BookError) -> Self {
        Self::Book(error)
    }
}
impl From<std::io::Error> for ChatError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}
impl From<crate::wire::FrameError> for ChatError {
    fn from(error: crate::wire::FrameError) -> Self {
        Self::Wire(error)
    }
}
impl From<translate::Error> for ChatError {
    fn from(error: translate::Error) -> Self {
        Self::Translate(error)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Recovery {
    /// The checkpoint and its tail were opened normally.
    Clean,
    /// A stopped writer left a valid book; the actor can reopen it and replay raw.
    Stopped,
    /// The book has damage that must be rebuilt from raw in the background.
    Rebuild,
}

pub struct ChatSubscription {
    pub window: Frame,
    /// Replay frames are returned before the receiver is installed in the actor. The last one
    /// is marked `replay: "end"`; live frames cannot be sent before it.
    pub replay: Vec<Frame>,
    pub receiver: tokio_mpsc::Receiver<Frame>,
}

pub struct ChatPage {
    pub frame: Frame,
}

pub struct ChatBlob {
    pub frame: BlobFrame,
}

enum Request {
    Line { bytes: Vec<u8>, base_offset: u64, reply: Option<mpsc::Sender<Result<(), ChatError>>> },
    Sub { request: Sub, reply: mpsc::Sender<Result<ChatSubscription, ChatError>> },
    Page { request: Page, reply: mpsc::Sender<Result<ChatPage, ChatError>> },
    Blob { request: BlobRequest, reply: mpsc::Sender<Result<ChatBlob, ChatError>> },
    Close { reply: mpsc::Sender<Result<(), ChatError>> },
}

impl Request {
    fn bytes(&self) -> usize {
        match self {
            Self::Line { bytes, .. } => bytes.len(),
            Self::Sub { request, .. } => request.sid.len() + request.stream.0.len() + 128,
            Self::Page { request, .. } => request.sid.len() + request.stream.0.len() + 128,
            Self::Blob { request, .. } => request.sid.len() + request.stream.0.len() + 128,
            Self::Close { .. } => 16,
        }
    }
}

/// A cheap cloneable mailbox handle. All log access still happens on the actor's thread.
#[derive(Clone)]
pub struct ChatHandle {
    tx: SyncSender<Request>,
    queued: Arc<Mutex<usize>>,
}

impl ChatHandle {
    fn send(&self, request: Request) -> Result<(), ChatError> {
        let bytes = request.bytes();
        {
            let mut queued = self.queued.lock().map_err(|_| ChatError::Closed)?;
            if queued.saturating_add(bytes) > MAILBOX_BYTES {
                return Err(ChatError::MailboxFull);
            }
            *queued = queued.saturating_add(bytes);
        }
        match self.tx.try_send(request) {
            Ok(()) => Ok(()),
            Err(TrySendError::Full(_)) => {
                if let Ok(mut queued) = self.queued.lock() {
                    *queued = queued.saturating_sub(bytes);
                }
                Err(ChatError::MailboxFull)
            }
            Err(TrySendError::Disconnected(_)) => {
                if let Ok(mut queued) = self.queued.lock() {
                    *queued = queued.saturating_sub(bytes);
                }
                Err(ChatError::Closed)
            }
        }
    }

    /// Sends a harness/v1 line without waiting for a client or the actor. The tee uses this
    /// path, so v1 remains the serving implementation while the book is built in the background.
    pub fn try_line(&self, bytes: &[u8], base_offset: u64) -> Result<(), ChatError> {
        self.send(Request::Line { bytes: bytes.to_vec(), base_offset, reply: None })
    }

    pub fn line(&self, bytes: Vec<u8>, base_offset: u64) -> Result<(), ChatError> {
        let (reply_tx, reply_rx) = mpsc::channel();
        self.send(Request::Line { bytes, base_offset, reply: Some(reply_tx) })?;
        reply_rx.recv().map_err(|_| ChatError::Response)?
    }

    pub fn subscribe(&self, request: Sub) -> Result<ChatSubscription, ChatError> {
        let (reply_tx, reply_rx) = mpsc::channel();
        self.send(Request::Sub { request, reply: reply_tx })?;
        reply_rx.recv().map_err(|_| ChatError::Response)?
    }

    pub fn page(&self, request: Page) -> Result<ChatPage, ChatError> {
        let (reply_tx, reply_rx) = mpsc::channel();
        self.send(Request::Page { request, reply: reply_tx })?;
        reply_rx.recv().map_err(|_| ChatError::Response)?
    }

    pub fn blob(&self, request: BlobRequest) -> Result<ChatBlob, ChatError> {
        let (reply_tx, reply_rx) = mpsc::channel();
        self.send(Request::Blob { request, reply: reply_tx })?;
        reply_rx.recv().map_err(|_| ChatError::Response)?
    }

    pub fn close(&self) -> Result<(), ChatError> {
        let (reply_tx, reply_rx) = mpsc::channel();
        self.send(Request::Close { reply: reply_tx })?;
        reply_rx.recv().map_err(|_| ChatError::Response)?
    }
}

pub struct ChatActor {
    pub handle: ChatHandle,
    join: Option<JoinHandle<()>>,
}

impl ChatActor {
    /// Starts a supervised actor. Hydration runs on this dedicated worker, never on a tokio
    /// runtime worker. A panic drops subscribers and reopens from the checkpoint.
    pub fn spawn(config: ChatConfig) -> Self {
        let (tx, rx) = sync_channel(256);
        let queued = Arc::new(Mutex::new(0));
        let handle = ChatHandle { tx, queued: queued.clone() };
        let join = thread::Builder::new()
            .name(format!("acpmux-chat-{}", config.id))
            .spawn(move || run_supervised(config, rx, queued))
            .ok();
        Self { handle, join }
    }

    pub fn join(mut self) {
        let _ = self.handle.close();
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

struct Subscriber {
    sid: String,
    tx: tokio_mpsc::Sender<Frame>,
    queued: usize,
    pending_text: Vec<(u64, u64, String)>,
    text_since: Option<Instant>,
}

struct ActorState {
    config: ChatConfig,
    log: Log,
    blobs: Blobs,
    folds: Folds,
    translate: State,
    bodies: BTreeMap<u64, Body>,
    raw_ranges: BTreeMap<u64, RawRange>,
    raw_file: u32,
    raw_place: u64,
    edition: u32,
    boot_id: u64,
    source_stamp: u64,
    subscribers: Vec<Subscriber>,
    last_used: Instant,
    last_checkpoint: Instant,
    settled_since_checkpoint: u32,
    recovery: Recovery,
}

fn run_supervised(config: ChatConfig, rx: Receiver<Request>, queued: Arc<Mutex<usize>>) {
    let mut first = true;
    loop {
        let mut state = loop {
            let opened = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                open_state(config.clone())
            }));
            match opened {
                Ok(Ok(state)) => break state,
                Ok(Err(ChatError::Book(BookError::Busy))) => {
                    // A handoff can retain the old descriptor briefly. Log::open already waits
                    // 200 ms; retrying here gives the restart path its bounded extra window.
                    thread::sleep(Duration::from_millis(10));
                }
                _ => return,
            }
        };
        if !first {
            state.recovery = Recovery::Stopped;
        }
        first = false;
        let run = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            run_once(&mut state, &rx, &queued)
        }));
        if matches!(run, Ok(true)) {
            return;
        }
    }
}

fn open_state(config: ChatConfig) -> Result<ActorState, ChatError> {
    let (log, recovered, rebuilt_edition) = match Log::open(&config.book, config.log_options) {
        Ok(opened) => (opened.0, opened.1, None),
        Err(BookError::Rebuild(_)) => {
            // A damaged or unknown checkpoint cannot be trusted, but the raw source and settled
            // segments remain useful. Reopen without the checkpoint, replay raw from byte zero,
            // and publish a fresh edition before serving the actor.
            let old_edition = CheckpointHead::read(&config.book)?.map(|head| head.edition);
            let opened = Log::open_without_checkpoint(&config.book, config.log_options)?;
            (opened.0, opened.1, Some(next_edition(old_edition, || 1)))
        }
        Err(error) => return Err(ChatError::Book(error)),
    };
    open_state_from_log(config, log, recovered, rebuilt_edition)
}

fn open_state_from_log(
    config: ChatConfig,
    log: Log,
    recovered: log::Recovered,
    rebuilt_edition: Option<u32>,
) -> Result<ActorState, ChatError> {
    let configured_source_stamp = config.source_stamp;
    let saved_checkpoint = if recovered.checkpoint {
        Some(Checkpoint::from_recovered(&recovered).map_err(ChatError::Book)?)
    } else {
        None
    };
    let translate = match saved_checkpoint.as_ref() {
        Some(checkpoint) if !checkpoint.translator.is_empty() => {
            State::restore(&checkpoint.translator)?
        }
        _ => State::default(),
    };
    let fold_len = saved_checkpoint.as_ref().map_or(0, |checkpoint| checkpoint.folds_len);
    let folds = Folds::open(&config.book.join("folds.idx"), fold_len)?;
    let mut bodies = BTreeMap::new();
    let mut raw_ranges = BTreeMap::new();
    if let Some(checkpoint) = &saved_checkpoint {
        for open in &checkpoint.open {
            bodies.insert(open.body.row, open.body.clone());
            raw_ranges.insert(open.body.row, open.raw);
        }
    }
    let mut blobs = Blobs::open(&config.book)?;
    blobs.recover(
        &bodies.values().cloned().collect::<Vec<_>>(),
        saved_checkpoint.as_ref().map_or(0, |c| c.last_row),
    )?;
    let mut actor = ActorState {
        config,
        log,
        blobs,
        folds,
        translate,
        bodies,
        raw_ranges,
        raw_file: recovered.raw_files,
        raw_place: recovered.raw_map_len,
        edition: rebuilt_edition.unwrap_or_else(|| {
            saved_checkpoint.as_ref().map_or(recovered.edition.max(1), |c| c.edition)
        }),
        boot_id: saved_checkpoint.as_ref().map_or(0, |c| c.boot_id),
        source_stamp: configured_source_stamp,
        subscribers: Vec::new(),
        last_used: Instant::now(),
        last_checkpoint: Instant::now(),
        settled_since_checkpoint: 0,
        recovery: if rebuilt_edition.is_some() {
            Recovery::Rebuild
        } else if recovered.checkpoint {
            Recovery::Clean
        } else {
            Recovery::Stopped
        },
    };
    let stamp_changed = saved_checkpoint.as_ref().is_some_and(|checkpoint| {
        checkpoint.boot_id != actor.config.boot_id
            || checkpoint.cursors.iter().any(|cursor| cursor.stamp != actor.source_stamp)
    });
    if stamp_changed {
        actor.edition = next_edition(Some(actor.edition), || 1);
        actor.boot_id = actor.config.boot_id;
    }
    let raw_tail = actor.log.raw_tail(recovered.raw_files, recovered.raw_map_len)?;
    let replayed_raw = !raw_tail.is_empty();
    for (file, offset, bytes) in raw_tail {
        apply_replayed_line(&mut actor, &bytes, file, offset)?;
    }
    if rebuilt_edition.is_some() || recovered.replayed != 0 || replayed_raw || stamp_changed {
        checkpoint(&mut actor)?;
    }
    Ok(actor)
}

fn run_once(state: &mut ActorState, rx: &Receiver<Request>, queued: &Arc<Mutex<usize>>) -> bool {
    loop {
        let wait = state
            .subscribers
            .iter()
            .filter_map(|subscriber| {
                subscriber.text_since.map(|at| TEXT_COALESCE.saturating_sub(at.elapsed()))
            })
            .min()
            .unwrap_or(IDLE_AFTER);
        let request = match rx.recv_timeout(wait) {
            Ok(request) => request,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                flush_text(state, true);
                if state.subscribers.is_empty()
                    && state.translate.open_rows().next().is_none()
                    && state.last_used.elapsed() >= IDLE_AFTER
                {
                    let _ = checkpoint(state);
                    return true;
                }
                continue;
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => return true,
        };
        flush_text(state, false);
        let bytes = request.bytes();
        if let Ok(mut queued) = queued.lock() {
            *queued = queued.saturating_sub(bytes);
        }
        state.last_used = Instant::now();
        let stop = match request {
            Request::Line { bytes, base_offset, reply } => {
                let result = apply_line(state, &bytes, base_offset);
                let stopped = matches!(&result, Err(ChatError::Book(BookError::Stopped)));
                if let Some(reply) = reply {
                    let _ = reply.send(result);
                }
                if stopped {
                    return false;
                }
                false
            }
            Request::Sub { request, reply } => {
                let result = subscribe(state, request);
                let _ = reply.send(result);
                false
            }
            Request::Page { request, reply } => {
                let result = page(state, request);
                let _ = reply.send(result);
                false
            }
            Request::Blob { request, reply } => {
                let result = blob(state, request);
                let _ = reply.send(result);
                false
            }
            Request::Close { reply } => {
                flush_text(state, true);
                let result = checkpoint(state);
                let _ = reply.send(result);
                true
            }
        };
        if stop {
            return true;
        }
    }
}

fn anchor(anchor: Option<Anchor>) -> BookAnchor {
    match anchor.unwrap_or(Anchor::End) {
        Anchor::End => BookAnchor::End,
        Anchor::Row { row_id, side } => BookAnchor::Row {
            id: row_id,
            side: match side {
                AnchorSide::Before => Side::Before,
                AnchorSide::After => Side::After,
                AnchorSide::Around => Side::Around,
            },
        },
        Anchor::List { .. } => BookAnchor::End,
    }
}

fn row_text(log: &mut Log, refs: &[log::RowRef]) -> Result<Vec<ChatRow>, ChatError> {
    let mut bytes = Vec::new();
    let mut ranges = Vec::new();
    match log.fill(refs, &mut bytes, &mut ranges) {
        Ok(_) => refs
            .iter()
            .zip(ranges)
            .map(|(reference, range)| {
                let text = bytes.get(range).ok_or(ChatError::Closed)?;
                let raw = RawValue::from_string(
                    String::from_utf8(text.to_vec()).map_err(|_| ChatError::Closed)?,
                )
                .map_err(|_| ChatError::Closed)?;
                Ok(ChatRow { id: reference.row_id, rev: reference.rev, text: raw })
            })
            .collect(),
        Err(BookError::CorruptRow { .. }) => {
            // A damaged record must not hide its neighbours. The book is rebuilt from raw by
            // the recovery owner; until then, isolate the bad row and serve the rest.
            let mut rows = Vec::with_capacity(refs.len());
            for reference in refs {
                let one = std::slice::from_ref(reference);
                let mut bytes = Vec::new();
                let mut ranges = Vec::new();
                match log.fill(one, &mut bytes, &mut ranges) {
                    Ok(_) => {
                        let Some(range) = ranges.into_iter().next() else { continue };
                        let Some(text) = bytes.get(range) else { continue };
                        let raw = RawValue::from_string(
                            String::from_utf8(text.to_vec()).map_err(|_| ChatError::Closed)?,
                        )
                        .map_err(|_| ChatError::Closed)?;
                        rows.push(ChatRow { id: reference.row_id, rev: reference.rev, text: raw });
                    }
                    Err(BookError::CorruptRow { .. }) => continue,
                    Err(error) => return Err(error.into()),
                }
            }
            Ok(rows)
        }
        Err(error) => Err(error.into()),
    }
}

fn open_row(state: &ActorState, row: &OwnedRow) -> Result<ChatRow, ChatError> {
    let mut encoded = Vec::new();
    let body = state.bodies.get(&row.id);
    let mut body_bytes = Vec::new();
    if let Some(body) = body {
        state.blobs.write_body(body, &mut body_bytes)?;
    } else {
        body_bytes.extend_from_slice(b"{}");
    }
    let body = std::str::from_utf8(&body_bytes).map_err(|_| ChatError::Closed)?;
    row.as_row(body).encode(None, &mut encoded).map_err(|_| ChatError::Closed)?;
    let raw = RawValue::from_string(String::from_utf8(encoded).map_err(|_| ChatError::Closed)?)
        .map_err(|_| ChatError::Closed)?;
    Ok(ChatRow { id: row.id, rev: row.rev, text: raw })
}

fn subscribe(state: &mut ActorState, request: Sub) -> Result<ChatSubscription, ChatError> {
    let cursor = request.cursor.as_ref().map(|cursor| cursor.0).unwrap_or(state.log.last_seq());
    let wanted = usize::from(request.window.unwrap_or(100)).clamp(1, 400);
    let window = state.log.window(anchor(request.anchor), wanted, log::MAX_PAGE_BYTES);
    let rows = row_text(&mut state.log, &window.rows)?;
    let open = state
        .translate
        .open_rows()
        .map(|row| open_row(state, row))
        .collect::<Result<Vec<_>, _>>()?;
    let wire = ChatWindow {
        sid: request.sid.clone(),
        cursor: state.log.last_seq(),
        rows,
        open: open.clone(),
        has_before: window.has_before,
        has_after: window.has_after,
        queue: Vec::new(),
        queue_count: 0,
    };
    let window_frame = chat_window_frame(&wire)?;
    let mut replay = Vec::new();
    if request.cursor.is_some() {
        let mut next_cursor = cursor;
        loop {
            let since = state.log.since(next_cursor, REPLAY_BYTES)?;
            let rows = row_text(&mut state.log, &since.rows)?;
            let mut ops = Vec::new();
            for (reference, row) in since.rows.iter().zip(rows) {
                let candidate =
                    ChatDelta::Row { sid: request.sid.clone(), seq: reference.seq, row };
                ops.push(candidate);
                let frame = chat_delta_frame(&ChatDeltaFrame {
                    sid: request.sid.clone(),
                    ops: ops.clone(),
                    replay: Some("replay".into()),
                    open: Vec::new(),
                    queue: Vec::new(),
                })?;
                if frame.encoded_len() > REPLAY_BYTES && !ops.is_empty() {
                    let Some(last) = ops.pop() else {
                        return Err(ChatError::Closed);
                    };
                    if !ops.is_empty() {
                        replay.push(chat_delta_frame(&ChatDeltaFrame {
                            sid: request.sid.clone(),
                            ops,
                            replay: Some("replay".into()),
                            open: Vec::new(),
                            queue: Vec::new(),
                        })?);
                    }
                    ops = vec![last];
                }
            }
            if !ops.is_empty() {
                replay.push(chat_delta_frame(&ChatDeltaFrame {
                    sid: request.sid.clone(),
                    ops,
                    replay: Some("replay".into()),
                    open: Vec::new(),
                    queue: Vec::new(),
                })?);
            }
            next_cursor = since.cursor;
            if !since.more || next_cursor <= cursor {
                break;
            }
        }
        replay.push(chat_delta_frame(&ChatDeltaFrame {
            sid: request.sid.clone(),
            ops: Vec::new(),
            replay: Some("end".into()),
            open,
            queue: Vec::new(),
        })?);
    }
    let (tx, receiver) = tokio_mpsc::channel(64);
    state.subscribers.push(Subscriber {
        sid: request.sid,
        tx,
        queued: 0,
        pending_text: Vec::new(),
        text_since: None,
    });
    Ok(ChatSubscription { window: window_frame, replay, receiver })
}

fn page(state: &mut ActorState, request: Page) -> Result<ChatPage, ChatError> {
    let (side, position) = request.side().ok_or(ChatError::Closed)?;
    let mut row_id = match position {
        crate::wire::Position::Row(id) => *id,
        crate::wire::Position::List(_) => return Err(ChatError::Closed),
    };
    if let Some(group) = request.fold
        && let Some(fold) = state.folds.containing(group)?
    {
        row_id = if side == crate::wire::PageSide::Before {
            fold.last.saturating_add(1)
        } else {
            fold.group
        };
    }
    let window = state.log.page(
        if side == crate::wire::PageSide::Before {
            Edge::Before(row_id)
        } else {
            Edge::After(row_id)
        },
        request.max_bytes as usize,
    );
    let rows = row_text(&mut state.log, &window.rows)?;
    Ok(ChatPage {
        frame: chat_page_frame(&ChatWindow {
            sid: request.sid,
            cursor: state.log.last_seq(),
            rows,
            open: Vec::new(),
            has_before: window.has_before,
            has_after: window.has_after,
            queue: Vec::new(),
            queue_count: 0,
        })?,
    })
}

fn blob(state: &mut ActorState, request: BlobRequest) -> Result<ChatBlob, ChatError> {
    let row_id = request.row_id.ok_or(ChatError::Closed)?;
    let mut bytes = Vec::new();
    let total =
        state.log.read_blob(row_id, request.offset, request.max_bytes as usize, &mut bytes)?;
    Ok(ChatBlob {
        frame: BlobFrame { sid: request.sid, offset: request.offset, total_bytes: total, bytes },
    })
}

fn apply_line(state: &mut ActorState, bytes: &[u8], base_offset: u64) -> Result<(), ChatError> {
    let file = state.log.append_raw_file(bytes)?;
    state.raw_file = file;
    state.raw_place = base_offset.saturating_add(bytes.len() as u64).saturating_add(1);
    apply_ops(state, bytes, file, base_offset, true)
}

fn apply_replayed_line(
    state: &mut ActorState,
    bytes: &[u8],
    file: u32,
    base_offset: u64,
) -> Result<(), ChatError> {
    state.raw_file = file;
    state.raw_place = base_offset.saturating_add(bytes.len() as u64).saturating_add(1);
    apply_ops(state, bytes, file, base_offset, false)
}

fn apply_ops(
    state: &mut ActorState,
    bytes: &[u8],
    file: u32,
    base_offset: u64,
    checkpoint_now: bool,
) -> Result<(), ChatError> {
    let before = state.log.last_seq();
    let ops = translate::translate(&mut state.translate, state.config.harness, bytes)?;
    for op in ops {
        let raw = RawRange {
            file,
            off: base_offset.saturating_add(op.raw.offset as u64),
            len: op.raw.length as u32,
        };
        match op.change {
            Change::Row(row) => settle_or_open(state, row, raw)?,
            Change::Patch(row) => patch(state, row, raw)?,
            Change::Body { id, field, append, source } => {
                let value = match &source {
                    BodySource::Text(text) => {
                        serde_json::to_string(text).map_err(|_| ChatError::Closed)?
                    }
                    BodySource::Input(range) => {
                        let end = range.offset.saturating_add(range.length);
                        let bytes = bytes.get(range.offset..end).ok_or(ChatError::Closed)?;
                        std::str::from_utf8(bytes).map_err(|_| ChatError::Closed)?.to_owned()
                    }
                };
                let key = body_key(field);
                let body =
                    state.bodies.entry(id).or_insert(Body::new(id).map_err(ChatError::Book)?);
                state.blobs.set(body, key, &value, append)?;
                state.raw_ranges.entry(id).or_insert(raw);
                if let BodySource::Text(text) = &source {
                    let seq = state.log.last_seq();
                    broadcast(
                        state,
                        ChatDelta::Text { sid: String::new(), seq, row_id: id, text: text.clone() },
                    );
                }
            }
        }
    }
    state.settled_since_checkpoint = state
        .settled_since_checkpoint
        .saturating_add(state.log.last_seq().saturating_sub(before) as u32);
    if checkpoint_now
        && (state.translate.open_rows().next().is_none()
            || state.settled_since_checkpoint >= 256
            || state.last_checkpoint.elapsed() >= Duration::from_secs(1))
    {
        checkpoint(state)?;
    }
    Ok(())
}

fn settle_or_open(state: &mut ActorState, row: OwnedRow, raw: RawRange) -> Result<(), ChatError> {
    let body = state.bodies.entry(row.id).or_insert(Body::new(row.id).map_err(ChatError::Book)?);
    let mut body_bytes = Vec::new();
    state.blobs.write_body(body, &mut body_bytes)?;
    let body_text = std::str::from_utf8(&body_bytes).map_err(|_| ChatError::Closed)?;
    let mut encoded = Vec::new();
    row.as_row(body_text).encode(None, &mut encoded).map_err(|_| ChatError::Closed)?;
    if row.open {
        state.raw_ranges.insert(row.id, raw);
        let seq = state.log.last_seq();
        broadcast(
            state,
            ChatDelta::Row { sid: String::new(), seq, row: chat_row(row.id, row.rev, encoded)? },
        );
        return Ok(());
    }
    let final_bytes = state.blobs.settle(body)?;
    if final_bytes.is_none() {
        let outline = Outline { head: "{}", preview: "" };
        encoded.clear();
        row.as_row("{}")
            .encode_blob(body.len(), outline, &mut encoded)
            .map_err(|_| ChatError::Closed)?;
    } else if let Some(bytes) = final_bytes {
        encoded.clear();
        let text = std::str::from_utf8(&bytes).map_err(|_| ChatError::Closed)?;
        row.as_row(text).encode(None, &mut encoded).map_err(|_| ChatError::Closed)?;
    }
    let seq = match state.log.append_settled(row.id, row.rev, raw, &encoded) {
        Ok(seq) => seq,
        Err(BookError::AlreadySettled { .. }) | Err(BookError::StaleRev { .. }) => {
            state.log.last_seq()
        }
        Err(error) => return Err(error.into()),
    };
    if row.kind == RowKind::Group
        && let Some(last) = row.fields.get("last").and_then(|last| last.parse::<u64>().ok())
    {
        // The replay after a checkpoint cuts the derived index first. It must append this
        // group again even when the record itself already settled before the kill.
        if state.folds.append(row.id, last).is_ok() {
            let _ = state.folds.sync();
        }
    }
    state.bodies.remove(&row.id);
    state.raw_ranges.remove(&row.id);
    broadcast(
        state,
        ChatDelta::Row { sid: String::new(), seq, row: chat_row(row.id, row.rev, encoded)? },
    );
    Ok(())
}

fn patch(state: &mut ActorState, row: OwnedRow, raw: RawRange) -> Result<(), ChatError> {
    let mut encoded = Vec::new();
    let body = state.bodies.get(&row.id);
    let body_text = if let Some(body) = body {
        let mut bytes = Vec::new();
        state.blobs.write_body(body, &mut bytes)?;
        String::from_utf8(bytes).map_err(|_| ChatError::Closed)?
    } else {
        "{}".into()
    };
    let body = body_text;
    row.as_row(&body).encode(None, &mut encoded).map_err(|_| ChatError::Closed)?;
    let seq = match state.log.patch(row.id, row.rev, raw, &encoded) {
        Ok(seq) => seq,
        Err(BookError::StaleRev { .. }) | Err(BookError::AlreadySettled { .. }) => {
            state.log.last_seq()
        }
        Err(error) => return Err(error.into()),
    };
    broadcast(
        state,
        ChatDelta::Patch { sid: String::new(), seq, row: chat_row(row.id, row.rev, encoded)? },
    );
    Ok(())
}

fn chat_row(id: u64, rev: u32, bytes: Vec<u8>) -> Result<ChatRow, ChatError> {
    let raw = RawValue::from_string(String::from_utf8(bytes).map_err(|_| ChatError::Closed)?)
        .map_err(|_| ChatError::Closed)?;
    Ok(ChatRow { id, rev, text: raw })
}

fn broadcast(state: &mut ActorState, operation: ChatDelta) {
    let mut dead = Vec::new();
    for (index, subscriber) in state.subscribers.iter_mut().enumerate() {
        let sid = subscriber.sid.clone();
        if let ChatDelta::Text { seq, row_id, text, .. } = &operation {
            if let Some((_, _, existing)) =
                subscriber.pending_text.iter_mut().find(|(id, _, _)| id == row_id)
            {
                existing.push_str(text);
            } else {
                subscriber.pending_text.push((*row_id, *seq, text.clone()));
            }
            subscriber.text_since.get_or_insert_with(Instant::now);
            continue;
        }
        flush_subscriber_text(subscriber);
        let operation = match operation.clone() {
            ChatDelta::Row { seq, row, .. } => ChatDelta::Row { sid: sid.clone(), seq, row },
            ChatDelta::Text { seq, row_id, text, .. } => {
                ChatDelta::Text { sid: sid.clone(), seq, row_id, text }
            }
            ChatDelta::Patch { seq, row, .. } => ChatDelta::Patch { sid: sid.clone(), seq, row },
            ChatDelta::Queue { seq, entry, queue_count, .. } => {
                ChatDelta::Queue { sid: sid.clone(), seq, entry, queue_count }
            }
            ChatDelta::Gone { seq, .. } => ChatDelta::Gone { sid: sid.clone(), seq },
        };
        let Ok(frame) = chat_delta_frame(&ChatDeltaFrame {
            sid,
            ops: vec![operation],
            replay: None,
            open: Vec::new(),
            queue: Vec::new(),
        }) else {
            dead.push(index);
            continue;
        };
        let bytes = frame.encoded_len();
        if subscriber.queued.saturating_add(bytes) > MAX_SUBSCRIBER_BYTES
            || subscriber.tx.try_send(frame).is_err()
        {
            dead.push(index);
        } else {
            subscriber.queued = subscriber.queued.saturating_add(bytes);
        }
    }
    for index in dead.into_iter().rev() {
        state.subscribers.swap_remove(index);
    }
}

fn flush_subscriber_text(subscriber: &mut Subscriber) {
    if subscriber.pending_text.is_empty() {
        subscriber.text_since = None;
        return;
    }
    let sid = subscriber.sid.clone();
    let ops = subscriber
        .pending_text
        .drain(..)
        .map(|(row_id, seq, text)| ChatDelta::Text { sid: sid.clone(), seq, row_id, text })
        .collect();
    subscriber.text_since = None;
    if let Ok(frame) = chat_delta_frame(&ChatDeltaFrame {
        sid,
        ops,
        replay: None,
        open: Vec::new(),
        queue: Vec::new(),
    }) {
        let bytes = frame.encoded_len();
        if subscriber.queued.saturating_add(bytes) <= MAX_SUBSCRIBER_BYTES
            && subscriber.tx.try_send(frame).is_ok()
        {
            subscriber.queued = subscriber.queued.saturating_add(bytes);
        }
    }
}

fn flush_text(state: &mut ActorState, force: bool) {
    for subscriber in &mut state.subscribers {
        if force || subscriber.text_since.is_some_and(|at| at.elapsed() >= TEXT_COALESCE) {
            flush_subscriber_text(subscriber);
        }
    }
}

fn body_key(field: BodyField) -> &'static str {
    match field {
        BodyField::Text => "text",
        BodyField::Content => "content",
        BodyField::Input => "input",
        BodyField::Entries => "entries",
        BodyField::Source => "source",
        BodyField::Images => "images",
        BodyField::Title => "title",
    }
}

fn checkpoint(state: &mut ActorState) -> Result<(), ChatError> {
    let mut checkpoint = Checkpoint::new(translate::VERSION);
    checkpoint.edition = state.edition.max(1);
    checkpoint.boot_id = state.boot_id;
    checkpoint.translator = state.translate.checkpoint()?;
    checkpoint.last_row = state.translate.last_row_id();
    checkpoint.folds_len = state.folds.len();
    if state.raw_file != 0 {
        checkpoint.cursors.push(Cursor {
            file: state.raw_file,
            place: state.raw_place,
            stamp: state.source_stamp,
        });
    }
    for row in state.translate.open_rows() {
        let body = state
            .bodies
            .get(&row.id)
            .cloned()
            .map_or_else(|| Body::new(row.id), Ok)
            .map_err(ChatError::Book)?;
        checkpoint.open.push(OpenBody {
            body,
            raw: state.raw_ranges.get(&row.id).copied().unwrap_or(RawRange::NONE),
        });
    }
    let bodies = checkpoint.open.iter().map(|open| &open.body).collect::<Vec<_>>();
    state.blobs.sync(bodies.iter().copied())?;
    state.folds.sync()?;
    let open = checkpoint.open.iter().map(|open| open.body.row).collect::<Vec<_>>();
    checkpoint.write(&mut state.log, &open)?;
    state.last_checkpoint = Instant::now();
    state.settled_since_checkpoint = 0;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn actor_books_a_line_and_resumes_before_live_frames() {
        let dir = tempfile::tempdir().unwrap();
        let actor = ChatActor::spawn(ChatConfig::new("chat", dir.path(), Harness::V1));
        let line = br#"{"kind":"prompt","id":"p1","text":"hello"}"#;
        let _ = actor.handle.try_line(line, 0);
        let subscription =
            actor.handle.subscribe(Sub::new("s", "chat:chat").from_cursor(0)).unwrap();
        let replay = subscription.replay;
        assert!(
            replay
                .last()
                .and_then(|frame| frame.decode_json::<ChatDeltaFrame>().ok())
                .and_then(|frame| frame.replay)
                .as_deref()
                == Some("end")
        );
        actor.join();
        thread::sleep(Duration::from_millis(1));
    }

    #[test]
    fn actor_rebuilds_from_raw_after_a_damaged_checkpoint() {
        let dir = tempfile::tempdir().unwrap();
        let config = ChatConfig::new("chat", dir.path(), Harness::V1);
        let actor = ChatActor::spawn(config.clone());
        actor.handle.try_line(br#"{"kind":"prompt","id":"p1","text":"hello"}"#, 0).unwrap();
        actor.join();

        let checkpoint = dir.path().join("checkpoint");
        let mut bytes = std::fs::read(&checkpoint).unwrap();
        let last = bytes.len().saturating_sub(1);
        if let Some(byte) = bytes.get_mut(last) {
            *byte ^= 1;
        }
        std::fs::write(checkpoint, bytes).unwrap();

        let rebuilt = ChatActor::spawn(config);
        let subscription =
            rebuilt.handle.subscribe(Sub::new("s", "chat:chat").from_cursor(0)).unwrap();
        assert!(
            subscription.replay.iter().any(|frame| frame.decode_json::<ChatDeltaFrame>().is_ok())
        );
        rebuilt.join();
    }
}

#[cfg(all(test, target_os = "linux"))]
mod v2_pr03_gate_tests {
    //! Release measurements are ignored during ordinary test runs and are invoked once by the
    //! Linux gate harness with the shared god/small fixtures. Keeping one named test per measure
    //! makes the registry's seven PR 3 numbers auditable.

    fn gate(name: &str) {
        // The release harness supplies measured p95s. Never write a placeholder: an absent line
        // keeps this registry row skipped instead of turning a smoke test into a green gate.
        let Ok(path) = std::env::var("V2_GATE_OUT") else { return };
        let key = name.replace('.', "_");
        let Some(small) = std::env::var_os(format!("V2_GATE_{key}_SMALL_P95")) else { return };
        let Some(god) = std::env::var_os(format!("V2_GATE_{key}_GOD_P95")) else { return };
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
        writeln!(
            file,
            "{{\"name\":\"{name}\",\"small_p95\":{},\"god_p95\":{},\"unit\":\"ms\"}}",
            small.to_string_lossy(),
            god.to_string_lossy()
        )
        .unwrap();
    }

    #[test]
    #[ignore]
    fn v2_pr03_window_cold() {
        gate("v2.pr03.window_cold");
    }
    #[test]
    #[ignore]
    fn v2_pr03_fold_window() {
        gate("v2.pr03.fold_window");
    }
    #[test]
    #[ignore]
    fn v2_pr03_resume_missed() {
        gate("v2.pr03.resume_missed");
    }
    #[test]
    #[ignore]
    fn v2_pr03_rss_subscribed() {
        gate("v2.pr03.rss_subscribed");
    }
    #[test]
    #[ignore]
    fn v2_pr03_append_behind_page() {
        gate("v2.pr03.append_behind_page");
    }
    #[test]
    #[ignore]
    fn v2_pr03_replay_kill() {
        gate("v2.pr03.replay_kill");
    }
    #[test]
    #[ignore]
    fn v2_pr03_resume_live() {
        gate("v2.pr03.resume_live");
    }
}
