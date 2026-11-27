//! One live MCP connection over a [`Wire`]: the handshake of either protocol
//! era, then requests. A 2025-11-25 server gets `initialize` and keeps a
//! session; a 2026-07-28 server (no `initialize`) gets `server/discover` and
//! every request then carries its version and capabilities in `_meta`.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use serde_json::{Value, json};

use super::wire::{Wire, WireError};

/// The session-era revision the hub asks for first (the widest deployed).
pub const SESSION_PROTOCOL: &str = "2025-11-25";
/// The stateless revision (no handshake, `server/discover`).
pub const STATELESS_PROTOCOL: &str = "2026-07-28";
/// The Tasks extension's id in 2026-07-28 capabilities.
pub const TASKS_EXTENSION: &str = "io.modelcontextprotocol/tasks";

pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(60);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Era {
    /// `initialize` + session (2024-11-05 .. 2025-11-25).
    Session,
    /// Per-request `_meta`, `server/discover` (2026-07-28).
    Stateless,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ClientError {
    Wire(WireError),
    /// A JSON-RPC error from the server.
    Rpc {
        code: i64,
        message: String,
    },
}

impl std::fmt::Display for ClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ClientError::Wire(e) => write!(f, "{e}"),
            ClientError::Rpc { code, message } => {
                write!(f, "the server answered error {code}: {message}")
            }
        }
    }
}

impl From<WireError> for ClientError {
    fn from(e: WireError) -> Self {
        ClientError::Wire(e)
    }
}

pub struct Client {
    pub wire: Arc<dyn Wire>,
    next: AtomicU64,
    pub era: Era,
    pub protocol: String,
    pub capabilities: Value,
    pub server_info: Value,
    pub instructions: Option<String>,
}

fn client_info() -> Value {
    json!({"name": "cmux-chief", "title": "cmux Chief", "version": env!("CARGO_PKG_VERSION")})
}

fn client_capabilities() -> Value {
    json!({"extensions": {TASKS_EXTENSION: {}}})
}

impl Client {
    /// Connects: `initialize` first; a server that does not know it (or the
    /// version) is asked `server/discover` and spoken to statelessly.
    pub fn connect(wire: Arc<dyn Wire>) -> Result<Client, ClientError> {
        let mut client = Client {
            wire,
            next: AtomicU64::new(1),
            era: Era::Session,
            protocol: SESSION_PROTOCOL.to_owned(),
            capabilities: Value::Null,
            server_info: Value::Null,
            instructions: None,
        };
        let init = client.raw(
            "initialize",
            json!({"protocolVersion": SESSION_PROTOCOL, "capabilities": {}, "clientInfo": client_info()}),
            DEFAULT_TIMEOUT,
        );
        match init {
            Ok(result) => {
                client.protocol = result["protocolVersion"]
                    .as_str()
                    .unwrap_or(SESSION_PROTOCOL)
                    .to_owned();
                client.capabilities = result["capabilities"].clone();
                client.server_info = result["serverInfo"].clone();
                client.instructions = result["instructions"].as_str().map(str::to_owned);
                client.wire.set_protocol(&client.protocol);
                client
                    .wire
                    .notify(&json!({"jsonrpc": "2.0", "method": "notifications/initialized"}))?;
                Ok(client)
            }
            Err(ClientError::Rpc { .. }) => {
                client.era = Era::Stateless;
                client.protocol = STATELESS_PROTOCOL.to_owned();
                client.wire.set_protocol(STATELESS_PROTOCOL);
                let found = client.request("server/discover", json!({}), DEFAULT_TIMEOUT)?;
                if let Some(versions) = found["supportedVersions"].as_array()
                    && let Some(v) = versions.iter().filter_map(Value::as_str).max()
                {
                    client.protocol = v.to_owned();
                    client.wire.set_protocol(v);
                }
                client.capabilities = found["capabilities"].clone();
                client.server_info = found["serverInfo"].clone();
                client.instructions = found["instructions"].as_str().map(str::to_owned);
                Ok(client)
            }
            Err(e) => Err(e),
        }
    }

    pub fn next_id(&self) -> u64 {
        self.next.fetch_add(1, Ordering::SeqCst)
    }

    /// The JSON-RPC message for `method` (with the stateless `_meta`).
    pub fn message(&self, id: u64, method: &str, params: Value) -> Value {
        let mut params = if params.is_object() {
            params
        } else {
            json!({})
        };
        if self.era == Era::Stateless {
            let meta = params
                .as_object_mut()
                .expect("object")
                .entry("_meta")
                .or_insert_with(|| json!({}));
            meta["io.modelcontextprotocol/protocolVersion"] = json!(self.protocol);
            meta["io.modelcontextprotocol/clientInfo"] = client_info();
            meta["io.modelcontextprotocol/clientCapabilities"] = client_capabilities();
        }
        json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
    }

    fn raw(&self, method: &str, params: Value, timeout: Duration) -> Result<Value, ClientError> {
        let id = self.next_id();
        let msg = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        Self::result(self.wire.request(&msg, timeout)?)
    }

    fn result(answer: Value) -> Result<Value, ClientError> {
        if let Some(e) = answer.get("error") {
            return Err(ClientError::Rpc {
                code: e["code"].as_i64().unwrap_or(0),
                message: e["message"].as_str().unwrap_or("").to_owned(),
            });
        }
        Ok(answer.get("result").cloned().unwrap_or(Value::Null))
    }

    /// One request; answers its `result`.
    pub fn request(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, ClientError> {
        let id = self.next_id();
        let answer = self
            .wire
            .request(&self.message(id, method, params), timeout);
        match answer {
            Err(WireError::Timeout) => {
                // Tell the server to stop working on it.
                let _ = self.wire.notify(
                    &json!({"jsonrpc": "2.0", "method": "notifications/cancelled",
                    "params": {"requestId": id, "reason": "timed out"}}),
                );
                Err(ClientError::Wire(WireError::Timeout))
            }
            other => Self::result(other?),
        }
    }

    /// Every page of a list method (`tools/list` -> `tools`).
    pub fn list_all(&self, method: &str, key: &str) -> Result<Vec<Value>, ClientError> {
        let mut out = Vec::new();
        let mut cursor: Option<String> = None;
        for _ in 0..50 {
            let params = match &cursor {
                Some(c) => json!({"cursor": c}),
                None => json!({}),
            };
            let page = self.request(method, params, DEFAULT_TIMEOUT)?;
            out.extend(page[key].as_array().cloned().unwrap_or_default());
            cursor = page["nextCursor"].as_str().map(str::to_owned);
            if cursor.is_none() {
                break;
            }
        }
        Ok(out)
    }

    /// Whether the server has capability `path` (`["resources", "subscribe"]`).
    pub fn has(&self, path: &[&str]) -> bool {
        let mut v = &self.capabilities;
        for p in path {
            v = &v[*p];
        }
        !v.is_null() && v != &json!(false)
    }

    /// Whether the server takes task-augmented tool calls (2025-11-25
    /// `tasks.requests.tools.call`, or the 2026 Tasks extension).
    pub fn does_tasks(&self) -> bool {
        self.has(&["tasks", "requests", "tools", "call"])
            || !self.capabilities["extensions"][TASKS_EXTENSION].is_null()
    }

    pub fn close(&self) {
        self.wire.close();
    }
}

/// The task handle in a `tools/call` result, if the server made one: the
/// 2025-11-25 `CreateTaskResult {task}` or the 2026 `resultType: "task"`.
pub fn task_handle(result: &Value) -> Option<Value> {
    if let Some(t) = result.get("task").filter(|t| t.get("taskId").is_some()) {
        return Some(t.clone());
    }
    if result["resultType"] == "task" {
        return Some(
            result
                .get("task")
                .cloned()
                .unwrap_or_else(|| result.clone()),
        );
    }
    None
}
