//! The connection worker: one owned thread that ensures the daemon, connects
//! with the SDK, identifies, loads a snapshot, follows `session.events`, and
//! reports each step to a caller callback. When the daemon advertises
//! `bookmarks-v1`, `profiles-v1`, `history-v1` or `keybindings-v1`, a second
//! thread per connection follows `bookmarks-changed`, `personal-changed`,
//! `history-changed` and `keybindings-changed` on a protocol-12 `subscribe`
//! stream (the resource API has none of them). With an install key the worker hands it to a daemon it
//! starts and checks on each connect that the daemon accepts the app's
//! `client-hello` proof ([`ConnectionInfo::verified_app`]).
//! See the crate docs for the thread contract.

use crate::app_connection::AppConnection;
use crate::install_key::InstallKey;
use crate::launcher::{self, Launcher};
use crate::mirror::{Applied, Mirror, MirrorChange};
use crate::resume_class::{ResumeErrorClass, SessionEnd};
use crate::spaces::PROFILES_CAPABILITY;
use acpmux_list_types::resume::{Decision, NextStep, ResumeBudget};
use cmux::{
    ClientMetadataOptions, Config, ConnectedClientId, EventStreamOptions, Selector,
    StreamCancellation, Update,
};
use std::cell::Cell;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::{JoinHandle, ThreadId};
use std::time::Duration;

/// Session name when `DaemonConfig::session` is not set otherwise.
pub const DEFAULT_SESSION: &str = "cmux2-gpui";
/// The capability of the bookmark commands and `bookmarks-changed`.
pub const BOOKMARKS_CAPABILITY: &str = "bookmarks-v1";
/// The capability of the `history.*` operations and `history-changed`.
pub const HISTORY_CAPABILITY: &str = "history-v1";
/// The capability of the `keybindings.*` operations and `keybindings-changed`.
pub const KEYBINDINGS_CAPABILITY: &str = "keybindings-v1";
/// How long the subscribe stream waits for one event before it waits again
/// (a quiet stream is healthy; `stop` closes it at once).
const SUBSCRIBE_EVENTS_IDLE: Duration = Duration::from_secs(3600);

#[derive(Clone, Debug)]
pub struct DaemonConfig {
    /// cmux-tui session name (one durable owner per name).
    pub session: String,
    /// Connect to this socket and never start a daemon (tests, remote
    /// forwards). `None` runs `server ensure`.
    pub socket: Option<PathBuf>,
    /// Binary for `server ensure`; `None` uses `launcher::resolve_binary`.
    pub binary: Option<PathBuf>,
    /// `CMUX_TUI_STATE_DIR` for a daemon this client starts.
    pub state_dir: Option<PathBuf>,
    /// The app's install key file ([`InstallKey::load_or_create`]). `None`
    /// uses `<state_dir>/frontend-install-key` (cmux-next's file for the
    /// same state directory) when `state_dir` is set, else no key: the
    /// daemon is started without one and no connection is the verified app.
    pub install_key_file: Option<PathBuf>,
    /// Reported through `client.metadata.update`.
    pub client_name: String,
    pub client_kind: String,
    /// Deadline for each SDK request (connect, identify, snapshot, ...).
    pub request_timeout: Duration,
    /// Deadline for `server ensure`.
    pub ensure_timeout: Duration,
    /// Reconnect backoff starts at `min_backoff` and doubles up to this.
    pub max_backoff: Duration,
    pub min_backoff: Duration,
    /// Report `bookmarks-changed` as [`DaemonEvent::BookmarksChanged`] (one
    /// more connection while connected to a daemon with `bookmarks-v1`).
    pub bookmark_events: bool,
    /// Report `personal-changed` as [`DaemonEvent::PersonalChanged`] (the
    /// same extra connection, while connected to a daemon with
    /// `profiles-v1`).
    pub personal_events: bool,
    /// Report `history-changed` as [`DaemonEvent::HistoryChanged`] (the
    /// same extra connection, while connected to a daemon with
    /// `history-v1`).
    pub history_events: bool,
    /// Report `keybindings-changed` as [`DaemonEvent::KeybindingsChanged`]
    /// (the same extra connection, while connected to a daemon with
    /// `keybindings-v1`).
    pub keybinding_events: bool,
    /// Report EVERY `subscribe` event as [`DaemonEvent::Event`] with its
    /// frame as the daemon sent it, typed in this crate or not (the same
    /// extra connection), so a new daemon event needs no client change
    /// (page-router-v1, generic event delivery). The typed variants above
    /// still come for the events they name.
    pub raw_events: bool,
    /// Report each applied `session.events` delta also as
    /// [`DaemonEvent::SessionDelta`] with the event the stream delivered,
    /// just before its typed [`DaemonEvent::Delta`] (cmux2-0b: the app reads
    /// fields the mirror does not keep). Off by default: then no
    /// `SessionDelta` comes and nothing is copied.
    pub raw_session_deltas: bool,
    /// Additive capabilities the mirror's connections declare (for example
    /// `conversation-tabs-v1` and `agent-session-tabs-v1`, so the snapshot
    /// and the event stream read those tabs in their canonical form). Only
    /// the ones the daemon advertises in `identify` are declared; empty
    /// declares nothing.
    pub capabilities: Vec<String>,
}

impl DaemonConfig {
    pub fn new(session: impl Into<String>) -> Self {
        Self {
            session: session.into(),
            socket: None,
            binary: None,
            state_dir: None,
            install_key_file: None,
            client_name: "cmux2".to_string(),
            client_kind: "frontend".to_string(),
            request_timeout: Duration::from_secs(5),
            ensure_timeout: Duration::from_secs(20),
            min_backoff: Duration::from_millis(250),
            max_backoff: Duration::from_secs(10),
            bookmark_events: true,
            personal_events: true,
            history_events: true,
            keybinding_events: true,
            raw_events: false,
            raw_session_deltas: false,
            capabilities: Vec::new(),
        }
    }

    /// The install key file this config uses, if any.
    pub fn install_key_path(&self) -> Option<PathBuf> {
        self.install_key_file.clone().or_else(|| self.state_dir.as_deref().map(InstallKey::file_in))
    }
}

/// The configured capabilities the daemon advertises, in configured order.
fn declared_capabilities(configured: &[String], advertised: &[String]) -> Vec<String> {
    configured.iter().filter(|c| advertised.contains(c)).cloned().collect()
}

/// What the worker learned when it connected.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ConnectionInfo {
    pub socket: PathBuf,
    /// Owner pid and whether this connect started it (`None` when the socket
    /// was given and `server ensure` did not run).
    pub pid: Option<u32>,
    pub started: bool,
    pub session_id: String,
    pub generation: String,
    /// From the protocol-12 `identify` (absent when it failed).
    pub build_commit: Option<String>,
    pub protocol: Option<u32>,
    pub capabilities: Vec<String>,
    /// This connection's client resource, after `client.metadata.update`.
    pub client_id: Option<ConnectedClientId>,
    /// The daemon accepted this app's install-key proof on a probe
    /// connection: an [`AppConnection`] with [`DaemonClient::install_key`]
    /// gets origin `user`. False without a key, or when the owner was
    /// started without it (by another app or before the key existed).
    pub verified_app: bool,
}

/// One step reported to the callback.
#[derive(Clone, Debug, PartialEq)]
pub enum DaemonEvent {
    Connected(ConnectionInfo),
    /// The mirror was replaced by a snapshot.
    Reset,
    /// A delta was applied to the mirror.
    Delta {
        revision: u64,
        changes: Vec<MirrorChange>,
    },
    /// A browser profile's bookmark tree changed (`bookmarks-changed`):
    /// read it again with `list-bookmarks`. Reported after `Connected` and
    /// before the connection's `Disconnected`; the mirror does not keep
    /// bookmarks.
    BookmarksChanged {
        browser_profile_id: String,
        bookmarks_revision: u64,
    },
    /// The home session's personal state changed (`personal-changed`):
    /// spaces, pins, follows, personal groups or workspace rows. Read it
    /// again with `list-personal` ([`crate::Spaces::from_personal`]).
    /// Reported after `Connected` and before the connection's
    /// `Disconnected`, while the daemon has `profiles-v1`.
    PersonalChanged {
        personal_revision: u64,
    },
    /// The daemon's history changed (`history-changed`): read it again
    /// with `history.entries.list`. `kinds` names what changed (`page`,
    /// `agent`, `command`, `closed`, ...). Reported after `Connected` and
    /// before the connection's `Disconnected`, while the daemon has
    /// `history-v1`.
    HistoryChanged {
        kinds: Vec<String>,
        history_revision: u64,
    },
    /// The user's keybindings.json changed (`keybindings-changed`): read it
    /// again with `keybindings.get`. `origin` names the writer (`user`,
    /// `cli`, `mcp`, `script`, `remote`, `app`, or `file` for a hand edit).
    /// Reported after `Connected` and before the connection's
    /// `Disconnected`, while the daemon has `keybindings-v1`.
    KeybindingsChanged {
        origin: String,
        keybindings_revision: u64,
    },
    /// One `subscribe` event exactly as the daemon sent it
    /// (`DaemonConfig::raw_events`): `name` is its `event` member and
    /// `frame` the whole object. Reported after `Connected` and before the
    /// connection's `Disconnected`. `overflow` is never reported: it ends
    /// the stream and the worker reconnects.
    Event {
        name: String,
        frame: serde_json::Value,
    },
    /// One applied `session.events` delta as the stream delivered it
    /// (`DaemonConfig::raw_session_deltas`). It comes just before the typed
    /// [`DaemonEvent::Delta`] of the same `revision`, which the mirror
    /// already holds; snapshots and skipped events give none.
    SessionDelta {
        revision: u64,
        /// Boxed: a delta is large next to the other variants.
        frame: Box<cmux::SessionEvent>,
    },
    /// The connection failed or ended; the worker retries after `retry_in`.
    /// `class` is what the failure means ([`ResumeErrorClass`]); `gave_up`
    /// is set once that class has spent its retry budget, and `retry_in` is
    /// then the slow park interval (`max_backoff`).
    Disconnected {
        error: String,
        retry_in: Duration,
        class: ResumeErrorClass,
        gave_up: bool,
    },
    /// The worker exited (after `stop`). Always the last event.
    Stopped,
}

/// Owner of the worker thread. Dropping it stops the worker.
pub struct DaemonClient {
    shared: Arc<Shared>,
    stop_tx: Option<mpsc::Sender<()>>,
    thread: Option<JoinHandle<()>>,
    thread_id: ThreadId,
}

struct Shared {
    mirror: Mutex<Mirror>,
    stopping: AtomicBool,
    cancel: Mutex<Option<StreamCancellation>>,
    connection: Mutex<Option<ConnectionInfo>>,
    /// Loaded by the worker before its first connect, and again when the
    /// daemon refuses it ([`ResumeErrorClass::Auth`]).
    install_key: Mutex<Option<InstallKey>>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|poison| poison.into_inner())
}

type Callback = Box<dyn FnMut(&DaemonEvent, &Mirror) + Send + 'static>;
/// The callback, shared by the worker and its subscribe thread, which call it
/// one at a time.
type SharedCallback = Arc<Mutex<Callback>>;

thread_local! {
    /// Set while this thread runs the callback: `stop` from inside it only
    /// signals.
    static IN_CALLBACK: Cell<bool> = const { Cell::new(false) };
}

impl DaemonClient {
    /// Starts the worker. `on_event` runs on the worker thread, once per
    /// event, in order, with the mirror as of that event.
    pub fn spawn(
        config: DaemonConfig,
        on_event: impl FnMut(&DaemonEvent, &Mirror) + Send + 'static,
    ) -> std::io::Result<Self> {
        let shared = Arc::new(Shared {
            mirror: Mutex::new(Mirror::default()),
            stopping: AtomicBool::new(false),
            cancel: Mutex::new(None),
            connection: Mutex::new(None),
            install_key: Mutex::new(None),
        });
        let (stop_tx, stop_rx) = mpsc::channel();
        let worker_shared = shared.clone();
        let thread =
            std::thread::Builder::new().name("cmux-daemon-client".into()).spawn(move || {
                let on_event: SharedCallback = Arc::new(Mutex::new(Box::new(on_event)));
                run(config, worker_shared, stop_rx, on_event);
            })?;
        let thread_id = thread.thread().id();
        Ok(Self { shared, stop_tx: Some(stop_tx), thread: Some(thread), thread_id })
    }

    /// A copy of the current mirror.
    pub fn mirror(&self) -> Mirror {
        lock(&self.shared.mirror).clone()
    }

    /// Reads the mirror without copying it. Keep `f` short: the worker waits.
    pub fn with_mirror<R>(&self, f: impl FnOnce(&Mirror) -> R) -> R {
        f(&lock(&self.shared.mirror))
    }

    /// The current connection, if connected.
    pub fn connection(&self) -> Option<ConnectionInfo> {
        lock(&self.shared.connection).clone()
    }

    /// The app's install key, once the worker loaded it (before its first
    /// `Connected`). Prove the app with it on a connection of your own:
    /// [`AppConnection::connect`]. A secret: never log it (its `Debug`
    /// shows only the install id).
    pub fn install_key(&self) -> Option<InstallKey> {
        lock(&self.shared.install_key).clone()
    }

    /// Stops the worker and waits for it: at once when it is waiting on the
    /// event stream or a retry, else after the current bounded step (a
    /// request deadline, or `ensure_timeout` while starting the daemon).
    /// Called from the callback it only signals; the worker exits after the
    /// callback returns.
    pub fn stop(&mut self) {
        self.shared.stopping.store(true, Ordering::SeqCst);
        self.stop_tx.take();
        if let Some(cancel) = lock(&self.shared.cancel).take() {
            let _ = cancel.cancel();
        }
        if std::thread::current().id() != self.thread_id
            && !IN_CALLBACK.with(Cell::get)
            && let Some(thread) = self.thread.take()
        {
            let _ = thread.join();
        }
    }
}

impl Drop for DaemonClient {
    fn drop(&mut self) {
        self.stop();
    }
}

fn run(
    config: DaemonConfig,
    shared: Arc<Shared>,
    stop_rx: mpsc::Receiver<()>,
    on_event: SharedCallback,
) {
    let mut budget = ResumeBudget::new();
    *lock(&shared.install_key) = load_install_key(&config);
    while !shared.stopping.load(Ordering::SeqCst) {
        let result = session(&config, &shared, &on_event, &mut budget);
        *lock(&shared.connection) = None;
        lock(&shared.cancel).take();
        if shared.stopping.load(Ordering::SeqCst) {
            break;
        }
        let end = match result {
            Ok(()) => SessionEnd::stream_ended(),
            Err(end) => end,
        };
        let next = reconnect_after(&mut budget, end.class, &config);
        let SessionEnd { class, error } = end;
        let retry_in = next.retry_in;
        if next.gave_up {
            log::warn!(
                "cmux daemon: {error} ({class}: retry budget spent); trying again in {retry_in:?}"
            );
        } else {
            log::warn!("cmux daemon: {error} ({class}); retrying in {retry_in:?}");
        }
        emit(
            &shared,
            &on_event,
            &DaemonEvent::Disconnected { error, retry_in, class, gave_up: next.gave_up },
        );
        // Interruptible wait: `stop` drops the sender, which wakes this.
        if !retry_in.is_zero() {
            match stop_rx.recv_timeout(retry_in) {
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                _ => break,
            }
        }
        if next.refresh_key {
            *lock(&shared.install_key) = load_install_key(&config);
        }
    }
    emit(&shared, &on_event, &DaemonEvent::Stopped);
}

fn load_install_key(config: &DaemonConfig) -> Option<InstallKey> {
    let key = config.install_key_path().and_then(|file| InstallKey::load_or_create(&file));
    if config.install_key_path().is_some() && key.is_none() {
        log::warn!("cmux daemon: no install key; this app cannot prove itself to the daemon");
    }
    key
}

/// What the worker does after a session ended with some class.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Reconnect {
    /// The wait before connecting again.
    pub retry_in: Duration,
    /// Load the install key again before connecting.
    pub refresh_key: bool,
    /// The class spent its budget: reported, then one try per `max_backoff`.
    pub gave_up: bool,
}

/// The class's decision for this worker. Every reconnect is a fresh
/// snapshot, so the class decides only the wait and whether the key is
/// loaded again: a gap or a clean close reconnects at once, a refused key
/// is loaded again once, and a transient failure keeps the configured
/// `min_backoff`..`max_backoff` doubling. Once the class's attempts are spent
/// the failure is surfaced (`gave_up`), the worker waits `max_backoff`, and
/// the budget starts over: never faster than that, never silently.
pub(crate) fn reconnect_after(
    budget: &mut ResumeBudget,
    class: ResumeErrorClass,
    config: &DaemonConfig,
) -> Reconnect {
    match budget.on_failure(class) {
        Decision::Act { step, after, attempt } => {
            let after = match class {
                ResumeErrorClass::Transient => {
                    config.min_backoff.saturating_mul(1u32 << (attempt - 1).min(16))
                }
                _ => after,
            };
            Reconnect {
                retry_in: after.min(config.max_backoff),
                refresh_key: step == NextStep::RefreshCredential,
                gave_up: false,
            }
        }
        Decision::Surface { .. } => {
            budget.reset();
            Reconnect { retry_in: config.max_backoff, refresh_key: false, gave_up: true }
        }
    }
}

fn emit(shared: &Shared, on_event: &SharedCallback, event: &DaemonEvent) {
    emit_all(shared, on_event, std::slice::from_ref(event));
}

/// Reports `events` in order under one hold of the callback, so no event
/// of the subscribe thread comes between them.
fn emit_all(shared: &Shared, on_event: &SharedCallback, events: &[DaemonEvent]) {
    let mirror = lock(&shared.mirror);
    let mut callback = lock(on_event);
    IN_CALLBACK.with(|flag| flag.set(true));
    for event in events {
        callback(event, &mirror);
    }
    IN_CALLBACK.with(|flag| flag.set(false));
}

/// One connection's life. Returns when the stream ends or fails.
fn session(
    config: &DaemonConfig,
    shared: &Arc<Shared>,
    on_event: &SharedCallback,
    budget: &mut ResumeBudget,
) -> Result<(), SessionEnd> {
    let mut info = ConnectionInfo::default();
    match &config.socket {
        Some(socket) => info.socket = socket.clone(),
        None => {
            let binary = match &config.binary {
                Some(binary) => binary.clone(),
                None => launcher::resolve_binary().map_err(|e| SessionEnd::launch(&e))?,
            };
            let mut launcher = Launcher::new(binary, config.session.clone());
            launcher.state_dir = config.state_dir.clone();
            launcher.timeout = config.ensure_timeout;
            launcher.install_key = lock(&shared.install_key).clone();
            let ensured = launcher.ensure().map_err(|e| SessionEnd::launch(&e))?;
            info.socket = ensured.socket;
            info.pid = Some(ensured.pid);
            info.started = ensured.status == "started";
        }
    }

    // Protocol-12 identify for build commit and capabilities (protocol/2
    // has no identify). Informational: a failure does not block the tree.
    match identify(&info.socket, config.request_timeout) {
        Ok(identity) => {
            info.build_commit = match identity.build_commit {
                cmux::raw::Optional::Value(commit) => Some(commit),
                _ => None,
            };
            info.protocol = Some(identity.protocol);
            info.capabilities = identity.capabilities.unwrap_or_default();
        }
        Err(e) => log::warn!("cmux daemon: identify failed: {e}"),
    }
    // A probe connection, as the app's own requests will make: the daemon
    // either holds this key or not for its whole life. Its `client-hello`
    // role main tells an app session's owner that its app came, and from
    // then on the owner stops when no client is connected and nothing else
    // keeps it (cmux-tui `server/owner_keepers.rs`). So the probe stays
    // open until the daemon has answered the long-lived connection
    // ([`follow`]): closed first, it would leave the owner a moment with no
    // client at all.
    let mut probe = None;
    let key = lock(&shared.install_key).clone();
    if let Some(key) = key.as_ref() {
        match AppConnection::connect(&info.socket, Some(key), config.request_timeout) {
            Ok(connection) => {
                info.verified_app = connection.verified();
                probe = Some(connection);
            }
            Err(e) => log::warn!("cmux daemon: client-hello probe failed: {e}"),
        }
    }

    let client = cmux::Client::connect(
        Config::from_socket_path(&info.socket)
            .with_timeout(config.request_timeout)
            .with_capabilities(declared_capabilities(&config.capabilities, &info.capabilities)),
    )
    .map_err(|e| SessionEnd::sdk(&format!("connect {}", info.socket.display()), &e))?;
    let result = follow(config, shared, on_event, budget, &client, info, probe);
    let _ = client.close();
    result
}

fn identify(
    socket: &std::path::Path,
    timeout: Duration,
) -> cmux::raw::Result<cmux::raw::IdentifyResult> {
    let config = cmux::raw::ClientConfig::from_socket_path(socket).with_timeout(timeout);
    cmux::raw::Client::connect(config)?.identify_server()
}

fn follow(
    config: &DaemonConfig,
    shared: &Arc<Shared>,
    on_event: &SharedCallback,
    budget: &mut ResumeBudget,
    client: &cmux::Client,
    mut info: ConnectionInfo,
    probe: Option<AppConnection>,
) -> Result<(), SessionEnd> {
    let session = client.current_session();
    // Names this control connection in `client.list` (protocol/2's
    // set-client-info). Informational, like identify.
    match session.connected_client(Selector::current()).update_metadata(ClientMetadataOptions {
        name: Update::Set(config.client_name.clone()),
        kind: Update::Set(config.client_kind.clone()),
    }) {
        Ok(me) => info.client_id = Some(me.id),
        Err(e) => log::warn!("cmux daemon: client.metadata.update failed: {e}"),
    }
    // The daemon has answered on this connection, so it counts it as a
    // client: the probe may go ([`session`]).
    if let Some(probe) = probe {
        probe.close();
    }

    let snapshot = session.snapshot().map_err(|e| SessionEnd::sdk("session.snapshot", &e))?;
    let cursor = snapshot.cursor.clone();
    info.session_id = snapshot.session.id.to_string();
    info.generation = cursor.generation.clone();
    let mut events = session
        .events(EventStreamOptions { cursor: Some(cursor) })
        .map_err(|e| SessionEnd::sdk("session.events", &e))?;
    *lock(&shared.cancel) = Some(events.cancellation());
    if shared.stopping.load(Ordering::SeqCst) {
        let _ = events.cancel();
        return Ok(());
    }

    lock(&shared.mirror).reset(snapshot);
    *lock(&shared.connection) = Some(info.clone());
    budget.on_success();
    let advertised = |name: &str| info.capabilities.iter().any(|capability| capability == name);
    let follow = Follow {
        bookmarks: config.bookmark_events && advertised(BOOKMARKS_CAPABILITY),
        personal: config.personal_events && advertised(PROFILES_CAPABILITY),
        history: config.history_events && advertised(HISTORY_CAPABILITY),
        keybindings: config.keybinding_events && advertised(KEYBINDINGS_CAPABILITY),
        raw: config.raw_events,
    };
    let socket = info.socket.clone();
    emit(shared, on_event, &DaemonEvent::Connected(info));
    emit(shared, on_event, &DaemonEvent::Reset);
    // Ends (closed and joined) when this function returns, so no
    // BookmarksChanged, PersonalChanged, HistoryChanged or KeybindingsChanged follows
    // the connection's Disconnected.
    let _subscribed = if follow.bookmarks
        || follow.personal
        || follow.history
        || follow.keybindings
        || follow.raw
    {
        let follower = SubscribeEvents::start(
            &socket,
            config,
            follow,
            shared,
            on_event,
            events.cancellation(),
        );
        Some(follower.inspect_err(|_| {
            let _ = events.cancel();
        })?)
    } else {
        None
    };

    // Event-driven: `recv` blocks until the daemon sends, the stream is
    // canceled by `stop`, or the socket closes.
    loop {
        let item = match events.recv() {
            Ok(Some(item)) => item,
            Ok(None) => return Err(SessionEnd::stream_ended()),
            Err(e) => return Err(SessionEnd::sdk("session.events", &e)),
        };
        let frame = config.raw_session_deltas.then(|| Box::new(item.value.clone()));
        let applied = {
            let mut mirror = lock(&shared.mirror);
            let applied = mirror.apply(item.value);
            applied.map(|a| (a, mirror.revision().unwrap_or(0)))
        };
        match applied {
            Ok((Applied::Reset, _)) => emit(shared, on_event, &DaemonEvent::Reset),
            Ok((Applied::Delta(changes), revision)) => {
                let delta = DaemonEvent::Delta { revision, changes };
                match frame {
                    Some(frame) => emit_all(
                        shared,
                        on_event,
                        &[DaemonEvent::SessionDelta { revision, frame }, delta],
                    ),
                    None => emit(shared, on_event, &delta),
                }
            }
            Ok((Applied::Skipped, _)) => {}
            Err(e) => {
                let _ = events.cancel();
                return Err(SessionEnd::mirror(&e));
            }
        }
    }
}

/// Which `subscribe` events a connection reports.
#[derive(Clone, Copy, Debug)]
struct Follow {
    bookmarks: bool,
    personal: bool,
    history: bool,
    keybindings: bool,
    raw: bool,
}

/// The `bookmarks-changed`, `personal-changed`, `history-changed` and
/// `keybindings-changed` follower of one
/// connection: a protocol-12 `subscribe` stream read on its own thread.
/// Dropping it closes the stream and joins the thread.
struct SubscribeEvents {
    closer: cmux::raw::StreamCloser,
    thread: Option<JoinHandle<()>>,
}

impl SubscribeEvents {
    fn start(
        socket: &std::path::Path,
        config: &DaemonConfig,
        follow: Follow,
        shared: &Arc<Shared>,
        on_event: &SharedCallback,
        session_events: StreamCancellation,
    ) -> Result<Self, SessionEnd> {
        let raw =
            cmux::raw::ClientConfig::from_socket_path(socket).with_timeout(config.request_timeout);
        let mut client = cmux::raw::Client::connect(raw)
            .map_err(|e| SessionEnd::sdk("subscribe events: connect", &e))?;
        let mut stream = client
            .subscribe(cmux::raw::SubscribeRequest {
                surface: cmux::raw::Optional::Missing,
                tree_events: cmux::raw::Optional::Missing,
            })
            .map_err(|e| SessionEnd::sdk("subscribe events: subscribe", &e))?;
        let closer = stream.closer();
        let (shared, on_event) = (shared.clone(), on_event.clone());
        let thread = std::thread::Builder::new()
            .name("cmux-daemon-client-subscribe".into())
            .spawn(move || {
                let error = loop {
                    let frame = match stream.recv_frame_timeout(SUBSCRIBE_EVENTS_IDLE) {
                        Ok(frame) => frame,
                        Err(cmux::raw::Error::Timeout(_)) => continue,
                        Err(cmux::raw::Error::Closed) => return,
                        Err(e) => break e.to_string(),
                    };
                    let name = frame.get("event").and_then(serde_json::Value::as_str);
                    if name == Some("overflow") {
                        break "overflow".to_string();
                    }
                    let raw = follow.raw.then(|| DaemonEvent::Event {
                        name: name.unwrap_or_default().to_owned(),
                        frame: frame.clone(),
                    });
                    if let Some(event) = typed_event(cmux::raw::decode_event(frame), follow) {
                        emit(&shared, &on_event, &event);
                    }
                    if let Some(event) = raw {
                        emit(&shared, &on_event, &event);
                    }
                };
                // A lost subscribe stream would hide changes: end the
                // connection so the worker reconnects both streams.
                log::warn!("cmux daemon: subscribe events ended: {error}");
                let _ = session_events.cancel();
                drop(client);
            })
            .map_err(|e| {
                SessionEnd::new(
                    ResumeErrorClass::from_io_kind(e.kind()),
                    format!("subscribe events: thread: {e}"),
                )
            })?;
        Ok(Self { closer, thread: Some(thread) })
    }
}

/// The typed report of one `subscribe` event, when `follow` asks for it.
fn typed_event(event: cmux::raw::Event, follow: Follow) -> Option<DaemonEvent> {
    Some(match event {
        cmux::raw::Event::BookmarksChanged(changed) if follow.bookmarks => {
            DaemonEvent::BookmarksChanged {
                browser_profile_id: changed.browser_profile_id,
                bookmarks_revision: changed.bookmarks_revision,
            }
        }
        cmux::raw::Event::PersonalChanged(changed) if follow.personal => {
            DaemonEvent::PersonalChanged { personal_revision: changed.personal_revision }
        }
        cmux::raw::Event::HistoryChanged(changed) if follow.history => {
            DaemonEvent::HistoryChanged { kinds: changed.kinds, history_revision: changed.revision }
        }
        cmux::raw::Event::KeybindingsChanged(changed) if follow.keybindings => {
            DaemonEvent::KeybindingsChanged {
                origin: keybindings_origin(changed.origin).to_owned(),
                keybindings_revision: changed.revision,
            }
        }
        _ => return None,
    })
}

/// The wire name of a `keybindings-changed` origin.
fn keybindings_origin(origin: cmux::raw::KeybindingsChangedEventOrigin) -> &'static str {
    use cmux::raw::KeybindingsChangedEventOrigin as Origin;
    match origin {
        Origin::User => "user",
        Origin::Cli => "cli",
        Origin::Mcp => "mcp",
        Origin::Script => "script",
        Origin::Remote => "remote",
        Origin::App => "app",
        Origin::File => "file",
    }
}

impl Drop for SubscribeEvents {
    fn drop(&mut self) {
        self.closer.close();
        if let Some(thread) = self.thread.take()
            && thread.thread().id() != std::thread::current().id()
        {
            let _ = thread.join();
        }
    }
}
