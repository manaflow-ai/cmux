//! Client library used by the CLI and TUI: connect to the daemon socket,
//! send requests, and receive notifications.

use crate::no_panic::JsonExt;
use crate::no_panic::LockExt;
use crate::rpc::{Message, RpcError, method};
use anyhow::{Context, Result, anyhow};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{Mutex, mpsc, oneshot};

pub struct Client {
    /// Build id the daemon reported at initialize, for mismatch hints.
    daemon_build: std::sync::Mutex<Option<String>>,
    /// The features the daemon listed at initialize (`_meta.acpmux.features`).
    daemon_features: std::sync::Mutex<Vec<String>>,
    /// The person challenge `{nonce, connection}` of this connection, when the
    /// daemon offered one at initialize (`hub/person.rs`).
    person_challenge: std::sync::Mutex<Option<(String, String)>>,
    out: mpsc::Sender<String>,
    next_id: AtomicI64,
    pending: Arc<Mutex<HashMap<String, oneshot::Sender<Result<Value, RpcError>>>>>,
    notifications: Mutex<Option<mpsc::Receiver<Message>>>,
    notif_tx: Arc<Mutex<mpsc::Sender<Message>>>,
    closed: Arc<std::sync::atomic::AtomicBool>,
}

impl Client {
    pub async fn connect(path: &Path) -> Result<Arc<Self>> {
        let stream = crate::local_stream::connect(path)
            .await
            .with_context(|| format!("connect {}", path.display()))?;
        let (rd, mut wr) = crate::local_stream::split(stream);
        let (out, mut out_rx) = mpsc::channel::<String>(1024);
        let (notif_tx, notif_rx) = mpsc::channel::<Message>(4096);
        let notif_tx = Arc::new(Mutex::new(notif_tx));
        let closed = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let pending: Arc<Mutex<HashMap<String, oneshot::Sender<Result<Value, RpcError>>>>> =
            Arc::new(Mutex::new(HashMap::new()));
        tokio::spawn(async move {
            while let Some(line) = out_rx.recv().await {
                if wr.write_all(line.as_bytes()).await.is_err() {
                    break;
                }
            }
        });
        {
            let pending = pending.clone();
            let notif_tx = notif_tx.clone();
            let closed = closed.clone();
            tokio::spawn(async move {
                let mut lines = BufReader::new(rd).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let Ok(msg) = Message::parse(&line) else { continue };
                    match msg {
                        Message::Response { id, result, error } => {
                            if let Some(tx) = pending.lock().await.remove(&id.to_string()) {
                                let _ = tx.send(match error {
                                    Some(e) => Err(e),
                                    None => Ok(result.unwrap_or(Value::Null)),
                                });
                            }
                        }
                        other => {
                            // Whoever holds the current receiver gets it; a
                            // dropped receiver just loses notifications and
                            // never kills the connection. A full queue drops
                            // the notification rather than stall responses.
                            let tx = notif_tx.lock().await.clone();
                            if let Err(mpsc::error::TrySendError::Full(_)) = tx.try_send(other) {
                                tracing::debug!("notification queue full; dropping a notification");
                            }
                        }
                    }
                }
                closed.store(true, Ordering::SeqCst);
                let mut p = pending.lock().await;
                for (_, tx) in p.drain() {
                    let _ = tx.send(Err(RpcError::internal("daemon connection closed")));
                }
                drop(p);
                // The stream never ends on its own (the client keeps a
                // sender), so say goodbye explicitly.
                let tx = notif_tx.lock().await.clone();
                let _ = tx.send(Message::notification(method::MUX_DISCONNECTED, json!({}))).await;
            });
        }
        let client = Arc::new(Self {
            daemon_build: std::sync::Mutex::new(None),
            daemon_features: std::sync::Mutex::new(Vec::new()),
            person_challenge: std::sync::Mutex::new(None),
            out,
            next_id: AtomicI64::new(1),
            pending,
            notifications: Mutex::new(Some(notif_rx)),
            notif_tx,
            closed,
        });
        let mut hello = json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "acpmux-cli", "version": crate::hub::VERSION}});
        // Inside an acpmux session: say which, with the caller token the
        // daemon put in that session's env (`hub/person.rs` (a)), only to
        // the socket of the daemon that issued it (never to another daemon,
        // or whatever listens on a path the agent pointed the CLI at).
        let caller = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
        let issuer = caller(crate::hub::person::CALLER_SOCKET_ENV);
        if let (Some(id), Some(token), true) = (
            caller("ACPMUX_SESSION_ID"),
            caller(crate::hub::person::CALLER_TOKEN_ENV),
            issuer.is_some_and(|socket| Path::new(&socket) == path),
        ) {
            let mut meta = serde_json::Map::new();
            meta.insert(
                crate::hub::person::CALLER_FIELD.to_owned(),
                json!({"sessionId": id, "token": token}),
            );
            hello.set("_meta", json!({"acpmux": meta}));
        }
        let init = client.request(method::INITIALIZE, hello).await?;
        *client.daemon_build.lock_or_recover() =
            init.pointer("/_meta/acpmux/build").and_then(Value::as_str).map(str::to_owned);
        if let Some(Value::Array(features)) = init.pointer("/_meta/acpmux/features") {
            *client.daemon_features.lock_or_recover() =
                features.iter().filter_map(Value::as_str).map(str::to_owned).collect();
        }
        if let (Some(n), Some(c)) = (
            init.pointer("/_meta/acpmux/personChallenge/nonce").and_then(Value::as_str),
            init.pointer("/_meta/acpmux/personChallenge/connection").and_then(Value::as_str),
        ) {
            *client.person_challenge.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
                Some((n.to_owned(), c.to_owned()));
        }
        Ok(client)
    }

    /// Proves this connection is the person (`_acpmux/person_prove`) with the
    /// key the daemon was started with; must be the request right after
    /// initialize. True when the daemon accepted the proof.
    pub async fn prove_person(&self, key: &str) -> bool {
        let challenge =
            self.person_challenge.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone();
        let Some((nonce, connection)) = challenge else { return false };
        let Some(proof) = crate::hub::person::person_proof(key, "unix", &nonce, &connection) else {
            return false;
        };
        self.request(method::MUX_PERSON_PROVE, json!({ "proof": proof })).await.is_ok()
    }

    /// The daemon's build id, as reported at initialize.
    pub fn daemon_build(&self) -> Option<String> {
        self.daemon_build.lock_or_recover().clone()
    }

    /// Whether the daemon listed `feature` at initialize.
    pub fn daemon_lists(&self, feature: &str) -> bool {
        self.daemon_features.lock_or_recover().iter().any(|f| f == feature)
    }

    /// The error for a connection that ended: says why, as far as the pid
    /// file and socket tell, and what to do.
    pub fn closed(&self, context: &str) -> anyhow::Error {
        closed_error(context, self.daemon_build().as_deref())
    }

    /// True once the daemon has closed this connection.
    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }

    /// Take the notification stream. The first call gets the original
    /// receiver; later calls get a fresh one and the previous holder stops
    /// receiving, so one command can stream several turns in sequence.
    pub async fn notifications(&self) -> Option<mpsc::Receiver<Message>> {
        if let Some(rx) = self.notifications.lock().await.take() {
            return Some(rx);
        }
        let (tx, rx) = mpsc::channel::<Message>(4096);
        *self.notif_tx.lock().await = tx;
        Some(rx)
    }

    pub async fn request(&self, m: &str, params: Value) -> Result<Value> {
        if m != method::SESSION_NEW {
            return self.send_request(m, params).await;
        }
        let tool_call = std::env::var(crate::hub::lineage::TOOL_CALL_ENV).ok();
        let reply = self.send_request(m, with_spawn_tool_call(params, tool_call)).await?;
        self.tag_spawned_by(&reply).await;
        Ok(reply)
    }

    /// A `session/new` that is never its caller's child: an ephemeral run (`acpmux run
    /// --ephemeral`, an agent's probe, `probe_prompt.rs`) is no subagent.
    pub async fn request_parentless(&self, m: &str, mut params: Value) -> Result<Value> {
        if m == method::SESSION_NEW {
            params = parentless(params);
        }
        self.send_request(m, params).await
    }

    /// A `session/new` sent from inside an acpmux session (its agent runs `acpmux new`,
    /// `acpmux run`) to a daemon that records no lineage (`hub/lineage.rs`): an older daemon,
    /// or a session on a peer (a family lives on one daemon). Tags the new session with that
    /// one (`hub::views::SPAWNED_BY_TAG`), so the chat lists still fold it under its parent.
    /// A daemon that records lineage decides alone: its root (`parent: null`, a caller it could
    /// not prove) is never tagged from this env var. The session exists either way; a failed
    /// tag only lists it on its own.
    async fn tag_spawned_by(&self, reply: &Value) {
        let Some(parent) = std::env::var("ACPMUX_SESSION_ID").ok().filter(|id| !id.is_empty())
        else {
            return;
        };
        if !reply_lacks_lineage(reply) {
            return;
        }
        let Some(id) = reply.get("sessionId").and_then(Value::as_str) else { return };
        let set = json!({ crate::hub::views::SPAWNED_BY_TAG: parent });
        let _ = self.send_request(method::MUX_TAG, json!({"sessionId": id, "set": set})).await;
    }

    async fn send_request(&self, m: &str, params: Value) -> Result<Value> {
        let context = format!("sending {m}");
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let key = Value::from(id).to_string();
        let (tx, rx) = oneshot::channel();
        {
            // Check and register under the lock the reader drains with after
            // it marks the connection closed, so no request slips between.
            let mut pending = self.pending.lock().await;
            if self.closed.load(Ordering::SeqCst) {
                return Err(self.closed(&context));
            }
            pending.insert(key.clone(), tx);
        }
        if self.out.send(Message::request(id, m, params).to_line()).await.is_err() {
            self.pending.lock().await.remove(&key);
            return Err(self.closed(&context));
        }
        match rx.await {
            Ok(Ok(v)) => Ok(v),
            Ok(Err(e)) if e.message == "daemon connection closed" => {
                Err(self.closed(&format!("waiting for the reply to {m}")))
            }
            Ok(Err(e)) => Err(DaemonError(e).into()),
            Err(_) => Err(self.closed(&format!("waiting for the reply to {m}"))),
        }
    }

    pub async fn notify(&self, m: &str, params: Value) -> Result<()> {
        self.out
            .send(Message::notification(m, params).to_line())
            .await
            .map_err(|_| self.closed(&format!("sending {m}")))
    }
}

/// `session/new` params that name the caller's tool call running it (`ACPMUX_TOOL_CALL_ID`,
/// when a harness exports it), unless they name one already.
fn with_spawn_tool_call(mut params: Value, tool_call: Option<String>) -> Value {
    let Some(id) = tool_call.filter(|id| !id.is_empty()) else { return params };
    if let Some(mux) = mux_meta(&mut params) {
        mux.entry(crate::hub::lineage::TOOL_CALL_FIELD).or_insert(Value::String(id));
    }
    params
}

/// `session/new` params that ask for no parent (`_meta.acpmux.parent: null`).
fn parentless(mut params: Value) -> Value {
    if let Some(mux) = mux_meta(&mut params) {
        mux.insert(crate::hub::lineage::PARENT_FIELD.into(), Value::Null);
    }
    params
}

/// `_meta.acpmux` of a request's params, made when missing; None when they are no object.
fn mux_meta(params: &mut Value) -> Option<&mut serde_json::Map<String, Value>> {
    let meta = params.as_object_mut()?.entry("_meta").or_insert_with(|| json!({}));
    meta.as_object_mut()?.entry("acpmux").or_insert_with(|| json!({})).as_object_mut()
}

/// Whether a `session/new` reply comes from a daemon that records no lineage: a session on a
/// peer, or an older daemon (its summary has no `parent` field). A `parent` that is null is
/// this daemon's root, never one to tag.
fn reply_lacks_lineage(reply: &Value) -> bool {
    reply.get("peer").is_some()
        || !reply
            .pointer("/_meta/acpmux")
            .and_then(Value::as_object)
            .is_some_and(|m| m.contains_key(crate::hub::lineage::PARENT_FIELD))
}

/// An error reply from the daemon. It prints as the message alone and
/// keeps the JSON-RPC code, so callers can tell invalid params (-32602)
/// from internal errors.
#[derive(Debug)]
pub struct DaemonError(pub RpcError);

impl std::fmt::Display for DaemonError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0.message)
    }
}

impl std::error::Error for DaemonError {}

/// "daemon connection closed" with a cause: the pid file and socket say
/// whether the daemon is still running (it dropped us: a restart or an
/// internal error), died without cleanup (a crash), or was shut down.
pub fn closed_error(context: &str, daemon_build: Option<&str>) -> anyhow::Error {
    use std::io::Read as _;

    let home = crate::config::home();
    let pid_path = home.join("daemon.pid");
    let pid = crate::config::private_state_file(&pid_path)
        .and_then(|mut file| {
            let mut text = String::new();
            file.read_to_string(&mut text)?;
            Ok(text)
        })
        .ok()
        .and_then(|s| s.trim().parse::<i32>().ok());
    #[cfg(unix)]
    let alive = pid.map(|p| unsafe { libc::kill(p, 0) } == 0).unwrap_or(false);
    #[cfg(not(unix))]
    let alive = pid.is_some();
    let socket = crate::config::socket_path().exists();
    let why = match (pid, alive, socket) {
        (Some(p), true, _) => format!(
            "the daemon (pid {p}) is still running but dropped this connection, usually because it was restarted (`acpmux daemon shutdown`, `acpmux host update`, a reinstall) or hit an internal error"
        ),
        (Some(p), false, _) => {
            format!("the daemon (pid {p}) exited without cleaning up, most likely a crash")
        }
        (None, _, true) => "the daemon stopped and left its socket behind".to_owned(),
        (None, _, false) => "the daemon was shut down".to_owned(),
    };
    let build = match daemon_build {
        Some(b) if b != crate::hub::BUILD => {
            format!(" It ran build {b}; this command is build {}.", crate::hub::BUILD)
        }
        _ => String::new(),
    };
    anyhow!(
        "daemon connection closed while {context}: {why}.{build} The next acpmux command starts a daemon; its log is {}",
        home.join("daemon.log").display()
    )
}

#[cfg(test)]
mod lineage_tests {
    use super::*;

    #[test]
    fn a_session_new_names_the_env_tool_call_once() {
        let p = json!({"cwd": "/tmp", "_meta": {"acpmux": {"name": "kid"}}});
        let sent = with_spawn_tool_call(p.clone(), Some("toolu_7".into()));
        assert_eq!(sent["_meta"]["acpmux"]["spawnToolCallId"], "toolu_7");
        assert_eq!(sent["_meta"]["acpmux"]["name"], "kid");
        assert_eq!(with_spawn_tool_call(p.clone(), None), p);
        assert_eq!(with_spawn_tool_call(p.clone(), Some(String::new())), p);
        let named = json!({"_meta": {"acpmux": {"spawnToolCallId": "mine"}}});
        let sent = with_spawn_tool_call(named, Some("env".into()));
        assert_eq!(sent["_meta"]["acpmux"]["spawnToolCallId"], "mine");
        let bare = with_spawn_tool_call(json!({"cwd": "/tmp"}), Some("t".into()));
        assert_eq!(bare["_meta"]["acpmux"]["spawnToolCallId"], "t");
    }

    #[test]
    fn a_parentless_session_new_asks_for_no_parent() {
        let sent = parentless(json!({"cwd": "/tmp", "_meta": {"acpmux": {"ephemeral": true}}}));
        assert_eq!(sent["_meta"]["acpmux"]["parent"], Value::Null);
        assert!(sent["_meta"]["acpmux"].as_object().unwrap().contains_key("parent"));
        assert_eq!(sent["_meta"]["acpmux"]["ephemeral"], true);
    }

    /// The tag request goes only to a daemon that records no lineage: the CLI path of a
    /// proven caller makes none, and a root the daemon made (an unproven caller) is never
    /// tagged under the env's session.
    #[test]
    fn only_a_daemon_without_lineage_gets_the_spawned_by_tag() {
        let recorded = json!({"sessionId": "c", "_meta": {"acpmux": {"parent": "p"}}});
        assert!(!reply_lacks_lineage(&recorded));
        let root = json!({"sessionId": "c", "_meta": {"acpmux": {"parent": null}}});
        assert!(!reply_lacks_lineage(&root), "a new daemon's root is final");
        let older_daemon = json!({"sessionId": "c", "_meta": {"acpmux": {"name": "c"}}});
        assert!(reply_lacks_lineage(&older_daemon));
        assert!(reply_lacks_lineage(&json!({"sessionId": "c"})));
        let on_a_peer =
            json!({"sessionId": "c", "peer": "box", "_meta": {"acpmux": {"parent": null}}});
        assert!(reply_lacks_lineage(&on_a_peer));
    }
}
