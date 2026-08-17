use super::id::StreamId;
use super::ops;
use super::options::{MutationOptions, RequestOptions, validate_idempotency_key};
use super::stream::{ResourceStream, StreamParts};
use super::wire::{Params, field};
use crate::codec::JsonLineConnection;
use crate::{Error, Result};
use serde_json::{Map, Value};
use std::cell::RefCell;
use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, TryLockError};
use std::time::{Duration, Instant};

const PROTOCOL: &str = "cmux.protocol/2";
const DEFAULT_REQUEST_BYTES: usize = 4 * 1024 * 1024;
const DEFAULT_RESPONSE_BYTES: usize = 16 * 1024 * 1024;
const DEFAULT_STREAM_ITEMS: usize = 256;
const DEFAULT_STREAM_BYTES: usize = 16 * 1024 * 1024;
const CANCELLATION_POLL_INTERVAL: Duration = Duration::from_millis(10);
const LOCK_POLL_INTERVAL: Duration = Duration::from_millis(1);

thread_local! {
    static REQUEST_SCOPES: RefCell<Vec<(usize, RequestOptions)>> = const {
        RefCell::new(Vec::new())
    };
}

struct RequestScopeGuard {
    client: usize,
}

impl Drop for RequestScopeGuard {
    fn drop(&mut self) {
        REQUEST_SCOPES.with(|scopes| {
            let popped = scopes.borrow_mut().pop();
            debug_assert_eq!(popped.as_ref().map(|(client, _)| *client), Some(self.client));
        });
    }
}

struct CallBudget {
    deadline: Instant,
    cancellation: Option<super::options::CancellationToken>,
}

impl CallBudget {
    fn new(options: RequestOptions, default_timeout: Duration) -> Result<Self> {
        options.validate()?;
        let timeout = options.timeout.unwrap_or(default_timeout);
        if timeout.is_zero() {
            return Err(Error::InvalidArgument(
                "request timeout must be greater than zero".to_string(),
            ));
        }
        let deadline = Instant::now().checked_add(timeout).ok_or_else(|| {
            Error::InvalidArgument("request timeout exceeds the supported range".to_string())
        })?;
        Ok(Self { deadline, cancellation: options.cancellation })
    }

    fn check(&self, operation: &str) -> Result<()> {
        if self.cancellation.as_ref().is_some_and(|token| token.is_cancelled()) {
            return Err(Error::Cancelled(format!("{operation} was canceled")));
        }
        if Instant::now() >= self.deadline {
            return Err(Error::Timeout(format!("{operation} did not respond before the deadline")));
        }
        Ok(())
    }

    fn remaining(&self, operation: &str) -> Result<Duration> {
        self.check(operation)?;
        Ok(self.deadline.saturating_duration_since(Instant::now()))
    }

    fn receive_timeout(&self, operation: &str) -> Result<Duration> {
        let remaining = self.remaining(operation)?;
        Ok(if self.cancellation.is_some() {
            remaining.min(CANCELLATION_POLL_INTERVAL)
        } else {
            remaining
        })
    }
}

fn connect_with_budget(
    config: &Config,
    operation: &str,
    budget: &CallBudget,
) -> Result<JsonLineConnection> {
    let timeout = budget.remaining(operation)?;
    let poll_interval =
        if budget.cancellation.is_some() { CANCELLATION_POLL_INTERVAL } else { timeout };
    JsonLineConnection::connect_with_poll_checks(
        &config.socket_path,
        timeout,
        config.timeout,
        config.max_response_bytes,
        poll_interval,
        || budget.check(operation),
    )
}

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
        if self.timeout.is_zero() {
            return Err(Error::InvalidArgument("timeout must be greater than zero".to_string()));
        }
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

    /// Runs exactly one high-level SDK call with a local deadline and
    /// cancellation signal.
    pub fn with_request_options<T>(
        &self,
        options: RequestOptions,
        call: impl FnOnce() -> Result<T>,
    ) -> Result<T> {
        options.validate()?;
        if options.cancellation.as_ref().is_some_and(|token| token.is_cancelled()) {
            return Err(Error::Cancelled("request was canceled before dispatch".to_string()));
        }
        let client = self.scope_id();
        REQUEST_SCOPES.with(|scopes| scopes.borrow_mut().push((client, options)));
        let _guard = RequestScopeGuard { client };
        call()
    }

    pub(crate) fn read(&self, operation: &'static str, params: Params) -> Result<Value> {
        let mut dispatched = false;
        self.request(
            operation,
            params,
            None,
            OperationClass::Read,
            self.scoped_request_options(),
            &mut dispatched,
        )
    }

    pub(crate) fn connection_control(
        &self,
        operation: &'static str,
        params: Params,
    ) -> Result<Value> {
        let mut dispatched = false;
        self.request(
            operation,
            params,
            None,
            OperationClass::ConnectionControl,
            self.scoped_request_options(),
            &mut dispatched,
        )
    }

    pub(crate) fn mutate(
        &self,
        operation: &'static str,
        mut params: Params,
        options: MutationOptions,
    ) -> Result<Value> {
        let request_options = options.request.merged_over(&self.scoped_request_options());
        let idempotency_key = options.idempotency_key;
        if let Some(revision) = options.expected_revision {
            params = params.u64(field::EXPECTED_REVISION, revision);
        }
        let mut dispatched = false;
        match self.request(
            operation,
            params,
            Some(idempotency_key.clone()),
            OperationClass::Mutation,
            request_options,
            &mut dispatched,
        ) {
            Err(error @ (Error::Connection(_) | Error::Timeout(_) | Error::Cancelled(_)))
                if dispatched =>
            {
                Err(Error::MutationTransport {
                    operation: operation.to_string(),
                    idempotency_key,
                    source: Box::new(error),
                })
            }
            result => result,
        }
    }

    pub(crate) fn stream(&self, operation: &'static str, params: Params) -> Result<ResourceStream> {
        if operation_class(operation) != OperationClass::StreamOpen {
            return Err(Error::InvalidArgument(format!(
                "{operation} is not a stream-open operation"
            )));
        }
        let id = self.next_request_id();
        let item_validator = super::typed_stream::stream_item_validator(operation)?;
        let budget = CallBudget::new(self.scoped_request_options(), self.shared.config.timeout)?;
        budget.check(operation)?;
        let stream_id = random_stream_id()?;
        let control_params = match operation {
            ops::TERMINAL_ATTACH => params.only(&[field::MACHINE, field::SESSION, field::TERMINAL]),
            ops::BROWSER_ATTACH => params.only(&[field::MACHINE, field::SESSION, field::BROWSER]),
            _ => Params::new(),
        };
        let params = params.id(field::STREAM_ID, &stream_id);
        let cancel_params = params.cancellation_scope(&stream_id);
        let envelope = request_envelope(&id, operation, params.into_value(), None);
        let mut connection = connect_with_budget(&self.shared.config, operation, &budget)?;
        let send_timeout = budget.remaining(operation)?;
        connection.with_write_timeout(send_timeout, |connection| {
            connection.send_with_limit(&envelope, self.shared.config.max_request_bytes)
        })?;
        let mut initial_envelopes = VecDeque::new();
        let mut initial_items = 0usize;
        let mut initial_bytes = 0usize;
        let mut initial_end_seen = false;
        let response = loop {
            let envelope = match receive_envelope_with_budget(&mut connection, operation, &budget) {
                Ok(envelope) => envelope,
                Err(error) => {
                    connection.close();
                    return Err(error);
                }
            };
            match envelope.get("type").and_then(Value::as_str) {
                Some("response") => {
                    break match decode_response(envelope, &id) {
                        Ok(response) => response,
                        Err(error) => {
                            // A valid `ok: false` means no stream lease exists,
                            // while malformed responses leave ownership
                            // ambiguous. Closing this dedicated transport is
                            // correct cleanup for both without hiding the
                            // server's original rejection.
                            connection.close();
                            return Err(error);
                        }
                    };
                }
                Some("stream_item") => {
                    if initial_end_seen
                        || envelope.get("stream_id").and_then(Value::as_str)
                            != Some(stream_id.as_str())
                    {
                        connection.close();
                        return Err(Error::UnexpectedEnvelope(
                            "invalid pre-ack stream item".to_string(),
                        ));
                    }
                    let size = match serde_json::to_vec(&envelope) {
                        Ok(encoded) => encoded.len(),
                        Err(error) => {
                            connection.close();
                            return Err(Error::Decode(error.to_string()));
                        }
                    };
                    if initial_items >= self.shared.config.max_stream_items
                        || size > self.shared.config.max_stream_bytes.saturating_sub(initial_bytes)
                    {
                        connection.close();
                        return Err(stream_overflow_error());
                    }
                    initial_items += 1;
                    initial_bytes += size;
                    initial_envelopes.push_back((envelope, size));
                }
                Some("stream_end")
                    if !initial_end_seen
                        && envelope.get("stream_id").and_then(Value::as_str)
                            == Some(stream_id.as_str()) =>
                {
                    initial_end_seen = true;
                    initial_envelopes.push_back((envelope, 0));
                }
                _ => {
                    connection.close();
                    return Err(Error::UnexpectedEnvelope(
                        "expected stream response, stream_item, or stream_end".to_string(),
                    ));
                }
            }
        };
        let attachment_lease = match validate_stream_open_ack(operation, &response, &stream_id) {
            Ok(attachment_lease) => attachment_lease,
            Err(error) => {
                connection.close();
                return Err(error);
            }
        };
        let writer = match connection.shutdown_clone() {
            Ok(writer) => writer,
            Err(error) => {
                connection.close();
                return Err(error);
            }
        };
        ResourceStream::from_parts(StreamParts {
            id: stream_id,
            attachment_lease,
            connection,
            writer,
            cancel_params,
            control_params,
            max_request_bytes: self.shared.config.max_request_bytes,
            max_stream_items: self.shared.config.max_stream_items,
            max_stream_bytes: self.shared.config.max_stream_bytes,
            cleanup_timeout: self.shared.config.timeout,
            item_validator,
            initial_envelopes,
        })
    }

    fn request(
        &self,
        operation: &'static str,
        params: Params,
        idempotency_key: Option<String>,
        expected_class: OperationClass,
        request_options: RequestOptions,
        dispatched: &mut bool,
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
        if let Some(idempotency_key) = idempotency_key.as_deref() {
            validate_idempotency_key(idempotency_key)?;
        }
        let budget = CallBudget::new(request_options, self.shared.config.timeout)?;
        budget.check(operation)?;
        let id = self.next_request_id();
        let envelope = request_envelope(&id, operation, params.into_value(), idempotency_key);
        let mut connection = loop {
            match self.shared.control.try_lock() {
                Ok(connection) => break connection,
                Err(TryLockError::Poisoned(_)) => {
                    return Err(Error::Connection("client connection lock poisoned".to_string()));
                }
                Err(TryLockError::WouldBlock) => {
                    let remaining = budget.remaining(operation)?;
                    std::thread::sleep(remaining.min(LOCK_POLL_INTERVAL));
                }
            }
        };
        if self.is_closed() {
            return Err(Error::Closed);
        }
        if connection.is_none() {
            budget.check(operation)?;
            *connection = Some(connect_with_budget(&self.shared.config, operation, &budget)?);
        }
        budget.check(operation)?;
        *dispatched = true;
        let mut reusable_after_abandonment = false;
        let result = {
            let active = connection.as_mut().ok_or(Error::Closed)?;
            let sent = budget.remaining(operation).and_then(|send_timeout| {
                active.with_write_timeout(send_timeout, |active| {
                    active.send_with_limit(&envelope, self.shared.config.max_request_bytes)
                })
            });
            match sent {
                Err(error) => Err(error),
                Ok(()) => match receive_response_with_budget(active, &id, operation, &budget) {
                    Err(original)
                        if request_can_be_abandoned(operation)
                            && matches!(&original, Error::Timeout(_) | Error::Cancelled(_)) =>
                    {
                        reusable_after_abandonment =
                            self.cancel_abandoned_request(active, &id, operation).is_ok();
                        Err(original)
                    }
                    result => result,
                },
            }
        };
        if !reusable_after_abandonment
            && result.as_ref().is_err_and(discard_connection_after)
            && let Some(active) = connection.take()
        {
            active.close();
        }
        result
    }

    fn cancel_abandoned_request(
        &self,
        connection: &mut JsonLineConnection,
        target_id: &str,
        target_operation: &str,
    ) -> Result<()> {
        let operation = ops::REQUEST_CANCEL;
        let budget = CallBudget::new(
            RequestOptions { timeout: Some(self.shared.config.timeout), cancellation: None },
            self.shared.config.timeout,
        )?;
        let cancel_id = self.next_request_id();
        let params = Value::Object(Map::from_iter([(
            "request_id".to_string(),
            Value::String(target_id.to_string()),
        )]));
        let envelope = request_envelope(&cancel_id, operation, params, None);
        let send_timeout = budget.remaining(operation)?;
        connection.with_write_timeout(send_timeout, |connection| {
            connection.send_with_limit(&envelope, self.shared.config.max_request_bytes)
        })?;

        let mut cancel_result = None;
        let mut target_seen = false;
        loop {
            let envelope = receive_envelope_with_budget(connection, operation, &budget)?;
            let response_id = envelope
                .as_object()
                .and_then(|object| object.get("id"))
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    Error::UnexpectedEnvelope(
                        "request cleanup requires a response with a string id".to_string(),
                    )
                })?;
            if response_id == target_id {
                if target_seen {
                    return Err(Error::UnexpectedEnvelope(
                        "request cleanup received a duplicate target response".to_string(),
                    ));
                }
                validate_completed_response(envelope, target_id, target_operation)?;
                target_seen = true;
            } else if response_id == cancel_id {
                if cancel_result.is_some() {
                    return Err(Error::UnexpectedEnvelope(
                        "request cleanup received a duplicate cancel response".to_string(),
                    ));
                }
                cancel_result =
                    Some(decode_request_cancel_result(decode_response(envelope, &cancel_id)?)?);
            } else {
                return Err(Error::UnexpectedEnvelope(
                    "request cleanup received a response for an unknown request".to_string(),
                ));
            }

            match cancel_result {
                Some(true) if target_seen => {
                    return Err(Error::UnexpectedEnvelope(
                        "canceled request also emitted a target response".to_string(),
                    ));
                }
                Some(true) => return Ok(()),
                Some(false) if target_seen => return Ok(()),
                _ => {}
            }
        }
    }

    fn next_request_id(&self) -> String {
        format!(
            "rust-{}-{}",
            std::process::id(),
            self.shared.next_request.fetch_add(1, Ordering::Relaxed)
        )
    }

    fn scope_id(&self) -> usize {
        Arc::as_ptr(&self.shared) as usize
    }

    fn scoped_request_options(&self) -> RequestOptions {
        let client = self.scope_id();
        REQUEST_SCOPES.with(|scopes| {
            scopes
                .borrow()
                .iter()
                .rev()
                .find(|(scope_client, _)| *scope_client == client)
                .map(|(_, options)| options.clone())
                .unwrap_or_default()
        })
    }
}

fn discard_connection_after(error: &Error) -> bool {
    matches!(
        error,
        Error::Connection(_)
            | Error::Timeout(_)
            | Error::Cancelled(_)
            | Error::Decode(_)
            | Error::FrameTooLarge { .. }
            | Error::UnexpectedEnvelope(_)
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
            | ops::SESSION_JOURNAL_SUBSCRIBE
            | ops::TERMINAL_ATTACH
            | ops::BROWSER_ATTACH
            | ops::SIDEBAR_VIEW_ATTACH
    ) {
        OperationClass::StreamOpen
    } else if matches!(
        operation,
        ops::REQUEST_CANCEL
            | ops::STREAM_CANCEL
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
            | ops::SESSION_CREATION_RESOLVE
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
            | ops::TERMINAL_WAIT_EXIT
            | ops::TERMINAL_COPY
            | ops::TERMINAL_PROCESS_GET
            | ops::BROWSER_LIST
            | ops::BROWSER_GET
            | ops::NOTIFICATION_LIST
            | ops::AGENT_LIST
            | ops::SIDEBAR_VIEW_GET
    ) {
        OperationClass::Read
    } else {
        OperationClass::Mutation
    }
}

pub(crate) fn request_envelope(
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

fn receive_response_with_budget(
    connection: &mut JsonLineConnection,
    expected_id: &str,
    operation: &str,
    budget: &CallBudget,
) -> Result<Value> {
    decode_response(receive_envelope_with_budget(connection, operation, budget)?, expected_id)
}

fn receive_envelope_with_budget(
    connection: &mut JsonLineConnection,
    operation: &str,
    budget: &CallBudget,
) -> Result<Value> {
    loop {
        let timeout = budget.receive_timeout(operation)?;
        match connection.with_read_timeout(timeout, JsonLineConnection::recv) {
            Err(Error::Timeout(_)) if budget.cancellation.is_some() => {
                budget.check(operation)?;
            }
            Err(Error::Timeout(_)) => {
                return Err(Error::Timeout(format!(
                    "{operation} did not respond before the deadline"
                )));
            }
            Err(error) => return Err(error),
            Ok(response) => return Ok(response),
        }
    }
}

fn request_can_be_abandoned(operation: &str) -> bool {
    matches!(operation, ops::TERMINAL_WAIT | ops::TERMINAL_WAIT_EXIT)
}

fn validate_completed_response(response: Value, expected_id: &str, operation: &str) -> Result<()> {
    match decode_response(response, expected_id) {
        Ok(value) if operation == ops::TERMINAL_WAIT => {
            super::wire::decode_exact::<super::model::TerminalWaitResult>(
                &value,
                "terminal wait result",
            )?;
            Ok(())
        }
        Ok(value) if operation == ops::TERMINAL_WAIT_EXIT => {
            super::wire::decode_exact::<super::model::TerminalWaitExitResult>(
                &value,
                "terminal wait exit result",
            )?;
            Ok(())
        }
        Ok(_) => Err(Error::UnexpectedEnvelope(format!(
            "request cancellation targeted unsupported operation {operation}"
        ))),
        Err(Error::Protocol { .. } | Error::ConfirmationRequired { .. }) => Ok(()),
        Err(error) => Err(error),
    }
}

fn decode_request_cancel_result(result: Value) -> Result<bool> {
    let object = result.as_object().ok_or_else(|| {
        Error::UnexpectedEnvelope("request cancel result must be an object".to_string())
    })?;
    if object.len() != 1 || !object.contains_key("canceled") {
        return Err(Error::UnexpectedEnvelope(
            "request cancel result must contain only canceled".to_string(),
        ));
    }
    object.get("canceled").and_then(Value::as_bool).ok_or_else(|| {
        Error::UnexpectedEnvelope("request cancel result canceled must be a boolean".to_string())
    })
}

fn stream_overflow_error() -> Error {
    Error::StreamEnded {
        reason: "gap".to_string(),
        recovery: Some("reopen the stream to obtain a fresh snapshot".to_string()),
        error: None,
    }
}

fn validate_stream_open_ack(
    operation: &str,
    response: &Value,
    expected: &StreamId,
) -> Result<Option<String>> {
    let object = response
        .as_object()
        .ok_or_else(|| Error::UnexpectedEnvelope("stream open result must be an object".into()))?;
    let stream_id = object
        .get("stream_id")
        .and_then(Value::as_str)
        .ok_or_else(|| Error::UnexpectedEnvelope("stream open result requires stream_id".into()))?;
    if stream_id != expected.as_str() {
        return Err(Error::UnexpectedEnvelope(format!(
            "stream response returned {stream_id}, expected {expected}"
        )));
    }
    if let Some(cursor) = object.get("cursor") {
        super::wire::parse_cursor(cursor)?;
    }
    let is_view_attachment = matches!(operation, ops::TERMINAL_ATTACH | ops::BROWSER_ATTACH);
    let attachment_lease = if is_view_attachment {
        let lease = object.get("attachment_lease").and_then(Value::as_str).ok_or_else(|| {
            Error::UnexpectedEnvelope(
                "terminal and browser stream results require attachment_lease".into(),
            )
        })?;
        if lease.is_empty() || lease.len() > 128 {
            return Err(Error::UnexpectedEnvelope(
                "stream attachment_lease must contain 1 to 128 bytes".into(),
            ));
        }
        Some(lease.to_string())
    } else {
        None
    };
    let mut unknown = object
        .keys()
        .filter(|field| {
            !(matches!(field.as_str(), "stream_id" | "cursor")
                || is_view_attachment && field.as_str() == "attachment_lease")
        })
        .cloned()
        .collect::<Vec<_>>();
    unknown.sort();
    if !unknown.is_empty() {
        return Err(Error::UnexpectedEnvelope(format!(
            "stream open result contains unknown fields: {}",
            unknown.join(", ")
        )));
    }
    Ok(attachment_lease)
}

pub(crate) fn decode_response(response: Value, expected_id: &str) -> Result<Value> {
    let object = response
        .as_object()
        .ok_or_else(|| Error::UnexpectedEnvelope("response must be an object".to_string()))?;
    if object.get("protocol").and_then(Value::as_str) != Some(PROTOCOL)
        || object.get("type").and_then(Value::as_str) != Some("response")
    {
        return Err(Error::UnexpectedEnvelope(
            "expected cmux.protocol/2 response envelope".to_string(),
        ));
    }
    if object.get("id").and_then(Value::as_str) != Some(expected_id) {
        return Err(Error::UnexpectedEnvelope("response id does not match request".to_string()));
    }
    let ok = object
        .get("ok")
        .and_then(Value::as_bool)
        .ok_or_else(|| Error::UnexpectedEnvelope("response ok must be a boolean".to_string()))?;
    let variant_field = if ok { "result" } else { "error" };
    let forbidden_field = if ok { "error" } else { "result" };
    if !object.contains_key(variant_field) {
        return Err(Error::UnexpectedEnvelope(format!(
            "{} response lacks {variant_field}",
            if ok { "successful" } else { "failed" }
        )));
    }
    if object.contains_key(forbidden_field) {
        return Err(Error::UnexpectedEnvelope(format!(
            "{} response must not contain {forbidden_field}",
            if ok { "successful" } else { "failed" }
        )));
    }
    let mut unknown = object
        .keys()
        .filter(|field| {
            !matches!(field.as_str(), "protocol" | "type" | "id" | "ok")
                && field.as_str() != variant_field
        })
        .cloned()
        .collect::<Vec<_>>();
    unknown.sort();
    if !unknown.is_empty() {
        return Err(Error::UnexpectedEnvelope(format!(
            "response contains unknown fields: {}",
            unknown.join(", ")
        )));
    }
    if ok { Ok(object["result"].clone()) } else { Err(decode_protocol_error(&object["error"])?) }
}

pub(crate) fn decode_protocol_error(value: &Value) -> Result<Error> {
    let object = value
        .as_object()
        .ok_or_else(|| Error::UnexpectedEnvelope("protocol error must be an object".to_string()))?;
    let mut unknown = object
        .keys()
        .filter(|field| !matches!(field.as_str(), "code" | "message" | "details" | "retryable"))
        .cloned()
        .collect::<Vec<_>>();
    unknown.sort();
    if !unknown.is_empty() {
        return Err(Error::UnexpectedEnvelope(format!(
            "protocol error contains unknown fields: {}",
            unknown.join(", ")
        )));
    }
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
    if code == "confirmation.required" {
        if retryable {
            return Err(Error::UnexpectedEnvelope(
                "confirmation.required must not be retryable".to_string(),
            ));
        }
        let details = super::wire::decode_exact(&details, "confirmation.required details")?;
        return Ok(Error::ConfirmationRequired { message, details });
    }
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
    fn cancellable_connect_reuses_one_socket_across_poll_slices() {
        let probe = crate::codec::ForcedPendingConnectProbe::install_with_poll_limit(3);
        let cancellation = super::super::options::CancellationToken::new();
        let options = RequestOptions::new()
            .with_timeout(Duration::from_secs(1))
            .unwrap()
            .with_cancellation(cancellation);
        let budget = CallBudget::new(options, Duration::from_secs(1)).unwrap();
        let config = Config::from_socket_path("pending-connect.sock");

        assert!(matches!(
            connect_with_budget(&config, ops::SESSION_LIST, &budget),
            Err(Error::Timeout(_))
        ));
        assert_eq!(probe.polls(), 3, "the connect should span the configured poll slices");
        assert_eq!(
            probe.attempts(),
            1,
            "cancellation polling must keep one pending Unix socket instead of recreating it"
        );
    }

    #[test]
    fn pending_connect_observes_cancellation_while_reusing_its_socket() {
        let cancellation = super::super::options::CancellationToken::new();
        let cancel_from_thread = cancellation.clone();
        let (pending_tx, pending_rx) = std::sync::mpsc::channel();
        let (cancelled_tx, cancelled_rx) = std::sync::mpsc::channel();
        let canceler = std::thread::spawn(move || {
            pending_rx.recv().unwrap();
            cancel_from_thread.cancel();
            cancelled_tx.send(()).unwrap();
        });
        let probe =
            crate::codec::ForcedPendingConnectProbe::install_with_after_first_poll(move || {
                pending_tx.send(()).unwrap();
                cancelled_rx.recv().unwrap();
            });
        let options = RequestOptions::new()
            .with_timeout(Duration::from_secs(1))
            .unwrap()
            .with_cancellation(cancellation);
        let budget = CallBudget::new(options, Duration::from_secs(1)).unwrap();
        let config = Config::from_socket_path("cancel-pending-connect.sock");

        assert!(matches!(
            connect_with_budget(&config, ops::SESSION_LIST, &budget),
            Err(Error::Cancelled(_))
        ));
        canceler.join().unwrap();
        assert_eq!(probe.polls(), 1, "the cancellation should interrupt the next poll check");
        assert_eq!(probe.attempts(), 1, "cancellation must close one pending Unix socket");
    }

    #[test]
    fn classification_matches_connection_control_exceptions() {
        assert_eq!(operation_class(ops::TERMINAL_COPY), OperationClass::Read);
        assert_eq!(operation_class(ops::REQUEST_CANCEL), OperationClass::ConnectionControl);
        assert_eq!(operation_class(ops::TERMINAL_VIEWER_RESIZE), OperationClass::ConnectionControl);
        assert_eq!(operation_class(ops::TAB_CREATE_TERMINAL), OperationClass::Mutation);
    }
}
