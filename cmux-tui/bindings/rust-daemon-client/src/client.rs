//! The connection worker: one owned thread that ensures the daemon, connects
//! with the SDK, identifies, loads a snapshot, follows `session.events`, and
//! reports each step to a caller callback. See the crate docs for the thread
//! contract.

use crate::launcher::{self, Launcher};
use crate::mirror::{Applied, Mirror, MirrorChange};
use cmux::{
    ClientMetadataOptions, Config, ConnectedClientId, EventStreamOptions, Selector,
    StreamCancellation, Update,
};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::{JoinHandle, ThreadId};
use std::time::Duration;

/// Session name when `DaemonConfig::session` is not set otherwise.
pub const DEFAULT_SESSION: &str = "cmux2-gpui";

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
}

impl DaemonConfig {
    pub fn new(session: impl Into<String>) -> Self {
        Self {
            session: session.into(),
            socket: None,
            binary: None,
            state_dir: None,
            client_name: "cmux2".to_string(),
            client_kind: "frontend".to_string(),
            request_timeout: Duration::from_secs(5),
            ensure_timeout: Duration::from_secs(20),
            min_backoff: Duration::from_millis(250),
            max_backoff: Duration::from_secs(10),
        }
    }
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
    /// The connection failed or ended; the worker retries after `retry_in`.
    Disconnected {
        error: String,
        retry_in: Duration,
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
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|poison| poison.into_inner())
}

type Callback = Box<dyn FnMut(&DaemonEvent, &Mirror) + Send + 'static>;

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
        });
        let (stop_tx, stop_rx) = mpsc::channel();
        let worker_shared = shared.clone();
        let thread = std::thread::Builder::new()
            .name("cmux-daemon-client".into())
            .spawn(move || run(config, worker_shared, stop_rx, Box::new(on_event)))?;
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
    mut on_event: Callback,
) {
    let mut backoff = config.min_backoff;
    while !shared.stopping.load(Ordering::SeqCst) {
        let result = session(&config, &shared, &mut on_event, &mut backoff);
        *lock(&shared.connection) = None;
        lock(&shared.cancel).take();
        if shared.stopping.load(Ordering::SeqCst) {
            break;
        }
        let error = match result {
            Ok(()) => "event stream ended".to_string(),
            Err(e) => e,
        };
        log::warn!("cmux daemon: {error}; retrying in {backoff:?}");
        emit(&shared, &mut on_event, &DaemonEvent::Disconnected { error, retry_in: backoff });
        // Interruptible wait: `stop` drops the sender, which wakes this.
        match stop_rx.recv_timeout(backoff) {
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            _ => break,
        }
        backoff = (backoff * 2).min(config.max_backoff);
    }
    emit(&shared, &mut on_event, &DaemonEvent::Stopped);
}

fn emit(shared: &Shared, on_event: &mut Callback, event: &DaemonEvent) {
    let mirror = lock(&shared.mirror);
    on_event(event, &mirror);
}

/// One connection's life. Returns when the stream ends or fails.
fn session(
    config: &DaemonConfig,
    shared: &Shared,
    on_event: &mut Callback,
    backoff: &mut Duration,
) -> Result<(), String> {
    let mut info = ConnectionInfo::default();
    match &config.socket {
        Some(socket) => info.socket = socket.clone(),
        None => {
            let binary = match &config.binary {
                Some(binary) => binary.clone(),
                None => launcher::resolve_binary().map_err(|e| e.to_string())?,
            };
            let mut launcher = Launcher::new(binary, config.session.clone());
            launcher.state_dir = config.state_dir.clone();
            launcher.timeout = config.ensure_timeout;
            let ensured = launcher.ensure().map_err(|e| e.to_string())?;
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

    let client = cmux::Client::connect(
        Config::from_socket_path(&info.socket).with_timeout(config.request_timeout),
    )
    .map_err(|e| format!("connect {}: {e}", info.socket.display()))?;
    let result = follow(config, shared, on_event, backoff, &client, info);
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
    shared: &Shared,
    on_event: &mut Callback,
    backoff: &mut Duration,
    client: &cmux::Client,
    mut info: ConnectionInfo,
) -> Result<(), String> {
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

    let snapshot = session.snapshot().map_err(|e| format!("session.snapshot: {e}"))?;
    let cursor = snapshot.cursor.clone();
    info.session_id = snapshot.session.id.to_string();
    info.generation = cursor.generation.clone();
    let mut events = session
        .events(EventStreamOptions { cursor: Some(cursor) })
        .map_err(|e| format!("session.events: {e}"))?;
    *lock(&shared.cancel) = Some(events.cancellation());
    if shared.stopping.load(Ordering::SeqCst) {
        let _ = events.cancel();
        return Ok(());
    }

    lock(&shared.mirror).reset(snapshot);
    *lock(&shared.connection) = Some(info.clone());
    *backoff = config.min_backoff;
    emit(shared, on_event, &DaemonEvent::Connected(info));
    emit(shared, on_event, &DaemonEvent::Reset);

    // Event-driven: `recv` blocks until the daemon sends, the stream is
    // canceled by `stop`, or the socket closes.
    loop {
        let item = match events.recv() {
            Ok(Some(item)) => item,
            Ok(None) => return Ok(()),
            Err(e) => return Err(format!("session.events: {e}")),
        };
        let applied = {
            let mut mirror = lock(&shared.mirror);
            let applied = mirror.apply(item.value);
            applied.map(|a| (a, mirror.revision().unwrap_or(0)))
        };
        match applied {
            Ok((Applied::Reset, _)) => emit(shared, on_event, &DaemonEvent::Reset),
            Ok((Applied::Delta(changes), revision)) => {
                emit(shared, on_event, &DaemonEvent::Delta { revision, changes });
            }
            Ok((Applied::Skipped, _)) => {}
            Err(e) => {
                let _ = events.cancel();
                return Err(format!("resync: {e}"));
            }
        }
    }
}
