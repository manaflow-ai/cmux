use super::id::StreamId;
use super::options::MutationOptions;
use super::stream::{ResourceStream, StreamParts};
use super::wire::{Params, field};
use crate::codec::JsonLineConnection;
use crate::{Error, Result};
use serde_json::{Map, Value};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const PROTOCOL: &str = "cmux.protocol/1";
const DEFAULT_REQUEST_BYTES: usize = 4 * 1024 * 1024;
const DEFAULT_RESPONSE_BYTES: usize = 16 * 1024 * 1024;
const DEFAULT_STREAM_ITEMS: usize = 256;
const DEFAULT_STREAM_BYTES: usize = 16 * 1024 * 1024;

/// Connection and bound configuration for the resource SDK.
#[derive(Clone, Debug)]
pub struct Config {
    pub socket_path: PathBuf,
    pub timeout: Duration,
    pub max_request_bytes: usize,
    pub max_response_bytes: usize,
    pub max_stream_items: usize,
    pub max_stream_bytes: usize,
}

impl Config {
    pub fn from_socket_path(socket_path: impl Into<PathBuf>) -> Self {
        Self {
            socket_path: socket_path.into(),
            timeout: Duration::from_secs(10),
            max_request_bytes: DEFAULT_REQUEST_BYTES,
            max_response_bytes: DEFAULT_RESPONSE_BYTES,
            max_stream_items: DEFAULT_STREAM_ITEMS,
            max_stream_bytes: DEFAULT_STREAM_BYTES,
        }
    }

    pub fn from_env_or_default_session(session: &str) -> Self {
        let socket_path = crate::client::env_socket_path()
            .unwrap_or_else(|| crate::client::default_socket_path(session));
        Self::from_socket_path(socket_path)
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    pub fn with_request_limit(mut self, bytes: usize) -> Self {
        self.max_request_bytes = bytes;
        self
    }

    pub fn with_response_limit(mut self, bytes: usize) -> Self {
        self.max_response_bytes = bytes;
        self
    }

    pub fn with_stream_limits(mut self, items: usize, bytes: usize) -> Self {
        self.max_stream_items = items;
        self.max_stream_bytes = bytes;
        self
    }

    fn validate(&self) -> Result<()> {
        if self.max_request_bytes == 0 || self.max_request_bytes > DEFAULT_REQUEST_BYTES {
            return Err(Error::InvalidArgument(format!(
                "max_request_bytes must be between 1 and {DEFAULT_REQUEST_BYTES}"
            )));
        }
        if self.max_response_bytes == 0 || self.max_response_bytes > DEFAULT_RESPONSE_BYTES {
            return Err(Error::InvalidArgument(format!(
                "max_response_bytes must be between 1 and {DEFAULT_RESPONSE_BYTES}"
            )));
        }
        if self.max_stream_items == 0 || self.max_stream_items > DEFAULT_STREAM_ITEMS {
            return Err(Error::InvalidArgument(format!(
                "max_stream_items must be between 1 and {DEFAULT_STREAM_ITEMS}"
            )));
        }
        if self.max_stream_bytes == 0 || self.max_stream_bytes > DEFAULT_STREAM_BYTES {
            return Err(Error::InvalidArgument(format!(
                "max_stream_bytes must be between 1 and {DEFAULT_STREAM_BYTES}"
            )));
        }
        Ok(())
    }
}

impl Default for Config {
    fn default() -> Self {
        Self::from_env_or_default_session("main")
    }
}

struct SharedClient {
    config: Config,
    control: Mutex<Option<JsonLineConnection>>,
    next_request: AtomicU64,
    closed: AtomicBool,
}

/// Blocking, cloneable cmux resource client.
///
/// Clones share one serialized control connection. Stream operations open a
/// dedicated connection so a blocking iterator cannot stall other calls.
#[derive(Clone)]
pub struct Client {
    shared: Arc<SharedClient>,
}

impl std::fmt::Debug for Client {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Client")
            .field("socket_path", &self.shared.config.socket_path)
            .field("closed", &self.shared.closed.load(Ordering::Acquire))
            .finish_non_exhaustive()
    }
}

impl Client {
    pub fn connect(config: Config) -> Result<Self> {
        config.validate()?;
        let connection = JsonLineConnection::connect(
            &config.socket_path,
            config.timeout,
            config.max_response_bytes,
        )?;
        Ok(Self {
            shared: Arc::new(SharedClient {
                config,
                control: Mutex::new(Some(connection)),
                next_request: AtomicU64::new(1),
                closed: AtomicBool::new(false),
            }),
        })
    }

    pub fn config(&self) -> &Config {
        &self.shared.config
    }

    /// Explicitly closes the shared control connection.
    pub fn close(&self) -> Result<()> {
        self.shared.closed.store(true, Ordering::Release);
        let mut connection = self
            .shared
            .control
            .lock()
            .map_err(|_| Error::Connection("client connection lock poisoned".to_string()))?;
        if let Some(connection) = connection.take() {
            connection.close();
        }
        Ok(())
    }

    pub fn is_closed(&self) -> bool {
        self.shared.closed.load(Ordering::Acquire)
    }

    pub(crate) fn read(&self, operation: &'static str, params: Params) -> Result<Value> {
        self.request(operation, params, None, OperationClass::Read)
    }

    pub(crate) fn connection_control(
        &self,
        operation: &'static str,
        params: Params,
    ) -> Result<Value> {
        self.request(operation, params, None, OperationClass::ConnectionControl)
    }

    pub(crate) fn mutate(
        &self,
        operation: &'static str,
        mut params: Params,
        options: MutationOptions,
    ) -> Result<Value> {
        if let Some(revision) = options.expected_revision {
            if !operation_accepts_revision(operation) {
                return Err(Error::InvalidArgument(format!(
                    "{operation} does not accept expected_revision"
                )));
            }
            params = params.u64(field::EXPECTED_REVISION, revision);
        }
        self.request(operation, params, Some(options.idempotency_key), OperationClass::Mutation)
    }

    pub(crate) fn stream(&self, operation: &'static str, params: Params) -> Result<ResourceStream> {
        if operation_class(operation) != OperationClass::StreamOpen {
            return Err(Error::InvalidArgument(format!(
                "{operation} is not a stream-open operation"
            )));
        }
        let id = self.next_request_id();
        let stream_id = random_stream_id()?;
        let params = params.id(field::STREAM_ID, &stream_id);
        let cancel_params = params.cancellation_scope(&stream_id);
        let envelope = request_envelope(&id, operation, params.into_value(), None);
        let mut connection = JsonLineConnection::connect(
            &self.shared.config.socket_path,
            self.shared.config.timeout,
            self.shared.config.max_response_bytes,
        )?;
        let writer = connection.shutdown_clone()?;
        connection.send_with_limit(&envelope, self.shared.config.max_request_bytes)?;
        let response = receive_response(&mut connection, &id)?;
        if let Some(response_stream_id) =
            response.as_object().and_then(|object| object.get("stream_id")).and_then(Value::as_str)
            && response_stream_id != stream_id.as_str()
        {
            return Err(Error::UnexpectedEnvelope(format!(
                "stream response returned {response_stream_id}, expected {stream_id}"
            )));
        }
        Ok(ResourceStream::from_parts(StreamParts {
            id: stream_id,
            connection,
            writer,
            cancel_params,
            max_request_bytes: self.shared.config.max_request_bytes,
        }))
    }

    fn request(
        &self,
        operation: &'static str,
        params: Params,
        idempotency_key: Option<String>,
        expected_class: OperationClass,
    ) -> Result<Value> {
        if self.is_closed() {
            return Err(Error::Closed);
        }
        let actual_class = operation_class(operation);
        if actual_class != expected_class {
            return Err(Error::InvalidArgument(format!(
                "{operation} is {actual_class:?}, not {expected_class:?}"
            )));
        }
        if (actual_class == OperationClass::Mutation) != idempotency_key.is_some() {
            return Err(Error::InvalidArgument(format!(
                "{operation} has invalid idempotency policy"
            )));
        }
        let id = self.next_request_id();
        let envelope = request_envelope(&id, operation, params.into_value(), idempotency_key);
        let mut connection = self
            .shared
            .control
            .lock()
            .map_err(|_| Error::Connection("client connection lock poisoned".to_string()))?;
        let connection = connection.as_mut().ok_or(Error::Closed)?;
        connection.send_with_limit(&envelope, self.shared.config.max_request_bytes)?;
        receive_response(connection, &id)
    }

    fn next_request_id(&self) -> String {
        format!(
            "rust-{}-{}",
            std::process::id(),
            self.shared.next_request.fetch_add(1, Ordering::Relaxed)
        )
    }
}

fn operation_accepts_revision(operation: &str) -> bool {
    use super::ops;
    !matches!(
        operation,
        ops::MACHINE_CREATE | ops::MACHINE_CONNECT_EXTERNAL | ops::WORKSPACE_CREATE
    )
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum OperationClass {
    Read,
    Mutation,
    StreamOpen,
    ConnectionControl,
}

fn operation_class(operation: &str) -> OperationClass {
    use super::ops;

    if matches!(
        operation,
        ops::SESSION_EVENTS
            | ops::TERMINAL_ATTACH
            | ops::BROWSER_ATTACH
            | ops::SIDEBAR_VIEW_ATTACH
            | ops::PROVIDER_NOTICE_EVENTS
    ) {
        OperationClass::StreamOpen
    } else if matches!(
        operation,
        ops::STREAM_CANCEL
            | ops::PROVIDER_NOTICE_ACKNOWLEDGE
            | ops::CLIENT_METADATA_UPDATE
            | ops::CLIENT_SIZING_SET
            | ops::CLIENT_SIZING_RELEASE
            | ops::CLIENT_CELL_PIXELS_SET
            | ops::CLIENT_DETACH
            | ops::TERMINAL_VIEWER_RESIZE
            | ops::TERMINAL_VIEWER_RELEASE
            | ops::BROWSER_VIEWER_RESIZE
            | ops::BROWSER_VIEWER_RELEASE
            | ops::TERMINAL_RENDERER_GRANT_CREATE
    ) {
        OperationClass::ConnectionControl
    } else if matches!(
        operation,
        ops::MACHINE_LIST
            | ops::MACHINE_GET
            | ops::SESSION_LIST
            | ops::SESSION_GET
            | ops::SESSION_SNAPSHOT
            | ops::SESSION_PING
            | ops::CLIENT_LIST
            | ops::CLIENT_GET
            | ops::PAIRING_REQUEST_LIST
            | ops::FRONTEND_PROJECTION_GET
            | ops::WORKSPACE_LIST
            | ops::WORKSPACE_GET
            | ops::SCREEN_LIST
            | ops::SCREEN_GET
            | ops::SCREEN_LAYOUT_EXPORT
            | ops::PANE_LIST
            | ops::PANE_GET
            | ops::PANE_NEIGHBOR_GET
            | ops::TAB_LIST
            | ops::TAB_GET
            | ops::TERMINAL_LIST
            | ops::TERMINAL_GET
            | ops::TERMINAL_SCREEN_READ
            | ops::TERMINAL_STATE_READ
            | ops::TERMINAL_HISTORY_READ
            | ops::TERMINAL_WAIT
            | ops::TERMINAL_COPY
            | ops::TERMINAL_PROCESS_GET
            | ops::BROWSER_LIST
            | ops::BROWSER_GET
            | ops::NOTIFICATION_LIST
            | ops::AGENT_LIST
            | ops::SIDEBAR_VIEW_GET
            | ops::PROVIDER_SCOPE_LIST
    ) {
        OperationClass::Read
    } else {
        OperationClass::Mutation
    }
}

fn request_envelope(
    id: &str,
    operation: &str,
    params: Value,
    idempotency_key: Option<String>,
) -> Value {
    let mut envelope = Map::from_iter([
        ("protocol".to_string(), Value::String(PROTOCOL.to_string())),
        ("type".to_string(), Value::String("request".to_string())),
        ("id".to_string(), Value::String(id.to_string())),
        ("operation".to_string(), Value::String(operation.to_string())),
        ("params".to_string(), params),
    ]);
    if let Some(idempotency_key) = idempotency_key {
        envelope.insert("idempotency_key".to_string(), Value::String(idempotency_key));
    }
    Value::Object(envelope)
}

fn receive_response(connection: &mut JsonLineConnection, expected_id: &str) -> Result<Value> {
    let response = connection.recv()?;
    let object = response
        .as_object()
        .ok_or_else(|| Error::UnexpectedEnvelope("response must be an object".to_string()))?;
    if object.get("protocol").and_then(Value::as_str) != Some(PROTOCOL)
        || object.get("type").and_then(Value::as_str) != Some("response")
    {
        return Err(Error::UnexpectedEnvelope(
            "expected cmux.protocol/1 response envelope".to_string(),
        ));
    }
    if object.get("id").and_then(Value::as_str) != Some(expected_id) {
        return Err(Error::UnexpectedEnvelope("response id does not match request".to_string()));
    }
    match object.get("ok").and_then(Value::as_bool) {
        Some(true) => object.get("result").cloned().ok_or_else(|| {
            Error::UnexpectedEnvelope("successful response lacks result".to_string())
        }),
        Some(false) => Err(decode_protocol_error(object.get("error").ok_or_else(|| {
            Error::UnexpectedEnvelope("failed response lacks error".to_string())
        })?)?),
        None => Err(Error::UnexpectedEnvelope("response ok must be a boolean".to_string())),
    }
}

pub(crate) fn decode_protocol_error(value: &Value) -> Result<Error> {
    let object = value
        .as_object()
        .ok_or_else(|| Error::UnexpectedEnvelope("protocol error must be an object".to_string()))?;
    let code = object
        .get("code")
        .and_then(Value::as_str)
        .ok_or_else(|| Error::UnexpectedEnvelope("protocol error code is required".to_string()))?
        .to_string();
    let message = object
        .get("message")
        .and_then(Value::as_str)
        .ok_or_else(|| Error::UnexpectedEnvelope("protocol error message is required".to_string()))?
        .to_string();
    let details = object.get("details").cloned().ok_or_else(|| {
        Error::UnexpectedEnvelope("protocol error details are required".to_string())
    })?;
    let retryable = object.get("retryable").and_then(Value::as_bool).ok_or_else(|| {
        Error::UnexpectedEnvelope("protocol error retryable is required".to_string())
    })?;
    Ok(Error::Protocol { code, message, details, retryable })
}

fn random_stream_id() -> Result<StreamId> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes)
        .map_err(|error| Error::Connection(format!("cannot allocate stream ID: {error}")))?;
    let mut value = String::with_capacity(39);
    value.push_str("stream_");
    for byte in bytes {
        use std::fmt::Write;
        write!(&mut value, "{byte:02x}").expect("writing to String cannot fail");
    }
    StreamId::parse(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classification_matches_connection_control_exceptions() {
        assert_eq!(operation_class(super::super::ops::TERMINAL_COPY), OperationClass::Read);
        assert_eq!(
            operation_class(super::super::ops::TERMINAL_VIEWER_RESIZE),
            OperationClass::ConnectionControl
        );
        assert_eq!(
            operation_class(super::super::ops::TAB_CREATE_TERMINAL),
            OperationClass::Mutation
        );
    }
}
