//! Byte-mode terminal attachment on its own protocol-v12 connection.
//!
//! [`ByteAttachment::open`] is the Rust twin of the cmux-next Swift
//! `TerminalAttachment`: it connects, sends `identify` and `set-client-info`
//! on the new connection (the daemon mints a view lease only for a connection
//! that advertised `view-attachment-lease-v1`), attaches with
//! `attach-surface mode:"bytes"`, and splits the connection into a
//! [`ByteAttachmentReader`] and a [`ByteAttachmentWriter`].
//!
//! # Thread contract
//!
//! - The API is blocking and spawns no thread. No async runtime is needed.
//! - The reader is `Send` but not `Sync`: one thread owns it and is the only
//!   code that reads the socket. It must drain items continuously; a stalled
//!   reader makes the daemon overflow or close the connection.
//! - The writer is `Clone + Send + Sync` and never reads. One mutex serializes
//!   whole request frames, so calls from one thread reach the daemon in call
//!   order and calls from several threads in lock order. Every frame write is
//!   bounded by the write timeout. A failed or timed-out write may leave a
//!   partial frame, so it closes the connection: later writer calls return
//!   [`Error::Closed`](crate::raw::Error::Closed) and the reader ends with
//!   [`EndReason::ConnectionLost`].
//! - After `open` every writer command is fire-and-forget. A daemon rejection
//!   arrives on the reader as [`AttachmentItem::CommandRejected`].
//! - Dropping the last writer clone detaches the view. Dropping the reader
//!   closes the connection.
//!
//! # Reconnect
//!
//! The SDK never reconnects. A reattach replays into a fresh terminal mirror,
//! and after a daemon restart the caller's control mirror must resolve the
//! terminal again; only the caller has both. After [`AttachmentItem::Ended`],
//! consult [`EndReason::reattach`] and open a new attachment, preferably with
//! [`AttachTarget::Terminal`] so the identity fence rejects a stale terminal.
//!
//! # Input
//!
//! Input always uses `send {surface, bytes}` on the attachment connection,
//! including for terminals with no tab: an identity attach learns their
//! numeric surface from the first `vt-state`. `send` also counts as shared
//! sizing activity for this view.

mod reader;
mod writer;

pub use reader::ByteAttachmentReader;
pub use writer::ByteAttachmentWriter;

use crate::TerminalId;
use crate::client::{ClientConfig, CmuxError, Result, ServerInfo, StreamControl, ensure_success};
use crate::codec::JsonLineConnection;
use crate::generated::{
    DetachReason, Id, KittyGraphicsState, KittyImageAlias, SizeDetachActor, SizeState,
    TerminalColors,
};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::net::Shutdown;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

/// Client capabilities every byte attachment advertises through
/// `set-client-info`. The set is fixed: it names exactly the event shapes the
/// reader decodes, so a caller cannot enable a shape the SDK does not know.
pub const BYTE_ATTACHMENT_CAPABILITIES: &[&str] = &[
    "view-attachment-lease-v1",
    "view-attachment-detach-v1",
    "attach-identity-v1",
    "terminal-pending-sequence-v1",
    "shared-sizing-v1",
    "terminal-color-overrides-v1",
];

/// Server capabilities `open` requires before it attaches.
const REQUIRED_SERVER_CAPABILITIES: &[&str] =
    &["view-attachment-lease-v1", "view-attachment-detach-v1", "attach-initial-size"];
const IDENTITY_CAPABILITY: &str = "attach-identity-v1";
const MIN_PROTOCOL: u32 = 12;
const ATTACH: &str = "attach-surface";
/// Writer request ids start after the four handshake requests.
const FIRST_WRITER_ID: u64 = 5;

/// Which terminal to attach.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AttachTarget {
    /// A numeric v12 surface id from the caller's current mirror.
    Surface(Id),
    /// A public terminal id fenced by the daemon generation it was read in
    /// (`attach-identity-v1`). Preferred for reattach.
    Terminal { id: TerminalId, generation: String },
}

/// A terminal grid in cells. Each dimension is at least 1 on the wire.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct CellSize {
    pub cols: u16,
    pub rows: u16,
}

impl CellSize {
    pub fn new(cols: u16, rows: u16) -> Self {
        Self { cols: cols.max(1), rows: rows.max(1) }
    }

    fn clamped(self) -> Self {
        Self::new(self.cols, self.rows)
    }
}

/// Identity sent with `set-client-info` on the attachment connection.
/// Capabilities and identity are per connection, so the control
/// connection's values do not apply here. Unset fields are omitted.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ClientIdentity {
    pub name: Option<String>,
    /// Defaults to `frontend`.
    pub kind: Option<String>,
    pub user_id: Option<String>,
    pub display_name: Option<String>,
    /// `mac`, `iphone`, `ipad`, `tui`, or `browser`.
    pub device_kind: Option<String>,
    pub device_name: Option<String>,
    pub device_id: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AttachOptions {
    pub client: ClientIdentity,
    /// Claim canonical geometry (`set-client-sizing {enabled, exclusive}`)
    /// before `open` returns. The focused view in the key window does this.
    pub claim_geometry: bool,
    /// Deadline for each writer frame, and for the handshake writes.
    /// Defaults to the config timeout.
    pub write_timeout: Option<Duration>,
}

/// Facts the daemon reported while attaching.
#[derive(Clone, Debug, PartialEq)]
pub struct AttachInfo {
    pub surface: Id,
    /// The opaque lease naming this connection's attach stream.
    pub lease: String,
    /// This view's shared-sizing participant id.
    pub participant: Option<String>,
    pub size_state: Option<SizeState>,
    /// The daemon generation reported by `identify` on this connection.
    pub generation: String,
    pub server: ServerInfo,
}

/// A VT replay: feed `data` into a fresh terminal of `cols` x `rows`, restore
/// the Kitty sidecars, apply `colors` (including cursor style), then write
/// `pending` immediately before the next output.
#[derive(Clone, Debug, PartialEq)]
pub struct Replay {
    pub surface: Id,
    pub cols: u16,
    pub rows: u16,
    pub data: Vec<u8>,
    pub pending: Vec<u8>,
    pub colors: Option<TerminalColors>,
    pub kitty_image_aliases: Vec<KittyImageAlias>,
    pub kitty_graphics_state: Option<KittyGraphicsState>,
}

/// One item of the attach stream, in wire order:
/// `VtState -> (Output | Resized | ColorsChanged | ScrollChanged | SizeState | ...)* -> Ended`.
#[derive(Clone, Debug, PartialEq)]
#[non_exhaustive]
pub enum AttachmentItem {
    /// The initial replay. Always the first item.
    VtState(Replay),
    /// Live PTY bytes in order. Apply `colors` with this chunk when present.
    Output {
        data: Vec<u8>,
        colors: Option<TerminalColors>,
    },
    /// The canonical grid changed: discard the mirror and rebuild it from
    /// this replay in a fresh terminal before later output.
    Resized(Replay),
    ColorsChanged(TerminalColors),
    ScrollChanged {
        offset: u64,
        at_bottom: bool,
    },
    /// Shared sizing state; order by `generation`.
    SizeState(SizeState),
    /// Only this view left shared sizing (`detached` with `scope:"view"`).
    /// The stream stays; `reattach-view` restores the view.
    ViewDetached {
        actor: Option<SizeDetachActor>,
    },
    /// The daemon rejected a writer command. The stream continues.
    CommandRejected {
        command: &'static str,
        message: String,
    },
    /// An event this SDK does not model, such as `notification`.
    Other {
        event: String,
        raw: Value,
    },
    /// The stream ended. Delivered exactly once; later reads return `Closed`.
    Ended(EndReason),
}

#[derive(Clone, Debug, PartialEq)]
pub enum EndReason {
    /// The daemon ended the stream. `None` is an absent or unrecognized
    /// reason, which the spec treats as `network`.
    Detached {
        reason: Option<DetachReason>,
        actor: Option<SizeDetachActor>,
    },
    /// This view fell behind the daemon's event queue.
    Overflow,
    /// `detach`, a stream closer, or a dropped writer ended it.
    ClosedByClient,
    ConnectionLost(String),
}

/// What the caller should do after an attachment ends.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reattach {
    /// Open a new attachment now and replay into a fresh terminal.
    Now,
    /// The daemon is shutting down: wait until the control mirror resolves
    /// the terminal in the new generation, then reattach.
    AfterGenerationResolves,
    /// Do not reattach automatically (a kick, or the client's own detach).
    Never,
}

impl EndReason {
    pub fn reattach(&self) -> Reattach {
        match self {
            Self::Detached { reason: Some(DetachReason::DisconnectedBy), .. }
            | Self::ClosedByClient => Reattach::Never,
            Self::Detached { reason: Some(DetachReason::HostShutdown), .. } => {
                Reattach::AfterGenerationResolves
            }
            Self::Detached { .. } | Self::Overflow | Self::ConnectionLost(_) => Reattach::Now,
        }
    }
}

/// An open attachment. Destructure it to move the halves to their threads.
pub struct ByteAttachment {
    pub writer: ByteAttachmentWriter,
    pub reader: ByteAttachmentReader,
    pub info: AttachInfo,
}

impl ByteAttachment {
    /// Opens a dedicated connection and attaches in byte mode at `size`.
    ///
    /// Blocking; each handshake step is bounded by `config.timeout`. Fails
    /// with `ProtocolVersion` or `MissingCapability` before attaching when the
    /// daemon lacks protocol 12, `view-attachment-lease-v1`,
    /// `view-attachment-detach-v1`, `attach-initial-size`, or (for
    /// [`AttachTarget::Terminal`]) `attach-identity-v1`.
    pub fn open(
        config: &ClientConfig,
        target: AttachTarget,
        size: CellSize,
        options: AttachOptions,
    ) -> Result<Self> {
        if config.max_queued_events == 0 {
            return Err(CmuxError::InvalidArgument(
                "max_queued_events must be greater than zero".to_string(),
            ));
        }
        let write_timeout = options.write_timeout.unwrap_or(config.timeout);
        if write_timeout.is_zero() {
            return Err(CmuxError::InvalidArgument("write_timeout must be positive".into()));
        }
        let mut connection = JsonLineConnection::connect(
            &config.socket_path,
            config.timeout,
            config.timeout,
            config.max_frame_bytes,
        )?;
        // Socket options are per socket, so this also bounds the handshake
        // writes. Set it before the handshake: macOS rejects setsockopt with
        // EINVAL once the peer has closed, and a daemon may close right
        // after the attach reply (the reader then reports the end).
        let socket = connection.shutdown_clone()?;
        socket
            .set_write_timeout(Some(write_timeout))
            .map_err(|error| CmuxError::Connection(format!("set write timeout failed: {error}")))?;
        let mut handshake = Handshake {
            connection: &mut connection,
            queued: VecDeque::new(),
            replies: HashMap::new(),
            max_queued: config.max_queued_events,
        };
        let opened = handshake.run(&target, size.clamped(), &options);
        let queued = std::mem::take(&mut handshake.queued);
        let info = match opened {
            Ok(info) => info,
            Err(error) => {
                connection.close();
                return Err(error);
            }
        };
        let control = Arc::new(StreamControl {
            socket: connection.shutdown_clone()?,
            closed: AtomicBool::new(false),
        });
        let shared = Arc::new(Shared {
            surface: info.surface,
            lease: info.lease.clone(),
            control,
            outbound: Mutex::new(Outbound {
                socket,
                next_id: FIRST_WRITER_ID,
                last_reported: Some(size.clamped()),
            }),
            pending: Mutex::new(BTreeMap::new()),
            detached: AtomicBool::new(false),
            ended: AtomicBool::new(false),
            poisoned: Mutex::new(None),
        });
        Ok(Self {
            writer: ByteAttachmentWriter::new(Arc::clone(&shared)),
            reader: ByteAttachmentReader::new(connection, queued, shared),
            info,
        })
    }
}

/// State both halves share.
pub(crate) struct Shared {
    surface: Id,
    lease: String,
    control: Arc<StreamControl>,
    outbound: Mutex<Outbound>,
    /// Writer request id -> command name, for rejection reports. Bounded.
    pending: Mutex<BTreeMap<u64, &'static str>>,
    detached: AtomicBool,
    ended: AtomicBool,
    poisoned: Mutex<Option<String>>,
}

struct Outbound {
    socket: crate::codec::UnixStream,
    next_id: u64,
    last_reported: Option<CellSize>,
}

const MAX_PENDING_COMMANDS: usize = 4_096;

impl Shared {
    fn closed_by_client(&self) -> bool {
        self.detached.load(Ordering::Acquire) || self.control.closed.load(Ordering::Acquire)
    }

    fn is_closed(&self) -> bool {
        self.closed_by_client() || self.ended.load(Ordering::Acquire) || self.poison().is_some()
    }

    fn poison(&self) -> Option<String> {
        lock(&self.poisoned).clone()
    }

    fn set_poison(&self, message: String) {
        lock(&self.poisoned).get_or_insert(message);
        self.shutdown();
    }

    fn shutdown(&self) {
        let _ = self.control.socket.shutdown(Shutdown::Both);
    }

    fn track(&self, id: u64, command: &'static str) {
        let mut pending = lock(&self.pending);
        pending.insert(id, command);
        while pending.len() > MAX_PENDING_COMMANDS {
            pending.pop_first();
        }
    }

    fn take_pending(&self, id: u64) -> Option<&'static str> {
        lock(&self.pending).remove(&id)
    }
}

/// Locks ignoring poisoning: every guarded value stays consistent between
/// statements, so a panicking holder cannot leave it half-written.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

struct Handshake<'a> {
    connection: &'a mut JsonLineConnection,
    queued: VecDeque<Value>,
    replies: HashMap<u64, Value>,
    max_queued: usize,
}

impl Handshake<'_> {
    fn run(
        &mut self,
        target: &AttachTarget,
        size: CellSize,
        options: &AttachOptions,
    ) -> Result<AttachInfo> {
        self.connection.send(&json!({"id": 1, "cmd": "identify"}))?;
        self.connection.send(&client_info_request(2, &options.client))?;
        let identify = self.reply(1, "identify")?;
        self.reply(2, "set-client-info")?;
        let (server, generation) = server_info(&identify)?;
        require_server(&server, target)?;

        let mut attach = json!({
            "id": 3, "cmd": ATTACH, "mode": "bytes", "cols": size.cols, "rows": size.rows
        });
        match target {
            AttachTarget::Surface(surface) => attach["surface"] = json!(surface),
            AttachTarget::Terminal { id, generation } => {
                attach["expected_terminal_id"] = json!(id.as_str());
                attach["expected_generation"] = json!(generation);
            }
        }
        self.connection.send(&attach)?;
        let data = self.reply(3, ATTACH)?;
        let lease = data
            .get("lease")
            .and_then(Value::as_str)
            .filter(|lease| !lease.is_empty())
            .ok_or_else(|| {
                CmuxError::UnexpectedEnvelope(
                    "attach-surface reply has no view lease despite view-attachment-lease-v1"
                        .to_string(),
                )
            })?
            .to_string();
        let surface = match target {
            AttachTarget::Surface(surface) => *surface,
            AttachTarget::Terminal { .. } => self.replayed_surface()?,
        };
        if options.claim_geometry {
            self.connection.send(&json!({
                "id": 4, "cmd": "set-client-sizing", "surface": surface,
                "enabled": true, "exclusive": true
            }))?;
            self.reply(4, "set-client-sizing")?;
        }
        Ok(AttachInfo {
            surface,
            lease,
            participant: data.get("participant").and_then(Value::as_str).map(str::to_string),
            size_state: data
                .get("size_state")
                .and_then(|state| serde_json::from_value(state.clone()).ok()),
            generation,
            server,
        })
    }

    /// Reads until the reply with `id`, keeping events for the reader.
    fn reply(&mut self, id: u64, command: &str) -> Result<Value> {
        loop {
            let message = match self.replies.remove(&id) {
                Some(message) => message,
                None => self.connection.recv()?,
            };
            if message.get("event").is_some() {
                if self.queued.len() == self.max_queued {
                    return Err(CmuxError::QueueOverflow { limit: self.max_queued });
                }
                self.queued.push_back(message);
                continue;
            }
            match message.get("id").and_then(Value::as_u64) {
                Some(received) if received == id => {
                    ensure_success(command, &message)?;
                    return Ok(message.get("data").cloned().unwrap_or_else(|| json!({})));
                }
                Some(other) if other < FIRST_WRITER_ID => {
                    self.replies.insert(other, message);
                }
                _ => {}
            }
        }
    }

    /// The numeric surface an identity attach resolved, from its `vt-state`.
    fn replayed_surface(&self) -> Result<Id> {
        self.queued
            .iter()
            .find(|event| event.get("event").and_then(Value::as_str) == Some("vt-state"))
            .and_then(|event| event.get("surface").and_then(Value::as_u64))
            .ok_or_else(|| {
                CmuxError::UnexpectedEnvelope(
                    "identity attach reply arrived before a vt-state naming its surface"
                        .to_string(),
                )
            })
    }
}

fn client_info_request(id: u64, client: &ClientIdentity) -> Value {
    let mut request = Map::new();
    request.insert("id".into(), json!(id));
    request.insert("cmd".into(), json!("set-client-info"));
    request.insert("kind".into(), json!(client.kind.as_deref().unwrap_or("frontend")));
    request.insert("capabilities".into(), json!(BYTE_ATTACHMENT_CAPABILITIES));
    for (key, value) in [
        ("name", &client.name),
        ("user_id", &client.user_id),
        ("display_name", &client.display_name),
        ("device_kind", &client.device_kind),
        ("device_name", &client.device_name),
        ("device_id", &client.device_id),
    ] {
        if let Some(value) = value {
            request.insert(key.into(), json!(value));
        }
    }
    Value::Object(request)
}

fn server_info(identify: &Value) -> Result<(ServerInfo, String)> {
    let protocol = identify
        .get("protocol")
        .and_then(Value::as_u64)
        .and_then(|protocol| u32::try_from(protocol).ok())
        .ok_or_else(|| CmuxError::UnexpectedEnvelope("identify reply has no protocol".into()))?;
    let capabilities = identify
        .get("capabilities")
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(Value::as_str).map(str::to_string).collect())
        .unwrap_or_default();
    let generation = identify
        .get("generation")
        .and_then(Value::as_str)
        .ok_or_else(|| CmuxError::UnexpectedEnvelope("identify reply has no generation".into()))?
        .to_string();
    Ok((ServerInfo { protocol, capabilities }, generation))
}

fn require_server(server: &ServerInfo, target: &AttachTarget) -> Result<()> {
    if server.protocol < MIN_PROTOCOL {
        return Err(CmuxError::ProtocolVersion {
            command: ATTACH,
            required: MIN_PROTOCOL,
            actual: server.protocol,
        });
    }
    let identity = matches!(target, AttachTarget::Terminal { .. }).then_some(IDENTITY_CAPABILITY);
    for capability in REQUIRED_SERVER_CAPABILITIES.iter().copied().chain(identity) {
        if !server.capabilities.iter().any(|offered| offered == capability) {
            return Err(CmuxError::MissingCapability { command: ATTACH, capability });
        }
    }
    Ok(())
}
