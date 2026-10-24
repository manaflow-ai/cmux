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
        let reply = self.send_request(m, params).await?;
        if m == method::SESSION_NEW {
            self.tag_spawned_by(&reply).await;
        }
        Ok(reply)
    }

    /// A `session/new` that never tags its caller's session as the parent: an ephemeral run
    /// (`acpmux run --ephemeral`, an agent's probe, `probe_prompt.rs`) is no subagent.
    pub async fn request_parentless(&self, m: &str, params: Value) -> Result<Value> {
        self.send_request(m, params).await
    }

    /// A `session/new` sent from inside an acpmux session (its agent runs `acpmux new`,
    /// `acpmux run`): tags the new session with that one (`hub::views::SPAWNED_BY_TAG`), so the chat
    /// lists fold it under its parent. The session exists either way; a failed tag only lists
    /// it on its own.
    async fn tag_spawned_by(&self, reply: &Value) {
        let Some(parent) = std::env::var("ACPMUX_SESSION_ID").ok().filter(|id| !id.is_empty())
        else {
            return;
        };
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
