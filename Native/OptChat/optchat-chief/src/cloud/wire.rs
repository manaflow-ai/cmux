//! A newline-JSON client for the daemon's `cloud-*` commands. The typed SDK
//! folds a failed reply into one message string; the cloud source needs the
//! reply's `error_code` and `reason` to tell an owner reject (drop the op)
//! from an outage (keep the op and reconnect).

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

use serde_json::{Map, Value, json};

use crate::daemon::OpError;

/// One daemon command with its params; `Ok` is the reply's `data`.
pub trait Rpc: Send {
    fn call(&mut self, cmd: &str, params: Value) -> Result<Value, OpError>;
}

/// The error a failed reply means for the brain. `cloud_conversation_rejected`
/// and plain errors were decided by an owner (or are a bad request): the op
/// is dropped. Every other cloud code means nothing was decided or the
/// outcome is unknown: the op stays and the link reconnects.
pub fn reply_error(reply: &Value) -> OpError {
    let message = reply
        .get("error")
        .map(|e| e.as_str().map_or_else(|| e.to_string(), str::to_owned))
        .unwrap_or_else(|| "unknown error".into());
    let reason = reply.get("reason").and_then(Value::as_str).unwrap_or("");
    match reply.get("error_code").and_then(Value::as_str) {
        None | Some("cloud_conversation_rejected") => OpError::Rejected(if reason.is_empty() {
            message
        } else {
            format!("{reason}: {message}")
        }),
        Some(code) => OpError::Transport(format!("{code} ({reason}): {message}")),
    }
}

/// A connection to the daemon's Unix socket (a trusted local connection).
pub struct LineClient {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
    /// A line read only in part when a read timed out.
    partial: String,
}

impl LineClient {
    pub fn connect(path: &Path, timeout: Duration) -> std::io::Result<LineClient> {
        let stream = UnixStream::connect(path)?;
        stream.set_read_timeout(Some(timeout))?;
        stream.set_write_timeout(Some(timeout))?;
        Ok(LineClient {
            reader: BufReader::new(stream.try_clone()?),
            writer: stream,
            next: 1,
            partial: String::new(),
        })
    }

    /// A handle that ends this connection from another thread.
    pub fn closer(&self) -> std::io::Result<UnixStream> {
        self.writer.try_clone()
    }

    /// The next event line on a subscribed connection: `Ok(None)` when the
    /// read timed out, `Err` when the connection ended.
    pub fn next_event(&mut self) -> std::io::Result<Option<Value>> {
        loop {
            match self.reader.read_line(&mut self.partial) {
                Ok(0) => return Err(std::io::ErrorKind::UnexpectedEof.into()),
                Ok(_) => {
                    let line = std::mem::take(&mut self.partial);
                    match serde_json::from_str::<Value>(&line) {
                        Ok(v) if v.get("event").is_some() => return Ok(Some(v)),
                        _ => continue,
                    }
                }
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    return Ok(None);
                }
                Err(e) => return Err(e),
            }
        }
    }

    /// Sends one command and returns the whole reply (events are skipped).
    pub fn request(&mut self, cmd: &str, params: Value) -> Result<Value, OpError> {
        let id = self.next;
        self.next += 1;
        let mut frame = match params {
            Value::Object(map) => map,
            Value::Null => Map::new(),
            other => {
                return Err(OpError::Transport(format!(
                    "{cmd}: params must be an object, not {other}"
                )));
            }
        };
        frame.insert("id".into(), json!(id));
        frame.insert("cmd".into(), json!(cmd));
        let mut line = serde_json::to_string(&Value::Object(frame))
            .map_err(|e| OpError::Transport(e.to_string()))?;
        line.push('\n');
        self.writer
            .write_all(line.as_bytes())
            .map_err(|e| OpError::Transport(format!("{cmd}: {e}")))?;
        loop {
            let mut text = String::new();
            let n = self
                .reader
                .read_line(&mut text)
                .map_err(|e| OpError::Transport(format!("{cmd}: {e}")))?;
            if n == 0 {
                return Err(OpError::Transport(format!(
                    "{cmd}: the daemon closed the connection"
                )));
            }
            let reply: Value = serde_json::from_str(&text)
                .map_err(|e| OpError::Transport(format!("{cmd}: {e}")))?;
            if reply.get("event").is_some() || reply.get("id") != Some(&json!(id)) {
                continue;
            }
            return Ok(reply);
        }
    }
}

impl Rpc for LineClient {
    fn call(&mut self, cmd: &str, params: Value) -> Result<Value, OpError> {
        let reply = self.request(cmd, params)?;
        if reply.get("ok") == Some(&Value::Bool(true)) {
            Ok(reply.get("data").cloned().unwrap_or(Value::Null))
        } else {
            Err(reply_error(&reply))
        }
    }
}
