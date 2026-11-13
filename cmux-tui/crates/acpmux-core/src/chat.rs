//! One actor and one book for one hydrated chat.
//!
//! The actor is intentionally a blocking owner of `acpmux_book::log::Log`. Its thread is the
//! only place that opens, reads, or appends the book. Requests cross a byte-bounded synchronous
//! mailbox, so a cold page cannot take a process-wide lock and a slow reader cannot make the
//! actor await a client.

use acpmux_book::blobs::{Blobs, Body};
use acpmux_book::checkpoint::{Checkpoint, Cursor, OpenBody, next_edition};
use acpmux_book::folds::Folds;
use acpmux_book::log::{self, Error as BookError, Log, Options, RawRange};
use acpmux_book::row::{Outline, RowKind};
use acpmux_book::translate::{self, BodyField, BodySource, Change, Harness, OwnedRow, State};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

pub mod source;

pub type SourceFactory = Arc<dyn Fn() -> std::io::Result<Box<dyn source::RawSource>> + Send + Sync>;

struct EmptySource;

impl source::RawSource for EmptySource {
    fn read_chunk(&mut self, place: u64) -> std::io::Result<source::Chunk> {
        Ok(source::Chunk::with_stamp(Vec::new(), place, source::byte_places, true, place, 1))
    }

    fn holds(&mut self, _place: u64) -> std::io::Result<bool> {
        Ok(true)
    }

    fn hint(&self) -> std::io::Result<u64> {
        Ok(0)
    }

    fn sync_through(&mut self, _place: u64) -> std::io::Result<()> {
        Ok(())
    }

    fn identity(&self) -> &[u8] {
        b"empty"
    }

    fn stamp(&self) -> u64 {
        1
    }
}

/// A chat mailbox is bounded in approximate encoded bytes. PR 4 adds connection credit; this
/// bound protects the actor before that connection-level budget exists.
pub const MAILBOX_BYTES: usize = 4 * 1024 * 1024;
pub const IDLE_AFTER: Duration = Duration::from_secs(5 * 60);

#[derive(Clone)]
pub struct ChatConfig {
    pub id: String,
    pub book: PathBuf,
    pub harness: Harness,
    pub log_options: Options,
    pub boot_id: u64,
    pub source_stamp: u64,
    pub source_factory: SourceFactory,
    pub edition_random: Arc<dyn Fn() -> u32 + Send + Sync>,
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
            source_factory: Arc::new(|| Ok(Box::new(EmptySource))),
            edition_random: Arc::new(|| 1),
        }
    }

    pub fn with_source_factory(mut self, source_factory: SourceFactory) -> Self {
        self.source_factory = source_factory;
        self
    }

    pub fn with_edition_random(
        mut self,
        edition_random: Arc<dyn Fn() -> u32 + Send + Sync>,
    ) -> Self {
        self.edition_random = edition_random;
        self
    }
}

#[derive(Debug)]
pub enum ChatError {
    MailboxFull,
    Closed,
    Book(BookError),
    Io(std::io::Error),
    Translate(translate::Error),
    Response,
    SourceChanged,
}

impl std::fmt::Display for ChatError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MailboxFull => f.write_str("chat mailbox is full"),
            Self::Closed => f.write_str("chat actor is closed"),
            Self::Book(error) => write!(f, "chat book: {error}"),
            Self::Io(error) => write!(f, "chat actor: {error}"),
            Self::Translate(error) => write!(f, "chat translate: {error}"),
            Self::Response => f.write_str("chat actor response was dropped"),
            Self::SourceChanged => f.write_str("chat source stamp changed"),
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

enum Request {
    Wake,
    Close { reply: mpsc::Sender<Result<(), ChatError>> },
}

impl Request {
    fn bytes(&self) -> usize {
        16
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

    /// Wakes the actor to read one bounded source chunk.
    pub fn wake(&self) -> Result<(), ChatError> {
        self.send(Request::Wake)
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
    /// runtime worker. A panic reopens from the checkpoint.
    pub fn spawn(config: ChatConfig) -> Self {
        let (tx, rx) = sync_channel(256);
        let queued = Arc::new(Mutex::new(0));
        let handle = ChatHandle { tx, queued: queued.clone() };
        let join = thread::Builder::new()
            .name(format!("acpmux-chat-{}", config.id))
            .spawn(move || {
                let Ok(runtime) =
                    tokio::runtime::Builder::new_current_thread().enable_time().build()
                else {
                    return;
                };
                let scope = cmux_scope::Scope::new("acpmux-chat");
                let (health, _) = tokio::sync::watch::channel(crate::life::Health::Starting);
                let mut receiver = Some(rx);
                let _ = runtime.block_on(crate::life::supervise(
                    &scope,
                    move || {
                        let receiver = receiver.take();
                        let config = config.clone();
                        let queued = queued.clone();
                        async move {
                            let Some(receiver) = receiver else {
                                return Err(ChatError::Closed);
                            };
                            tokio::task::spawn_blocking(move || {
                                run_supervised(config, receiver, queued);
                            })
                            .await
                            .map_err(|_| ChatError::Closed)
                        }
                    },
                    crate::life::Policy::default(),
                    health,
                ));
                let _ = runtime.block_on(scope.close(Duration::from_secs(1)));
            })
            .ok();
        Self { handle, join }
    }

    pub fn join(mut self) {
        let _ = self.handle.close();
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }

    pub(crate) fn is_finished(&self) -> bool {
        self.join.as_ref().is_none_or(JoinHandle::is_finished)
    }
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
    source: Box<dyn source::RawSource>,
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
                Ok(Err(ChatError::Book(BookError::Rebuild(_)))) => {
                    match rebuild_from_raw(config.clone()) {
                        Ok(state) => break state,
                        Err(_) => return,
                    }
                }
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
        match run {
            Ok(Ok(true)) => return,
            Ok(Ok(false)) => continue,
            Ok(Err(ChatError::Book(BookError::CorruptRow { .. }))) => {
                drop(state);
                match rebuild_from_raw(config.clone()) {
                    Ok(rebuilt) => {
                        state = rebuilt;
                        state.recovery = Recovery::Rebuild;
                    }
                    Err(_) => return,
                }
                let run = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    run_once(&mut state, &rx, &queued)
                }));
                if matches!(run, Ok(Ok(true))) {
                    return;
                }
            }
            Ok(Err(ChatError::SourceChanged)) => continue,
            Ok(Err(_)) | Err(_) => return,
        }
    }
}

fn open_state(config: ChatConfig) -> Result<ActorState, ChatError> {
    let source_cell = RefCell::new((config.source_factory)()?);
    let source_stamp = source_cell.borrow().stamp();
    let opened = Log::open_with_raw_holds(&config.book, config.log_options, |_, place| {
        source_cell.borrow_mut().holds(place)
    });
    let (log, recovered, rebuilt_edition) = match opened {
        Ok(opened) => (opened.0, opened.1, None),
        Err(error) => return Err(ChatError::Book(error)),
    };
    let source = source_cell.into_inner();
    open_state_from_log(config, log, recovered, rebuilt_edition, source, source_stamp)
}

fn rebuild_from_raw(config: ChatConfig) -> Result<ActorState, ChatError> {
    let previous =
        log::CheckpointHead::read(&config.book).map_err(ChatError::Book)?.map(|head| head.edition);
    let mut new_config = config.clone();
    new_config.book = config.book.with_extension("new");
    let source_cell = RefCell::new((new_config.source_factory)()?);
    let source_stamp = source_cell.borrow().stamp();
    let (log, recovered) = match Log::open(&new_config.book, new_config.log_options) {
        Ok(opened) => opened,
        Err(BookError::Rebuild(_)) => {
            let _ = fs::remove_dir_all(&new_config.book);
            Log::open(&new_config.book, new_config.log_options).map_err(ChatError::Book)?
        }
        Err(error) => return Err(error.into()),
    };
    let source = source_cell.into_inner();
    let mut state = open_state_from_log(new_config, log, recovered, None, source, source_stamp)?;
    loop {
        if read_source(&mut state)? {
            break;
        }
    }
    state.edition = next_edition(previous, || (config.edition_random)());
    checkpoint(&mut state)?;
    let new_book = state.config.book.clone();
    drop(state);
    if config.book.exists() {
        let mut backup = config.book.with_extension("old");
        let mut suffix = 1u32;
        while backup.exists() {
            backup = config.book.with_extension(format!("old-{suffix}"));
            suffix = suffix.saturating_add(1);
        }
        fs::rename(&config.book, &backup)?;
    }
    fs::rename(new_book, &config.book)?;
    open_state(config)
}

fn open_state_from_log(
    config: ChatConfig,
    log: Log,
    recovered: log::Recovered,
    rebuilt_edition: Option<u32>,
    source: Box<dyn source::RawSource>,
    source_stamp: u64,
) -> Result<ActorState, ChatError> {
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
    let source_cursor =
        saved_checkpoint.as_ref().and_then(|checkpoint| checkpoint.cursors.first()).cloned();
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
        raw_file: source_cursor.as_ref().map_or(0, |cursor| cursor.file),
        raw_place: source_cursor.as_ref().map_or(0, |cursor| cursor.place),
        edition: rebuilt_edition.unwrap_or_else(|| {
            saved_checkpoint.as_ref().map_or(recovered.edition.max(1), |c| c.edition)
        }),
        boot_id: saved_checkpoint.as_ref().map_or(0, |c| c.boot_id),
        source_stamp,
        source,
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
        actor.edition = next_edition(Some(actor.edition), || (actor.config.edition_random)());
        actor.boot_id = actor.config.boot_id;
    }
    if rebuilt_edition.is_some() || recovered.replayed != 0 || stamp_changed {
        checkpoint(&mut actor)?;
    }
    Ok(actor)
}

fn run_once(
    state: &mut ActorState,
    rx: &Receiver<Request>,
    queued: &Arc<Mutex<usize>>,
) -> Result<bool, ChatError> {
    loop {
        let at_end = read_source(state)?;
        if !at_end {
            match rx.try_recv() {
                Ok(request) => {
                    if !handle_request(state, request, queued) {
                        return Ok(true);
                    }
                }
                Err(mpsc::TryRecvError::Disconnected) => return Ok(true),
                Err(mpsc::TryRecvError::Empty) => {}
            }
            continue;
        }
        let request = match rx.recv_timeout(IDLE_AFTER) {
            Ok(request) => request,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if state.translate.open_rows().next().is_none() {
                    let _ = checkpoint(state);
                    return Ok(true);
                }
                continue;
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => return Ok(true),
        };
        if !handle_request(state, request, queued) {
            return Ok(true);
        }
    }
}

fn handle_request(state: &mut ActorState, request: Request, queued: &Arc<Mutex<usize>>) -> bool {
    let bytes = request.bytes();
    if let Ok(mut queued) = queued.lock() {
        *queued = queued.saturating_sub(bytes);
    }
    state.last_used = Instant::now();
    match request {
        Request::Wake => true,
        Request::Close { reply } => {
            let result = checkpoint(state);
            let _ = reply.send(result);
            false
        }
    }
}

fn read_source(state: &mut ActorState) -> Result<bool, ChatError> {
    let chunk = state.source.read_chunk(state.raw_place)?;
    if chunk.stamp != state.source_stamp {
        return Err(ChatError::SourceChanged);
    }
    chunk.validate(state.raw_place)?;
    for line in chunk.lines() {
        let line = line?;
        let bytes = chunk.bytes().get(line.bytes.clone()).ok_or(ChatError::Closed)?;
        let bytes = bytes.strip_suffix(b"\n").unwrap_or(bytes);
        let span = line.end.saturating_sub(line.start);
        apply_line(state, bytes, line.start, span)?;
        state.raw_place = line.end;
    }
    Ok(chunk.at_end)
}

fn apply_line(
    state: &mut ActorState,
    bytes: &[u8],
    base_offset: u64,
    span: u64,
) -> Result<(), ChatError> {
    if state.raw_file == 0 {
        state.raw_file = state.log.append_raw_file(state.source.identity())?;
    }
    let file = state.raw_file;
    state.raw_place = base_offset.saturating_add(bytes.len() as u64).saturating_add(1);
    apply_ops(state, bytes, file, base_offset, span, true)
}

fn apply_ops(
    state: &mut ActorState,
    bytes: &[u8],
    file: u32,
    base_offset: u64,
    span: u64,
    checkpoint_now: bool,
) -> Result<(), ChatError> {
    let before = state.log.last_seq();
    let ops =
        translate::translate(&mut state.translate, state.config.harness, base_offset, span, bytes)?;
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
                    BodySource::Raw { place, span } => raw_body_value(state, *place, *span)?,
                };
                let key = body_key(field);
                let body =
                    state.bodies.entry(id).or_insert(Body::new(id).map_err(ChatError::Book)?);
                state.blobs.set(body, key, &value, append)?;
                state.raw_ranges.entry(id).or_insert(raw);
            }
            Change::Queue(_) => {}
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

fn raw_body_value(state: &mut ActorState, place: u64, span: u64) -> Result<String, ChatError> {
    let chunk = state.source.read_chunk(place)?;
    if chunk.stamp != state.source_stamp {
        return Err(ChatError::SourceChanged);
    }
    for line in chunk.lines() {
        let line = line?;
        if line.start != place {
            continue;
        }
        if line.end.saturating_sub(line.start) != span {
            return Err(ChatError::Closed);
        }
        let bytes = chunk.bytes().get(line.bytes).ok_or(ChatError::Closed)?;
        let bytes = bytes.strip_suffix(b"\n").unwrap_or(bytes);
        let value: serde_json::Value =
            serde_json::from_slice(bytes).map_err(|_| ChatError::Closed)?;
        let text = value.get("msg").and_then(|msg| msg.get("text")).ok_or(ChatError::Closed)?;
        return serde_json::to_string(text).map_err(|_| ChatError::Closed);
    }
    Err(ChatError::Closed)
}

fn settle_or_open(state: &mut ActorState, row: OwnedRow, raw: RawRange) -> Result<(), ChatError> {
    let body = state.bodies.entry(row.id).or_insert(Body::new(row.id).map_err(ChatError::Book)?);
    if row.open {
        state.raw_ranges.insert(row.id, raw);
        return Ok(());
    }
    let mut body_bytes = Vec::new();
    state.blobs.write_body(body, &mut body_bytes)?;
    let body_text = std::str::from_utf8(&body_bytes).map_err(|_| ChatError::Closed)?;
    let mut encoded = Vec::new();
    row.as_row(body_text).encode(None, &mut encoded).map_err(|_| ChatError::Closed)?;
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
    let _ = seq;
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
    let _ = seq;
    Ok(())
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
    if state.raw_file != 0 {
        state.source.sync_through(state.raw_place)?;
    }
    let open = checkpoint.open.iter().map(|open| open.body.row).collect::<Vec<_>>();
    checkpoint.write(&mut state.log, &open)?;
    state.last_checkpoint = Instant::now();
    state.settled_since_checkpoint = 0;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file_config(dir: &tempfile::TempDir) -> ChatConfig {
        let source_path = dir.path().join("source.ndjson");
        fs::write(
            &source_path,
            br#"{"kind":"prompt","id":"p1","text":"hello"}
"#,
        )
        .unwrap();
        let source_path = Arc::new(source_path);
        ChatConfig::new("chat", dir.path(), Harness::V1).with_source_factory(Arc::new(move || {
            source::FileSource::open(&source_path)
                .map(|source| Box::new(source) as Box<dyn source::RawSource>)
        }))
    }

    #[test]
    fn actor_books_a_line_from_the_source() {
        let dir = tempfile::tempdir().unwrap();
        let actor = ChatActor::spawn(file_config(&dir));
        actor.handle.wake().unwrap();
        actor.join();
        assert!(log::CheckpointHead::read(dir.path()).unwrap().is_some());
    }

    #[test]
    fn actor_rebuilds_from_raw_after_a_damaged_checkpoint() {
        let dir = tempfile::tempdir().unwrap();
        let config = file_config(&dir);
        let actor = ChatActor::spawn(config.clone());
        actor.handle.wake().unwrap();
        actor.join();

        let checkpoint = dir.path().join("checkpoint");
        let mut bytes = fs::read(&checkpoint).unwrap();
        let last = bytes.len().saturating_sub(1);
        if let Some(byte) = bytes.get_mut(last) {
            *byte ^= 1;
        }
        fs::write(checkpoint, bytes).unwrap();

        let rebuilt = ChatActor::spawn(config);
        rebuilt.handle.wake().unwrap();
        rebuilt.join();
        assert!(log::CheckpointHead::read(dir.path()).unwrap().is_some());
        let (_log, recovered) = Log::open(dir.path(), Options::default()).unwrap();
        assert!(recovered.checkpoint);
        let _ = Checkpoint::from_recovered(&recovered).unwrap();
    }
}
