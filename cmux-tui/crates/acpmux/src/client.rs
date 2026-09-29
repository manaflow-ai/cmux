//! Client library used by the CLI and TUI: connect to the daemon socket,
//! send requests, and receive notifications.

use crate::rpc::{Message, RpcError, method};
use anyhow::{Context, Result, anyhow};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::{Mutex, mpsc, oneshot};

pub struct Client {
    /// Build id the daemon reported at initialize, for mismatch hints.
    daemon_build: std::sync::Mutex<Option<String>>,
    out: mpsc::Sender<String>,
    next_id: AtomicI64,
    pending: Arc<Mutex<HashMap<String, oneshot::Sender<Result<Value, RpcError>>>>>,
    notifications: Mutex<Option<mpsc::Receiver<Message>>>,
    notif_tx: Arc<Mutex<mpsc::Sender<Message>>>,
    closed: Arc<std::sync::atomic::AtomicBool>,
}

impl Client {
    pub async fn connect(path: &Path) -> Result<Arc<Self>> {
        let stream = UnixStream::connect(path)
            .await
            .with_context(|| format!("connect {}", path.display()))?;
        let (rd, mut wr) = stream.into_split();
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
                            // never kills the connection.
                            let tx = notif_tx.lock().await.clone();
                            let _ = tx.send(other).await;
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
            out,
            next_id: AtomicI64::new(1),
            pending,
            notifications: Mutex::new(Some(notif_rx)),
            notif_tx,
            closed,
        });
        let init = client
            .request(
                method::INITIALIZE,
                json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "acpmux-cli", "version": crate::hub::VERSION}}),
            )
            .await?;
        *client.daemon_build.lock().unwrap() = init.pointer("/_meta/acpmux/build").and_then(Value::as_str).map(str::to_owned);
        Ok(client)
    }

    /// The daemon's build id, as reported at initialize.
    pub fn daemon_build(&self) -> Option<String> {
        self.daemon_build.lock().unwrap().clone()
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
        let context = format!("sending {m}");
        if self.closed.load(Ordering::SeqCst) {
            return Err(self.closed(&context));
        }
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(Value::from(id).to_string(), tx);
        self.out
            .send(Message::request(id, m, params).to_line())
            .await
            .map_err(|_| self.closed(&context))?;
        match rx.await {
            Ok(Ok(v)) => Ok(v),
            Ok(Err(e)) if e.message == "daemon connection closed" => Err(self.closed(&format!("waiting for the reply to {m}"))),
            Ok(Err(e)) => Err(anyhow!("{}", e.message)),
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

/// "daemon connection closed" with a cause: the pid file and socket say
/// whether the daemon is still running (it dropped us: a restart or an
/// internal error), died without cleanup (a crash), or was shut down.
pub fn closed_error(context: &str, daemon_build: Option<&str>) -> anyhow::Error {
    let home = crate::config::home();
    let pid = std::fs::read_to_string(home.join("daemon.pid")).ok().and_then(|s| s.trim().parse::<i32>().ok());
    #[cfg(unix)]
    let alive = pid.map(|p| unsafe { libc::kill(p, 0) } == 0).unwrap_or(false);
    #[cfg(not(unix))]
    let alive = pid.is_some();
    let socket = crate::config::socket_path().exists();
    let why = match (pid, alive, socket) {
        (Some(p), true, _) => format!("the daemon (pid {p}) is still running but dropped this connection, usually because it was restarted (`acpmux daemon shutdown`, `acpmux host update`, a reinstall) or hit an internal error"),
        (Some(p), false, _) => format!("the daemon (pid {p}) exited without cleaning up, most likely a crash"),
        (None, _, true) => "the daemon stopped and left its socket behind".to_owned(),
        (None, _, false) => "the daemon was shut down".to_owned(),
    };
    let build = match daemon_build {
        Some(b) if b != crate::hub::BUILD => format!(" It ran build {b}; this command is build {}.", crate::hub::BUILD),
        _ => String::new(),
    };
    anyhow!("daemon connection closed while {context}: {why}.{build} The next acpmux command starts a daemon; its log is {}", home.join("daemon.log").display())
}
