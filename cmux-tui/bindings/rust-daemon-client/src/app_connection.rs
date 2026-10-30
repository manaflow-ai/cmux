//! The verified app connection (plans/cmux-next/request-origin.md, "Hello
//! and capability"; cmux-next `HandshakeLines`): a daemon connection whose
//! first lines are `client-hello` role `main` with the app's install id, then
//! the HMAC proof over the daemon's nonce. When the daemon accepts the proof
//! the connection is `verified_app`, and its `cmux.protocol/2` requests have
//! origin `user` (gate A2: `history.visit.record`, `history.visit.title`,
//! `history.visit.import`, `apps.install`, ...). Without a key, or when the
//! daemon refuses the proof (an owner started by another app or without the
//! key, an older daemon, Windows), the connection stays open with origin
//! `agent` and the daemon refuses those operations with `origin.forbidden`.
//!
//! The proof and the key never reach a log line.

use crate::install_key::InstallKey;
use cmux::raw;
use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// One app connection. Requests block the calling thread up to the
/// connection's timeout; use it from a work thread, never a UI thread.
pub struct AppConnection {
    client: raw::Client,
    socket: PathBuf,
    verified: bool,
    next_id: u64,
}

impl AppConnection {
    /// Connects to `socket` and, with `key`, proves the app with
    /// `client-hello` before any other line. A refused hello is not an
    /// error: [`Self::verified`] is false.
    pub fn connect(
        socket: &Path,
        key: Option<&InstallKey>,
        timeout: Duration,
    ) -> raw::Result<Self> {
        let config = raw::ClientConfig::from_socket_path(socket).with_timeout(timeout);
        let mut client = raw::Client::connect(config)?;
        let verified = key.is_some_and(|key| hello(&mut client, key));
        Ok(Self { client, socket: socket.to_path_buf(), verified, next_id: 1 })
    }

    /// True when the daemon accepted the proof: requests have origin `user`.
    pub fn verified(&self) -> bool {
        self.verified
    }

    pub fn socket(&self) -> &Path {
        &self.socket
    }

    /// One `cmux.protocol/2` request (`operation` without a `cmux.`
    /// prefix, e.g. `history.visit.record`); mutations need an
    /// `idempotency_key`. `machine` and `session` default to `current`, as
    /// cmux-next's `ResourceRequest` sends them. Returns the reply's
    /// `result`; a refusal is `Error::Protocol` with the daemon's code
    /// (`origin.forbidden`, ...).
    pub fn request(
        &mut self,
        operation: &str,
        mut params: Value,
        idempotency_key: Option<&str>,
    ) -> raw::Result<Value> {
        if let Some(object) = params.as_object_mut() {
            for selector in ["machine", "session"] {
                object.entry(selector).or_insert_with(|| json!("current"));
            }
        }
        let id = format!("cmux-app-{}", self.next_id);
        self.next_id += 1;
        let mut envelope = Map::from_iter([
            ("protocol".to_string(), json!("cmux.protocol/2")),
            ("type".to_string(), json!("request")),
            ("id".to_string(), json!(id)),
            ("operation".to_string(), json!(operation)),
            ("params".to_string(), params),
        ]);
        if let Some(key) = idempotency_key {
            envelope.insert("idempotency_key".to_string(), json!(key));
        }
        let mut reply = self.client.request_raw(envelope)?;
        Ok(reply.get_mut("result").map(Value::take).unwrap_or(Value::Null))
    }

    /// The raw client, for protocol-12 commands on the same connection.
    pub fn raw(&mut self) -> &mut raw::Client {
        &mut self.client
    }

    pub fn close(mut self) {
        self.client.close();
    }
}

/// `client-hello` step 1 (role main, install id) and step 2 (proof). True
/// only when the daemon answers `verified: true`.
fn hello(client: &mut raw::Client, key: &InstallKey) -> bool {
    let start = Map::from_iter([
        ("cmd".to_string(), json!("client-hello")),
        ("role".to_string(), json!("main")),
        ("install_id".to_string(), json!(key.install_id())),
    ]);
    let nonce = match client.request_raw(start) {
        Ok(reply) => reply.pointer("/data/nonce").and_then(Value::as_str).map(str::to_string),
        Err(error) => {
            log::info!("cmux daemon: client-hello not accepted ({})", code(&error));
            return false;
        }
    };
    // No nonce: the daemon could not make one; the connection stays unverified.
    let Some(proof) = nonce.as_deref().and_then(|nonce| key.proof(nonce)) else {
        log::info!("cmux daemon: client-hello gave no nonce; connection unverified");
        return false;
    };
    let step2 = Map::from_iter([
        ("cmd".to_string(), json!("client-hello")),
        ("install_id".to_string(), json!(key.install_id())),
        ("proof".to_string(), json!(proof)),
    ]);
    match client.request_raw(step2) {
        Ok(reply) => reply.pointer("/data/verified") == Some(&Value::Bool(true)),
        Err(error) => {
            log::info!("cmux daemon: install-key proof refused ({})", code(&error));
            false
        }
    }
}

fn code(error: &raw::Error) -> String {
    error.error_code().map_or_else(|| error.to_string(), str::to_string)
}
