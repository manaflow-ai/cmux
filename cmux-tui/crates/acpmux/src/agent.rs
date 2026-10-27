//! A child ACP agent process. acpmux is the client on this connection.
//!
//! Every line in either direction is reported through the `tap` callback so
//! the session log holds the raw wire traffic.

use crate::config::HarnessProfile;
use crate::no_panic::RwLockExt;
use crate::rpc::{Id, Message, RpcError};
use anyhow::{Context, Result, anyhow};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Child;
use tokio::sync::{Mutex, mpsc, oneshot};

mod command;
#[cfg(unix)]
pub(crate) mod session_tmp;
pub(crate) use command::{
    REMOTE_ENV_POLICY_ID, REMOTE_ENV_POLICY_KEY, command_env, command_env_cleared, harness_command,
    host_environment, pinned_preview_format, preview_format,
};

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
    /// `agent` is the [`ChildAgent::generation`] it came from: the hub drops what an agent
    /// already replaced still had in flight where it would stand for the new one (a hosted
    /// agent has no pid of its own, so the pid cannot tell two of them apart).
    Notification {
        method: String,
        params: Option<Value>,
        agent: u64,
    },
    /// One stderr line; `host_seq` names the agent host entry it came from.
    Stderr(String, Option<u64>),
    /// The agent process with this pid exited. The pid tells a late exit of
    /// a replaced process apart from the current one.
    Exited {
        pid: Option<u32>,
        code: Option<i32>,
        host_seq: Option<u64>,
    },
    /// Answered once every item queued before it was handled. A prompt's answer
    /// bypasses this queue, so a turn sends one before it settles: the agent's
    /// last notifications (the reply text) are applied first.
    Barrier(tokio::sync::oneshot::Sender<()>),
    /// The history the agent of this generation replayed on `session/load` (or a fork's prime)
    /// is all in front of this: the session's preview takes that agent's words again
    /// (`ReplayHold` in `hub/lifecycle.rs`). Queued through the agent's own sender, behind
    /// everything its reader already queued.
    ReplayDone {
        agent: u64,
    },
}

/// Logs one wire message. The `u64` is the agent host entry it logs, when
/// the agent runs under a host (`hostSeq` on the record).
/// Returns whether the record reached the store; an agent host entry is
/// acknowledged only then.
pub type Tap = Arc<dyn Fn(Direction, &Message, Option<u64>) -> bool + Send + Sync>;

/// Tap methods for an agent host's stderr and exit entries, so they are
/// logged in entry order before the entry is acknowledged.
pub const HOST_STDERR: &str = "_acpmux/host_stderr";
pub const HOST_EXIT: &str = "_acpmux/host_exit";

/// A Claude stream-json harness's translator state.
#[derive(Debug, Clone, Default)]
pub struct ClaudeState {
    pub session_id: Option<String>,
    pub modes: Value,
    pub config_options: Value,
}

/// The answer to one request, as `ChildAgent::request` returns it.
pub type Response = oneshot::Receiver<Result<Value, RpcError>>;

/// How long the reader waits for the Exit entry's ack to be written.
const EXIT_ACK_BUDGET: std::time::Duration = std::time::Duration::from_secs(2);

/// The agent runs under an `__agent-host` process (durable sessions).
struct Hosted {
    /// The current owner connection; replaced by `reattach`.
    link: std::sync::RwLock<Arc<crate::agent_host::link::Link>>,
    inbound: mpsc::Sender<Inbound>,
    exited: std::sync::atomic::AtomicBool,
    /// Set as soon as the Exit entry is logged (before its ack is written):
    /// the agent is no longer alive, though `exited` waits for the ack.
    exit_seen: std::sync::atomic::AtomicBool,
    /// Set before a detach: the connection's end is a hand-off, not the
    /// agent's death, so pending requests stay open for the next daemon.
    detached: Arc<std::sync::atomic::AtomicBool>,
    exit: tokio::sync::Notify,
    /// Last entry whose record reached the store.
    logged: tokio::sync::watch::Sender<u64>,
    /// The reader stopped (an entry could not be logged): the agent is not
    /// usable through this link; the next request adopts the host again.
    broken: std::sync::atomic::AtomicBool,
}

impl Hosted {
    fn link(&self) -> Arc<crate::agent_host::link::Link> {
        self.link.read_or_recover().clone()
    }
}

/// How a hosted agent was reached.
pub enum Attached {
    /// The agent, what its host reported, and a receiver per id in
    /// `awaiting`, registered before any replayed entry was read.
    Ready(Arc<ChildAgent>, crate::agent_host::link::Adopted, Vec<Response>),
    /// The host runs a protocol this build does not speak; it keeps running.
    Incompatible { min: u16, max: u16, host_build: String },
}

/// How long `kill` lets the agent's process group exit after SIGTERM.
const KILL_GRACE: std::time::Duration = std::time::Duration::from_millis(300);

/// How often the reader checks that the agent process is still running.
const LEADER_CHECK: std::time::Duration = std::time::Duration::from_millis(500);

/// How long the reader keeps draining stdout after the agent process exits.
const LEADER_DRAIN: std::time::Duration = std::time::Duration::from_secs(2);

/// Bounded stderr drain after stdout closes, before failing pending requests.
const STDERR_DRAIN: std::time::Duration = std::time::Duration::from_secs(1);

struct Pending {
    map: HashMap<String, oneshot::Sender<Result<Value, RpcError>>>,
    /// Answers that arrived with nobody waiting (a replayed answer to a
    /// request of the previous daemon); `await_response` takes them.
    orphans: std::collections::VecDeque<(String, Result<Value, RpcError>)>,
}

const ORPHAN_ANSWERS: usize = 64;

/// The next [`ChildAgent::generation`]: one per agent this daemon starts or adopts.
static NEXT_GENERATION: AtomicU64 = AtomicU64::new(1);

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
    /// The queue its reader hands requests and notifications to: an item sent here lands
    /// behind every one the reader already sent (a pooled agent's goes through its hold).
    inbound: mpsc::Sender<Inbound>,
    pub pid: Option<u32>,
    /// This agent among every one the daemon ran, never reused: what its notifications carry
    /// (`Inbound::Notification`), so the hub knows one from an agent it already replaced.
    pub generation: u64,
    /// Present when the child speaks Claude's stream-json instead of ACP
    /// and runs directly under acpmux (a host owns its own translator).
    pub translator: Option<Arc<crate::claude_stdio::Translator>>,
    /// Present when the child is `codex app-server`, bridged in process
    /// (`codex_app_server.rs`) and run directly under acpmux.
    codex: Option<CodexLink>,
    hosted: Option<Hosted>,
    /// Its cmux MCP server lists every tool (`agent_tools::lists_all_tools`,
    /// decided at its session/new or load), for a fork through it.
    pub all_tools: std::sync::atomic::AtomicBool,
    /// Set once the agent is replaced or stopped (`retire`): a /context answer it still sends
    /// is not the chat's context any more, and is neither logged nor handed to the hub. A lock,
    /// not a flag: the reader holds it while it checks and logs such an answer (`tap_live`), so a
    /// failover that retires the agent and then logs itself can never land between the two.
    retired: std::sync::Mutex<bool>,
    /// The question preview format its command was pinned to, for a direct
    /// start (a host's is recorded where the host starts, `hub/hosts.rs`).
    pub preview_format: Option<crate::hub::questions::PreviewFormat>,
    /// Windows: the agent's job (its process group on Unix).
    #[cfg(windows)]
    job: Option<crate::job::Job>,
}

/// The in-process Codex bridge of a direct child: its translator, and the
/// inbound queue for the ACP requests and notifications it answers with
/// without asking the app-server (a mode change's updates).
struct CodexLink {
    tr: Arc<crate::codex_app_server::Translator>,
    inbound: mpsc::Sender<Inbound>,
    /// Held from a translator call until its lines are queued for stdin, so
    /// the reader and writers send them in the translator's order.
    order: Mutex<()>,
}

/// A session update whose news is only the agent process's own to give: Claude Code's /context
/// breakdown, its account's usage limits. One a replaced process sends is not the chat's.
pub fn process_state(params: &Value) -> bool {
    params
        .pointer("/update/_meta/acpmux")
        .is_some_and(|m| m.get("contextBreakdown").is_some() || m.get("usageLimits").is_some())
}

impl ChildAgent {
    /// Ends every process in the agent's job (Windows; killpg on Unix).
    #[cfg(windows)]
    fn kill_job(&self) {
        if let Some(job) = &self.job {
            job.kill();
        }
    }

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
        // The build-session kill switch: no agent process at all (cx-9ettq).
        crate::launch_policy::refuse_if_disabled()?;
        let codex = (translator.is_none()
            && command_line.is_none()
            && crate::codex_app_server::is_profile_launch(&profile.argv))
        .then(|| CodexLink {
            tr: crate::codex_app_server::translator(),
            inbound: inbound.clone(),
            order: Mutex::new(()),
        });
        let mut cmd = harness_command(name, profile, cwd, command_line, session)?;
        let preview_format = Some(pinned_preview_format(&cmd));
        #[cfg(windows)]
        cmd.creation_flags(crate::job::AGENT_FLAGS);
        let mut child = cmd.spawn().map_err(|e| spawn_error(&format!("spawn agent {name}"), e))?;
        #[cfg(windows)]
        let job = {
            let contained = child
                .raw_handle()
                .ok_or_else(|| std::io::Error::other("the agent has no process handle"))
                .and_then(crate::job::Job::contain);
            match contained {
                Ok(job) => Some(job),
                Err(e) => {
                    let _ = child.start_kill();
                    anyhow::bail!("spawn agent {name}: its job object: {e}");
                }
            }
        };
        let pid = child.id();
        let stdin = child.stdin.take().context("agent stdin")?;
        let stdout = child.stdout.take().context("agent stdout")?;
        let stderr = child.stderr.take().context("agent stderr")?;

        let (stdin_tx, mut stdin_rx) = mpsc::channel::<String>(256);
        let pending =
            Arc::new(Mutex::new(Pending { map: HashMap::new(), orphans: Default::default() }));
        let agent = Arc::new(Self {
            name: name.to_owned(),
            child: Mutex::new(Some(child)),
            stdin_tx,
            next_id: AtomicI64::new(1),
            pending: pending.clone(),
            tap: tap.clone(),
            inbound: inbound.clone(),
            pid,
            translator: translator.clone(),
            codex,
            hosted: None,
            all_tools: std::sync::atomic::AtomicBool::new(false),
            retired: std::sync::Mutex::new(false),
            generation: NEXT_GENERATION.fetch_add(1, Ordering::Relaxed),
            preview_format,
            #[cfg(windows)]
            job,
        });

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

        // The app-server's initialize goes out at spawn, before the hub's.
        if let Some(cx) = &agent.codex {
            let first = crate::codex_app_server::split(cx.tr.start());
            agent.codex_lines(first.server).await;
        }

        let stderr_done = {
            let inbound = inbound.clone();
            tokio::spawn(async move {
                let mut lines = BufReader::new(stderr).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let _ = inbound.send(Inbound::Stderr(line, None)).await;
                }
            })
        };

        {
            let inbound = inbound.clone();
            let pending = pending.clone();
            let tap = tap.clone();
            let agent_for_exit = agent.clone();
            tokio::spawn(async move {
                let mut lines = BufReader::new(stdout).lines();
                // The leader can exit while a descendant still holds stdout
                // open; watch it so its exit is reported regardless.
                let mut leader_check = tokio::time::interval(LEADER_CHECK);
                let mut leader_gone: Option<tokio::time::Instant> = None;
                loop {
                    let next = tokio::select! {
                        next = lines.next_line() => next,
                        _ = leader_check.tick() => {
                            if let Some(at) = leader_gone {
                                // Give buffered output a moment, then stop reading.
                                if at.elapsed() >= LEADER_DRAIN {
                                    break;
                                }
                            } else if !agent_for_exit.is_alive().await {
                                leader_gone = Some(tokio::time::Instant::now());
                                // Stop what the agent left running so the pipe closes.
                                #[cfg(unix)]
                                if let Some(pg) = agent_for_exit.pid {
                                    unsafe {
                                        libc::killpg(pg as i32, libc::SIGKILL);
                                    }
                                }
                                #[cfg(windows)]
                                agent_for_exit.kill_job();
                            }
                            continue;
                        }
                    };
                    let line = match next {
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
                                let _ = inbound
                                    .send(Inbound::Stderr(
                                        format!("[non-json stdout] {line}"),
                                        None,
                                    ))
                                    .await;
                                continue;
                            }
                        };
                        // Keep the raw claude line in the log under its own kind.
                        tap(Direction::In, &crate::claude_stdio::logged_line(&raw), None);
                        let translated = tr.inbound(&raw).await;
                        // Answers the translator owes claude itself.
                        for l in tr.take_stdin_replies().await {
                            tap(
                                Direction::Out,
                                &Message::notification("claude.stdin", l.clone()),
                                None,
                            );
                            let mut s = l.to_string();
                            s.push('\n');
                            let _ = agent_for_exit.stdin_tx.send(s).await;
                        }
                        let mut translated = translated;
                        // Translated ACP messages go through the same tap as
                        // native ACP traffic, so the log and viewers see them;
                        // a retired agent's /context answer is dropped instead.
                        translated.retain(|m| {
                            matches!(m, Message::Response { .. })
                                || agent_for_exit
                                    .tap_live(m, || tap(Direction::In, m, None))
                                    .is_some()
                        });
                        translated
                    } else if let Some(cx) = &agent_for_exit.codex {
                        let raw: Value = match serde_json::from_str(&line) {
                            Ok(v) => v,
                            Err(_) => {
                                let _ = inbound
                                    .send(Inbound::Stderr(
                                        format!("[non-json stdout] {line}"),
                                        None,
                                    ))
                                    .await;
                                continue;
                            }
                        };
                        if let Some(kind) = crate::codex_app_server::tap_kind(&raw) {
                            tap(Direction::In, &Message::notification(&kind, raw.clone()), None);
                        }
                        let order = cx.order.lock().await;
                        let split = crate::codex_app_server::split(cx.tr.from_server(&raw));
                        agent_for_exit.codex_lines(split.server).await;
                        drop(order);
                        for m in &split.hub {
                            if !matches!(m, Message::Response { .. }) {
                                tap(Direction::In, m, None);
                            }
                        }
                        split.hub
                    } else {
                        match Message::parse(&line) {
                            Ok(m) => {
                                tap(Direction::In, &m, None);
                                vec![m]
                            }
                            Err(e) => {
                                tracing::warn!(agent = %agent_for_exit.name, "bad line from agent: {e}: {line}");
                                let _ = inbound
                                    .send(Inbound::Stderr(
                                        format!("[non-json stdout] {line}"),
                                        None,
                                    ))
                                    .await;
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
                                let _ = inbound
                                    .send(Inbound::Notification {
                                        method,
                                        params,
                                        agent: agent_for_exit.generation,
                                    })
                                    .await;
                            }
                        }
                    }
                }
                // Claude's background shells ended with it (cx-ncc.84).
                if let Some(tr) = &agent_for_exit.translator {
                    for m in tr.end_background_shells().await {
                        tap(Direction::In, &m, None);
                        if let Message::Notification { method, params } = m {
                            let _ = inbound
                                .send(Inbound::Notification {
                                    method,
                                    params,
                                    agent: agent_for_exit.generation,
                                })
                                .await;
                        }
                    }
                }
                // Settle the app-server translator's requests too.
                if let Some(cx) = &agent_for_exit.codex {
                    let closed = crate::codex_app_server::split(cx.tr.server_closed("it exited"));
                    agent_for_exit.codex_to_hub(cx, closed.hub).await;
                }
                // Queue stderr first so limit/sign-in deaths are not continued.
                let _ = tokio::time::timeout(STDERR_DRAIN, stderr_done).await;
                let mut p = pending.lock().await;
                for (_, tx) in p.map.drain() {
                    let _ = tx.send(Err(RpcError::internal("agent process closed")));
                }
                drop(p);
                let code = agent_for_exit.wait_exit().await;
                let _ = inbound
                    .send(Inbound::Exited { pid: agent_for_exit.pid, code, host_seq: None })
                    .await;
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

    /// Mark the agent replaced (a failover) or stopping: a /context breakdown or usage limits it
    /// still sends, answering a turn that ended before, are dropped (`tap_live`). Waits for a breakdown being
    /// logged right now, so what the caller logs next comes after it.
    pub fn retire(&self) {
        *self.retired.lock().unwrap_or_else(|e| e.into_inner()) = true;
    }

    /// Whether [`Self::retire`] ran.
    pub fn is_retired(&self) -> bool {
        *self.retired.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Runs `log` for `m`, unless `m` is a /context breakdown or usage limits update
    /// (`process_state`) from a retired agent (None).
    /// For such an update the retire lock is held across the check and `log`.
    fn tap_live<R>(&self, m: &Message, log: impl FnOnce() -> R) -> Option<R> {
        let context = matches!(m, Message::Notification { method, params }
            if method == crate::rpc::method::SESSION_UPDATE
                && params.as_ref().is_some_and(process_state));
        if !context {
            return Some(log());
        }
        let retired = self.retired.lock().unwrap_or_else(|e| e.into_inner());
        (!*retired).then(log)
    }

    pub async fn kill(&self) {
        self.retire();
        if self.hosted.is_some() {
            self.terminate(KILL_GRACE).await;
            return;
        }
        let mut guard = self.child.lock().await;
        #[cfg(unix)]
        let under = under_unreaped(guard.as_ref()).await;
        // The saved group id, not `child.id()`: once the leader is reaped
        // that is None, and its background processes would survive.
        if let Some(pid) = self.pid {
            // TERM the whole group first so children get a chance to exit,
            // then KILL whatever is left. The wait ends as soon as the
            // agent exits; 300 ms is only the most it gets.
            #[cfg(unix)]
            unsafe {
                libc::killpg(pid as i32, libc::SIGTERM);
            }
            // Windows: Ctrl+Break to the agent's process group first.
            #[cfg(windows)]
            crate::job::ctrl_break(pid);
            if let Some(child) = guard.as_mut() {
                let _ = tokio::time::timeout(KILL_GRACE, child.wait()).await;
            }
            // Then the job ends, stragglers included (SIGKILL on Unix).
            #[cfg(windows)]
            self.kill_job();
            #[cfg(unix)]
            unsafe {
                libc::killpg(pid as i32, libc::SIGKILL);
            }
        }
        if let Some(child) = guard.as_mut() {
            let _ = child.kill().await;
        }
        *guard = None;
        #[cfg(unix)]
        end_still_running(under).await;
    }

    /// Stop the agent within a bound: SIGTERM to its process group, wait up
    /// to `grace` for it to exit, then SIGKILL the group (stragglers
    /// included). Never waits on a lock or a pipe without a deadline.
    pub async fn terminate(&self, grace: std::time::Duration) {
        self.retire();
        if let Some(h) = &self.hosted {
            if h.exited.load(Ordering::SeqCst) || h.link().is_closed() {
                return;
            }
            let exited = h.exit.notified();
            tokio::pin!(exited);
            exited.as_mut().enable();
            if h.exited.load(Ordering::SeqCst) {
                return;
            }
            if h.link().terminate(grace).await.is_ok() {
                // The host's exit entry ends the wait; the bound covers a
                // host that cannot report it.
                let _ =
                    tokio::time::timeout(grace + std::time::Duration::from_secs(1), exited).await;
            }
            return;
        }
        let pgid = self.pid.map(|p| p as i32);
        // Busy: the exit watcher holds it while it reaps the agent (its
        // stdout closed); a helper then is not taken here.
        #[cfg(unix)]
        let under = match self.child.try_lock() {
            Ok(g) => under_unreaped(g.as_ref()).await,
            Err(_) => Vec::new(),
        };
        #[cfg(unix)]
        if let Some(pg) = pgid {
            unsafe {
                libc::killpg(pg, libc::SIGTERM);
            }
        }
        // Windows: Ctrl+Break to the agent's process group first.
        #[cfg(windows)]
        if let Some(pg) = pgid {
            crate::job::ctrl_break(pg as u32);
        }
        let _ = tokio::time::timeout(grace, async {
            // The exit watcher may hold this lock while it reaps, and frees
            // it once the child is gone; otherwise wait on the exit here.
            if let Some(child) = self.child.lock().await.as_mut() {
                let _ = child.wait().await;
            }
        })
        .await;
        // Then the job ends, stragglers included (SIGKILL on Unix).
        #[cfg(windows)]
        self.kill_job();
        #[cfg(unix)]
        if let Some(pg) = pgid {
            unsafe {
                libc::killpg(pg, libc::SIGKILL);
            }
        }
        if let Ok(mut g) = self.child.try_lock()
            && let Some(c) = g.as_mut()
        {
            let _ = c.start_kill();
        }
        #[cfg(unix)]
        end_still_running(under).await;
    }

    pub async fn is_alive(&self) -> bool {
        if let Some(h) = &self.hosted {
            return !h.exit_seen.load(Ordering::SeqCst)
                && !h.broken.load(Ordering::SeqCst)
                && !h.link().is_closed();
        }
        let mut guard = self.child.lock().await;
        match guard.as_mut() {
            Some(child) => matches!(child.try_wait(), Ok(None)),
            None => false,
        }
    }

    async fn write(&self, msg: &Message) -> Result<()> {
        if let Some(h) = &self.hosted {
            // The host writes it and logs it back as an `out` entry.
            return h.link().line(msg.to_value()).await;
        }
        (self.tap)(Direction::Out, msg, None);
        if let Some(cx) = &self.codex {
            let order = cx.order.lock().await;
            let split = crate::codex_app_server::split(cx.tr.from_client(&msg.to_value()));
            let written = self.codex_lines(split.server).await;
            drop(order);
            if !written {
                return Err(anyhow!("agent {} stdin closed", self.name));
            }
            self.codex_to_hub(cx, split.hub).await;
            return Ok(());
        }
        if let Some(tr) = &self.translator {
            match tr.outbound(msg).await {
                crate::claude_stdio::Outbound::Lines(lines) => {
                    for l in lines {
                        (self.tap)(
                            Direction::Out,
                            &Message::notification("claude.stdin", l.clone()),
                            None,
                        );
                        let mut s = l.to_string();
                        s.push('\n');
                        self.stdin_tx
                            .send(s)
                            .await
                            .map_err(|_| anyhow!("agent {} stdin closed", self.name))?;
                    }
                    Ok(())
                }
                crate::claude_stdio::Outbound::Reply(reply) => {
                    // Immediate local answer: feed it back as if claude replied.
                    if let Message::Response { id, result, error } = reply
                        && let Some(tx) = self.pending.lock().await.map.remove(&key(&id))
                    {
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

    /// ACP messages the Codex translator produced for the hub: an answer
    /// to a request of ours resolves it, as if Codex replied; requests and
    /// notifications go to the session's inbound queue.
    async fn codex_to_hub(&self, cx: &CodexLink, hub: Vec<Message>) {
        for m in hub {
            if !matches!(m, Message::Response { .. }) {
                (self.tap)(Direction::In, &m, None);
            }
            match m {
                Message::Response { id, result, error } => {
                    if let Some(tx) = self.pending.lock().await.map.remove(&key(&id)) {
                        let _ = tx.send(match error {
                            Some(e) => Err(e),
                            None => Ok(result.unwrap_or(Value::Null)),
                        });
                    }
                }
                Message::Request { id, method, params } => {
                    let _ = cx.inbound.send(Inbound::Request { id, method, params }).await;
                }
                Message::Notification { method, params } => {
                    let _ = cx
                        .inbound
                        .send(Inbound::Notification { method, params, agent: self.generation })
                        .await;
                }
            }
        }
    }

    /// Writes translator lines to the app-server's stdin, each logged.
    /// Returns false once stdin is closed.
    async fn codex_lines(&self, lines: Vec<Value>) -> bool {
        for l in lines {
            (self.tap)(
                Direction::Out,
                &Message::notification(crate::codex_app_server::STDIN_KIND, l.clone()),
                None,
            );
            if self.stdin_tx.send(crate::codex_app_server::line(&l)).await.is_err() {
                return false;
            }
        }
        true
    }

    /// Queue [`Inbound::ReplayDone`] behind what the reader queued so far, waiting for room.
    /// False when the queue is closed.
    pub async fn queue_replay_done(&self) -> bool {
        self.inbound.send(Inbound::ReplayDone { agent: self.generation }).await.is_ok()
    }

    /// Send a request and wait for its response.
    pub async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        self.request_with_hook(method, params, || {}).await
    }

    /// Send a request and run `on_written` only after its frame reached the agent write path.
    /// Used by first-message title generation to start beside the turn, after the harness can
    /// publish its own session title.
    pub async fn request_with_hook<F: FnOnce()>(
        &self,
        method: &str,
        params: Value,
        on_written: F,
    ) -> Result<Value, RpcError> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.map.insert(key(&Value::from(id)), tx);
        let msg = Message::request(id, method, params);
        if let Err(e) = self.write(&msg).await {
            self.pending.lock().await.map.remove(&key(&Value::from(id)));
            return Err(RpcError::internal(e.to_string()));
        }
        on_written();
        rx.await.unwrap_or_else(|_| Err(RpcError::internal("agent response channel dropped")))
    }

    /// [`Self::request`], given up after `limit`: the pending entry goes too, so an agent that
    /// never answers leaves nothing waiting, and a late answer to this id (never reused: ids
    /// only grow) finds no one and is dropped. None on timeout.
    pub async fn request_within(
        &self,
        method: &str,
        params: Value,
        limit: std::time::Duration,
    ) -> Option<Result<Value, RpcError>> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.map.insert(key(&Value::from(id)), tx);
        let msg = Message::request(id, method, params);
        if let Err(e) = self.write(&msg).await {
            self.pending.lock().await.map.remove(&key(&Value::from(id)));
            return Some(Err(RpcError::internal(e.to_string())));
        }
        match tokio::time::timeout(limit, rx).await {
            Ok(answer) => Some(
                answer
                    .unwrap_or_else(|_| Err(RpcError::internal("agent response channel dropped"))),
            ),
            Err(_) => {
                self.pending.lock().await.map.remove(&key(&Value::from(id)));
                None
            }
        }
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

    /// Register interest in the response to a request a previous controller
    /// sent this agent (a recovered turn); it arrives like any other.
    pub async fn await_response(&self, id: Id) -> oneshot::Receiver<Result<Value, RpcError>> {
        let (tx, rx) = oneshot::channel();
        let mut p = self.pending.lock().await;
        let orphan =
            p.orphans.iter().position(|(k, _)| *k == key(&id)).and_then(|i| p.orphans.remove(i));
        if let Some((_, answer)) = orphan {
            let _ = tx.send(answer);
        } else {
            p.map.insert(key(&id), tx);
        }
        rx
    }

    /// Wait until the entries through `h` are in the session log, as long as
    /// they keep coming: it gives up when no entry is logged for `stall` (a
    /// stalled, broken or closed link), and in any case after `ceiling`, so
    /// one large replay cannot hold daemon startup without end.
    pub async fn wait_replayed(
        &self,
        h: u64,
        stall: std::time::Duration,
        ceiling: std::time::Duration,
    ) -> bool {
        let Some(hosted) = &self.hosted else { return true };
        let mut rx = hosted.logged.subscribe();
        let progress = async {
            loop {
                if *rx.borrow_and_update() >= h {
                    return true;
                }
                // `changed` ends only with progress: the sender lives as long
                // as this agent, so a dead link ends the wait by the stall.
                if tokio::time::timeout(stall, rx.changed()).await.is_err() {
                    return false;
                }
            }
        };
        tokio::time::timeout(ceiling, progress).await.unwrap_or(false)
    }

    /// Whether the agent answers now: a hosted agent's host answers a query
    /// within `budget` (a wedged host keeps its link open but never
    /// answers); a direct child is alive.
    pub async fn answers_within(&self, budget: std::time::Duration) -> bool {
        if let Some(h) = &self.hosted {
            return h.link().query_within(budget).await.is_ok();
        }
        self.is_alive().await
    }

    /// Whether Claude Code's translator runs this agent: here, or in its host
    /// (only that translator answers the host's query with modes). None: the
    /// host did not answer in time.
    pub async fn runs_claude(&self) -> Option<bool> {
        if self.translator.is_some() {
            return Some(true);
        }
        let Some(h) = &self.hosted else { return Some(false) };
        h.link().query().await.ok().map(|reply| reply.modes.is_some())
    }

    /// The Claude translator's state, wherever the translator runs.
    pub async fn claude_state(&self) -> Option<ClaudeState> {
        if let Some(tr) = &self.translator {
            return Some(ClaudeState {
                session_id: tr.session_id.lock().await.clone(),
                modes: tr.modes_value().await,
                config_options: tr.config_options_value().await,
            });
        }
        let link = self.hosted.as_ref()?.link();
        let reply = link.query().await.ok()?;
        Some(ClaudeState {
            session_id: reply.claude_session_id,
            modes: reply.modes?,
            config_options: reply.config_options.unwrap_or(Value::Null),
        })
    }

    /// The host record when this agent runs under a host.
    pub fn host_record(&self) -> Option<crate::agent_host::HostRecord> {
        self.hosted.as_ref().map(|h| h.link().record.clone())
    }

    /// The hosted harness exited (its host is finishing).
    pub fn has_exited(&self) -> bool {
        self.hosted.as_ref().is_some_and(|h| h.exited.load(Ordering::SeqCst))
    }

    /// The reader stopped because an entry could not be logged.
    pub fn is_broken(&self) -> bool {
        self.hosted.as_ref().is_some_and(|h| h.broken.load(Ordering::SeqCst))
    }

    /// Reconnect to the same host after the reader stopped, keeping every
    /// open request, answer waiter and turn of this process: resume after
    /// the last logged entry on a new owner connection. No recovery runs:
    /// this process still holds the state the recovery would rebuild.
    pub async fn reattach(self: &Arc<Self>) -> Result<()> {
        use crate::agent_host::link::{Connect, connect};
        let Some(h) = &self.hosted else { return Ok(()) };
        let record = h.link().record.clone();
        let after = *h.logged.borrow();
        let link: Arc<crate::agent_host::link::Link> = match connect(record, after).await? {
            Connect::Ready(link, _) => Arc::from(link),
            Connect::Incompatible { .. } => return Err(anyhow!("agent host refused this build")),
        };
        *h.link.write_or_recover() = link.clone();
        h.broken.store(false, Ordering::SeqCst);
        self.start_reader(link);
        Ok(())
    }

    /// Leave a hosted agent running and let go of it (daemon shutdown or
    /// upgrade). A direct child cannot outlive acpmux and is terminated.
    pub async fn detach(&self, grace: std::time::Duration) {
        match &self.hosted {
            Some(h) => {
                h.detached.store(true, Ordering::SeqCst);
                let _ = tokio::time::timeout(grace, h.link().detach()).await;
            }
            None => self.terminate(grace).await,
        }
    }

    /// Become the owner of a running host and resume after `resume_after`,
    /// the last entry of it already in the session log.
    pub async fn attach_hosted(
        name: &str,
        record: crate::agent_host::HostRecord,
        resume_after: u64,
        awaiting: Vec<Id>,
        inbound: mpsc::Sender<Inbound>,
        tap: Tap,
    ) -> Result<Attached> {
        use crate::agent_host::link::{Connect, connect};
        let (link, adopted): (Arc<crate::agent_host::link::Link>, _) =
            match connect(record, resume_after).await? {
                Connect::Ready(link, adopted) => (Arc::from(link), adopted),
                Connect::Incompatible { min, max, host_build } => {
                    return Ok(Attached::Incompatible { min, max, host_build });
                }
            };
        let (agent, responses) =
            Self::from_link(name, link, &adopted, resume_after, awaiting, inbound, tap);
        Ok(Attached::Ready(agent, adopted, responses))
    }

    /// The agent over an owner connection that is already open; starts its
    /// reader.
    pub(crate) fn from_link(
        name: &str,
        link: Arc<crate::agent_host::link::Link>,
        adopted: &crate::agent_host::link::Adopted,
        resume_after: u64,
        awaiting: Vec<Id>,
        inbound: mpsc::Sender<Inbound>,
        tap: Tap,
    ) -> (Arc<Self>, Vec<Response>) {
        // Never reuse an id the harness may still answer.
        let (stdin_tx, _unused) = mpsc::channel::<String>(1);
        // Answers to requests a previous controller sent may be among the
        // replayed entries: register them before the reader starts.
        let mut map = HashMap::new();
        let mut responses = Vec::new();
        for id in awaiting {
            let (tx, rx) = oneshot::channel();
            map.insert(key(&id), tx);
            responses.push(rx);
        }
        let pending = Arc::new(Mutex::new(Pending { map, orphans: Default::default() }));
        let agent = Arc::new(Self {
            name: name.to_owned(),
            child: Mutex::new(None),
            stdin_tx,
            next_id: AtomicI64::new(adopted.max_out_id.max(0) + 1),
            pending,
            tap,
            inbound: inbound.clone(),
            pid: adopted.harness_pid,
            translator: None,
            codex: None,
            hosted: Some(Hosted {
                link: std::sync::RwLock::new(link.clone()),
                inbound,
                detached: Arc::new(std::sync::atomic::AtomicBool::new(false)),
                logged: tokio::sync::watch::channel(resume_after).0,
                broken: std::sync::atomic::AtomicBool::new(false),
                exited: std::sync::atomic::AtomicBool::new(false),
                exit_seen: std::sync::atomic::AtomicBool::new(false),
                exit: tokio::sync::Notify::new(),
            }),
            all_tools: std::sync::atomic::AtomicBool::new(false),
            retired: std::sync::Mutex::new(false),
            generation: NEXT_GENERATION.fetch_add(1, Ordering::Relaxed),
            preview_format: None,
            #[cfg(windows)]
            job: None,
        });
        agent.start_reader(link);
        (agent, responses)
    }

    /// Read `link`'s entries: log each, act on it, then acknowledge it.
    fn start_reader(self: &Arc<Self>, link: Arc<crate::agent_host::link::Link>) {
        let reader = self.clone();
        tokio::spawn(async move {
            let Some(hosted) = reader.hosted.as_ref() else { return };
            let mut entries = link.entries.lock().await;
            while let Some((h, entry)) = entries.recv().await {
                let is_exit = matches!(entry, crate::agent_host::Entry::Exit { .. });
                if !reader.on_host_entry(h, entry, &hosted.inbound).await {
                    // Not stored: never acknowledge it or anything after it.
                    // Open requests stay open; the next request reattaches.
                    tracing::warn!(agent = %reader.name, "agent host entry {h} not logged; acks stop");
                    hosted.broken.store(true, Ordering::SeqCst);
                    return;
                }
                hosted.logged.send_replace(h);
                if is_exit {
                    // Written before anyone hears of the exit: a daemon that
                    // ends the agent and exits at once still acks the Exit.
                    let acked = link.ack_written(h, EXIT_ACK_BUDGET).await;
                    hosted.exited.store(true, Ordering::SeqCst);
                    hosted.exit.notify_waiters();
                    if acked.is_err() {
                        break;
                    }
                    continue;
                }
                if link.ack(h).await.is_err() {
                    break;
                }
            }
            // A detach hands the agent and its open requests to the next
            // daemon; a replaced link hands them to its own reader.
            if hosted.detached.load(Ordering::SeqCst) || !Arc::ptr_eq(&hosted.link(), &link) {
                return;
            }
            // The host died or another owner took it.
            let mut p = reader.pending.lock().await;
            for (_, tx) in p.map.drain() {
                let _ = tx.send(Err(RpcError::internal("agent process closed")));
            }
        });
    }

    /// Log one host entry, then act on it. Returns whether its record was
    /// stored (only then may it be acknowledged).
    async fn on_host_entry(
        &self,
        h: u64,
        entry: crate::agent_host::Entry,
        inbound: &mpsc::Sender<Inbound>,
    ) -> bool {
        use crate::agent_host::{Entry, TapDir};
        // Debug builds only: `ACPMUX_TEST_UNLOGGED_ONCE=TEXT` fails to log the first host entry
        // whose text holds TEXT, once per process, as a full disk does: the link breaks and the
        // entry stays with the host for the next attach. Release builds have no seam.
        #[cfg(debug_assertions)]
        if let Ok(text) = std::env::var("ACPMUX_TEST_UNLOGGED_ONCE") {
            static FIRED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
            let msg = match &entry {
                Entry::Tap { msg, .. } | Entry::In { msg } => Some(msg.to_string()),
                _ => None,
            };
            if msg.is_some_and(|m| m.contains(&text)) && !FIRED.swap(true, Ordering::SeqCst) {
                return false;
            }
        }
        match entry {
            Entry::Tap { dir, msg } => match Message::from_value(msg) {
                Ok(m) => {
                    let d = if dir == TapDir::In { Direction::In } else { Direction::Out };
                    (self.tap)(d, &m, Some(h))
                }
                Err(_) => true,
            },
            Entry::In { msg } => {
                let Ok(m) = Message::from_value(msg) else { return true };
                // Dropped as the direct reader drops it; the entry counts as handled.
                match self.tap_live(&m, || (self.tap)(Direction::In, &m, Some(h))) {
                    None => return true,
                    Some(false) => return false,
                    Some(true) => {}
                }
                match m {
                    Message::Response { id, result, error } => {
                        let answer = match error {
                            Some(e) => Err(e),
                            None => Ok(result.unwrap_or(Value::Null)),
                        };
                        let mut p = self.pending.lock().await;
                        if let Some(tx) = p.map.remove(&key(&id)) {
                            let _ = tx.send(answer);
                        } else {
                            if p.orphans.len() >= ORPHAN_ANSWERS {
                                p.orphans.pop_front();
                            }
                            p.orphans.push_back((key(&id), answer));
                        }
                    }
                    Message::Request { id, method, params } => {
                        let _ = inbound.send(Inbound::Request { id, method, params }).await;
                    }
                    Message::Notification { method, params } => {
                        let _ = inbound
                            .send(Inbound::Notification { method, params, agent: self.generation })
                            .await;
                    }
                }
                true
            }
            Entry::Err { line } => {
                let note = Message::notification(HOST_STDERR, serde_json::json!({"text": line}));
                if !(self.tap)(Direction::In, &note, Some(h)) {
                    return false;
                }
                let _ = inbound.send(Inbound::Stderr(line, Some(h))).await;
                true
            }
            Entry::Exit { code } => {
                let note = Message::notification(HOST_EXIT, serde_json::json!({"code": code}));
                if !(self.tap)(Direction::In, &note, Some(h)) {
                    return false;
                }
                // Not alive from here: no turn may set the session ready on
                // a harness that is gone while the ack is still being written.
                if let Some(hosted) = &self.hosted {
                    hosted.exit_seen.store(true, Ordering::SeqCst);
                }
                let mut p = self.pending.lock().await;
                for (_, tx) in p.map.drain() {
                    let _ = tx.send(Err(RpcError::internal("agent process closed")));
                }
                drop(p);
                // `exited` and the exit notify follow the Exit entry's ack
                // (`start_reader`), so a terminate that waits on them never
                // returns before the host knows its Exit is logged.
                let _ =
                    inbound.send(Inbound::Exited { pid: self.pid, code, host_seq: Some(h) }).await;
                true
            }
        }
    }
}

/// The processes under a direct agent, by pid and start time, taken before
/// its group is signalled: a helper the harness moved out of its group
/// (setsid, Node's `detached: true`) is out of reach of the group signal
/// and runs on with parent pid 1 once the harness is gone (cx-n3uid). The
/// pid is read only while the agent is not reaped (`Child::id` is Some), so
/// it cannot name a reused pid. Not reached, as in `terminate_unadoptable`:
/// a helper that already has ppid 1 (a double fork) or starts after this.
#[cfg(unix)]
async fn under_unreaped(child: Option<&Child>) -> Vec<crate::agent_host::tree::Started> {
    let Some(pid) = child.and_then(Child::id) else { return Vec::new() };
    tokio::task::spawn_blocking(move || crate::agent_host::tree::descendants(&[pid]))
        .await
        .unwrap_or_default()
}

/// SIGKILL each of `procs` that still runs as the same process: what the
/// group signal of a direct agent did not reach.
#[cfg(unix)]
async fn end_still_running(procs: Vec<crate::agent_host::tree::Started>) {
    if procs.is_empty() {
        return;
    }
    let _ =
        tokio::task::spawn_blocking(move || crate::agent_host::tree::kill_still_running(&procs))
            .await;
}

/// The error of an agent (or its agent host) that did not start; `what` says which, e.g.
/// "spawn agent claude". Out of descriptors, the bare "Too many open files (os error 24)"
/// read like the agent's fault (cmux16, 2026-10-22): say it is the daemon's, with its limit
/// and what to do.
pub(crate) fn spawn_error(what: &str, e: std::io::Error) -> anyhow::Error {
    #[cfg(unix)]
    if matches!(e.raw_os_error(), Some(libc::EMFILE | libc::ENFILE)) {
        let mut lim = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
        let limit = if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut lim) } == 0 {
            format!(" (its limit is {})", lim.rlim_cur)
        } else {
            String::new()
        };
        return anyhow!(
            "{what}: the acpmux daemon is out of open files{limit}; \
             `acpmux daemon shutdown` stops it and the next acpmux command starts it again: {e}"
        );
    }
    anyhow::Error::new(e).context(what.to_owned())
}

#[cfg(all(test, unix))]
mod spawn_error_tests {
    use super::*;

    #[test]
    fn out_of_descriptors_says_it_is_the_daemon_and_what_to_do() {
        let error = spawn_error("start host", std::io::Error::from_raw_os_error(libc::EMFILE));
        let text = format!("{error:#}");
        assert!(text.starts_with("start host: the acpmux daemon is out of open files"), "{text}");
        assert!(text.contains("acpmux daemon shutdown"), "{text}");
        let other = spawn_error("start host", std::io::Error::from_raw_os_error(libc::ENOENT));
        assert!(format!("{other:#}").starts_with("start host: "), "{other:#}");
    }

    #[tokio::test]
    async fn direct_spawn_failure_does_not_expose_harness_argv() {
        const SENTINEL: &str = "argv-secret-must-not-leave-the-daemon";
        let profile: HarnessProfile = serde_json::from_value(serde_json::json!({
            "argv": ["/nonexistent/acpmux-test-harness", "--token", SENTINEL]
        }))
        .unwrap();
        let (inbound, _rx) = mpsc::channel(1);
        let tap: Tap = Arc::new(|_, _, _| true);
        let error =
            match ChildAgent::spawn("missing", &profile, &std::env::temp_dir(), inbound, tap).await
            {
                Ok(_) => panic!("a missing harness started"),
                Err(error) => error,
            };
        assert!(
            !error.to_string().contains(SENTINEL),
            "spawn failure exposed harness argv: {error:#}"
        );
    }
}
