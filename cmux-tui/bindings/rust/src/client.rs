use crate::CommandMetadata;
use crate::codec::JsonLineConnection;
use crate::generated::{Event, IdentifyResult, decode_event};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value};
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

    pub fn from_env_or_default_session(session: &str) -> Self {
        let socket_path = env_socket_path().unwrap_or_else(|| default_socket_path(session));
        Self::from_socket_path(socket_path)
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
        Self::from_env_or_default_session("main")
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
        if config.max_queued_events == 0 {
            return Err(CmuxError::InvalidArgument(
                "max_queued_events must be greater than zero".to_string(),
            ));
        }
        let connection = JsonLineConnection::connect(
            &config.socket_path,
            config.timeout,
            config.timeout,
            config.max_frame_bytes,
        )?;
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

pub fn default_socket_path(session: &str) -> PathBuf {
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .filter(|value| !value.is_empty())
        .or_else(|| std::env::var_os("TMPDIR").filter(|value| !value.is_empty()))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    default_socket_path_in_runtime_dir(session, base.join(private_runtime_dir_name()))
}

fn default_socket_path_in_runtime_dir(session: &str, runtime_dir: PathBuf) -> PathBuf {
    let file_name = format!("{}.sock", socket_session_component(session));
    let preferred = runtime_dir.join(&file_name);
    if !unix_socket_path_fits(&preferred) {
        return PathBuf::from("/tmp").join(private_runtime_dir_name()).join(file_name);
    }
    preferred
}

/// Keep the selected session as one portable filename component.
/// Encoding invalid names prevents separators and dot components escaping the
/// private runtime directory while preserving distinct user input.
fn socket_session_component(session: &str) -> String {
    if !session.is_empty()
        && session.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.')
        })
        && session != "."
        && session != ".."
    {
        return session.to_owned();
    }
    let mut encoded = String::from("session-");
    for byte in session.as_bytes() {
        use std::fmt::Write as _;
        write!(&mut encoded, "{byte:02x}").expect("writing to String cannot fail");
    }
    encoded
}

fn private_runtime_dir_name() -> String {
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixListener;
    use std::thread;
    use std::time::Instant;

    static SUBSCRIBE_METADATA: CommandMetadata = CommandMetadata {
        name: "subscribe",
        since: 1,
        capability: None,
        authority: "control",
        stream: Some(crate::StreamMetadata { kind: "subscribe", terminal_event: None }),
    };

    #[test]
    fn session_names_cannot_escape_runtime_directory() {
        let runtime = PathBuf::from("/private/runtime/cmux-tui-42");
        for session in ["", ".", "..", "../outside", "nested/name", r"nested\name"] {
            let path = default_socket_path_in_runtime_dir(session, runtime.clone());
            assert_eq!(path.parent(), Some(runtime.as_path()));
            assert!(path.file_name().is_some_and(|name| name != "..sock"));
        }
        assert_eq!(
            default_socket_path_in_runtime_dir("demo", runtime),
            PathBuf::from("/private/runtime/cmux-tui-42/demo.sock")
        );
    }

    fn temp_socket(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "cmux-sdk-{name}-{}-{}.sock",
            std::process::id(),
            Instant::now().elapsed().as_nanos()
        ))
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
}
