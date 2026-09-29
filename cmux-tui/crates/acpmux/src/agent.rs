//! A child ACP agent process. acpmux is the client on this connection.
//!
//! Every line in either direction is reported through the `tap` callback so
//! the session log holds the raw wire traffic.

use crate::config::HarnessProfile;
use crate::rpc::{Id, Message, RpcError};
use anyhow::{Context, Result, anyhow};
use serde_json::Value;
use std::collections::HashMap;
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{Mutex, mpsc, oneshot};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    /// acpmux -> agent (stdin)
    Out,
    /// agent -> acpmux (stdout)
    In,
}

/// Something the agent sent that acpmux must act on.
#[derive(Debug)]
pub enum Inbound {
    Request {
        id: Id,
        method: String,
        params: Option<Value>,
    },
    Notification {
        method: String,
        params: Option<Value>,
    },
    Stderr(String),
    Exited(Option<i32>),
}

pub type Tap = Arc<dyn Fn(Direction, &Message) + Send + Sync>;

struct Pending {
    map: HashMap<String, oneshot::Sender<Result<Value, RpcError>>>,
}

fn key(id: &Id) -> String {
    id.to_string()
}

pub struct ChildAgent {
    pub name: String,
    child: Mutex<Option<Child>>,
    stdin_tx: mpsc::Sender<String>,
    next_id: AtomicI64,
    pending: Arc<Mutex<Pending>>,
    tap: Tap,
    pub pid: Option<u32>,
    /// Present when the child speaks Claude's stream-json instead of ACP.
    pub translator: Option<Arc<crate::claude_stdio::Translator>>,
}

impl ChildAgent {
    /// Spawn the agent and start its reader loop. Inbound requests and
    /// notifications are delivered on `inbound`.
    pub async fn spawn(
        name: &str,
        profile: &HarnessProfile,
        cwd: &std::path::Path,
        inbound: mpsc::Sender<Inbound>,
        tap: Tap,
    ) -> Result<Arc<Self>> {
        Self::spawn_with(name, profile, cwd, inbound, tap, None, None, None).await
    }

    /// Spawn with an explicit command line (used by the Claude stdio backend,
    /// which builds its own argv) and an optional translator.
    pub async fn spawn_with(
        name: &str,
        profile: &HarnessProfile,
        cwd: &std::path::Path,
        inbound: mpsc::Sender<Inbound>,
        tap: Tap,
        command_line: Option<(String, Vec<String>)>,
        translator: Option<Arc<crate::claude_stdio::Translator>>,
        // (session id, session name): exported to the agent as ACPMUX_* so
        // it can drive its own session and siblings through the CLI.
        session: Option<(&str, &str)>,
    ) -> Result<Arc<Self>> {
        let owned: (String, Vec<String>) = match command_line {
            Some(c) => c,
            None => {
                let (program, args) = profile
                    .argv
                    .split_first()
                    .ok_or_else(|| anyhow!("agent {name} has an empty argv"))?;
                (program.clone(), args.to_vec())
            }
        };
        let (program, args) = (&owned.0, &owned.1);
        let mut cmd = Command::new(program);
        crate::config::scrub_nested_claude_env_tokio(&mut cmd);
        // Caller context, herdr-style: the agent knows which session it is.
        for (k, _) in std::env::vars_os() {
            if k.to_string_lossy().starts_with("ACPMUX_") {
                cmd.env_remove(&k);
            }
        }
        // A nested launch must not be taken for its parent's thread.
        cmd.env_remove("CODEX_THREAD_ID").env_remove("OMPCODE");
        if let Some((id, sname)) = session {
            cmd.env("ACPMUX_ENV", "1")
                .env("ACPMUX_SESSION_ID", id)
                .env("ACPMUX_SESSION_NAME", sname)
                .env("ACPMUX_SOCKET", crate::config::socket_path());
        }
        cmd.args(args)
            .envs(profile.env.iter())
            // Claude refuses to nest inside another Claude session.
            .env_remove("CLAUDECODE")
            .env_remove("CLAUDE_CODE_ENTRYPOINT")
            .current_dir(cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            // Own process group, so stopping the session stops everything the
            // agent started underneath it (background shells included).
            .process_group(0)
            .kill_on_drop(true);
        let mut child = cmd
            .spawn()
            .with_context(|| format!("spawn agent {name}: {}", profile.argv.join(" ")))?;
        let pid = child.id();
        let stdin = child.stdin.take().context("agent stdin")?;
        let stdout = child.stdout.take().context("agent stdout")?;
        let stderr = child.stderr.take().context("agent stderr")?;

        let (stdin_tx, mut stdin_rx) = mpsc::channel::<String>(256);
        let pending = Arc::new(Mutex::new(Pending {
            map: HashMap::new(),
        }));
        let agent = Arc::new(Self {
            name: name.to_owned(),
            child: Mutex::new(Some(child)),
            stdin_tx,
            next_id: AtomicI64::new(1),
            pending: pending.clone(),
            tap: tap.clone(),
            pid,
            translator: translator.clone(),
        });

        // Writer task.
        tokio::spawn(async move {
            let mut stdin = stdin;
            while let Some(line) = stdin_rx.recv().await {
                if stdin.write_all(line.as_bytes()).await.is_err() {
                    break;
                }
                if stdin.flush().await.is_err() {
                    break;
                }
            }
        });

        // Stderr task.
        {
            let inbound = inbound.clone();
            tokio::spawn(async move {
                let mut lines = BufReader::new(stderr).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let _ = inbound.send(Inbound::Stderr(line)).await;
                }
            });
        }

        // Reader task.
        {
            let inbound = inbound.clone();
            let pending = pending.clone();
            let tap = tap.clone();
            let agent_for_exit = agent.clone();
            tokio::spawn(async move {
                let mut lines = BufReader::new(stdout).lines();
                loop {
                    let line = match lines.next_line().await {
                        Ok(Some(l)) => l,
                        _ => break,
                    };
                    if line.trim().is_empty() {
                        continue;
                    }
                    let msgs: Vec<Message> = if let Some(tr) = &agent_for_exit.translator {
                        let raw: Value = match serde_json::from_str(&line) {
                            Ok(v) => v,
                            Err(_) => {
                                let _ = inbound.send(Inbound::Stderr(format!("[non-json stdout] {line}"))).await;
                                continue;
                            }
                        };
                        // Keep the raw claude line in the log under its own kind.
                        let kind = format!(
                            "claude.{}{}",
                            raw.get("type").and_then(Value::as_str).unwrap_or("?"),
                            raw.get("subtype").and_then(Value::as_str).map(|s| format!(".{s}")).unwrap_or_default()
                        );
                        tap(Direction::In, &Message::notification(&kind, raw.clone()));
                        let translated = tr.inbound(&raw).await;
                        // Translated ACP messages go through the same tap as
                        // native ACP traffic, so the log and viewers see them.
                        for m in &translated {
                            if !matches!(m, Message::Response { .. }) {
                                tap(Direction::In, m);
                            }
                        }
                        translated
                    } else {
                        match Message::parse(&line) {
                            Ok(m) => {
                                tap(Direction::In, &m);
                                vec![m]
                            }
                            Err(e) => {
                                tracing::warn!(agent = %agent_for_exit.name, "bad line from agent: {e}: {line}");
                                let _ = inbound.send(Inbound::Stderr(format!("[non-json stdout] {line}"))).await;
                                continue;
                            }
                        }
                    };
                    for msg in msgs {
                    match msg {
                        Message::Response { id, result, error } => {
                            let tx = pending.lock().await.map.remove(&key(&id));
                            if let Some(tx) = tx {
                                let _ = tx.send(match error {
                                    Some(e) => Err(e),
                                    None => Ok(result.unwrap_or(Value::Null)),
                                });
                            }
                        }
                        Message::Request { id, method, params } => {
                            let _ = inbound.send(Inbound::Request { id, method, params }).await;
                        }
                        Message::Notification { method, params } => {
                            let _ = inbound.send(Inbound::Notification { method, params }).await;
                        }
                    }
                    }
                }
                // Fail every pending request, then report exit.
                let mut p = pending.lock().await;
                for (_, tx) in p.map.drain() {
                    let _ = tx.send(Err(RpcError::internal("agent process closed")));
                }
                drop(p);
                let code = agent_for_exit.wait_exit().await;
                let _ = inbound.send(Inbound::Exited(code)).await;
            });
        }
        Ok(agent)
    }

    async fn wait_exit(&self) -> Option<i32> {
        let mut guard = self.child.lock().await;
        if let Some(child) = guard.as_mut() {
            let status = tokio::time::timeout(std::time::Duration::from_secs(5), child.wait())
                .await
                .ok()
                .and_then(|r| r.ok());
            if let Some(s) = status {
                *guard = None;
                return s.code();
            }
            let _ = child.kill().await;
            *guard = None;
        }
        None
    }

    pub async fn kill(&self) {
        let mut guard = self.child.lock().await;
        if let Some(child) = guard.as_mut() {
            if let Some(pid) = child.id() {
                // TERM the whole group first so children get a chance to exit,
                // then KILL whatever is left.
                unsafe {
                    libc::killpg(pid as i32, libc::SIGTERM);
                }
                tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                unsafe {
                    libc::killpg(pid as i32, libc::SIGKILL);
                }
            }
            let _ = child.kill().await;
        }
        *guard = None;
    }

    pub async fn is_alive(&self) -> bool {
        let mut guard = self.child.lock().await;
        match guard.as_mut() {
            Some(child) => matches!(child.try_wait(), Ok(None)),
            None => false,
        }
    }

    async fn write(&self, msg: &Message) -> Result<()> {
        (self.tap)(Direction::Out, msg);
        if let Some(tr) = &self.translator {
            match tr.outbound(msg).await {
                crate::claude_stdio::Outbound::Lines(lines) => {
                    for l in lines {
                        (self.tap)(Direction::Out, &Message::notification("claude.stdin", l.clone()));
                        let mut s = l.to_string();
                        s.push('\n');
                        self.stdin_tx.send(s).await.map_err(|_| anyhow!("agent {} stdin closed", self.name))?;
                    }
                    Ok(())
                }
                crate::claude_stdio::Outbound::Reply(reply) => {
                    // Immediate local answer: feed it back as if claude replied.
                    if let Message::Response { id, result, error } = reply
                        && let Some(tx) = self.pending.lock().await.map.remove(&key(&id)) {
                            let _ = tx.send(match error {
                                Some(e) => Err(e),
                                None => Ok(result.unwrap_or(Value::Null)),
                            });
                        }
                    Ok(())
                }
            }
        } else {
            self.stdin_tx
                .send(msg.to_line())
                .await
                .map_err(|_| anyhow!("agent {} stdin closed", self.name))
        }
    }

    /// Send a request and wait for its response.
    pub async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        self.pending
            .lock()
            .await
            .map
            .insert(key(&Value::from(id)), tx);
        let msg = Message::request(id, method, params);
        if let Err(e) = self.write(&msg).await {
            self.pending.lock().await.map.remove(&key(&Value::from(id)));
            return Err(RpcError::internal(e.to_string()));
        }
        rx.await
            .unwrap_or_else(|_| Err(RpcError::internal("agent response channel dropped")))
    }

    pub async fn notify(&self, method: &str, params: Value) -> Result<()> {
        self.write(&Message::notification(method, params)).await
    }

    /// Answer a request the agent sent to us.
    pub async fn respond(&self, id: Id, result: Result<Value, RpcError>) -> Result<()> {
        let msg = match result {
            Ok(v) => Message::ok(id, v),
            Err(e) => Message::err(id, e),
        };
        self.write(&msg).await
    }
}
