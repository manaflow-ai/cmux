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
    /// One stderr line; `host_seq` names the agent host entry it came from.
    Stderr(String, Option<u64>),
    /// The agent process with this pid exited. The pid tells a late exit of
    /// a replaced process apart from the current one.
    Exited {
        pid: Option<u32>,
        code: Option<i32>,
        host_seq: Option<u64>,
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
        self.link.read().unwrap().clone()
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

struct Pending {
    map: HashMap<String, oneshot::Sender<Result<Value, RpcError>>>,
    /// Answers that arrived with nobody waiting (a replayed answer to a
    /// request of the previous daemon); `await_response` takes them.
    orphans: std::collections::VecDeque<(String, Result<Value, RpcError>)>,
}

const ORPHAN_ANSWERS: usize = 64;

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
    /// Present when the child speaks Claude's stream-json instead of ACP
    /// and runs directly under acpmux (a host owns its own translator).
    pub translator: Option<Arc<crate::claude_stdio::Translator>>,
    hosted: Option<Hosted>,
}

/// The harness command line and environment, as acpmux runs it: the login
/// environment, no nested-agent markers, the session's `ACPMUX_*` caller
/// context, and the profile's env. Shared by direct children and hosts.
pub(crate) fn harness_command(
    name: &str,
    profile: &HarnessProfile,
    cwd: &std::path::Path,
    command_line: Option<(String, Vec<String>)>,
    session: Option<(&str, &str)>,
) -> Result<Command> {
    // A session's Claude Code (a planned command line) gets cmux's browser
    // and computer use tools and skills (agent_tools.rs); a remote chain's
    // sandboxed plan carries --strict-mcp-config and gets none.
    let claude_session = profile.kind == crate::config::HarnessKind::ClaudeStdio
        && command_line.is_some()
        && session.is_some();
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
    if profile.kind == crate::config::HarnessKind::Terminal {
        return Err(anyhow!(
            "{name} is a terminal harness without ACP; open it with `cmux harness run {name}`"
        ));
    }
    let owned = if let (true, Some((session_id, _))) = (claude_session, session) {
        let extra = crate::agent_tools::claude_args_for(false, &profile.env, &owned.1, session_id);
        (owned.0, owned.1.into_iter().chain(extra).collect())
    } else {
        owned
    };
    let env = resolved_profile_env(profile)?;
    let (program, args) = (&owned.0, &owned.1);
    let mut cmd = Command::new(program);
    crate::login_env::apply_tokio(&mut cmd);
    crate::config::scrub_nested_claude_env_tokio(&mut cmd);
    // Caller context, herdr-style: the agent knows which session it is.
    for (k, _) in std::env::vars_os() {
        if k.to_string_lossy().starts_with("ACPMUX_") {
            cmd.env_remove(&k);
        }
    }
    // Helper tokens reach the cmux-cua MCP server through its own env only.
    crate::cua_socket::scrub_agent_env(&mut cmd);
    // A nested launch must not be taken for its parent's thread.
    cmd.env_remove("CODEX_THREAD_ID").env_remove("OMPCODE");
    if let Some((id, sname)) = session {
        cmd.env("ACPMUX_ENV", "1")
            .env("ACPMUX_SESSION_ID", id)
            .env("ACPMUX_SESSION_NAME", sname)
            .env("ACPMUX_SOCKET", crate::config::socket_path());
    }
    cmd.args(args)
        .envs(env.iter())
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
    Ok(cmd)
}

/// The profile's env with its `${keychain:…}` and `${env:…}` references
/// resolved (`config::profiles`). The secret store is asked only when a
/// value holds a reference; the lookup blocks, so a multi-thread runtime
/// moves it off its worker first.
fn resolved_profile_env(
    profile: &HarnessProfile,
) -> Result<std::collections::BTreeMap<String, String>> {
    let mut env = profile.env.clone();
    if !crate::config::profiles::has_env_refs(&env) {
        return Ok(env);
    }
    let resolve = |env: &mut std::collections::BTreeMap<String, String>| {
        crate::config::profiles::resolve_env_refs(
            env,
            &|var| crate::login_env::var(var).or_else(|| std::env::var(var).ok()),
            &crate::config::profiles::keychain_lookup,
        )
    };
    let multi_thread = tokio::runtime::Handle::try_current()
        .is_ok_and(|h| h.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread);
    let result = if multi_thread {
        tokio::task::block_in_place(|| resolve(&mut env))
    } else {
        resolve(&mut env)
    };
    result.map_err(|e| anyhow!(e))?;
    Ok(env)
}

/// The full environment `cmd` gives its child (inherited, then changed).
pub(crate) fn command_env(cmd: &Command) -> Vec<(String, String)> {
    let mut env: std::collections::BTreeMap<String, String> = std::env::vars().collect();
    for (k, v) in cmd.as_std().get_envs() {
        let k = k.to_string_lossy().into_owned();
        match v {
            Some(v) => {
                env.insert(k, v.to_string_lossy().into_owned());
            }
            None => {
                env.remove(&k);
            }
        }
    }
    env.into_iter().collect()
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
        let mut cmd = harness_command(name, profile, cwd, command_line, session)?;
        let mut child = cmd
            .spawn()
            .with_context(|| format!("spawn agent {name}: {}", profile.argv.join(" ")))?;
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
            pid,
            translator: translator.clone(),
            hosted: None,
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
                    let _ = inbound.send(Inbound::Stderr(line, None)).await;
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
                                if let Some(pg) = agent_for_exit.pid {
                                    unsafe {
                                        libc::killpg(pg as i32, libc::SIGKILL);
                                    }
                                }
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
                        let kind = format!(
                            "claude.{}{}",
                            raw.get("type").and_then(Value::as_str).unwrap_or("?"),
                            raw.get("subtype")
                                .and_then(Value::as_str)
                                .map(|s| format!(".{s}"))
                                .unwrap_or_default()
                        );
                        tap(Direction::In, &Message::notification(&kind, raw.clone()), None);
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
                        // Translated ACP messages go through the same tap as
                        // native ACP traffic, so the log and viewers see them.
                        for m in &translated {
                            if !matches!(m, Message::Response { .. }) {
                                tap(Direction::In, m, None);
                            }
                        }
                        translated
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
                                let _ =
                                    inbound.send(Inbound::Notification { method, params }).await;
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

    pub async fn kill(&self) {
        if self.hosted.is_some() {
            self.terminate(KILL_GRACE).await;
            return;
        }
        let mut guard = self.child.lock().await;
        // The saved group id, not `child.id()`: once the leader is reaped
        // that is None, and its background processes would survive.
        if let Some(pid) = self.pid {
            // TERM the whole group first so children get a chance to exit,
            // then KILL whatever is left. The wait ends as soon as the
            // agent exits; 300 ms is only the most it gets.
            unsafe {
                libc::killpg(pid as i32, libc::SIGTERM);
            }
            if let Some(child) = guard.as_mut() {
                let _ = tokio::time::timeout(KILL_GRACE, child.wait()).await;
            }
            unsafe {
                libc::killpg(pid as i32, libc::SIGKILL);
            }
        }
        if let Some(child) = guard.as_mut() {
            let _ = child.kill().await;
        }
        *guard = None;
    }

    /// Stop the agent within a bound: SIGTERM to its process group, wait up
    /// to `grace` for it to exit, then SIGKILL the group (stragglers
    /// included). Never waits on a lock or a pipe without a deadline.
    pub async fn terminate(&self, grace: std::time::Duration) {
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
        if let Some(pg) = pgid {
            unsafe {
                libc::killpg(pg, libc::SIGTERM);
            }
        }
        let _ = tokio::time::timeout(grace, async {
            // The exit watcher may hold this lock while it reaps, and frees
            // it once the child is gone; otherwise wait on the exit here.
            if let Some(child) = self.child.lock().await.as_mut() {
                let _ = child.wait().await;
            }
        })
        .await;
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

    /// Send a request and wait for its response.
    pub async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.map.insert(key(&Value::from(id)), tx);
        let msg = Message::request(id, method, params);
        if let Err(e) = self.write(&msg).await {
            self.pending.lock().await.map.remove(&key(&Value::from(id)));
            return Err(RpcError::internal(e.to_string()));
        }
        rx.await.unwrap_or_else(|_| Err(RpcError::internal("agent response channel dropped")))
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
        if let Some(i) = p.orphans.iter().position(|(k, _)| *k == key(&id)) {
            let (_, answer) = p.orphans.remove(i).expect("position is in range");
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
        *h.link.write().unwrap() = link.clone();
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
            pid: adopted.harness_pid,
            translator: None,
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
                if !(self.tap)(Direction::In, &m, Some(h)) {
                    return false;
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
                        let _ = inbound.send(Inbound::Notification { method, params }).await;
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
