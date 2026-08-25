use crate::CommandMetadata;
use crate::codec::JsonLineConnection;
use crate::generated::{Event, IdentifyResult, decode_event};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::fmt;
use std::mem::{offset_of, size_of};
use std::net::Shutdown;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

pub type Result<T> = std::result::Result<T, CmuxError>;

#[derive(Clone, Debug)]
#[non_exhaustive]
pub enum CmuxError {
    Command {
        command: String,
        message: String,
        id: Option<Value>,
    },
    /// Structured `cmux.protocol/2` operation failure.
    Protocol {
        code: String,
        message: String,
        details: Value,
        retryable: bool,
    },
    /// A destructive layout mutation requires an exact stale-state fence.
    ConfirmationRequired {
        message: String,
        details: crate::ConfirmationRequiredDetails,
    },
    AuthorityDenied {
        command: &'static str,
        authority: &'static str,
    },
    Decode(String),
    Connection(String),
    ConnectionIo {
        message: String,
        kind: std::io::ErrorKind,
    },
    Timeout(String),
    /// A caller canceled one resource operation before its response arrived.
    Cancelled(String),
    /// A mutation lost its response after a transport failure.
    MutationTransport {
        operation: String,
        idempotency_key: String,
        source: Box<CmuxError>,
    },
    ProtocolVersion {
        command: &'static str,
        required: u32,
        actual: u32,
    },
    MissingCapability {
        command: &'static str,
        capability: &'static str,
    },
    InvalidArgument(String),
    FrameTooLarge {
        size: usize,
        limit: usize,
    },
    QueueOverflow {
        limit: usize,
    },
    InvalidId {
        expected_prefix: &'static str,
        value: String,
    },
    UnexpectedEnvelope(String),
    StreamEnded {
        reason: String,
        recovery: Option<String>,
        error: Option<Box<CmuxError>>,
    },
    Closed,
}

impl fmt::Display for CmuxError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Command { command, message, .. } => write!(formatter, "{command}: {message}"),
            Self::Protocol { code, message, .. } => write!(formatter, "{code}: {message}"),
            Self::ConfirmationRequired { message, .. } => {
                write!(formatter, "confirmation.required: {message}")
            }
            Self::AuthorityDenied { command, authority } => {
                write!(
                    formatter,
                    "{command} requires {authority}; explicitly enable provider authority on ClientConfig"
                )
            }
            Self::Decode(message)
            | Self::Connection(message)
            | Self::Timeout(message)
            | Self::Cancelled(message)
            | Self::InvalidArgument(message) => formatter.write_str(message),
            Self::ConnectionIo { .. } => formatter.write_str("cannot connect to cmux session"),
            Self::MutationTransport { operation, idempotency_key, .. } => write!(
                formatter,
                "{operation} transport failed after dispatch; mutation outcome is uncertain \
                 (idempotency_key={idempotency_key})"
            ),
            Self::ProtocolVersion { command, required, actual } => {
                write!(
                    formatter,
                    "{command} requires protocol {required}; server uses protocol {actual}"
                )
            }
            Self::MissingCapability { command, capability } => {
                write!(formatter, "{command} requires server capability {capability}")
            }
            Self::FrameTooLarge { size, limit } => {
                write!(formatter, "JSON frame is {size} bytes; configured limit is {limit}")
            }
            Self::QueueOverflow { limit } => {
                write!(formatter, "event queue exceeded configured limit {limit}")
            }
            Self::InvalidId { expected_prefix, value } => {
                write!(formatter, "expected {expected_prefix}_ opaque ID, got {value:?}")
            }
            Self::UnexpectedEnvelope(message) => formatter.write_str(message),
            Self::StreamEnded { reason, recovery, error } => {
                write!(formatter, "stream ended: {reason}")?;
                if let Some(error) = error {
                    write!(formatter, ": {error}")?;
                }
                if let Some(recovery) = recovery {
                    write!(formatter, " ({recovery})")?;
                }
                Ok(())
            }
            Self::Closed => formatter.write_str("stream is closed"),
        }
    }
}

impl std::error::Error for CmuxError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::MutationTransport { source, .. } => Some(source.as_ref()),
            _ => None,
        }
    }
}

/// Connection settings.
#[derive(Debug, Clone)]
pub struct ClientConfig {
    pub socket_path: PathBuf,
    pub timeout: Duration,
    pub max_frame_bytes: usize,
    pub max_queued_events: usize,
    /// Allows commands that act with external provider authority.
    ///
    /// This is disabled by default. Control, frontend, and local-admin
    /// commands remain enabled.
    pub allow_provider_authority: bool,
}

impl ClientConfig {
    pub fn from_socket_path(socket_path: impl Into<PathBuf>) -> Self {
        Self {
            socket_path: socket_path.into(),
            timeout: Duration::from_secs(10),
            max_frame_bytes: 32 * 1024 * 1024,
            max_queued_events: 1_024,
            allow_provider_authority: false,
        }
    }

    /// Builds a configuration from the environment or a named session.
    ///
    /// This source-compatible convenience API cannot return an error. When no
    /// `CMUX_TUI_SOCKET` or `CMUX_MUX_SOCKET` override is set, invalid session
    /// names use an isolated, deterministic path that cannot select a normal
    /// session socket. An explicit or inherited socket path is authoritative
    /// and bypasses session derivation. Callers handling user input should use
    /// [`Self::try_from_env_or_default_session`] to receive the validation error.
    pub fn from_env_or_default_session(session: &str) -> Self {
        let environment = env_socket_path();
        let socket_path = compatibility_socket_path_for_session(session, environment);
        Self::from_socket_path(socket_path)
    }

    /// Builds a configuration from the environment or a named session.
    ///
    /// Unlike [`Self::from_env_or_default_session`], this API reports an
    /// invalid derived session before constructing a socket path. An explicit
    /// or inherited socket path is authoritative and does not require session
    /// derivation. The older non-fallible API remains source-compatible and
    /// uses an isolated, deterministic path only through the path-only
    /// compatibility helper.
    pub fn try_from_env_or_default_session(session: &str) -> Result<Self> {
        let environment = env_socket_path();
        let socket_path = socket_path_for_session(session, environment)?;
        Ok(Self::from_socket_path(socket_path))
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    pub fn with_max_frame_bytes(mut self, max_frame_bytes: usize) -> Self {
        self.max_frame_bytes = max_frame_bytes;
        self
    }

    pub fn with_max_queued_events(mut self, max_queued_events: usize) -> Self {
        self.max_queued_events = max_queued_events;
        self
    }

    /// Explicitly opts this client into provider-authority commands.
    pub fn with_provider_authority(mut self, allow: bool) -> Self {
        self.allow_provider_authority = allow;
        self
    }
}

impl Default for ClientConfig {
    fn default() -> Self {
        Self::try_from_env_or_default_session("main")
            .expect("the built-in main session name is valid")
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerInfo {
    pub protocol: u32,
    pub capabilities: Vec<String>,
}

pub struct CmuxClient {
    config: ClientConfig,
    connection: JsonLineConnection,
    next_id: u64,
    server: Option<ServerInfo>,
    buffered_events: VecDeque<Event>,
}

impl CmuxClient {
    pub fn connect(config: ClientConfig) -> Result<Self> {
        Self::connect_inner(config, false)
    }

    pub fn connect_with_legacy_fallback(config: ClientConfig) -> Result<Self> {
        Self::connect_inner(config, true)
    }

    fn connect_inner(config: ClientConfig, allow_legacy_fallback: bool) -> Result<Self> {
        if config.max_queued_events == 0 {
            return Err(CmuxError::InvalidArgument(
                "max_queued_events must be greater than zero".to_string(),
            ));
        }
        let mut config = config;
        let mut connection = JsonLineConnection::connect(
            &config.socket_path,
            config.timeout,
            config.timeout,
            config.max_frame_bytes,
        );
        if let Err(CmuxError::ConnectionIo { kind, .. }) = &connection
            && matches!(kind, std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused)
            && is_hashed_socket(&config.socket_path)
            && allow_legacy_fallback
        {
            let Some(legacy) = hashed_socket_legacy_path(&config.socket_path) else {
                return match connection {
                    Ok(_) => unreachable!("connection error was matched above"),
                    Err(error) => Err(error),
                };
            };
            if let Ok(candidate) = JsonLineConnection::connect(
                &legacy,
                config.timeout,
                config.timeout,
                config.max_frame_bytes,
            ) {
                config.socket_path = legacy;
                connection = Ok(candidate);
            }
        }
        let connection = connection?;
        Ok(Self { config, connection, next_id: 1, server: None, buffered_events: VecDeque::new() })
    }

    pub fn config(&self) -> &ClientConfig {
        &self.config
    }

    pub fn server_info(&self) -> Option<&ServerInfo> {
        self.server.as_ref()
    }

    pub fn take_buffered_event(&mut self) -> Option<Event> {
        self.buffered_events.pop_front()
    }

    pub fn close(&mut self) {
        self.connection.close();
    }

    /// Send an escape-hatch request for an extension unknown to this SDK.
    ///
    /// Normal protocol commands should use the generated typed methods.
    pub fn request_raw(&mut self, mut request: Map<String, Value>) -> Result<Value> {
        if let Some(command) = request.get("cmd").and_then(Value::as_str)
            && let Some(metadata) =
                crate::generated::COMMANDS.iter().find(|metadata| metadata.name == command)
        {
            self.require_authority(metadata)?;
        }
        let id = request.get("id").cloned().unwrap_or_else(|| {
            let id = Value::from(self.next_id());
            request.insert("id".to_string(), id.clone());
            id
        });
        let command = request.get("cmd").and_then(Value::as_str).unwrap_or("<raw>").to_string();
        self.connection.send(&Value::Object(request))?;
        self.receive_response(&id, &command)
    }

    pub(crate) fn execute<Request, Response>(
        &mut self,
        metadata: &'static CommandMetadata,
        request: &Request,
    ) -> Result<Response>
    where
        Request: Serialize,
        Response: DeserializeOwned,
    {
        self.require_compatible(metadata)?;
        let id = Value::from(self.next_id());
        let envelope = request_envelope(metadata.name, id.clone(), request)?;
        self.connection.send(&envelope)?;
        let response = self.receive_response(&id, metadata.name)?;
        decode_response(metadata.name, response)
    }

    pub(crate) fn execute_identify<Request>(
        &mut self,
        metadata: &'static CommandMetadata,
        request: &Request,
    ) -> Result<IdentifyResult>
    where
        Request: Serialize,
    {
        let result: IdentifyResult = self.execute(metadata, request)?;
        self.server = Some(ServerInfo {
            protocol: result.protocol,
            capabilities: result.capabilities.clone().unwrap_or_default(),
        });
        Ok(result)
    }

    pub(crate) fn execute_stream<Request>(
        &mut self,
        metadata: &'static CommandMetadata,
        request: &Request,
    ) -> Result<CmuxStream>
    where
        Request: Serialize,
    {
        self.require_compatible(metadata)?;
        let id = Value::from(self.next_id());
        let envelope = request_envelope(metadata.name, id.clone(), request)?;
        let mut connection = JsonLineConnection::connect(
            &self.config.socket_path,
            self.config.timeout,
            self.config.timeout,
            self.config.max_frame_bytes,
        )?;
        let control = Arc::new(StreamControl {
            socket: connection.shutdown_clone()?,
            closed: AtomicBool::new(false),
        });
        connection.send(&envelope)?;
        let mut buffered = VecDeque::new();
        loop {
            let message = connection.recv().map_err(|error| map_closed(error, &control))?;
            if message.get("event").is_some() {
                if buffered.len() == self.config.max_queued_events {
                    connection.close();
                    return Err(CmuxError::QueueOverflow { limit: self.config.max_queued_events });
                }
                buffered.push_back(decode_event(message));
                continue;
            }
            if message.get("id") != Some(&id) {
                continue;
            }
            ensure_success(metadata.name, &message)?;
            return Ok(CmuxStream {
                connection,
                buffered,
                control,
                terminal_event: metadata.stream.and_then(|stream| stream.terminal_event),
                max_queued_events: self.config.max_queued_events,
                finished: false,
            });
        }
    }

    pub(crate) fn require_compatible(&self, metadata: &'static CommandMetadata) -> Result<()> {
        self.require_authority(metadata)?;
        let Some(server) = &self.server else {
            return Ok(());
        };
        if server.protocol < metadata.since {
            return Err(CmuxError::ProtocolVersion {
                command: metadata.name,
                required: metadata.since,
                actual: server.protocol,
            });
        }
        if let Some(capability) = metadata.capability
            && !server.capabilities.iter().any(|candidate| candidate == capability)
        {
            return Err(CmuxError::MissingCapability { command: metadata.name, capability });
        }
        Ok(())
    }

    fn require_authority(&self, metadata: &'static CommandMetadata) -> Result<()> {
        if metadata.authority == "provider-authority" && !self.config.allow_provider_authority {
            return Err(CmuxError::AuthorityDenied {
                command: metadata.name,
                authority: metadata.authority,
            });
        }
        Ok(())
    }

    pub(crate) fn require_protocol_field(
        &self,
        command: &'static str,
        required: u32,
    ) -> Result<()> {
        if let Some(server) = &self.server
            && server.protocol < required
        {
            return Err(CmuxError::ProtocolVersion { command, required, actual: server.protocol });
        }
        Ok(())
    }

    pub(crate) fn require_capability_field(
        &self,
        command: &'static str,
        capability: &'static str,
    ) -> Result<()> {
        if let Some(server) = &self.server
            && !server.capabilities.iter().any(|candidate| candidate == capability)
        {
            return Err(CmuxError::MissingCapability { command, capability });
        }
        Ok(())
    }

    fn receive_response(&mut self, id: &Value, command: &str) -> Result<Value> {
        loop {
            let response = self.connection.recv()?;
            if response.get("event").is_some() {
                if self.buffered_events.len() == self.config.max_queued_events {
                    self.connection.close();
                    return Err(CmuxError::QueueOverflow { limit: self.config.max_queued_events });
                }
                self.buffered_events.push_back(decode_event(response));
                continue;
            }
            if response.get("id") != Some(id) {
                continue;
            }
            ensure_success(command, &response)?;
            return Ok(response);
        }
    }

    fn next_id(&mut self) -> u64 {
        let id = self.next_id;
        self.next_id = self.next_id.wrapping_add(1).max(1);
        id
    }
}

fn is_hashed_socket(path: &Path) -> bool {
    path.parent()
        .and_then(Path::file_name)
        .is_some_and(|name| name.to_string_lossy().starts_with("cmux-tui-hashed-"))
}

/// Finds a legacy session socket for a hashed endpoint.
///
/// This bounded compatibility probe scans only UID-private runtime directories,
/// limiting each directory to 256 entries. It validates the session digest and
/// Unix socket type before returning a candidate, so unrelated paths are ignored.
pub(crate) fn hashed_socket_legacy_path(path: &Path) -> Option<PathBuf> {
    let parent = path.parent()?;
    let leaf = path.file_name()?.to_str()?;
    let uid = parent.file_name()?.to_str()?.strip_prefix("cmux-tui-hashed-")?;
    if uid != current_uid_component() || !leaf.ends_with(".sock") {
        return None;
    }
    let digest = leaf.strip_suffix(".sock")?;
    if digest.len() != 64 || !digest.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let canonical = PathBuf::from("/tmp").join(format!("cmux-tui-{uid}"));
    let sibling = parent.parent()?.join(format!("cmux-tui-{uid}"));
    let mut roots = vec![canonical];
    if sibling != roots[0] {
        roots.push(sibling);
    }
    for dir in roots {
        let Ok(entries) = std::fs::read_dir(dir) else { continue };
        for entry in entries.flatten().take(256) {
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            if !name.ends_with(".sock")
                || format!(
                    "{:x}.sock",
                    Sha256::digest(name.strip_suffix(".sock").unwrap_or(name).as_bytes())
                ) != leaf
            {
                continue;
            }
            if std::os::unix::fs::FileTypeExt::is_socket(&entry.file_type().ok()?) {
                return Some(entry.path());
            }
        }
    }
    None
}

impl Drop for CmuxClient {
    fn drop(&mut self) {
        self.close();
    }
}

pub struct CmuxStream {
    connection: JsonLineConnection,
    buffered: VecDeque<Event>,
    control: Arc<StreamControl>,
    terminal_event: Option<&'static str>,
    max_queued_events: usize,
    finished: bool,
}

impl CmuxStream {
    pub fn recv(&mut self) -> Result<Event> {
        if self.finished || self.control.closed.load(Ordering::Acquire) {
            return Err(CmuxError::Closed);
        }
        if let Some(event) = self.buffered.pop_front() {
            return Ok(self.finish_if_terminal(event));
        }
        loop {
            let value = self.connection.recv().map_err(|error| map_closed(error, &self.control))?;
            if value.get("event").is_some() {
                return Ok(self.finish_if_terminal(decode_event(value)));
            }
        }
    }

    pub fn recv_timeout(&mut self, timeout: Duration) -> Result<Event> {
        if self.finished || self.control.closed.load(Ordering::Acquire) {
            return Err(CmuxError::Closed);
        }
        if let Some(event) = self.buffered.pop_front() {
            return Ok(self.finish_if_terminal(event));
        }
        let control = Arc::clone(&self.control);
        let value = self.connection.with_read_timeout(timeout, |connection| {
            loop {
                let value = connection.recv().map_err(|error| map_closed(error, &control))?;
                if value.get("event").is_some() {
                    return Ok(value);
                }
            }
        })?;
        Ok(self.finish_if_terminal(decode_event(value)))
    }

    pub fn closer(&self) -> StreamCloser {
        StreamCloser { control: Arc::clone(&self.control) }
    }

    pub fn close(&mut self) {
        self.finished = true;
        self.closer().close();
    }

    pub fn buffered_len(&self) -> usize {
        self.buffered.len()
    }

    pub fn max_queued_events(&self) -> usize {
        self.max_queued_events
    }

    fn finish_if_terminal(&mut self, event: Event) -> Event {
        let terminal = self.terminal_event.is_some_and(|name| event.wire_name() == Some(name))
            || event.wire_name() == Some("overflow");
        if terminal {
            self.finished = true;
            self.control.closed.store(true, Ordering::Release);
            self.connection.close();
        }
        event
    }
}

impl Iterator for CmuxStream {
    type Item = Result<Event>;

    fn next(&mut self) -> Option<Self::Item> {
        (!self.finished).then(|| self.recv())
    }
}

impl Drop for CmuxStream {
    fn drop(&mut self) {
        self.close();
    }
}

#[derive(Clone)]
pub struct StreamCloser {
    control: Arc<StreamControl>,
}

impl StreamCloser {
    /// Close the stream from another thread and unblock an active `recv`.
    pub fn close(&self) {
        if !self.control.closed.swap(true, Ordering::AcqRel) {
            let _ = self.control.socket.shutdown(Shutdown::Both);
        }
    }

    pub fn is_closed(&self) -> bool {
        self.control.closed.load(Ordering::Acquire)
    }
}

struct StreamControl {
    socket: UnixStream,
    closed: AtomicBool,
}

fn request_envelope<Request: Serialize>(
    command: &str,
    id: Value,
    request: &Request,
) -> Result<Value> {
    let mut fields = match serde_json::to_value(request)
        .map_err(|error| CmuxError::Decode(error.to_string()))?
    {
        Value::Object(fields) => fields,
        _ => {
            return Err(CmuxError::InvalidArgument(
                "generated request did not serialize as a JSON object".to_string(),
            ));
        }
    };
    fields.insert("id".to_string(), id);
    fields.insert("cmd".to_string(), Value::String(command.to_string()));
    Ok(Value::Object(fields))
}

fn ensure_success(command: &str, response: &Value) -> Result<()> {
    if response.get("ok") == Some(&Value::Bool(true)) {
        return Ok(());
    }
    let message = response
        .get("error")
        .and_then(Value::as_str)
        .unwrap_or("unknown command error")
        .to_string();
    Err(CmuxError::Command {
        command: command.to_string(),
        message,
        id: response.get("id").cloned(),
    })
}

fn decode_response<Response: DeserializeOwned>(command: &str, response: Value) -> Result<Response> {
    let data = response.get("data").cloned().unwrap_or_else(|| Value::Object(Map::new()));
    serde_json::from_value(data)
        .map_err(|error| CmuxError::Decode(format!("{command} result: {error}")))
}

fn map_closed(error: CmuxError, control: &StreamControl) -> CmuxError {
    if control.closed.load(Ordering::Acquire) { CmuxError::Closed } else { error }
}

pub fn env_socket_path() -> Option<PathBuf> {
    std::env::var_os("CMUX_TUI_SOCKET")
        .filter(|value| !value.is_empty())
        .or_else(|| std::env::var_os("CMUX_MUX_SOCKET").filter(|value| !value.is_empty()))
        .map(PathBuf::from)
}

pub(crate) fn socket_path_for_session(
    session: &str,
    environment_path: Option<PathBuf>,
) -> Result<PathBuf> {
    match environment_path {
        Some(path) => Ok(path),
        None => try_default_socket_path(session),
    }
}

pub(crate) fn compatibility_socket_path_for_session(
    session: &str,
    environment_path: Option<PathBuf>,
) -> PathBuf {
    match socket_path_for_session(session, environment_path) {
        Ok(path) => path,
        Err(_) => default_socket_path(session),
    }
}

/// Validates the session component used by the default Unix socket path.
///
/// Session names may contain legacy spaces, Unicode, punctuation, and long
/// text. They must remain one non-empty path component and cannot contain
/// separators, NUL, control characters, or Unicode line separators.
pub fn validate_session_name(session: &str) -> Result<()> {
    let invalid = session.is_empty()
        || matches!(session, "." | "..")
        || session.chars().any(|character| {
            character == '/'
                || character == '\\'
                || character == '\0'
                || character.is_control()
                || matches!(character, '\u{0085}' | '\u{2028}' | '\u{2029}')
        });
    if invalid {
        return Err(CmuxError::InvalidArgument(
            "session name must be a non-empty path component without separators or control characters"
                .to_string(),
        ));
    }
    Ok(())
}

/// Resolves a session socket path and reports invalid session input.
pub fn try_default_socket_path(session: &str) -> Result<PathBuf> {
    validate_session_name(session)?;
    Ok(default_socket_path_for_session(session))
}

/// Resolves a session socket path without changing the historical signature.
///
/// New callers should use `try_default_socket_path`. If an old caller passes
/// an invalid name, this wrapper returns a per-input path below a private
/// invalid-session directory. It is path-only compatibility behavior, not a
/// connection route. It never joins the supplied text and cannot select a
/// normal session socket.
pub fn default_socket_path(session: &str) -> PathBuf {
    match try_default_socket_path(session) {
        Ok(path) => path,
        Err(_) => invalid_session_socket_path(session),
    }
}

fn default_socket_path_for_session(session: &str) -> PathBuf {
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .filter(|value| !value.is_empty())
        .or_else(|| std::env::var_os("TMPDIR").filter(|value| !value.is_empty()))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    default_socket_path_in_runtime_dir(session, base.join(private_runtime_dir_name()))
}

fn invalid_session_socket_path(session: &str) -> PathBuf {
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .filter(|value| !value.is_empty())
        .or_else(|| std::env::var_os("TMPDIR").filter(|value| !value.is_empty()))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    invalid_session_socket_path_in_runtime_dir(session, base)
}

fn invalid_session_socket_path_in_runtime_dir(session: &str, runtime_dir: PathBuf) -> PathBuf {
    let component = invalid_session_socket_leaf(session);
    let preferred =
        runtime_dir.join(format!("cmux-tui-invalid-{}", current_uid_component())).join(component);
    if unix_socket_path_fits(&preferred) {
        preferred
    } else {
        PathBuf::from("/tmp")
            .join(format!("cmux-tui-invalid-{}", current_uid_component()))
            .join(invalid_session_socket_leaf(session))
    }
}

fn default_socket_path_in_runtime_dir(session: &str, runtime_dir: PathBuf) -> PathBuf {
    let file_name = format!("{session}.sock");
    let preferred = runtime_dir.join(&file_name);
    if !unix_socket_path_fits(&preferred) {
        let fallback = PathBuf::from("/tmp").join(private_runtime_dir_name()).join(file_name);
        if unix_socket_path_fits(&fallback) {
            return fallback;
        }
        let digest = Sha256::digest(session.as_bytes());
        let preferred_base = runtime_dir.parent().unwrap_or_else(|| Path::new("/tmp"));
        let hashed = preferred_base
            .join(format!("cmux-tui-hashed-{}", current_uid_component()))
            .join(format!("{digest:x}.sock"));
        if unix_socket_path_fits(&hashed) {
            return hashed;
        }
        let hashed = PathBuf::from("/tmp")
            .join(format!("cmux-tui-hashed-{}", current_uid_component()))
            .join(format!("{digest:x}.sock"));
        debug_assert!(unix_socket_path_fits(&hashed));
        return hashed;
    }
    preferred
}

pub(crate) fn private_runtime_dir_name() -> String {
    format!("cmux-tui-{}", current_uid_component())
}

fn unix_socket_path_fits(path: &Path) -> bool {
    const SUN_PATH_CAPACITY: usize =
        size_of::<libc::sockaddr_un>() - offset_of!(libc::sockaddr_un, sun_path);
    path.as_os_str().as_bytes().len() < SUN_PATH_CAPACITY
}

fn current_uid_component() -> String {
    // SAFETY: getuid has no preconditions and does not dereference pointers.
    unsafe { libc::getuid() }.to_string()
}

fn invalid_session_socket_leaf(session: &str) -> String {
    format!("{:x}.sock", Sha256::digest(session.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixListener;
    use std::sync::atomic::{AtomicU64, Ordering as AtomicOrdering};
    use std::thread;

    static NEXT_TEST_SOCKET: AtomicU64 = AtomicU64::new(1);

    static SUBSCRIBE_METADATA: CommandMetadata = CommandMetadata {
        name: "subscribe",
        since: 1,
        capability: None,
        authority: "control",
        stream: Some(crate::StreamMetadata { kind: "subscribe", terminal_event: None }),
    };

    fn temp_socket(name: &str) -> PathBuf {
        let id = NEXT_TEST_SOCKET.fetch_add(1, AtomicOrdering::Relaxed);
        std::env::temp_dir().join(format!("cmux-sdk-{name}-{}-{id}.sock", std::process::id()))
    }

    struct SocketFile(PathBuf);

    impl Drop for SocketFile {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }

    fn spawn_stream_server(
        name: &str,
        handler: impl FnOnce(UnixStream) + Send + 'static,
    ) -> (PathBuf, thread::JoinHandle<()>) {
        let path = temp_socket(name);
        let listener = UnixListener::bind(&path).unwrap();
        let handle = thread::spawn(move || {
            let (_command_connection, _) = listener.accept().unwrap();
            let (stream_connection, _) = listener.accept().unwrap();
            handler(stream_connection);
        });
        (path, handle)
    }

    #[test]
    fn close_handle_unblocks_a_reader() {
        let (release_server_tx, release_server_rx) = std::sync::mpsc::channel();
        let (path, server) = spawn_stream_server("close", move |mut stream| {
            let mut request = String::new();
            BufReader::new(stream.try_clone().unwrap()).read_line(&mut request).unwrap();
            let id = serde_json::from_str::<Value>(&request).unwrap()["id"].clone();
            writeln!(stream, "{}", serde_json::json!({"id": id, "ok": true, "data": {}})).unwrap();
            release_server_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        });
        let mut client = CmuxClient::connect(
            ClientConfig::from_socket_path(&path).with_timeout(Duration::from_secs(5)),
        )
        .unwrap();
        let stream = client.execute_stream(&SUBSCRIBE_METADATA, &serde_json::json!({})).unwrap();
        let closer = stream.closer();
        let (reader_started_tx, reader_started_rx) = std::sync::mpsc::channel();
        let (reader_result_tx, reader_result_rx) = std::sync::mpsc::channel();
        let reader = thread::spawn(move || {
            let mut stream = stream;
            reader_started_tx.send(()).unwrap();
            reader_result_tx.send(stream.recv()).unwrap();
        });
        reader_started_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        closer.close();
        let result = reader_result_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        release_server_tx.send(()).unwrap();
        reader.join().unwrap();
        server.join().unwrap();
        let _ = std::fs::remove_file(path);
        assert!(matches!(result, Err(CmuxError::Closed)));
    }

    #[test]
    fn session_socket_helpers_reject_unsafe_names_before_joining() {
        for session in [
            "",
            ".",
            "..",
            "../escape",
            "nested/session",
            "nested\\session",
            "bad\0name",
            "bad\nname",
            "bad\u{0085}name",
            "bad\u{2028}name",
            "bad\u{2029}name",
        ] {
            assert!(
                try_default_socket_path(session).is_err(),
                "accepted unsafe session {session:?}"
            );
        }
        for session in ["legacy name", "名前", "_legacy", "-legacy", "legacy:colon"] {
            assert!(
                try_default_socket_path(session).is_ok(),
                "rejected legacy-safe session {session:?}"
            );
        }
        assert!(try_default_socket_path(&format!("legacy-{}", "x".repeat(200))).is_ok());

        let escaped = default_socket_path("../escape");
        let escaped_again = default_socket_path("../escape");
        let other_escaped = default_socket_path("nested/escape");
        assert_eq!(escaped, escaped_again);
        assert_ne!(escaped, other_escaped);
        assert!(!escaped.to_string_lossy().contains("../"));
        assert!(
            escaped
                .parent()
                .and_then(Path::file_name)
                .is_some_and(|name| name.to_string_lossy().starts_with("cmux-tui-invalid-"))
        );
        let runtime_dir = PathBuf::from("/tmp/cmux-sdk-runtime");
        let isolated = invalid_session_socket_path_in_runtime_dir("../escape", runtime_dir.clone());
        assert_eq!(
            isolated,
            invalid_session_socket_path_in_runtime_dir("../escape", runtime_dir.clone())
        );
        assert!(
            isolated
                .components()
                .all(|component| !matches!(component, std::path::Component::ParentDir))
        );
        let preferred = runtime_dir
            .join(format!("cmux-tui-invalid-{}", current_uid_component()))
            .join(isolated.file_name().expect("invalid path has a leaf"));
        let expected_outer = if unix_socket_path_fits(&preferred) {
            runtime_dir.as_path()
        } else {
            Path::new("/tmp")
        };
        assert_eq!(isolated.parent().and_then(Path::parent), Some(expected_outer));
        let legacy_runtime = runtime_dir.join(private_runtime_dir_name());
        assert_eq!(
            default_socket_path_in_runtime_dir("legacy name", legacy_runtime.clone()),
            legacy_runtime.join("legacy name.sock")
        );
        assert!(ClientConfig::try_from_env_or_default_session("../escape").is_err());
        let invalid_leaf = escaped.file_name().expect("invalid path has a leaf").to_string_lossy();
        assert_eq!(
            invalid_leaf,
            "1ba7343c47dc442de7dec43a995deb9a7b62234ecca16d7c6f597b5155bd85b1.sock"
        );
        assert!(socket_path_for_session("../escape", None).is_err());
    }

    #[test]
    fn compatibility_config_constructor_does_not_panic_for_invalid_session() {
        let result =
            std::panic::catch_unwind(|| ClientConfig::from_env_or_default_session("../escape"));
        assert!(result.is_ok(), "source-compatible constructor must not panic");
    }

    #[test]
    fn implicit_hashed_socket_falls_back_to_the_legacy_session_socket() {
        let id = NEXT_TEST_SOCKET.fetch_add(1, AtomicOrdering::Relaxed);
        let session = format!("raw-fallback-{}-{id}", std::process::id());
        let dir = PathBuf::from("/tmp").join(private_runtime_dir_name());
        std::fs::create_dir_all(&dir).unwrap();
        let legacy = SocketFile(dir.join(format!("{session}.sock")));
        let hashed_dir =
            PathBuf::from("/tmp").join(format!("cmux-tui-hashed-{}", current_uid_component()));
        std::fs::create_dir_all(&hashed_dir).unwrap();
        let digest = format!("{:x}.sock", Sha256::digest(session.as_bytes()));
        let config = ClientConfig::from_socket_path(hashed_dir.join(digest));
        assert!(is_hashed_socket(&config.socket_path));
        let listener = UnixListener::bind(&legacy.0).unwrap();
        assert_eq!(hashed_socket_legacy_path(&config.socket_path), Some(legacy.0.clone()));

        let client = CmuxClient::connect_with_legacy_fallback(config).unwrap();
        assert_eq!(client.config().socket_path, legacy.0);
        drop(listener);
    }

    #[test]
    fn explicit_socket_authority_does_not_install_a_legacy_fallback() {
        let explicit = temp_socket("explicit-authority");
        let raw = ClientConfig::from_socket_path(&explicit);
        assert_eq!(raw.socket_path, explicit);

        let inherited =
            socket_path_for_session("../invalid-without-authority", Some(explicit.clone()))
                .unwrap();
        assert_eq!(inherited, explicit);
    }

    #[test]
    fn long_session_socket_path_uses_bindable_digest_fallback() {
        const EXPECTED_DIGEST: &str =
            "e538a84493067947f7376110a6f695dd3db062b67eee939c3660c07f3f47dce2";
        let session = format!("legacy-{}", "x".repeat(200));
        let path = try_default_socket_path(&session).unwrap();
        let expected_leaf = format!("{EXPECTED_DIGEST}.sock");

        assert_eq!(path.file_name().and_then(|name| name.to_str()), Some(expected_leaf.as_str()));
        assert!(
            path.parent()
                .and_then(Path::file_name)
                .is_some_and(|name| name.to_string_lossy().starts_with("cmux-tui-hashed-"))
        );
        assert!(unix_socket_path_fits(&path), "unusable socket path: {path:?}");

        let bind_session = format!("rust-sdk-bind-{}-{}", std::process::id(), "x".repeat(200));
        let bind_path = try_default_socket_path(&bind_session).unwrap();
        std::fs::create_dir_all(bind_path.parent().unwrap()).unwrap();
        let _ = std::fs::remove_file(&bind_path);
        let listener = UnixListener::bind(&bind_path)
            .unwrap_or_else(|error| panic!("failed to bind {bind_path:?}: {error}"));
        drop(listener);
        std::fs::remove_file(bind_path).unwrap();
    }

    #[test]
    fn long_session_hash_prefers_runtime_base_and_falls_back_to_tmp() {
        let session = format!("legacy-{}", "x".repeat(200));
        let preferred_runtime = PathBuf::from("/run/user/501/cmux-tui-501");
        let preferred = default_socket_path_in_runtime_dir(&session, preferred_runtime);
        assert!(preferred.to_string_lossy().starts_with("/run/user/501/cmux-tui-hashed-"));

        let long_runtime = PathBuf::from("/tmp").join("x".repeat(200)).join("cmux-tui-501");
        let fallback = default_socket_path_in_runtime_dir(&session, long_runtime);
        assert!(fallback.to_string_lossy().starts_with("/tmp/cmux-tui-hashed-"));
    }

    #[test]
    fn unix_socket_path_boundary_reserves_trailing_nul() {
        const SUN_PATH_CAPACITY: usize =
            size_of::<libc::sockaddr_un>() - offset_of!(libc::sockaddr_un, sun_path);
        let parent = PathBuf::from("/tmp/cmux-tui-boundary");
        let parent_bytes = parent.as_os_str().as_bytes().len();
        let fit_leaf_bytes = SUN_PATH_CAPACITY - parent_bytes - 2;
        let fit = parent.join("x".repeat(fit_leaf_bytes));
        let first_over_limit = parent.join("x".repeat(fit_leaf_bytes + 1));

        assert_eq!(fit.as_os_str().as_bytes().len(), SUN_PATH_CAPACITY - 1);
        assert_eq!(first_over_limit.as_os_str().as_bytes().len(), SUN_PATH_CAPACITY);
        assert!(unix_socket_path_fits(&fit));
        assert!(!unix_socket_path_fits(&first_over_limit));
    }

    #[test]
    fn non_ascii_long_session_uses_utf8_sha256_digest_fallback() {
        const EXPECTED_DIGEST: &str =
            "0d3fd777d54547652e50e049becfce29b81513bc248da9d22bbd37593f0d52e3";
        let session = "名前".repeat(100);
        let path = try_default_socket_path(&session).unwrap();
        let expected_leaf = format!("{EXPECTED_DIGEST}.sock");

        assert_eq!(path.file_name().and_then(|name| name.to_str()), Some(expected_leaf.as_str()));
        assert!(
            path.parent()
                .and_then(Path::file_name)
                .is_some_and(|name| name.to_string_lossy().starts_with("cmux-tui-hashed-"))
        );
    }

    #[test]
    fn stream_buffers_events_that_precede_ack() {
        let (path, server) = spawn_stream_server("pre-ack", |mut stream| {
            let mut request = String::new();
            BufReader::new(stream.try_clone().unwrap()).read_line(&mut request).unwrap();
            let id = serde_json::from_str::<Value>(&request).unwrap()["id"].clone();
            writeln!(stream, "{}", serde_json::json!({"event": "tree-changed"})).unwrap();
            writeln!(stream, "{}", serde_json::json!({"id": id, "ok": true, "data": {}})).unwrap();
        });
        let mut client = CmuxClient::connect(ClientConfig::from_socket_path(&path)).unwrap();
        let mut stream =
            client.execute_stream(&SUBSCRIBE_METADATA, &serde_json::json!({})).unwrap();
        assert_eq!(stream.buffered_len(), 1);
        assert_eq!(stream.recv().unwrap().wire_name(), Some("tree-changed"));
        server.join().unwrap();
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn stream_rejects_an_unbounded_pre_ack_event_queue() {
        let (path, server) = spawn_stream_server("queue-bound", |mut stream| {
            let mut request = String::new();
            BufReader::new(stream.try_clone().unwrap()).read_line(&mut request).unwrap();
            writeln!(stream, "{}", serde_json::json!({"event": "tree-changed"})).unwrap();
            writeln!(stream, "{}", serde_json::json!({"event": "tree-changed"})).unwrap();
        });
        let mut client =
            CmuxClient::connect(ClientConfig::from_socket_path(&path).with_max_queued_events(1))
                .unwrap();
        let result = client.execute_stream(&SUBSCRIBE_METADATA, &serde_json::json!({}));
        assert!(matches!(result, Err(CmuxError::QueueOverflow { limit: 1 })));
        server.join().unwrap();
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn connection_io_display_omits_socket_path_and_os_detail() {
        let error = CmuxError::ConnectionIo {
            message: "cannot connect to session socket /private/secret.sock: permission denied"
                .to_string(),
            kind: std::io::ErrorKind::PermissionDenied,
        };
        assert_eq!(error.to_string(), "cannot connect to cmux session");
        assert!(format!("{error:?}").contains("/private/secret.sock"));
    }
}
