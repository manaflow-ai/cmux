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
            });
        }
        let client = Arc::new(Self {
            out,
            next_id: AtomicI64::new(1),
            pending,
            notifications: Mutex::new(Some(notif_rx)),
            notif_tx,
            closed,
        });
        client
            .request(
                method::INITIALIZE,
                json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "acpmux-cli", "version": crate::hub::VERSION}}),
            )
            .await?;
        Ok(client)
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
        if self.closed.load(Ordering::SeqCst) {
            return Err(anyhow!("daemon connection closed"));
        }
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(Value::from(id).to_string(), tx);
        self.out
            .send(Message::request(id, m, params).to_line())
            .await
            .map_err(|_| anyhow!("daemon connection closed"))?;
        match rx.await {
            Ok(Ok(v)) => Ok(v),
            Ok(Err(e)) => Err(anyhow!("{}", e.message)),
            Err(_) => Err(anyhow!("daemon connection closed")),
        }
    }

    pub async fn notify(&self, m: &str, params: Value) -> Result<()> {
        self.out
            .send(Message::notification(m, params).to_line())
            .await
            .map_err(|_| anyhow!("daemon connection closed"))
    }
}
