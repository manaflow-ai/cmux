//! One actor and one book for one hydrated chat.
//!
//! The actor is intentionally a blocking owner of `acpmux_book::log::Log`. Its thread is the
//! only place that opens, reads, or appends the book. Requests cross a byte-bounded synchronous
//! mailbox, so a cold page cannot take a process-wide lock and a slow reader cannot make the
//! actor await a client.

use acpmux_book::blobs::{Blobs, Body};
use acpmux_book::checkpoint::{Checkpoint, Cursor, OpenBody, Person, next_edition};
use acpmux_book::folds::Folds;
use acpmux_book::log::{self, Error as BookError, Log, Options, RawRange};
use acpmux_book::row::{Outline, RowKind};
use acpmux_book::translate::{self, BodyField, BodySource, Change, Harness, OwnedRow, State};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub mod queue;
pub mod source;
pub mod stream;

use crate::conn::Reply;
use crate::wire::{Blob, Page};

pub type SourceFactory = Arc<dyn Fn() -> std::io::Result<Box<dyn source::RawSource>> + Send + Sync>;

struct EmptySource;

impl source::RawSource for EmptySource {
    fn read_chunk(&mut self, place: u64) -> std::io::Result<source::Chunk> {
        Ok(source::Chunk::with_stamp(Vec::new(), place, source::byte_places, true, 0, 1))
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
/// How often a caught-up actor with an empty mailbox looks at its source's hint. A notice that
/// the source grew wakes it at once; the hint finds the lines a dropped notice told of.
pub const HINT_POLL: Duration = Duration::from_millis(250);

#[derive(Clone)]
pub struct ChatConfig {
    pub id: String,
    pub book: PathBuf,
    pub harness: Harness,
    pub log_options: Options,
    pub boot_id: u64,
    pub hint_poll: Duration,
    pub supervision: crate::life::Policy,
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
            boot_id: crate::boot::system_boot_id(),
            hint_poll: HINT_POLL,
            supervision: crate::life::Policy::default(),
            source_factory: Arc::new(|| Ok(Box::new(EmptySource))),
            edition_random: Arc::new(system_random_edition),
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

fn system_random_edition() -> u32 {
    let mut bytes = [0u8; 4];
    if let Ok(mut source) = fs::File::open("/dev/urandom")
        && source.read_exact(&mut bytes).is_ok()
    {
        return u32::from_le_bytes(bytes).max(1);
    }
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(1, |duration| duration.subsec_nanos().max(1))
}

#[derive(Debug)]
pub enum ChatError {
    MailboxFull,
    Closed,
    Book(BookError),
    Io(std::io::Error),
    Translate(translate::Error),
    Failed,
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
            Self::Failed => f.write_str("chat actor is failed"),
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
    Close {
        reply: mpsc::Sender<Result<(), ChatError>>,
    },
    Sub {
        sub: Box<stream::ChatSub>,
        ticket: stream::Ticket,
    },
    Resume {
        conn: u64,
        sid: String,
        cursor: u64,
    },
    End {
        conn: u64,
        sid: String,
    },
    Page {
        page: Box<Page>,
        person: stream::PersonId,
        reply: Reply,
    },
    Blob {
        blob: Box<Blob>,
        person: stream::PersonId,
        reply: Reply,
    },
    #[cfg(test)]
    SetPerson(Person),
}

impl Request {
    /// What the request holds, as the mailbox counts it.
    fn bytes(&self) -> usize {
        let held = match self {
            Self::Wake | Self::Close { .. } => 0,
            Self::Sub { sub, .. } => size_of::<stream::ChatSub>() + sub.sid.len(),
            Self::Resume { sid, .. } | Self::End { sid, .. } => sid.len(),
            Self::Page { page, .. } => {
                size_of::<Page>() + page.sid.len() + page.stream.as_str().len() + size_of::<Reply>()
            }
            Self::Blob { blob, .. } => {
                size_of::<Blob>()
                    + blob.id.len()
                    + blob.stream.as_str().len()
                    + blob.prompt.as_ref().map_or(0, String::len)
                    + blob.from.as_ref().map_or(0, String::len)
                    + size_of::<Reply>()
            }
            #[cfg(test)]
            Self::SetPerson(person) => person.folds.len() * 8,
        };
        size_of::<Self>() + held
    }
}

impl ChatError {
    /// The `error` code a request this error refused is answered with.
    pub fn code(&self) -> &'static str {
        match self {
            Self::MailboxFull => "mailbox_full",
            _ => "failed",
        }
    }
}

/// A cheap cloneable mailbox handle. All log access still happens on the actor's thread.
#[derive(Clone)]
pub struct ChatHandle {
    tx: SyncSender<Request>,
    queued: Arc<Mutex<usize>>,
    health: tokio::sync::watch::Receiver<crate::life::Health>,
    failures: Arc<AtomicU64>,
}

impl ChatHandle {
    pub fn failures(&self) -> u64 {
        self.failures.load(Ordering::Relaxed)
    }

    /// The chat is `ready`: a read from its cursor said `at_end` in this actor's life, so it
    /// follows its source from here and no window is cut from half a book.
    pub fn ready(&self) -> bool {
        *self.health.borrow() == crate::life::Health::Running
    }

    /// Queues `request`, or gives it back with why it was refused, so its reply is answered at
    /// once with the reason.
    fn send(&self, request: Request) -> Result<(), (ChatError, Request)> {
        if *self.health.borrow() == crate::life::Health::Failed {
            return Err((ChatError::Failed, request));
        }
        let bytes = request.bytes();
        {
            let Ok(mut queued) = self.queued.lock() else {
                return Err((ChatError::Closed, request));
            };
            if queued.saturating_add(bytes) > MAILBOX_BYTES {
                return Err((ChatError::MailboxFull, request));
            }
            *queued = queued.saturating_add(bytes);
        }
        let refused = match self.tx.try_send(request) {
            Ok(()) => return Ok(()),
            Err(TrySendError::Full(request)) => (ChatError::MailboxFull, request),
            Err(TrySendError::Disconnected(request)) => (ChatError::Closed, request),
        };
        if let Ok(mut queued) = self.queued.lock() {
            *queued = queued.saturating_sub(bytes);
        }
        Err(refused)
    }

    /// Wakes the actor to read one bounded source chunk.
    pub fn wake(&self) -> Result<(), ChatError> {
        self.send(Request::Wake).map_err(|(error, _)| error)
    }

    pub fn close(&self) -> Result<(), ChatError> {
        let (reply_tx, reply_rx) = mpsc::channel();
        self.send(Request::Close { reply: reply_tx }).map_err(|(error, _)| error)?;
        reply_rx.recv().map_err(|_| ChatError::Response)?
    }

    /// A `sub`: its window, its resume or `not_ready` comes from the actor through `ticket`'s
    /// sink. Refused, the ticket says nothing and the error is the caller's to send.
    pub fn subscribe(&self, sub: stream::ChatSub, ticket: stream::Ticket) -> Result<(), ChatError> {
        match self.send(Request::Sub { sub: Box::new(sub), ticket }) {
            Ok(()) => Ok(()),
            Err((error, Request::Sub { ticket, .. })) => {
                ticket.forget();
                Err(error)
            }
            Err((error, _)) => Err(error),
        }
    }

    /// The connection gave a stopped subscription credit again.
    pub fn resume(&self, conn: u64, sid: &str, cursor: u64) -> Result<(), ChatError> {
        self.send(Request::Resume { conn, sid: sid.to_owned(), cursor }).map_err(|(error, _)| error)
    }

    pub fn end(&self, conn: u64, sid: &str) -> Result<(), ChatError> {
        self.send(Request::End { conn, sid: sid.to_owned() }).map_err(|(error, _)| error)
    }

    /// A `page`, answered through `reply`; refused, it is answered at once.
    pub fn page(&self, page: Page, person: stream::PersonId, reply: Reply) {
        let request = Request::Page { page: Box::new(page), person, reply };
        if let Err((error, Request::Page { reply, .. })) = self.send(request) {
            reply.error(error.code(), &error.to_string());
        }
    }

    /// A `blob`, answered through `reply`; refused, it is answered at once.
    pub fn blob(&self, blob: Blob, person: stream::PersonId, reply: Reply) {
        let request = Request::Blob { blob: Box::new(blob), person, reply };
        if let Err((error, Request::Blob { reply, .. })) = self.send(request) {
            reply.error(error.code(), &error.to_string());
        }
    }

    #[cfg(test)]
    fn set_person(&self, person: Person) -> Result<(), ChatError> {
        self.send(Request::SetPerson(person)).map_err(|(error, _)| error)
    }
}

pub struct ChatActor {
    pub handle: ChatHandle,
    join: Option<JoinHandle<()>>,
    stop: Arc<AtomicBool>,
    stopped: Arc<tokio::sync::Notify>,
}

impl ChatActor {
    /// Starts a supervised actor. Hydration runs on this dedicated worker, never on a tokio
    /// runtime worker. A panic reopens from the checkpoint.
    pub fn spawn(config: ChatConfig) -> Self {
        let (tx, rx) = sync_channel(256);
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = Arc::new(tokio::sync::Notify::new());
        let worker_stop = stop.clone();
        let worker_stopped = stopped.clone();
        let queued = Arc::new(Mutex::new(0));
        let (health, health_receiver) = tokio::sync::watch::channel(crate::life::Health::Starting);
        let failures = Arc::new(AtomicU64::new(0));
        let handle = ChatHandle {
            tx,
            queued: queued.clone(),
            health: health_receiver,
            failures: failures.clone(),
        };
        let join = thread::Builder::new()
            .name(format!("acpmux-chat-{}", config.id))
            .spawn(move || {
                let runtime =
                    match tokio::runtime::Builder::new_current_thread().enable_time().build() {
                        Ok(runtime) => runtime,
                        Err(_) => {
                            health.send_replace(crate::life::Health::Failed);
                            return;
                        }
                    };
                let scope = cmux_scope::Scope::new("acpmux-chat");
                let receiver = Arc::new(Mutex::new(rx));
                let actor_health = health.clone();
                let policy = config.supervision;
                let supervisor = crate::life::supervise(
                    &scope,
                    move || {
                        let receiver = receiver.clone();
                        let config = config.clone();
                        let queued = queued.clone();
                        let stop = worker_stop.clone();
                        let health = actor_health.clone();
                        let failures = failures.clone();
                        async move {
                            match tokio::task::spawn_blocking(move || {
                                run_supervised(config, receiver, queued, &stop, &health)
                            })
                            .await
                            {
                                Ok(result) => {
                                    if result.is_err() {
                                        failures.fetch_add(1, Ordering::Relaxed);
                                    }
                                    result
                                }
                                Err(error) if error.is_panic() => {
                                    failures.fetch_add(1, Ordering::Relaxed);
                                    std::panic::resume_unwind(error.into_panic())
                                }
                                Err(_) => Err(ChatError::Closed),
                            }
                        }
                    },
                    policy,
                    health,
                );
                runtime.block_on(async {
                    tokio::select! {
                        _ = supervisor => {},
                        _ = worker_stopped.notified() => {},
                    }
                });
                let _ = runtime.block_on(scope.close(Duration::from_secs(1)));
            })
            .ok();
        Self { handle, join, stop, stopped }
    }

    pub fn join(mut self) {
        self.stop.store(true, Ordering::Release);
        // Wake both the blocking mailbox and a supervisor in retry backoff. Neither
        // depends on the failed actor accepting another user request.
        let _ = self.handle.tx.try_send(Request::Wake);
        self.stopped.notify_one();
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
    replay_remaining: u64,
    /// The hint the last read that said `at_end` saw. The actor reads again when its mailbox is
    /// empty and the source's hint is another; the hint is never taken for an end.
    seen_hint: Option<u64>,
    /// A read said `at_end` in this state's life: windows are cut from here on.
    ready: bool,
    subs: stream::Subscribers,
    /// The people the book keeps: the row each has seen and the folds each opened.
    people: Vec<Person>,
    /// Each open row's generation: another one whenever the row's body is set again rather
    /// than appended to, so a client knows bytes it holds before `fixed` are still the row's.
    gens: BTreeMap<u64, u64>,
    gen_next: u64,
    /// The queue head's entries as read, by id hash: the place of the record read, the id
    /// and the text's first kilobyte. Only the head's 64 are kept.
    queue_heads: BTreeMap<u64, (u64, String, String)>,
}

impl ActorState {
    fn generation(&mut self, row: u64) -> u64 {
        match self.gens.get(&row) {
            Some(generation) => *generation,
            None => self.next_generation(row),
        }
    }

    fn next_generation(&mut self, row: u64) -> u64 {
        self.gen_next = self.gen_next.wrapping_add(1);
        self.gens.insert(row, self.gen_next);
        self.gen_next
    }
}

/// Where this actor's generations start: random, so no two lives of a chat give the same one.
fn random_u64() -> u64 {
    let mut bytes = [0u8; 8];
    if let Ok(mut source) = fs::File::open("/dev/urandom")
        && source.read_exact(&mut bytes).is_ok()
    {
        return u64::from_le_bytes(bytes);
    }
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |duration| duration.as_nanos() as u64)
        ^ u64::from(std::process::id()) << 32
}

fn run_supervised(
    config: ChatConfig,
    receiver: Arc<Mutex<Receiver<Request>>>,
    queued: Arc<Mutex<usize>>,
    stop: &AtomicBool,
    health: &tokio::sync::watch::Sender<crate::life::Health>,
) -> Result<(), ChatError> {
    let receiver = receiver.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut rebuild = false;
    // The subscribers outlive a reopen and a rebuild; an actor that ends or panics drops them,
    // and each is told `dropped`.
    let mut subs = stream::Subscribers::default();
    loop {
        let mut state = if rebuild || suffix(&config.book, ".new").exists() {
            match rebuild_from_raw(config.clone(), &receiver, &queued, stop, &mut subs)? {
                Some(state) => state,
                None => return Ok(()),
            }
        } else {
            match retry_busy(|| open_state(config.clone())) {
                Ok(state) => state,
                Err(error) if damaged(&error) => {
                    rebuild = true;
                    continue;
                }
                Err(error) => return Err(error),
            }
        };
        rebuild = false;
        state.subs = std::mem::take(&mut subs);
        let edition = state.edition;
        state.subs.reopened(edition);
        let result = run_once(&mut state, &receiver, &queued, stop, health);
        subs = std::mem::take(&mut state.subs);
        match result {
            Ok(true) => return Ok(()),
            Ok(false) => {}
            Err(error) if damaged(&error) => rebuild = true,
            Err(ChatError::SourceChanged) => {}
            Err(error) => return Err(error),
        }
    }
}

fn damaged(error: &ChatError) -> bool {
    matches!(
        error,
        ChatError::Book(
            BookError::Rebuild(_) | BookError::Corrupt(_) | BookError::CorruptRow { .. }
        )
    )
}

fn retry_busy<T>(mut open: impl FnMut() -> Result<T, ChatError>) -> Result<T, ChatError> {
    let started = Instant::now();
    loop {
        match open() {
            Err(ChatError::Book(BookError::Busy)) if started.elapsed() < Duration::from_secs(1) => {
                thread::sleep(Duration::from_millis(10));
            }
            result => return result,
        }
    }
}

fn open_state(config: ChatConfig) -> Result<ActorState, ChatError> {
    let old = suffix(&config.book, ".old");
    if old.exists() && log::saved_checkpoint(&config.book)?.is_some_and(|saved| saved.edition != 0)
    {
        fs::remove_dir_all(old)?;
        sync_parent(&config.book)?;
    }
    if !config.book.join("checkpoint").exists()
        && fs::metadata(config.book.join("rows/000001.seg"))
            .is_ok_and(|metadata| metadata.len() > log::SEGMENT_HEADER_LEN)
    {
        return Err(BookError::Rebuild("checkpoint disappeared from a nonempty book").into());
    }
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

#[inline]
fn rebuild_point(_point: &str) {
    #[cfg(test)]
    tests::rebuild_point(_point);
}

fn suffix(book: &Path, suffix: &str) -> PathBuf {
    let mut path = book.as_os_str().to_os_string();
    path.push(suffix);
    PathBuf::from(path)
}

#[derive(serde::Serialize, serde::Deserialize)]
struct RebuildBasis {
    edition: Option<u32>,
    stamp: u64,
    identity: Vec<u8>,
    keep: bool,
}

fn sync_parent(path: &Path) -> Result<(), ChatError> {
    if let Some(parent) = path.parent() {
        fs::File::open(parent)?.sync_all()?;
    }
    Ok(())
}

fn same_file(left: &Path, right: &Path) -> std::io::Result<bool> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let (left, right) = (fs::metadata(left)?, fs::metadata(right)?);
        Ok(left.dev() == right.dev() && left.ino() == right.ino())
    }
    #[cfg(not(unix))]
    {
        let _ = (left, right);
        Ok(false)
    }
}

fn save_basis(book: &Path, basis: &RebuildBasis) -> Result<(), ChatError> {
    let path = book.join("rebuild");
    let temporary = book.join("rebuild.tmp");
    let mut file = fs::File::create(&temporary)?;
    file.write_all(&serde_json::to_vec(basis).map_err(std::io::Error::other)?)?;
    file.sync_all()?;
    fs::rename(temporary, &path)?;
    sync_parent(&path)
}

// The final synced checkpoint is the commit record. A restart after either rename
// finishes the same swap without translating or choosing an edition a second time.
fn finish_swap(config: &ChatConfig, new_book: &Path) -> Result<(), ChatError> {
    let old_book = suffix(&config.book, ".old");
    if config.book.exists() {
        if old_book.exists() {
            fs::remove_dir_all(&old_book)?;
        }
        fs::rename(&config.book, &old_book)?;
        sync_parent(&config.book)?;
    }
    rebuild_point("old-renamed");
    fs::rename(new_book, &config.book)?;
    sync_parent(&config.book)?;
    rebuild_point("new-renamed");
    if old_book.exists() {
        fs::remove_dir_all(&old_book)?;
        sync_parent(&old_book)?;
    }
    Ok(())
}

fn rebuild_from_raw(
    config: ChatConfig,
    rx: &Receiver<Request>,
    queued: &Arc<Mutex<usize>>,
    stop: &AtomicBool,
    subs: &mut stream::Subscribers,
) -> Result<Option<ActorState>, ChatError> {
    let new_book = suffix(&config.book, ".new");
    if log::saved_checkpoint(&new_book)?.is_some_and(|saved| saved.edition != 0) {
        // A committed replacement normally needs only the renames. If the served
        // source was replaced while we were down, its newer inode must survive:
        // the old staging link is no longer a copy of the authoritative raw file.
        let replaced = if config.book.exists() {
            let source = (config.source_factory)()?;
            let mut basis: RebuildBasis =
                serde_json::from_slice(&fs::read(new_book.join("rebuild"))?)
                    .map_err(std::io::Error::other)?;
            if basis.identity != source.identity() {
                fs::remove_dir_all(&new_book)?;
                fs::create_dir_all(&new_book)?;
                basis.identity = source.identity().to_vec();
                basis.keep = false;
                save_basis(&new_book, &basis)?;
                true
            } else {
                false
            }
        } else {
            false
        };
        if !replaced {
            finish_swap(&config, &new_book)?;
            return retry_busy(|| open_state(config.clone())).map(Some);
        }
    }
    let mut source = (config.source_factory)()?;
    let source_stamp = source.stamp();
    let previous = log::CheckpointHead::read(&config.book)?.map(|head| head.edition);
    let old = log::saved_checkpoint(&config.book)?
        .and_then(|saved| Checkpoint::from_recovered(&saved).ok());
    let mut keep = old.as_ref().is_some_and(|saved| {
        saved.translator_version == translate::VERSION
            && saved.boot_id == config.boot_id
            && saved.cursors.iter().all(|cursor| cursor.stamp == source_stamp)
    });
    if let Some(saved) = &old {
        for cursor in &saved.cursors {
            keep &= source.holds(cursor.place)?;
        }
    }
    fs::create_dir_all(&new_book)?;
    let mut basis = match fs::read(new_book.join("rebuild")) {
        Ok(bytes) => {
            serde_json::from_slice::<RebuildBasis>(&bytes).map_err(std::io::Error::other)?
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => RebuildBasis {
            edition: previous,
            stamp: source_stamp,
            identity: source.identity().to_vec(),
            keep,
        },
        Err(error) => return Err(error.into()),
    };
    if basis.identity != source.identity() {
        // A new source inode invalidates a partial rebuild, even at the same byte
        // length and stamp. Its old raw link must never replace the current file.
        fs::remove_dir_all(&new_book)?;
        fs::create_dir_all(&new_book)?;
        basis.identity = source.identity().to_vec();
        basis.keep = false;
    }
    basis.keep &= keep && basis.stamp == source_stamp;
    save_basis(&new_book, &basis)?;
    rebuild_point("basis");
    let mut new_config = config.clone();
    new_config.book = new_book.clone();
    let mut state = restart_staging(&new_config, &mut basis)?;
    // A staging book is never ready: its subscribers wait.
    state.subs = std::mem::take(subs);
    rebuild_point("opened");
    loop {
        match read_source(&mut state) {
            Ok(at_end) => {
                rebuild_point("chunk");
                if stop.load(Ordering::Acquire) {
                    checkpoint(&mut state)?;
                    return Ok(None);
                }
                match rx.try_recv() {
                    Ok(request) => {
                        if !handle_request(&mut state, request, queued)? {
                            return Ok(None);
                        }
                    }
                    Err(mpsc::TryRecvError::Empty) => {}
                    Err(mpsc::TryRecvError::Disconnected) => return Ok(None),
                }
                if at_end {
                    break;
                }
            }
            Err(ChatError::SourceChanged) => {
                basis.keep = false;
                save_basis(&new_book, &basis)?;
                *subs = std::mem::take(&mut state.subs);
                drop(state);
                state = restart_staging(&new_config, &mut basis)?;
                state.subs = std::mem::take(subs);
            }
            Err(error) => return Err(error),
        }
    }
    rebuild_point("caught-up");
    // A colocated raw file is linked into the replacement before committing it. Both
    // names refer to the original inode; removing the derived old book cannot remove raw.
    if let Some(raw) = state.source.file_path()
        && config.book.exists()
    {
        let served = config.book.canonicalize()?;
        if let Ok(relative) = raw.strip_prefix(&served) {
            let linked = new_book.join(relative);
            if linked.exists() && !same_file(raw, &linked)? {
                fs::remove_file(&linked)?;
            }
            if !linked.exists() {
                if let Some(parent) = linked.parent() {
                    fs::create_dir_all(parent)?;
                }
                fs::hard_link(raw, &linked)?;
                sync_parent(&linked)?;
            }
        }
    }
    rebuild_point("raw-linked");
    let current = log::CheckpointHead::read(&config.book)?.map(|head| head.edition);
    state.edition = if basis.keep && current == basis.edition {
        current
            .filter(|edition| *edition != 0)
            .unwrap_or_else(|| next_edition(None, || (config.edition_random)()))
    } else {
        next_edition(current, || (config.edition_random)())
    };
    rebuild_point("edition-chosen");
    checkpoint(&mut state)?;
    rebuild_point("committed");
    *subs = std::mem::take(&mut state.subs);
    drop(state);
    rebuild_point("closed");
    finish_swap(&config, &new_book)?;
    retry_busy(|| open_state(config.clone())).map(Some)
}

fn restart_staging(config: &ChatConfig, basis: &mut RebuildBasis) -> Result<ActorState, ChatError> {
    match retry_busy(|| open_staging_state(config.clone())) {
        Ok(state) => Ok(state),
        Err(error) if damaged(&error) => {
            basis.keep = false;
            fs::remove_dir_all(&config.book)?;
            fs::create_dir_all(&config.book)?;
            save_basis(&config.book, basis)?;
            retry_busy(|| open_staging_state(config.clone()))
        }
        Err(error) => Err(error),
    }
}

fn open_staging_state(config: ChatConfig) -> Result<ActorState, ChatError> {
    let source = RefCell::new((config.source_factory)()?);
    let stamp = source.borrow().stamp();
    let (log, recovered) = Log::open_staging(&config.book, config.log_options, |_, place| {
        source.borrow_mut().holds(place)
    })?;
    open_state_from_log(config, log, recovered, Some(0), source.into_inner(), stamp)
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
    if let Some(saved) = &saved_checkpoint
        && saved.translator_version != translate::VERSION
    {
        return Err(BookError::Rebuild("translator version changed").into());
    }
    let mut source = source;
    if let Some(saved) = &saved_checkpoint {
        for cursor in &saved.cursors {
            if !source.holds(cursor.place)? {
                return Err(BookError::Rebuild("checkpoint source cursor is gone").into());
            }
        }
    }
    let translate = match saved_checkpoint.as_ref() {
        Some(checkpoint) if !checkpoint.translator.is_empty() => {
            State::restore(&checkpoint.translator, &checkpoint.prompts)
                .map_err(|_| BookError::Rebuild("translator checkpoint is damaged"))?
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
    let boot_id = saved_checkpoint.as_ref().map_or(config.boot_id, |c| c.boot_id);
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
        boot_id,
        source_stamp,
        source,
        last_used: Instant::now(),
        last_checkpoint: Instant::now(),
        settled_since_checkpoint: 0,
        replay_remaining: recovered.replayed,
        seen_hint: None,
        ready: false,
        subs: stream::Subscribers::default(),
        people: saved_checkpoint.as_ref().map_or_else(Vec::new, |c| c.people.clone()),
        gens: BTreeMap::new(),
        gen_next: random_u64(),
        queue_heads: BTreeMap::new(),
    };
    let stamp_changed = saved_checkpoint.as_ref().is_some_and(|checkpoint| {
        checkpoint.boot_id != actor.config.boot_id
            || checkpoint.cursors.iter().any(|cursor| cursor.stamp != actor.source_stamp)
    });
    if stamp_changed {
        let open_rows = saved_checkpoint
            .as_ref()
            .map(|checkpoint| checkpoint.open.iter().map(|open| open.body.row).collect::<Vec<_>>())
            .unwrap_or_default();
        actor.log.cut_to_checkpoint(&open_rows)?;
        actor.edition = if rebuilt_edition == Some(0) {
            0
        } else {
            next_edition(Some(actor.edition), || (actor.config.edition_random)())
        };
        actor.boot_id = actor.config.boot_id;
        actor.replay_remaining = 0;
    }
    // The source's line in `raw.map` from the book's first checkpoint on, so every checkpoint
    // holds a cursor with the stamp: a source that changes before the first line settles (v1
    // compacting a chat mid catch-up) is then a changed stamp at the next open.
    let named = actor.raw_file == 0;
    if named {
        actor.raw_file = actor.log.append_raw_file(actor.source.identity())?;
    }
    if stamp_changed || !recovered.checkpoint || named {
        checkpoint(&mut actor)?;
    }
    Ok(actor)
}

fn run_once(
    state: &mut ActorState,
    rx: &Receiver<Request>,
    queued: &Arc<Mutex<usize>>,
    stop: &AtomicBool,
    health: &tokio::sync::watch::Sender<crate::life::Health>,
) -> Result<bool, ChatError> {
    loop {
        if stop.load(Ordering::Acquire) {
            checkpoint(state)?;
            return Ok(true);
        }
        let at_end = read_source(state)?;
        if at_end && !state.ready {
            state.ready = true;
            stream::ready(state);
        }
        stream::step(state)?;
        if !at_end {
            match rx.try_recv() {
                Ok(request) => {
                    if !handle_request(state, request, queued)? {
                        return Ok(true);
                    }
                }
                Err(mpsc::TryRecvError::Disconnected) => return Ok(true),
                Err(mpsc::TryRecvError::Empty) => {}
            }
            continue;
        }
        // `ready` is a read that said `at_end`, never only a first read: a catch-up that has
        // read one chunk of a long history is not ready.
        if *health.borrow() != crate::life::Health::Running {
            health.send_replace(crate::life::Health::Running);
        }
        match wait_for_work(state, rx, stop) {
            Wait::Request(request) => {
                if !handle_request(state, request, queued)? {
                    return Ok(true);
                }
            }
            Wait::Read => {}
            Wait::Idle => {
                if state.translate.open_rows().next().is_none()
                    && state.subs.is_empty()
                    && state.translate.queue_len() == 0
                {
                    checkpoint(state)?;
                    return Ok(true);
                }
            }
            Wait::Closed => return Ok(true),
        }
    }
}

enum Wait {
    Request(Request),
    /// The source's hint is not the one the last read that said `at_end` saw, or a stop.
    Read,
    Idle,
    Closed,
}

/// A caught-up actor's wait: a request, a hint that moved (looked at every `hint_poll` while the
/// mailbox is empty), a stop, or `IDLE_AFTER` with none of them.
fn wait_for_work(state: &ActorState, rx: &Receiver<Request>, stop: &AtomicBool) -> Wait {
    let started = Instant::now();
    loop {
        if stop.load(Ordering::Acquire) || state.source.hint().ok() != state.seen_hint {
            return Wait::Read;
        }
        // A subscriber with a resume frame or a window to take: a request first, if one waits.
        if state.subs.busy() {
            return match rx.try_recv() {
                Ok(request) => Wait::Request(request),
                Err(mpsc::TryRecvError::Empty) => Wait::Read,
                Err(mpsc::TryRecvError::Disconnected) => Wait::Closed,
            };
        }
        let left = IDLE_AFTER.saturating_sub(started.elapsed());
        if left.is_zero() {
            return Wait::Idle;
        }
        let mut wait = left.min(state.config.hint_poll.max(Duration::from_millis(1)));
        // Held text is due.
        if let Some(at) = state.subs.flush_at() {
            let now = Instant::now();
            if at <= now {
                return Wait::Read;
            }
            wait = wait.min(at - now);
        }
        match rx.recv_timeout(wait) {
            Ok(request) => return Wait::Request(request),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => return Wait::Closed,
        }
    }
}

fn handle_request(
    state: &mut ActorState,
    request: Request,
    queued: &Arc<Mutex<usize>>,
) -> Result<bool, ChatError> {
    let bytes = request.bytes();
    if let Ok(mut queued) = queued.lock() {
        *queued = queued.saturating_sub(bytes);
    }
    state.last_used = Instant::now();
    match request {
        Request::Wake => Ok(true),
        Request::Close { reply } => {
            let result = checkpoint(state);
            let failed = result.is_err();
            let _ = reply.send(result);
            if failed { Err(ChatError::Failed) } else { Ok(false) }
        }
        Request::Sub { sub, ticket } => {
            stream::subscribe(state, *sub, ticket);
            Ok(true)
        }
        Request::Resume { conn, sid, cursor } => {
            stream::resume(state, conn, &sid, cursor);
            Ok(true)
        }
        Request::End { conn, sid } => {
            stream::end(state, conn, &sid);
            Ok(true)
        }
        Request::Page { page, person, reply } => {
            if state.ready {
                stream::page(state, *page, person, reply);
            } else {
                reply.error("not_ready", "the chat's book is catching up");
            }
            Ok(true)
        }
        Request::Blob { blob, person: _, reply } => {
            if state.ready {
                stream::blob(state, *blob, reply);
            } else {
                reply.error("not_ready", "the chat's book is catching up");
            }
            Ok(true)
        }
        #[cfg(test)]
        Request::SetPerson(person) => {
            state.people.retain(|known| known.id != person.id);
            state.people.push(person);
            Ok(true)
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
        apply_line(state, bytes, line.start, line.end, span)?;
        state.raw_place = line.end;
    }
    stream::queue_publish(state)?;
    if chunk.at_end {
        state.seen_hint = Some(chunk.hint);
    }
    Ok(chunk.at_end)
}

fn apply_line(
    state: &mut ActorState,
    bytes: &[u8],
    base_offset: u64,
    cursor_end: u64,
    span: u64,
) -> Result<(), ChatError> {
    if state.raw_file == 0 {
        state.raw_file = state.log.append_raw_file(state.source.identity())?;
    }
    let file = state.raw_file;
    state.raw_place = cursor_end;
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
    let mut changed = false;
    let before = state.translate.counters();
    let ops =
        translate::translate(&mut state.translate, state.config.harness, base_offset, span, bytes)?;
    let after = state.translate.counters();
    if after.invalid_records != before.invalid_records || after.line_errors != before.line_errors {
        return Err(translate::Error::InvalidRecord("raw line did not translate").into());
    }
    for op in ops {
        changed |= matches!(&op.change, Change::Row(row) if !row.open)
            || matches!(&op.change, Change::Patch(_));
        if matches!(&op.change, Change::Row(row) if !row.open) {
            state.settled_since_checkpoint = state.settled_since_checkpoint.saturating_add(1);
        }
        let raw = RawRange {
            file,
            // The log stores source places, not offsets into the encoded JSON.
            // Include the whole line end (the newline for files); places may have gaps.
            off: base_offset,
            len: u32::try_from(span).unwrap_or(u32::MAX),
        };
        match op.change {
            Change::Row(row) => {
                let id = row.id;
                if settle_or_open(state, row, raw)? {
                    state.next_generation(id);
                    stream::opened(state, id)?;
                }
            }
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
                if append && field == BodyField::Text {
                    // Appended text keeps the row's generation: the bytes before it stay.
                    stream::text(state, id, &value);
                } else {
                    state.next_generation(id);
                    stream::opened(state, id)?;
                }
            }
            Change::Queue(_) => stream::queue_changed(state),
        }
    }
    stream::publish(state);
    if checkpoint_now
        && changed
        && state.replay_remaining == 0
        && (!state.translate.in_turn()
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

fn merge_row_fields(
    state: &mut ActorState,
    row: &OwnedRow,
    hidden_settle: bool,
) -> Result<(), ChatError> {
    if hidden_settle && row.fields.get("hidden").is_some_and(|value| value == "true") {
        let body = Body::new(row.id).map_err(ChatError::Book)?;
        state.bodies.insert(row.id, body);
        let body = state.bodies.get_mut(&row.id).ok_or(ChatError::Closed)?;
        state.blobs.set(body, "hidden", "true", false)?;
        return Ok(());
    }
    let body = state.bodies.entry(row.id).or_insert(Body::new(row.id).map_err(ChatError::Book)?);
    for (field, value) in &row.fields {
        state.blobs.set(body, field, value, false)?;
    }
    Ok(())
}

/// Stores a row: settled, it is appended to the log and offered; open, its body is kept and
/// `true` says so.
fn settle_or_open(state: &mut ActorState, row: OwnedRow, raw: RawRange) -> Result<bool, ChatError> {
    merge_row_fields(state, &row, true)?;
    let body = state.bodies.get(&row.id).ok_or(ChatError::Closed)?;
    if row.open {
        state.raw_ranges.insert(row.id, raw);
        return Ok(true);
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
        Ok(seq) => Some(seq),
        Err(BookError::AlreadySettled { .. }) | Err(BookError::StaleRev { .. }) => {
            state.replay_remaining = state.replay_remaining.saturating_sub(1);
            None
        }
        Err(error) => return Err(error.into()),
    };
    if row.kind == RowKind::Group
        && let Some(last) = row.fields.get("last").and_then(|last| last.parse::<u64>().ok())
    {
        // The replay after a checkpoint cuts the derived index first. It must append this
        // group again even when the record itself already settled before the kill.
        state.folds.append(row.id, last)?;
    }
    state.bodies.remove(&row.id);
    state.raw_ranges.remove(&row.id);
    state.gens.remove(&row.id);
    if let Some(seq) = seq {
        stream::settled(state, "row", seq, &encoded, row.id);
    }
    Ok(false)
}

fn patch(state: &mut ActorState, row: OwnedRow, raw: RawRange) -> Result<(), ChatError> {
    // A patch replaces a settled row's body. Keep its temporary body local: settled rows are
    // never checkpoint-open, so retaining one here would leak every superseded body until the
    // actor next opened.
    state.bodies.remove(&row.id);
    state.raw_ranges.remove(&row.id);
    let mut patch_body = Body::new(row.id).map_err(ChatError::Book)?;
    for (field, value) in &row.fields {
        state.blobs.set(&mut patch_body, field, value, false)?;
    }
    let mut encoded = Vec::new();
    let mut body_text = Vec::new();
    state.blobs.write_body(&patch_body, &mut body_text)?;
    let body_text = std::str::from_utf8(&body_text).map_err(|_| ChatError::Closed)?;
    row.as_row(body_text).encode(None, &mut encoded).map_err(|_| ChatError::Closed)?;
    state.source.sync_through(state.raw_place)?;
    match state.log.patch(row.id, row.rev, raw, &encoded) {
        Ok(seq) => stream::settled(state, "patch", seq, &encoded, row.id),
        Err(BookError::StaleRev { .. }) | Err(BookError::AlreadySettled { .. }) => {
            state.replay_remaining = state.replay_remaining.saturating_sub(1);
        }
        Err(error) => return Err(error.into()),
    }
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
    if state.replay_remaining != 0 {
        // The log is ahead of translator state after a kill. Keep the old checkpoint
        // until raw replay accounts for those records; its open bodies are authoritative.
        return Ok(());
    }
    let mut checkpoint = Checkpoint::new(translate::VERSION);
    checkpoint.edition = state.edition;
    checkpoint.boot_id = state.boot_id;
    let saved = state.translate.checkpoint()?;
    checkpoint.translator = saved.translator;
    checkpoint.prompts = saved.prompts;
    checkpoint.people = state.people.clone();
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
    let bodies = checkpoint.open.iter().map(|open| open.body.clone()).collect::<Vec<_>>();
    state.blobs.sync(bodies.iter())?;
    state.folds.sync()?;
    if state.raw_file != 0 {
        state.source.sync_through(state.raw_place)?;
    }
    let open = checkpoint.open.iter().map(|open| open.body.row).collect::<Vec<_>>();
    checkpoint.write(&mut state.log, &open)?;
    state.blobs.recover(&bodies, checkpoint.last_row)?;
    state.last_checkpoint = Instant::now();
    state.settled_since_checkpoint = 0;
    Ok(())
}

#[cfg(test)]
mod tests;
