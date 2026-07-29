use super::id::StreamId;
use super::model::{StreamEnd, StreamEndReason, StreamItem};
use super::ops;
use super::wire::{self, Params};
use crate::{Error, Result};
use serde_json::{Value, json};
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

pub(crate) struct StreamParts {
    pub(crate) id: StreamId,
    pub(crate) connection: crate::codec::JsonLineConnection,
    pub(crate) writer: UnixStream,
    pub(crate) cancel_params: Params,
    pub(crate) max_request_bytes: usize,
}

struct CancellationInner {
    id: StreamId,
    writer: Mutex<UnixStream>,
    cancel_params: Params,
    max_request_bytes: usize,
    canceled: AtomicBool,
}

/// Thread-safe cancellation handle for an owned resource stream.
#[derive(Clone)]
pub struct StreamCancellation {
    inner: Arc<CancellationInner>,
}

impl StreamCancellation {
    /// Sends a detached cancellation request.
    ///
    /// Use the owned typed stream's `cancel` method when the caller must wait
    /// for the matching response and canceled end state.
    pub fn cancel(&self) -> Result<()> {
        self.send().map(|_| ())
    }

    fn request_id(&self) -> String {
        format!("rust-cancel-{}", self.inner.id.as_str())
    }

    fn send(&self) -> Result<bool> {
        if self.inner.canceled.swap(true, Ordering::AcqRel) {
            return Ok(false);
        }
        let request_id = self.request_id();
        let envelope = json!({
            "protocol": "cmux.protocol/1",
            "type": "request",
            "id": request_id,
            "operation": ops::STREAM_CANCEL,
            "params": self.inner.cancel_params.clone().into_value(),
        });
        let encoded =
            serde_json::to_vec(&envelope).map_err(|error| Error::Decode(error.to_string()))?;
        if encoded.len() > self.inner.max_request_bytes {
            return Err(Error::FrameTooLarge {
                size: encoded.len(),
                limit: self.inner.max_request_bytes,
            });
        }
        let mut writer = self
            .inner
            .writer
            .lock()
            .map_err(|_| Error::Connection("stream writer lock poisoned".to_string()))?;
        writer
            .write_all(&encoded)
            .and_then(|()| writer.write_all(b"\n"))
            .map_err(|error| Error::Connection(format!("stream cancel failed: {error}")))?;
        Ok(true)
    }
}

/// Owned, blocking, cancellable iterator over one resource stream.
pub struct ResourceStream {
    id: StreamId,
    connection: crate::codec::JsonLineConnection,
    cancellation: StreamCancellation,
    last_sequence: Option<u64>,
    end: Option<StreamEnd>,
    terminal_error_emitted: bool,
}

impl ResourceStream {
    pub(crate) fn from_parts(parts: StreamParts) -> Self {
        let cancellation = StreamCancellation {
            inner: Arc::new(CancellationInner {
                id: parts.id.clone(),
                writer: Mutex::new(parts.writer),
                cancel_params: parts.cancel_params,
                max_request_bytes: parts.max_request_bytes,
                canceled: AtomicBool::new(false),
            }),
        };
        Self {
            id: parts.id,
            connection: parts.connection,
            cancellation,
            last_sequence: None,
            end: None,
            terminal_error_emitted: false,
        }
    }

    pub fn id(&self) -> &StreamId {
        &self.id
    }

    pub fn cancellation(&self) -> StreamCancellation {
        self.cancellation.clone()
    }

    /// Cancels the stream and discards unread items until cancellation is
    /// confirmed by both the response and the matching canceled end envelope.
    pub fn cancel(&mut self) -> Result<()> {
        if self.end.is_some() {
            return Ok(());
        }
        let request_id = self.cancellation.request_id();
        self.cancellation.send()?;
        let mut response_seen = false;
        let mut end_seen = false;
        while !response_seen || !end_seen {
            let envelope = self.connection.recv()?;
            match envelope.get("type").and_then(Value::as_str) {
                Some("response") => {
                    super::client::decode_response(envelope, &request_id)?;
                    response_seen = true;
                }
                Some("stream_item") => {
                    // Items already in flight before cancellation are stale.
                    // Decode the envelope for protocol/sequence validation,
                    // then intentionally discard the typed payload.
                    self.decode_item(envelope)?;
                }
                Some("stream_end") => {
                    let end = self.decode_end(envelope)?;
                    if end.reason != StreamEndReason::Canceled {
                        return Err(Error::UnexpectedEnvelope(format!(
                            "cancel ended stream with {:?}, expected canceled",
                            end.reason
                        )));
                    }
                    self.end = Some(end);
                    end_seen = true;
                }
                _ => {
                    return Err(Error::UnexpectedEnvelope(
                        "expected cancel response, stream_item, or stream_end".to_string(),
                    ));
                }
            }
        }
        Ok(())
    }

    pub fn end(&self) -> Option<&StreamEnd> {
        self.end.as_ref()
    }

    pub fn recv(&mut self) -> Result<Option<StreamItem>> {
        loop {
            if let Some(end) = &self.end {
                return match end.reason {
                    StreamEndReason::Completed
                    | StreamEndReason::Canceled
                    | StreamEndReason::Closed => Ok(None),
                    StreamEndReason::Gap | StreamEndReason::Error => Err(Error::StreamEnded {
                        reason: format!("{:?}", end.reason).to_lowercase(),
                        recovery: end.recovery.clone(),
                        error: end.error.as_ref().map(|error| {
                            Box::new(Error::Protocol {
                                code: error.code.clone(),
                                message: error.message.clone(),
                                details: error.details.0.clone(),
                                retryable: error.retryable,
                            })
                        }),
                    }),
                };
            }
            let envelope = self.connection.recv()?;
            let envelope_type = envelope.get("type").and_then(Value::as_str);
            match envelope_type {
                Some("response") => continue,
                Some("stream_item") => return self.decode_item(envelope).map(Some),
                Some("stream_end") => {
                    self.end = Some(self.decode_end(envelope)?);
                }
                _ => {
                    return Err(Error::UnexpectedEnvelope(
                        "expected response, stream_item, or stream_end".to_string(),
                    ));
                }
            }
        }
    }

    fn decode_item(&mut self, value: Value) -> Result<StreamItem> {
        let object = value.as_object().ok_or_else(|| {
            Error::UnexpectedEnvelope("stream item must be an object".to_string())
        })?;
        validate_protocol(object)?;
        validate_stream_id(object, &self.id)?;
        let sequence = wire::parse_decimal(
            object.get("sequence").ok_or_else(|| {
                Error::UnexpectedEnvelope("stream item sequence is required".to_string())
            })?,
            "stream sequence",
        )?;
        if let Some(last) = self.last_sequence {
            let expected = last.checked_add(1).ok_or_else(|| {
                Error::UnexpectedEnvelope(
                    "stream emitted an item after the maximum sequence".to_string(),
                )
            })?;
            if sequence != expected {
                return Err(Error::UnexpectedEnvelope(format!(
                    "stream sequence jumped from {last} to {sequence}"
                )));
            }
        }
        self.last_sequence = Some(sequence);
        let cursor = object.get("cursor").map(wire::parse_cursor).transpose()?;
        let value = object.get("item").cloned().ok_or_else(|| {
            Error::UnexpectedEnvelope("stream item payload is required".to_string())
        })?;
        Ok(StreamItem { sequence, cursor, value })
    }

    fn decode_end(&self, value: Value) -> Result<StreamEnd> {
        let object = value
            .as_object()
            .ok_or_else(|| Error::UnexpectedEnvelope("stream end must be an object".to_string()))?;
        validate_protocol(object)?;
        validate_stream_id(object, &self.id)?;
        let reason = object
            .get("reason")
            .and_then(Value::as_str)
            .and_then(StreamEndReason::parse)
            .ok_or_else(|| Error::UnexpectedEnvelope("invalid stream end reason".to_string()))?;
        let cursor = object.get("cursor").map(wire::parse_cursor).transpose()?;
        let recovery = object
            .get("recovery")
            .map(|value| {
                value.as_str().map(ToOwned::to_owned).ok_or_else(|| {
                    Error::UnexpectedEnvelope("stream recovery must be a string".to_string())
                })
            })
            .transpose()?;
        let error = object
            .get("error")
            .map(|error| {
                let object = error.as_object().ok_or_else(|| {
                    Error::UnexpectedEnvelope("stream error must be an object".to_string())
                })?;
                Ok(super::model::ProtocolFailure {
                    code: object
                        .get("code")
                        .and_then(Value::as_str)
                        .ok_or_else(|| {
                            Error::UnexpectedEnvelope(
                                "stream error code must be a string".to_string(),
                            )
                        })?
                        .to_string(),
                    message: object
                        .get("message")
                        .and_then(Value::as_str)
                        .ok_or_else(|| {
                            Error::UnexpectedEnvelope(
                                "stream error message must be a string".to_string(),
                            )
                        })?
                        .to_string(),
                    details: super::model::Document(object.get("details").cloned().ok_or_else(
                        || {
                            Error::UnexpectedEnvelope(
                                "stream error details are required".to_string(),
                            )
                        },
                    )?),
                    retryable: object.get("retryable").and_then(Value::as_bool).ok_or_else(
                        || {
                            Error::UnexpectedEnvelope(
                                "stream error retryable must be a boolean".to_string(),
                            )
                        },
                    )?,
                })
            })
            .transpose()?;
        if matches!(reason, StreamEndReason::Error) != error.is_some() {
            return Err(Error::UnexpectedEnvelope(
                "stream_end error is required exactly when reason is error".to_string(),
            ));
        }
        Ok(StreamEnd { reason, cursor, recovery, error })
    }
}

impl Iterator for ResourceStream {
    type Item = Result<StreamItem>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.terminal_error_emitted {
            return None;
        }
        match self.recv() {
            Ok(Some(item)) => Some(Ok(item)),
            Ok(None) => None,
            Err(error) => {
                self.terminal_error_emitted = true;
                Some(Err(error))
            }
        }
    }
}

impl Drop for ResourceStream {
    fn drop(&mut self) {
        // This releases only the connection-local stream lease. It never
        // closes or deletes the resource being observed. Drop sends a
        // best-effort detached request rather than blocking for confirmation.
        let _ = self.cancellation.cancel();
        self.connection.close();
    }
}

fn validate_protocol(object: &serde_json::Map<String, Value>) -> Result<()> {
    if object.get("protocol").and_then(Value::as_str) != Some("cmux.protocol/1") {
        return Err(Error::UnexpectedEnvelope(
            "stream envelope protocol must be cmux.protocol/1".to_string(),
        ));
    }
    Ok(())
}

fn validate_stream_id(object: &serde_json::Map<String, Value>, expected: &StreamId) -> Result<()> {
    let actual = object
        .get("stream_id")
        .and_then(Value::as_str)
        .ok_or_else(|| Error::UnexpectedEnvelope("stream_id is required".to_string()))?;
    if actual != expected.as_str() {
        return Err(Error::UnexpectedEnvelope(format!(
            "received stream {actual}, expected {expected}"
        )));
    }
    Ok(())
}
