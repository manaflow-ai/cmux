//! Codex threads acpmux did not start, reached the way Codex's own clients reach each other
//! (Leo 2026-11-09: "if cmux-next could be the bridge between claude desktop and codex desktop,
//! that'd be super cool. we should keep going further into the whole messaging system type
//! situation").
//!
//! The Codex desktop app runs its threads on a Codex app-server. What Codex records of them, and
//! what acpmux reads (nothing here is typed by a sender):
//! - `<CODEX_HOME>/thread-writer-locks/<id>.lock`: an exclusive `flock` the app-server holds while
//!   the thread is open, removed when it closes (`adopt_live.rs` probes it). A held lock is a
//!   live thread.
//! - `threads` in `<CODEX_HOME>/state_<n>.sqlite`: its `originator` is the client that started
//!   the thread (the `clientInfo.name` of its app-server connection), `codex_desktop` for the
//!   desktop app; also its folder, name and title (`cmux_chat_index::codex_thread_rows`).
//! - The environment Codex gives every command a thread runs: `CODEX_THREAD_ID` names the thread.
//!
//! Delivery is the app-server's own queue (`codex queue --thread <id> --message <text>` makes the
//! same call): `thread/queue/add` with the thread id, a `clientUserMessageId` and the text, sent
//! over the shared daemon's control socket (`<CODEX_HOME>/app-server-control/app-server-control.sock`,
//! JSON-RPC in WebSocket text frames). The queue lives in `queue_<n>.sqlite`, which every
//! app-server of the home reads, so the process that runs the thread (the daemon, or the
//! desktop app's own app-server) takes the message as its next turn, at once while the thread is
//! idle. With no daemon listening, a `codex app-server` over stdio is started for the one call,
//! as `codex queue` does in process.
//!
//! Sender binding (`hub/desktop_bridge.rs`): a send whose socket-peer ancestry runs under a
//! process Codex started for a thread is that thread's. The kernel reports the peer pid and each
//! parent; of them, the first process whose environment (`/proc/<pid>/environ`, macOS
//! `KERN_PROCARGS2`: what its exec was given) names a thread and whose parent is a `codex` binary
//! that names none is the one Codex spawned for the thread (`thread_in`). A process that sets
//! the variable itself has a parent that is no Codex, or one that names another thread: it
//! binds to nothing new. The environment is chosen over the writer lock's holder because one
//! app-server holds the locks of every thread it runs (the pid alone names no thread), and no
//! lock holder can be read on macOS.
//!
//! Off unless `agents.desktopBridge.enabled` is true and `agents.desktopBridge.entrypoints` lists
//! `codex_desktop` (`claude_peers.rs`).

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The originator Codex records for a thread the Codex desktop app started.
pub const DESKTOP_ORIGINATOR: &str = "codex_desktop";
/// The variable Codex sets in the environment of every command a thread runs.
pub const THREAD_ENV: &str = "CODEX_THREAD_ID";

/// Longest a delivery over the daemon's control socket takes, connecting included.
const SOCKET_TIMEOUT: Duration = Duration::from_secs(10);
/// Longest a delivery through a `codex app-server` started for it takes, its start included.
const SPAWNED_TIMEOUT: Duration = Duration::from_secs(30);
/// Most messages read while waiting for one answer (the server's notifications come between).
const MAX_MESSAGES: usize = 1_000;

/// One live Codex thread, as Codex recorded it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Thread {
    pub id: String,
    pub originator: String,
    pub cwd: Option<PathBuf>,
    pub name: Option<String>,
    pub title: Option<String>,
    pub version: Option<String>,
}

/// The folder of the writer locks of the Codex home `home`.
pub fn lock_dir(home: &Path) -> PathBuf {
    home.join("thread-writer-locks")
}

/// The control socket of the home's shared app-server daemon.
pub fn control_socket(home: &Path) -> PathBuf {
    home.join("app-server-control").join("app-server-control.sock")
}

/// Whether `id` can be a Codex thread id (a UUID's characters): only such a lock file name is
/// read as one.
fn is_thread_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
}

/// The ids of the threads whose writer lock a running Codex holds now.
fn held(home: &Path) -> Vec<String> {
    let Ok(dir) = std::fs::read_dir(lock_dir(home)) else { return Vec::new() };
    dir.flatten()
        .filter_map(|e| e.file_name().to_str()?.strip_suffix(".lock").map(str::to_owned))
        .filter(|id| is_thread_id(id))
        .filter(|id| crate::adopt_live::holder("codex", id, home).is_some())
        .collect()
}

/// The threads of `ids` whose row names an originator of `listed`, not archived.
fn rows(home: &Path, ids: &[String], listed: &[String]) -> Vec<Thread> {
    cmux_chat_index::codex_thread_rows(home, ids)
        .into_iter()
        .filter(|r| !r.archived)
        .filter_map(|r| {
            let originator = r.originator.filter(|o| listed.contains(o))?;
            Some(Thread {
                id: r.id,
                originator,
                cwd: r.cwd.map(PathBuf::from),
                name: r.name,
                title: r.title,
                version: r.cli_version,
            })
        })
        .collect()
}

/// Every live thread of the home at `home` that a client of `listed` started. Only the threads
/// whose lock is held are looked up, so the cost follows the open threads, not the thousands a
/// home keeps.
pub fn live(home: &Path, listed: &[String]) -> Vec<Thread> {
    if !listed.iter().any(|l| l == DESKTOP_ORIGINATOR) {
        return Vec::new();
    }
    let ids = held(home);
    if ids.is_empty() {
        return Vec::new();
    }
    rows(home, &ids, listed)
}

/// Thread `id`, while a running Codex holds it and a client of `listed` started it.
pub fn find(home: &Path, id: &str, listed: &[String]) -> Option<Thread> {
    if !is_thread_id(id) || crate::adopt_live::holder("codex", id, home).is_none() {
        return None;
    }
    rows(home, &[id.to_owned()], listed).into_iter().next()
}

/// The thread whose Codex started a process of `ancestry` (the socket peer first, then each
/// parent): the first process whose environment names a thread (`env_thread`) and whose parent
/// is a Codex binary (`is_codex`) naming no thread or another one. Unreadable processes are passed.
pub fn thread_in(
    ancestry: &[u32],
    env_thread: impl Fn(u32) -> Option<String>,
    is_codex: impl Fn(u32) -> bool,
) -> Option<String> {
    ancestry.windows(2).find_map(|pair| {
        let [child, parent] = *pair else { return None };
        let id = env_thread(child)?;
        (env_thread(parent).as_deref() != Some(id.as_str()) && is_codex(parent)).then_some(id)
    })
}

/// [`thread_in`] over the processes the kernel reports.
#[cfg(unix)]
pub fn sender_thread(ancestry: &[u32]) -> Option<String> {
    let env_thread = |pid: u32| {
        crate::agent_host::tree::environ(pid)?
            .into_iter()
            .find(|(k, _)| k == THREAD_ENV)
            .map(|(_, v)| v)
            .filter(|v| is_thread_id(v))
    };
    let is_codex = |pid: u32| {
        crate::agent_host::tree::exe(pid)
            .and_then(|exe| exe.file_name().map(|n| n.to_string_lossy().into_owned()))
            .is_some_and(|name| is_codex_binary(&name))
    };
    thread_in(ancestry, env_thread, is_codex)
}

#[cfg(not(unix))]
pub fn sender_thread(_ancestry: &[u32]) -> Option<String> {
    None
}

/// A Codex executable's file name: `codex`, or a release build's `codex-<target>`.
fn is_codex_binary(name: &str) -> bool {
    name == "codex" || (name.starts_with("codex-") && !name.contains("sandbox"))
}

/// The `initialize` request a delivery opens with. The queue is an experimental call.
pub fn initialize(id: u64) -> Value {
    json!({"id": id, "method": "initialize", "params": {
        "clientInfo": {"name": "acpmux", "title": "acpmux", "version": env!("CARGO_PKG_VERSION")},
        "capabilities": {"experimentalApi": true},
    }})
}

/// The `thread/queue/add` request that queues `text` for `thread_id` as `client_id`.
pub fn queue_add(id: u64, thread_id: &str, text: &str, client_id: &str) -> Value {
    json!({"id": id, "method": "thread/queue/add", "params": {
        "threadId": thread_id,
        "clientUserMessageId": client_id,
        "input": [{"type": "text", "text": text, "text_elements": []}],
    }})
}

/// The result of request `id` among `msg`, or its error; `None` for anything else (a
/// notification, a request of the server's, another answer).
pub fn answer_to(id: u64, msg: &Value) -> Option<Result<Value, String>> {
    if msg.get("id").and_then(Value::as_u64) != Some(id) || msg.get("method").is_some() {
        return None;
    }
    Some(match msg.get("error") {
        Some(e) => Err(e
            .get("message")
            .and_then(Value::as_str)
            .map_or_else(|| e.to_string(), str::to_owned)),
        None => Ok(msg.get("result").cloned().unwrap_or(Value::Null)),
    })
}

/// One app-server connection: the daemon's control socket (WebSocket text frames), or a
/// `codex app-server` started for the call (a JSON line each way).
#[cfg(unix)]
enum Link {
    Socket(tokio_tungstenite::WebSocketStream<tokio::net::UnixStream>),
    Spawned {
        child: tokio::process::Child,
        stdin: Option<tokio::process::ChildStdin>,
        lines: tokio::io::Lines<tokio::io::BufReader<tokio::process::ChildStdout>>,
    },
}

#[cfg(unix)]
impl Link {
    async fn send(&mut self, msg: &Value) -> Result<(), String> {
        use futures_util::SinkExt;
        use tokio::io::AsyncWriteExt;
        let text = msg.to_string();
        match self {
            Link::Socket(ws) => ws
                .send(tokio_tungstenite::tungstenite::Message::Text(text.into()))
                .await
                .map_err(|e| format!("could not write to the Codex app-server: {e}")),
            Link::Spawned { stdin, .. } => {
                let stdin = stdin.as_mut().ok_or("the Codex app-server's input is closed")?;
                let line = format!("{text}\n");
                stdin
                    .write_all(line.as_bytes())
                    .await
                    .map_err(|e| format!("could not write to the Codex app-server: {e}"))
            }
        }
    }

    async fn recv(&mut self) -> Result<Value, String> {
        use futures_util::StreamExt;
        use tokio_tungstenite::tungstenite::Message;
        loop {
            let text = match self {
                Link::Socket(ws) => match ws.next().await {
                    Some(Ok(Message::Text(t))) => t.as_str().to_owned(),
                    Some(Ok(Message::Close(_))) | None => {
                        return Err("the Codex app-server closed the connection".into());
                    }
                    Some(Ok(_)) => continue,
                    Some(Err(e)) => return Err(format!("the Codex app-server connection: {e}")),
                },
                Link::Spawned { lines, .. } => match lines.next_line().await {
                    Ok(Some(line)) => line,
                    Ok(None) => return Err("the Codex app-server exited".into()),
                    Err(e) => return Err(format!("could not read the Codex app-server: {e}")),
                },
            };
            if let Ok(msg) = serde_json::from_str::<Value>(&text) {
                return Ok(msg);
            }
        }
    }

    async fn call(&mut self, msg: Value) -> Result<Value, String> {
        let id = msg.get("id").and_then(Value::as_u64).unwrap_or_default();
        self.send(&msg).await?;
        for _ in 0..MAX_MESSAGES {
            if let Some(answer) = answer_to(id, &self.recv().await?) {
                return answer;
            }
        }
        Err("the Codex app-server did not answer".into())
    }

    async fn close(self) {
        match self {
            Link::Socket(mut ws) => {
                let _ = ws.close(None).await;
            }
            Link::Spawned { mut child, stdin, .. } => {
                // Its input closed, the server exits; one that does not is ended.
                drop(stdin);
                let waited = tokio::time::timeout(Duration::from_secs(2), child.wait()).await;
                if waited.is_err() {
                    let _ = child.kill().await;
                }
            }
        }
    }
}

/// Queues `text` for thread `thread_id` of the home `home` as message `client_id`; the
/// queued submission's id on success.
#[cfg(unix)]
pub async fn deliver(
    home: &Path,
    thread_id: &str,
    text: &str,
    client_id: &str,
) -> Result<String, String> {
    let socket = control_socket(home);
    let daemon = socket.exists();
    let limit = if daemon { SOCKET_TIMEOUT } else { SPAWNED_TIMEOUT };
    let run = async {
        let mut link = if daemon { connect(&socket).await? } else { spawn(home)? };
        let result = queue(&mut link, thread_id, text, client_id).await;
        link.close().await;
        result
    };
    tokio::time::timeout(limit, run)
        .await
        .unwrap_or_else(|_| Err("the Codex app-server did not answer in time".into()))
}

#[cfg(unix)]
async fn queue(
    link: &mut Link,
    thread_id: &str,
    text: &str,
    client_id: &str,
) -> Result<String, String> {
    link.call(initialize(1)).await?;
    link.send(&json!({"method": "initialized"})).await?;
    let added = link.call(queue_add(2, thread_id, text, client_id)).await?;
    added
        .pointer("/queuedSubmission/id")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| format!("the Codex app-server queued nothing: {added}"))
}

#[cfg(unix)]
async fn connect(socket: &Path) -> Result<Link, String> {
    let stream = tokio::net::UnixStream::connect(socket).await.map_err(|e| {
        format!("could not reach the Codex app-server at {}: {e}", socket.display())
    })?;
    let (ws, _) = tokio_tungstenite::client_async("ws://localhost/", stream)
        .await
        .map_err(|e| format!("the Codex app-server at {} refused: {e}", socket.display()))?;
    Ok(Link::Socket(ws))
}

#[cfg(unix)]
fn spawn(home: &Path) -> Result<Link, String> {
    use std::process::Stdio;
    let program = crate::managed_codex::codex_binary()
        .ok_or("no Codex app-server daemon runs and no codex is installed to queue the message")?;
    let mut child = tokio::process::Command::new(program)
        .arg("app-server")
        .env("CODEX_HOME", home)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("could not start codex app-server: {e}"))?;
    let stdin = child.stdin.take();
    let stdout = child.stdout.take().ok_or("codex app-server has no output")?;
    let lines = tokio::io::AsyncBufReadExt::lines(tokio::io::BufReader::new(stdout));
    Ok(Link::Spawned { child, stdin, lines })
}

#[cfg(not(unix))]
pub async fn deliver(_: &Path, _: &str, _: &str, _: &str) -> Result<String, String> {
    Err("delivering to a Codex thread is Unix-only".into())
}

#[cfg(test)]
#[path = "codex_desktop_tests.rs"]
pub(crate) mod tests;
