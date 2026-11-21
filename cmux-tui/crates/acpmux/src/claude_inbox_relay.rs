//! The inbox relay: acpmux's deliveries into a Claude Code session it did not start (a desktop
//! chat, a Claude Code terminal: `claude_peers.rs`, `hub/bridge.rs`) written by a process that
//! session runs itself, an MCP stdio server it launched, instead of by the daemon.
//!
//! Why: a Claude Code session in `bypassPermissions` holds a peer message for its person to let
//! in by hand ("Held message from another session") unless it can tell the message came from its
//! own child. It asks the kernel which process connected to its inbox (`LOCAL_PEERPID`) and walks
//! that process's parents: when the walk finds the session, the message is its own child's
//! (`selfSent`) and runs; when the walk succeeds without finding it (the acpmux daemon, which no
//! Claude Code session starts), the message is held. When the walk cannot be made, a connection
//! opened with the session's own token (`CLAUDE_CODE_MESSAGING_TOKEN`, which `acpmux register`
//! hands over) runs. So the daemon's own deliveries ran or were held by a race: on cosmic-gray,
//! 2026-11-13..21, 6,819 acpmux deliveries arrived `selfSent` and 394 into bypass sessions did
//! not (33 the walk proved were the daemon's, 361 from one desktop chat with no peer pid).
//!
//! Option 1 of that finding, decided: the delivery comes from the session's own child, so the
//! walk finds the session every time. The session's MCP server (`acpmux acpmux-mcp` in guest
//! mode, which `acpmux desktop link` adds, or the tool-less `acpmux inbox-relay`) polls the
//! daemon ([`poll`], `_acpmux/inbox_relay`); the daemon hands it each delivery for the session
//! it runs under, and it writes the daemon's message line to that inbox, opened with the token
//! Claude Code exported to it (`own_frames`), as its own hooks and Bash would. Nothing here declares a permission mode or races the check: Claude Code's own walk
//! decides, and finds a real child. A session with no relay attached is delivered to by the
//! daemon as before (and may be held as before).
//!
//! Which session a relay serves is what the kernel says: the nearest live registered Claude Code
//! process among the relay connection's own ancestors (the pid the kernel gave at accept), never
//! one it names, rechecked on every poll. That process's children already hold its token, so
//! handing a relay the lines meant for its own session gives it nothing it could not read.

use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::{Notify, oneshot};

/// The variables Claude Code exports to its own children: its inbox and that inbox's token.
const SOCKET_ENV: &str = "CLAUDE_CODE_MESSAGING_SOCKET";
const TOKEN_ENV: &str = "CLAUDE_CODE_MESSAGING_TOKEN";
/// The name of the tool-less MCP server `acpmux inbox-relay` serves.
pub const SERVER_NAME: &str = "cmux-inbox";
/// Why the daemon refuses a relay for good: no Claude Code session runs it.
pub const NO_SESSION: &str = "inbox_relay.no_session";

/// How long one poll waits for a delivery before it answers with none.
// timeout: a long-poll's idle answer; the relay polls again at once, nothing is dropped
const POLL_WAIT: Duration = Duration::from_secs(20);
/// A relay counts as attached while it polls, or polled this recently.
const ATTACHED_FOR: Duration = Duration::from_secs(35);
/// How long a delivery waits for the relay to write it.
// timeout: the relay writes one local socket line pair; past it the sender gets an error and the outbox retries
const RELAY_ANSWER: Duration = Duration::from_secs(10);
/// Most deliveries one poll answers with.
const BATCH: usize = 16;
/// Most deliveries waiting for one session's relay.
const MAX_PENDING: usize = 256;

/// One delivery waiting for the relay.
struct Job {
    id: String,
    socket: PathBuf,
    frames: String,
    answer: oneshot::Sender<Result<(), String>>,
}

/// One session's relays: what waits for them and what they took.
struct Entry {
    pending: VecDeque<Job>,
    taken: HashMap<String, oneshot::Sender<Result<(), String>>>,
    polling: usize,
    last_poll: Instant,
    wake: Arc<Notify>,
}

impl Entry {
    fn new() -> Self {
        Self {
            pending: VecDeque::new(),
            taken: HashMap::new(),
            polling: 0,
            last_poll: Instant::now(),
            wake: Arc::new(Notify::new()),
        }
    }

    fn attached(&self) -> bool {
        self.polling > 0 || self.last_poll.elapsed() < ATTACHED_FOR
    }
}

/// The relays attached, by the pid of the Claude Code session they run under.
static RELAYS: LazyLock<Mutex<HashMap<u32, Entry>>> = LazyLock::new(Default::default);
/// The session each relay process serves, by the relay's pid: found once, rechecked each poll.
static SERVES: LazyLock<Mutex<HashMap<u32, u32>>> = LazyLock::new(Default::default);

fn relays() -> std::sync::MutexGuard<'static, HashMap<u32, Entry>> {
    RELAYS.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// Whether a relay runs under the Claude Code session `pid`.
pub fn attached(pid: u32) -> bool {
    relays().get(&pid).is_some_and(Entry::attached)
}

/// Hands `frames` for session `pid`'s inbox at `socket` to a relay that session runs, when one is
/// attached, and waits for it to write them. None: no relay; the caller delivers itself.
pub async fn deliver(pid: u32, socket: &Path, frames: &str) -> Option<Result<(), String>> {
    let id = uuid::Uuid::now_v7().to_string();
    let (tx, rx) = oneshot::channel();
    {
        let mut all = relays();
        let entry = all.get_mut(&pid)?;
        if !entry.attached() {
            // Gone quiet: what waited for it fails (its senders retry), and the daemon delivers.
            drop(all.remove(&pid));
            return None;
        }
        if entry.pending.len() >= MAX_PENDING {
            return Some(Err("the session's inbox relay has too many messages waiting".into()));
        }
        entry.pending.push_back(Job {
            id: id.clone(),
            socket: socket.to_path_buf(),
            frames: frames.to_owned(),
            answer: tx,
        });
        entry.wake.notify_one();
    }
    match tokio::time::timeout(RELAY_ANSWER, rx).await {
        Ok(Ok(result)) => Some(result),
        Ok(Err(_)) => {
            Some(Err("the session's inbox relay ended before it wrote the message".into()))
        }
        Err(_) => {
            // Never written later, after the sender was told it failed and retried.
            if let Some(entry) = relays().get_mut(&pid) {
                entry.pending.retain(|j| j.id != id);
                entry.taken.remove(&id);
            }
            Some(Err("the session's inbox relay did not answer in time".into()))
        }
    }
}

/// The session the relay process `relay` runs under: the nearest of its ancestors (below this
/// daemon) that `live` lists.
pub(crate) fn session_of(relay: u32, live: &[crate::claude_peers::Peer]) -> Option<u32> {
    let ancestry = crate::hub::register::below_daemon(crate::sender_harness::ancestors(relay));
    crate::hub::register::nearest_claude(&ancestry, live, None).map(|p| p.pid)
}

/// `_acpmux/inbox_relay` from the local process `relay`: settles the deliveries it wrote
/// (`done`), then answers with the next ones for its session, waiting up to [`POLL_WAIT`] or
/// until `ended` (its connection closed).
pub async fn poll(
    relay: u32,
    claude_home: PathBuf,
    params: &Value,
    ended: tokio::sync::watch::Receiver<bool>,
) -> Result<Value, RpcError> {
    let known =
        SERVES.lock().unwrap_or_else(std::sync::PoisonError::into_inner).get(&relay).copied();
    let session = tokio::task::spawn_blocking(move || match known {
        // Still its ancestor: a relay's parents change only when its session ends.
        Some(pid) if crate::sender_harness::ancestors(relay).contains(&pid) => Some(pid),
        _ => session_of(relay, &crate::claude_peers::live(&claude_home)),
    })
    .await
    .map_err(|e| RpcError::internal(e.to_string()))?;
    let session = {
        let mut serves = SERVES.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        match session {
            Some(pid) => {
                serves.insert(relay, pid);
                pid
            }
            None => {
                serves.remove(&relay);
                return Err(RpcError::invalid_params(
                    "no Claude Code session runs this process: an inbox relay serves only the session that started it",
                )
                .with_data(json!({"reason": NO_SESSION})));
            }
        }
    };
    poll_for(session, params, ended).await
}

/// [`poll`] for the relays of session `session`, once the caller is proven to run under it.
pub(crate) async fn poll_for(
    session: u32,
    params: &Value,
    mut ended: tokio::sync::watch::Receiver<bool>,
) -> Result<Value, RpcError> {
    let done = params.get("done").and_then(Value::as_array).cloned().unwrap_or_default();
    let wake = {
        let mut all = relays();
        let entry = all.entry(session).or_insert_with(Entry::new);
        for d in &done {
            let Some(id) = d.get("id").and_then(Value::as_str) else { continue };
            if let Some(answer) = entry.taken.remove(id) {
                let error = d.get("error").and_then(Value::as_str).map(str::to_owned);
                let _ = answer.send(error.map_or(Ok(()), Err));
            }
        }
        entry.polling += 1;
        entry.last_poll = Instant::now();
        entry.wake.clone()
    };
    let deadline = tokio::time::Instant::now() + POLL_WAIT;
    let deliveries = loop {
        let batch = take(session);
        if !batch.is_empty() || tokio::time::Instant::now() >= deadline || *ended.borrow() {
            break batch;
        }
        tokio::select! {
            () = wake.notified() => {}
            () = tokio::time::sleep_until(deadline) => {}
            _ = ended.changed() => {}
        }
    };
    if let Some(entry) = relays().get_mut(&session) {
        entry.polling = entry.polling.saturating_sub(1);
        entry.last_poll = Instant::now();
    }
    Ok(json!({"session": session, "deliveries": deliveries}))
}

/// Up to [`BATCH`] waiting deliveries for `session`'s relays, now taken by one.
fn take(session: u32) -> Vec<Value> {
    let mut all = relays();
    let Some(entry) = all.get_mut(&session) else { return Vec::new() };
    let mut out = Vec::new();
    while out.len() < BATCH {
        let Some(job) = entry.pending.pop_front() else { break };
        if job.answer.is_closed() {
            continue;
        }
        out.push(json!({"id": job.id, "socket": job.socket, "frames": job.frames}));
        entry.taken.insert(job.id, job.answer);
    }
    out
}

/// The relay's side, run in a Claude Code session's MCP server: polls this machine's daemon and
/// writes each delivery it hands over into the inbox it names. Returns when the daemon says no
/// Claude Code session runs this process, or does not know the method (an older daemon); else it
/// reconnects for as long as the server runs.
#[cfg(unix)]
pub async fn run() {
    let mut done: Vec<Value> = Vec::new();
    let mut backoff = Duration::from_secs(1);
    loop {
        if let Ok(client) =
            crate::client::Client::connect_without_caller(&crate::config::socket_path()).await
        {
            loop {
                let params = json!({"done": std::mem::take(&mut done)});
                match client.request(crate::rpc::method::MUX_INBOX_RELAY, params).await {
                    Ok(reply) => {
                        backoff = Duration::from_secs(1);
                        for d in
                            reply.get("deliveries").and_then(Value::as_array).into_iter().flatten()
                        {
                            done.push(write_one(d).await);
                        }
                    }
                    Err(e) if refused_for_good(&e) => return,
                    Err(_) => break,
                }
            }
        }
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(Duration::from_secs(60));
    }
}

#[cfg(not(unix))]
pub async fn run() {}

/// Writes one delivery the daemon handed over; its `done` entry.
#[cfg(unix)]
async fn write_one(d: &Value) -> Value {
    let id = d.get("id").cloned().unwrap_or(Value::Null);
    let (Some(socket), Some(frames)) =
        (d.get("socket").and_then(Value::as_str), d.get("frames").and_then(Value::as_str))
    else {
        return json!({"id": id, "error": "the delivery named no inbox or text"});
    };
    let frames = own_frames(socket, frames, &own_inbox());
    match crate::claude_peers::write_frames(Path::new(socket), &frames).await {
        Ok(()) => json!({"id": id}),
        Err(e) => json!({"id": id, "error": e}),
    }
}

/// The inbox and token Claude Code gave this process, its own child: `CLAUDE_CODE_MESSAGING_SOCKET`
/// and `CLAUDE_CODE_MESSAGING_TOKEN`, exported to the session's hooks, Bash and MCP servers.
#[cfg(unix)]
fn own_inbox() -> Option<(String, String)> {
    let socket = std::env::var(SOCKET_ENV).ok().filter(|s| !s.is_empty())?;
    let token = std::env::var(TOKEN_ENV).ok().filter(|s| !s.is_empty())?;
    Some((socket, token))
}

/// The lines the relay writes to `socket`: the daemon's message line opened with this session's
/// own token when `socket` is the inbox Claude Code gave this process (so a chat the bridge
/// setting listed, which the daemon reaches only with the peer key, is opened as its own child
/// would), else the daemon's `frames` unchanged.
pub(crate) fn own_frames(socket: &str, frames: &str, own: &Option<(String, String)>) -> String {
    let Some((_, token)) = own.as_ref().filter(|(own_socket, _)| own_socket == socket) else {
        return frames.to_owned();
    };
    let mut lines = frames.lines().filter(|l| !l.trim().is_empty());
    let first = lines.next();
    let message = match first.map(serde_json::from_str::<Value>) {
        Some(Ok(v)) if v.get("type").and_then(Value::as_str) == Some("auth") => lines.next(),
        _ => first,
    };
    let Some(message) = message else { return frames.to_owned() };
    format!("{}\n{message}\n", json!({"type": "auth", "token": token}))
}

/// Whether the daemon refused this relay for good: no session runs it, or no such method.
fn refused_for_good(e: &anyhow::Error) -> bool {
    e.downcast_ref::<crate::client::DaemonError>().is_some_and(|d| {
        d.0.code == RpcError::method_not_found("").code
            || d.0.data.as_ref().and_then(|v| v.get("reason")).and_then(Value::as_str)
                == Some(NO_SESSION)
    })
}

/// Runs `server` (an MCP stdio server of this Claude Code session's) with the relay beside it;
/// the relay stops when the server ends.
pub async fn beside<T>(server: impl std::future::Future<Output = T>) -> T {
    let tasks = cmux_scope::Scope::new("inbox-relay");
    tasks.spawn_until_cancelled("inbox relay", run());
    let out = server.await;
    let _ = tasks.close(Duration::from_secs(1)).await;
    out
}

/// `acpmux inbox-relay`: an MCP stdio server with no tools that runs the relay for the Claude
/// Code session that started it, for a session that wants the relay without the guest tools.
pub async fn serve() -> anyhow::Result<()> {
    beside(crate::secret_mcp::serve_as(SERVER_NAME, String::new(), json!([]), None, |_, _| async {
        crate::secret_mcp::error_result("this server has no tools".to_owned())
    }))
    .await
}

#[cfg(test)]
#[path = "claude_inbox_relay_tests.rs"]
mod tests;
