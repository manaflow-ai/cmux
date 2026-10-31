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

/// Which pipe of an agent a line of `Inbound::Stderr` came from: its stderr, or a `[non-json
/// stdout]` note. The hub cleans each as its own stream.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum StderrPipe {
    Stderr,
    Stdout,
}

/// Something the agent sent that acpmux must act on.
#[derive(Debug)]
pub enum Inbound {
    Request {
        id: Id,
        method: String,
        params: Option<Value>,
        /// The hosted agent entry that carried this message, when durable.
        host_seq: Option<u64>,
        /// The host incarnation or direct child generation that owns this message.
        host_incarnation: Option<String>,
    },
    /// `agent` is the [`ChildAgent::generation`] it came from: the hub drops what an agent
    /// already replaced still had in flight where it would stand for the new one (a hosted
    /// agent has no pid of its own, so the pid cannot tell two of them apart).
    Notification {
        method: String,
        params: Option<Value>,
        agent: u64,
        /// The hosted agent entry that carried this message, when durable.
        host_seq: Option<u64>,
        /// The host incarnation or direct child generation that owns this message.
        host_incarnation: Option<String>,
        /// A hosted cancellation is acknowledged only after its durable
        /// withdrawal marker is stored. The reader owns the receiver.
        persisted: Option<oneshot::Sender<bool>>,
    },
    /// One stderr line of the agent of `agent` (its generation and which of its pipes); `host_seq`
    /// names the agent host entry it came from. A `[non-json stdout]` note is the agent's stdout.
    Stderr(String, Option<u64>, Option<(u64, StderrPipe)>),
    /// The agent process with this pid exited. The pid tells a late exit of
    /// a replaced process apart from the current one.
    Exited { pid: Option<u32>, code: Option<i32>, host_seq: Option<u64> },
    /// Answered once every item queued before it was handled. A prompt's answer
    /// bypasses this queue, so a turn sends one before it settles: the agent's
    /// last notifications (the reply text) are applied first.
    Barrier(tokio::sync::oneshot::Sender<()>),
    /// The history the agent of this generation replayed on `session/load` (or a fork's prime)
    /// is all in front of this: the session's preview takes that agent's words again
    /// (`ReplayHold` in `hub/lifecycle.rs`). Queued through the agent's own sender, behind
    /// everything its reader already queued.
    ReplayDone { agent: u64 },
    /// The reader of this generation's host link stopped: an entry could not be logged, or the
    /// link closed (the host died, or another owner took it), so what the host reports from there
    /// is not heard until a reattach. The hub's full-access bound treats such an agent as unheard
    /// (#23322).
    LinkBroken { agent: u64 },
}

/// Tests only: the agent generation `ChildAgent::replay_pending` reports as replaying.
#[cfg(test)]
pub(crate) static TEST_REPLAYING: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0);

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
    /// How far the host replays on this link (`learn_replay_end`): until `logged` reaches it, what
    /// the host kept while no reader logged it is not all in the session log. `u64::MAX` while it is
    /// not known (from a reattach or an adoption until it is learned, or for good when the host did
    /// not say).
    replay_to: std::sync::atomic::AtomicU64,
    /// The reader of the current link stopped otherwise (the link closed, or an acknowledgement
    /// failed while its socket still looked open): the agent is not heard through this link
    /// (`is_stopped`, review 68 of #23322); a reattach clears it. Under MDM's off only: with it
    /// unset the agent counts as alive as before (`is_alive`, review 1 of #26059).
    stopped: std::sync::atomic::AtomicBool,
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
pub(crate) const KILL_GRACE: std::time::Duration = std::time::Duration::from_millis(300);

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

/// This side's own error for a request whose agent or connection went: no answer of its agent.
pub(crate) const AGENT_CLOSED: &str = "agent process closed";

/// A request's error once its message was cut (`Fence::cut`) before it was written.
pub const FENCE_CUT: &str =
    "an MDM push turned full access off before this message reached the agent, so it was not sent";

/// One message's way to its agent: queued, being written, written (its agent's own stdin has
/// it: for a hosted agent, once its host wrote it to the harness, `WRITTEN_METHOD`), cut
/// while queued (never written after), or failed (its transport closed). A family message or
/// answer is held to it (`hub/full_access_bound.rs` `hold_until_written`).
#[derive(Clone)]
pub struct Fence(Arc<FenceState>);

struct FenceState {
    step: tokio::sync::watch::Sender<u8>,
    /// The agent whose writer takes it (`ChildAgent::write_fenced`): the one a cut ends while
    /// it writes it (`Fence::cut_or_end`).
    writer: std::sync::OnceLock<Writer>,
    /// A hosted writer's end that outlived its bound (`Fence::cut_or_end`), awaited again by the
    /// next try, never started twice.
    ending: std::sync::Mutex<Option<tokio::task::JoinHandle<bool>>>,
}

/// Who writes a fenced message, by an identity a cut can prove before it ends it (review 82 of
/// #23322): never a bare process id, which a reaped process gives up.
enum Writer {
    /// A direct child: its own slot, whose lock its reaper takes too, its process group, and
    /// its stdin writer.
    Direct {
        child: std::sync::Weak<Mutex<Option<Child>>>,
        pid: Option<u32>,
        stop: Option<WriterStop>,
    },
    /// A hosted agent: its host, proven by its start nonce's live lock.
    Hosted(crate::agent_host::HostRecord),
    /// A host of this session (of every session: `None`) an adoption could not resolve
    /// (`agent_host::unresolved`).
    Unresolved(Option<String>),
}

impl std::fmt::Debug for Fence {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("Fence").field(&*self.0.step.borrow()).finish()
    }
}

impl Default for Fence {
    fn default() -> Self {
        let step = tokio::sync::watch::channel(Self::QUEUED).0;
        let (writer, ending) = (std::sync::OnceLock::new(), std::sync::Mutex::new(None));
        Self(Arc::new(FenceState { step, writer, ending }))
    }
}

impl Fence {
    const QUEUED: u8 = 0;
    const WRITING: u8 = 1;
    const WRITTEN: u8 = 2;
    const CUT: u8 = 3;
    const FAILED: u8 = 4;

    fn step(&self, from: u8, to: u8) -> bool {
        self.0.step.send_if_modified(|s| {
            let now = *s == from;
            if now {
                *s = to;
            }
            now
        })
    }

    fn now(&self) -> u8 {
        *self.0.step.borrow()
    }

    /// A fenced line a previous daemon handed to `host`, held again at adoption
    /// (`link::adopt_receipt`): its host has it, so only its receipt or its host's end settles
    /// it, and a cut ends that host (`Self::cut_or_end`).
    pub fn held_by_host(host: crate::agent_host::HostRecord) -> Self {
        Self::taken_by(Writer::Hosted(host))
    }

    /// What a host of `session` (of every session: `None`) an adoption could not resolve may
    /// still write (`agent_host::unresolved`): only a cut settles it, once that proves no such
    /// host lives (fail closed).
    pub fn unresolved(session: Option<String>) -> Self {
        Self::taken_by(Writer::Unresolved(session))
    }

    fn taken_by(writer: Writer) -> Self {
        let fence = Self::default();
        let _ = fence.0.writer.set(writer);
        fence.begin();
        fence
    }

    /// The writer takes it: false when it was cut, and it is dropped.
    pub fn begin(&self) -> bool {
        self.step(Self::QUEUED, Self::WRITING) || self.now() != Self::CUT
    }

    /// The writer wrote it.
    pub fn written(&self) {
        self.step(Self::WRITING, Self::WRITTEN);
    }

    /// The writer could not write it: its transport closed, so it never reaches the agent.
    pub fn failed(&self) {
        self.step(Self::WRITING, Self::FAILED);
    }

    /// Makes sure it is not written after this: false while the writer is writing it.
    pub fn cut(&self) -> bool {
        self.step(Self::QUEUED, Self::CUT) || self.now() != Self::WRITING
    }

    /// Resolves once it is written, cut or failed. A holder keeps its own `Fence`, so this
    /// never resolves only because a carrier let go of it (review 82 of #23322): every carrier
    /// settles it (a writer that stops cuts what it still queues; a host's end fails what it
    /// had, `link::settle_receipts_of`).
    pub fn settled(&self) -> impl Future<Output = ()> + use<> {
        let mut rx = self.0.step.subscribe();
        async move {
            let _ = rx.wait_for(|s| *s >= Self::WRITTEN).await;
        }
    }

    /// Whether it is settled: written, cut or failed.
    pub fn is_settled(&self) -> bool {
        self.now() >= Self::WRITTEN
    }

    /// Whether it was cut while queued: never written.
    pub fn is_cut(&self) -> bool {
        self.now() == Self::CUT
    }

    /// Resolves once it left the queue: its writer took it, or it was cut or settled. Only a
    /// queued message can be cut (`Self::cut`).
    pub fn taken(&self) -> impl Future<Output = ()> + use<> {
        let mut rx = self.0.step.subscribe();
        async move {
            let _ = rx.wait_for(|s| *s != Self::QUEUED).await;
        }
    }

    /// Resolves once it is cut.
    async fn was_cut(&self) {
        let _ = self.0.step.subscribe().wait_for(|s| *s == Self::CUT).await;
    }

    /// [`Self::cut`], and while its writer has it, that agent ends first, within about
    /// `budget` per step and never through a chat's agent slot (review 81 of #23322): a direct
    /// child's writer stops, then its group is signalled only while its leader is unreaped under
    /// its slot's lock; a hosted one by its host's start nonce and live lock
    /// (`terminate_unadoptable`), one try at a time, each bounded (review 87). True once
    /// the message can not reach the agent after this; false when that is not proven in time,
    /// and the caller, which must not let go before it is proven, tries again.
    pub async fn cut_or_end(&self, budget: std::time::Duration) -> bool {
        if self.cut() {
            return true;
        }
        match self.0.writer.get() {
            Some(Writer::Direct { child, pid, stop }) => {
                let ended = end_direct(child, *pid, stop.as_ref(), budget).await;
                if ended {
                    self.failed();
                }
                ended
            }
            Some(Writer::Hosted(record)) => {
                let running = self.0.ending.lock().unwrap_or_else(|e| e.into_inner()).take();
                let mut ending = running.unwrap_or_else(|| end_hosted(record.clone()));
                let Ok(ended) = tokio::time::timeout(budget * 4, &mut ending).await else {
                    *self.0.ending.lock().unwrap_or_else(|e| e.into_inner()) = Some(ending);
                    return false;
                };
                let ended = ended.unwrap_or(false);
                if ended {
                    crate::agent_host::link::settle_receipts_of(&record.incarnation);
                }
                ended
            }
            Some(Writer::Unresolved(session)) => {
                let running = self.0.ending.lock().unwrap_or_else(|e| e.into_inner()).take();
                let mut ending = running.unwrap_or_else(|| end_unresolved(session.clone()));
                let Ok(ended) = tokio::time::timeout(budget * 4, &mut ending).await else {
                    *self.0.ending.lock().unwrap_or_else(|e| e.into_inner()) = Some(ending);
                    return false;
                };
                let ended = ended.unwrap_or(false);
                if ended {
                    self.failed();
                }
                ended
            }
            None => false,
        }
    }
}

/// Ends the direct child behind `child` (`Fence::cut_or_end`): its writer stops, so nothing more
/// of the message reaches its stdin; then its process group is signalled only while its leader
/// is unreaped and its slot is locked, so the group is still its own.
async fn end_direct(
    child: &std::sync::Weak<Mutex<Option<Child>>>,
    pid: Option<u32>,
    stop: Option<&WriterStop>,
    budget: std::time::Duration,
) -> bool {
    // On every platform, and also when its leader is gone and a descendant kept its stdin
    // (review 87 of #23322).
    if let Some(stop) = stop {
        stop.abort.abort();
        let mut ended = stop.ended.clone();
        if tokio::time::timeout(budget, ended.wait_for(|e| *e)).await.is_err() {
            return false;
        }
    }
    // The agent is gone: its child was killed when it went (`kill_on_drop`).
    let Some(slot) = child.upgrade() else { return true };
    // Its reaper holds the slot while it reaps (`wait_exit`), at most its own bound.
    let Ok(mut slot) = tokio::time::timeout(budget * 2, slot.lock()).await else { return false };
    let Some(child) = slot.as_mut() else { return true };
    // Exited (now reaped): its group may be another's now, so it is not signalled; its writer
    // stopped above, so a descendant that kept its stdin gets nothing more of the message. A
    // failed check proves neither, so the caller tries again (review 87).
    match child.try_wait() {
        Ok(Some(_)) => return true,
        Ok(None) => {}
        Err(_) => return false,
    }
    #[cfg(unix)]
    if let Some(pg) = pid {
        // SAFETY: its leader is unreaped and its slot is locked here, so the group is its own.
        unsafe { libc::killpg(pg as i32, libc::SIGKILL) };
    }
    #[cfg(not(unix))]
    let _ = pid;
    let _ = child.start_kill();
    tokio::time::timeout(budget, child.wait()).await.is_ok()
}

/// Ends the host behind `record` (`Fence::cut_or_end`) by its start nonce: proven by its live
/// lock (`terminate_unadoptable`), with its harness. Its caller bounds the wait.
/// [`crate::agent_host::unresolved::end_unresolved`], off the runtime.
fn end_unresolved(session: Option<String>) -> tokio::task::JoinHandle<bool> {
    tokio::task::spawn_blocking(move || {
        crate::agent_host::unresolved::end_unresolved(session.as_deref())
    })
}

fn end_hosted(record: crate::agent_host::HostRecord) -> tokio::task::JoinHandle<bool> {
    tokio::task::spawn_blocking(move || {
        for dir in crate::agent_host::live_lock_dirs(&record) {
            if crate::agent_host::live_lock_exists(&dir, &record.session_id, &record.start_nonce) {
                return crate::agent_host::terminate_unadoptable(
                    &dir,
                    &record.session_id,
                    Some(&record.start_nonce),
                    Some(record.host_pid),
                )
                .unwrap_or(false);
            }
        }
        // No live lock: the host ended and its lock went with it.
        true
    })
}

/// A direct agent's stdin writer, which a cut stops (`Fence::cut_or_end`): `ended` turns true
/// once it stopped, after which nothing more of a message reaches its stdin. `writing` is the
/// fence of the message it is writing.
#[derive(Clone)]
struct WriterStop {
    abort: tokio::task::AbortHandle,
    ended: tokio::sync::watch::Receiver<bool>,
    writing: Arc<std::sync::Mutex<Option<Fence>>>,
}

impl WriterStop {
    /// Its agent ended: the writer stops, and the message it was writing, which a descendant
    /// that kept its stdin may never read, fails, so no holder waits on it for ever (review 87
    /// of #23322).
    async fn agent_ended(&self) {
        self.abort.abort();
        let mut ended = self.ended.clone();
        if tokio::time::timeout(LEADER_DRAIN, ended.wait_for(|e| *e)).await.is_ok() {
            let writing = self.writing.lock().unwrap_or_else(|e| e.into_inner()).take();
            if let Some(f) = writing {
                f.failed();
            }
        }
    }
}

/// A direct agent's stdin queue (`ChildAgent::spawn`): once its writer stops, also by a cut, what
/// it still queues is cut (or failed, once a translator took it), so no holder waits on it, and
/// `WriterStop::ended` turns true.
struct WriterQueue(mpsc::Receiver<(String, Option<Fence>)>, tokio::sync::watch::Sender<bool>);

impl Drop for WriterQueue {
    fn drop(&mut self) {
        self.0.close();
        while let Ok((_, fence)) = self.0.try_recv() {
            // One a translator took is never written now (`ChildAgent::hand_on`).
            if let Some(f) = fence
                && !f.cut()
            {
                f.failed();
            }
        }
        self.1.send_replace(true);
    }
}

/// Cuts its fence when dropped (`ChildAgent::request_with_hook`, `hub/subsession_answer.rs`),
/// unless it was let go.
pub(crate) struct CutOnDrop<'a>(pub(crate) Option<&'a Fence>);

impl Drop for CutOnDrop<'_> {
    fn drop(&mut self) {
        if let Some(f) = self.0 {
            f.cut();
        }
    }
}

/// Settles its fence when dropped (`ChildAgent::write_fenced`), unless it was handed on: cut
/// while queued, or failed once a translator took it (`ChildAgent::hand_on`).
struct Unsent<'a>(Option<&'a Fence>);

impl Drop for Unsent<'_> {
    fn drop(&mut self) {
        if let Some(f) = self.0
            && !f.cut()
        {
            f.failed();
        }
    }
}

/// Tests only: a pause in an agent's stdin writer at the first line holding `.0`, as a
/// transport that stops taking input: before the writer takes the line, or (`.1`) once it took
/// it and is writing it. `.2` fires there, the line waits for `.3`.
#[cfg(test)]
pub(crate) type InputSeam =
    Arc<std::sync::Mutex<Option<(String, bool, oneshot::Sender<()>, oneshot::Receiver<()>)>>>;

#[cfg(test)]
async fn pause_input(seam: &InputSeam, line: &str, writing: bool) {
    let hit = {
        let mut seam = seam.lock().unwrap_or_else(|e| e.into_inner());
        let ours =
            seam.as_ref().is_some_and(|(p, w, ..)| *w == writing && line.contains(p.as_str()));
        if ours { seam.take() } else { None }
    };
    if let Some((_, _, arrived, release)) = hit {
        let _ = arrived.send(());
        let _ = release.await;
    }
}

/// How acpmux started a harness: its argv, the part of its environment that decides which MCP
/// configs it reads and which program a name runs, and its folder (`hub/idle_census.rs`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Launch {
    pub args: Vec<String>,
    pub env: std::collections::BTreeMap<String, String>,
    pub cwd: std::path::PathBuf,
}

impl Launch {
    const ENV: [&str; 4] = ["PATH", "HOME", "CLAUDE_CONFIG_DIR", "CODEX_HOME"];

    /// From a spawn's program, args, full environment and folder.
    pub fn new(
        program: &str,
        args: &[String],
        env: &[(String, String)],
        cwd: &std::path::Path,
    ) -> Self {
        let args = std::iter::once(program.to_owned()).chain(args.iter().cloned()).collect();
        let env = env.iter().filter(|(k, _)| Self::ENV.contains(&k.as_str())).cloned().collect();
        Launch { args, env, cwd: cwd.to_path_buf() }
    }

    /// From the command a direct child runs.
    fn of(cmd: &tokio::process::Command, cwd: &std::path::Path) -> Self {
        let std = cmd.as_std();
        let args: Vec<String> = std.get_args().map(|a| a.to_string_lossy().into_owned()).collect();
        Self::new(&std.get_program().to_string_lossy(), &args, &command_env(cmd), cwd)
    }
}

pub struct ChildAgent {
    pub name: String,
    /// Shared with the fences its writer takes (`Writer::Direct`, a weak reference).
    child: Arc<Mutex<Option<Child>>>,
    stdin_tx: mpsc::Sender<(String, Option<Fence>)>,
    /// Its direct stdin writer, which a cut stops (`WriterStop`); unset for a hosted agent.
    writer_stop: std::sync::OnceLock<WriterStop>,
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
    /// The `mcpServers` acpmux gave it at its session/new or load (`spawn.rs` `acp_params`), for
    /// the idle census (`hub/idle_census.rs`). None for an agent adopted from another daemon.
    pub given_servers: std::sync::Mutex<Option<Value>>,
    /// The MCP servers its harness's configs named as it started (`LaunchServers::read`, before
    /// it started), for the idle census. None for a harness another daemon started.
    pub(crate) launch: std::sync::Mutex<Option<crate::hub::LaunchServers>>,
    /// Set once the agent is replaced or stopped (`retire`): a /context answer it still sends
    /// is not the chat's context any more, and is neither logged nor handed to the hub. A lock,
    /// not a flag: the reader holds it while it checks and logs such an answer (`tap_live`), so a
    /// failover that retires the agent and then logs itself can never land between the two.
    retired: std::sync::Mutex<bool>,
    /// Set once acpmux ends the agent on purpose (MDM's off, `end_managed_full_access`): its
    /// turn's end leaves the chat idle and no failover runs its prompt again (review 3 of #26034).
    ended_on_purpose: std::sync::atomic::AtomicBool,
    /// The question preview format its command was pinned to, for a direct
    /// start (a host's is recorded where the host starts, `hub/hosts.rs`).
    pub preview_format: Option<crate::hub::questions::PreviewFormat>,
    /// The CPU class its harness runs at once its session's start is over (`cpu_class.rs`), set
    /// by the start that spawned it; unset for a harness another daemon started.
    run_class: std::sync::OnceLock<crate::cpu_class::CpuClass>,
    /// Its harness was put in `run_class` (once).
    run_class_entered: std::sync::atomic::AtomicBool,
    /// Tests only: a pause in its stdin writer (`InputSeam`).
    #[cfg(test)]
    pub(crate) input_seam: InputSeam,
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
    /// Direct children have no durable host record, but requests must still
    /// belong to one process generation when a replacement reuses their ids.
    fn direct_incarnation(&self) -> String {
        format!("direct:{}", self.generation)
    }

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
        // A delivery may have updated or removed the machine's secrets since
        // daemon startup. Never build a process env from stale cached values.
        anyhow::ensure!(
            crate::login_env::machine_env_fresh_before_spawn().await,
            "machine environment changed; login env refresh failed"
        );
        let mut cmd = harness_command(name, profile, cwd, command_line, session)?;
        // Its MCP configs are read before it starts, never after (`hub/idle_census.rs`).
        let launch = crate::hub::LaunchServers::read(
            &Launch::of(&cmd, cwd),
            crate::config::derive_family(name, profile),
        )
        .await;
        let preview_format = Some(pinned_preview_format(&cmd));
        #[cfg(windows)]
        cmd.creation_flags(crate::job::AGENT_FLAGS);
        // Never at background class while it starts; its class, from the harness's own env (its
        // profile's value as resolved), is set once its session's start is over (`cpu_class.rs`).
        let env = command_env(&cmd);
        let run_class = crate::cpu_class::CpuClass::for_session(
            env.iter().map(|(k, v)| (k.as_str(), v.as_str())),
        );
        crate::cpu_class::start_at_normal(&mut cmd);
        let mut child = cmd.spawn().map_err(|e| spawn_error(&format!("spawn agent {name}"), e))?;
        // Not at a background class another process set on this daemon (`cpu_class.rs`, item 1):
        // the child is held and not reaped, so its pid is its own.
        if let Some(pid) = child.id() {
            crate::cpu_class::clear_running(pid);
        }
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

        let (stdin_tx, stdin_rx) = mpsc::channel::<(String, Option<Fence>)>(256);
        let pending =
            Arc::new(Mutex::new(Pending { map: HashMap::new(), orphans: Default::default() }));
        let agent = Arc::new(Self {
            name: name.to_owned(),
            child: Arc::new(Mutex::new(Some(child))),
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
            given_servers: std::sync::Mutex::new(None),
            launch: std::sync::Mutex::new(Some(launch)),
            retired: std::sync::Mutex::new(false),
            ended_on_purpose: std::sync::atomic::AtomicBool::new(false),
            generation: NEXT_GENERATION.fetch_add(1, Ordering::Relaxed),
            preview_format,
            run_class: std::sync::OnceLock::from(run_class),
            run_class_entered: std::sync::atomic::AtomicBool::new(false),
            writer_stop: std::sync::OnceLock::new(),
            #[cfg(test)]
            input_seam: InputSeam::default(),
            #[cfg(windows)]
            job,
        });

        #[cfg(test)]
        let seam = agent.input_seam.clone();
        let (ended_tx, ended) = tokio::sync::watch::channel(false);
        let writing = Arc::new(std::sync::Mutex::new(None));
        let in_flight = writing.clone();
        // Made before the writer runs, so a writer stopped before its first poll still settles
        // what it queues (review 87 of #23322).
        let mut queue = WriterQueue(stdin_rx, ended_tx);
        let writer = tokio::spawn(async move {
            let mut stdin = stdin;
            while let Some((line, fence)) = queue.0.recv().await {
                #[cfg(test)]
                pause_input(&seam, &line, false).await;
                if fence.as_ref().is_some_and(|f| !f.begin()) {
                    continue;
                }
                if let Some(f) = &fence {
                    *in_flight.lock().unwrap_or_else(|e| e.into_inner()) = Some(f.clone());
                }
                #[cfg(test)]
                pause_input(&seam, &line, true).await;
                if stdin.write_all(line.as_bytes()).await.is_err() || stdin.flush().await.is_err() {
                    if let Some(f) = fence {
                        f.failed();
                    }
                    break;
                }
                in_flight.lock().unwrap_or_else(|e| e.into_inner()).take();
                if let Some(f) = fence {
                    f.written();
                }
            }
        });
        let _ = agent.writer_stop.set(WriterStop { abort: writer.abort_handle(), ended, writing });

        // The app-server's initialize goes out at spawn, before the hub's.
        if let Some(cx) = &agent.codex {
            let first = crate::codex_app_server::split(cx.tr.start());
            agent.codex_lines(first.server, None).await;
        }

        let stderr_done = {
            let inbound = inbound.clone();
            let generation = agent.generation;
            tokio::spawn(async move {
                let mut lines = BufReader::new(stderr).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let _ = inbound
                        .send(Inbound::Stderr(line, None, Some((generation, StderrPipe::Stderr))))
                        .await;
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
                // The carry whose hold was waited out (`claude_stdio/carry.rs`): once per carry.
                let mut held: Option<u64> = None;
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
                                        Some((agent_for_exit.generation, StderrPipe::Stdout)),
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
                            let _ = agent_for_exit.stdin_tx.send((s, None)).await;
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
                                        Some((agent_for_exit.generation, StderrPipe::Stdout)),
                                    ))
                                    .await;
                                continue;
                            }
                        };
                        if let Some(kind) = crate::codex_app_server::tap_kind(&raw) {
                            let safe = crate::codex_app_server::redact(&raw);
                            tap(Direction::In, &Message::notification(&kind, safe), None);
                        }
                        let order = cx.order.lock().await;
                        let split = crate::codex_app_server::split(cx.tr.from_server(&raw));
                        agent_for_exit.codex_lines(split.server, None).await;
                        drop(order);
                        for m in &split.hub {
                            if !matches!(m, Message::Response { .. }) {
                                let safe = crate::codex_app_server::redact(&m.to_value());
                                if let Ok(safe) = Message::from_value(safe) {
                                    tap(Direction::In, &safe, None);
                                }
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
                                        Some((agent_for_exit.generation, StderrPipe::Stdout)),
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
                                let _ = inbound
                                    .send(Inbound::Request {
                                        id,
                                        method,
                                        params,
                                        host_seq: None,
                                        host_incarnation: Some(agent_for_exit.direct_incarnation()),
                                    })
                                    .await;
                            }
                            Message::Notification { method, params } => {
                                let _ = inbound
                                    .send(Inbound::Notification {
                                        method,
                                        params,
                                        agent: agent_for_exit.generation,
                                        host_seq: None,
                                        host_incarnation: Some(agent_for_exit.direct_incarnation()),
                                        persisted: None,
                                    })
                                    .await;
                            }
                        }
                    }
                    // Claude Code ended its turn and runs on with steers it had not read: its next
                    // line waits until the hub logged that turn's end and the next one's start
                    // (the next turn's prompt), bounded (`claude_stdio/carry.rs`).
                    // Each carry holds once, also one made while an earlier one still holds.
                    let tr = agent_for_exit.translator.as_ref();
                    let holding = tr.and_then(|tr| tr.holding().map(|carry| (tr, carry)));
                    match holding {
                        Some((tr, carry)) if held != Some(carry) => {
                            tr.wait_unheld(crate::claude_stdio::CARRY_HOLD_MAX).await;
                            held = Some(carry);
                        }
                        Some(_) => {}
                        None => held = None,
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
                                    host_seq: None,
                                    host_incarnation: Some(agent_for_exit.direct_incarnation()),
                                    persisted: None,
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
                    let _ = tx.send(Err(RpcError::internal(AGENT_CLOSED)));
                }
                drop(p);
                let code = agent_for_exit.wait_exit().await;
                if let Some(stop) = agent_for_exit.writer_stop.get() {
                    stop.agent_ended().await;
                }
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

    /// Mark the agent ended on purpose ([`Self::ended_on_purpose`]).
    pub fn end_on_purpose(&self) {
        self.ended_on_purpose.store(true, Ordering::SeqCst);
    }

    /// Whether [`Self::end_on_purpose`] ran.
    pub fn ended_on_purpose(&self) -> bool {
        self.ended_on_purpose.load(Ordering::SeqCst)
    }

    /// Fails every request still waiting on this agent: it was ended, and no exit may be read for
    /// it (a host whose reader stopped, #23322 review 65). A request already answered is not here.
    pub async fn fail_pending(&self) {
        let mut p = self.pending.lock().await;
        for (_, tx) in p.map.drain() {
            let _ = tx.send(Err(RpcError::internal(AGENT_CLOSED)));
        }
    }

    /// `fail_pending` while this agent's link is still broken or stopped: a reattach clears those
    /// under the same lock, so a late notice of an old link never fails the open requests of the
    /// link that replaced it (review 2 of #26059).
    pub async fn fail_pending_if_unheard(&self) {
        let mut p = self.pending.lock().await;
        if !self.is_broken() && !self.is_stopped() {
            return;
        }
        for (_, tx) in p.map.drain() {
            let _ = tx.send(Err(RpcError::internal("agent process closed")));
        }
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
        self.write_fenced(msg, None).await
    }

    /// [`Self::write`], `fence` held to it: one line (or frame) each, so a cut drops it whole.
    async fn write_fenced(&self, msg: &Message, fence: Option<&Fence>) -> Result<()> {
        if let Some(f) = fence {
            let _ = f.0.writer.set(match &self.hosted {
                Some(h) => Writer::Hosted(h.link().record.clone()),
                None => Writer::Direct {
                    child: Arc::downgrade(&self.child),
                    pid: self.pid,
                    stop: self.writer_stop.get().cloned(),
                },
            });
        }
        // Not handed to a writer (an error, or dropped while it waits for room): it is never
        // written, also once a translator took it (review 87 of #23322).
        let mut unsent = Unsent(fence);
        let handed = self.hand_on(msg, fence).await;
        if handed.is_ok() {
            unsent.0 = None;
        }
        handed
    }

    async fn hand_on(&self, msg: &Message, fence: Option<&Fence>) -> Result<()> {
        if let Some(h) = &self.hosted {
            // The host writes it and logs it back as an `out` entry.
            return h.link().line_fenced(msg.to_value(), fence.cloned()).await;
        }
        // A translator's state moves on with what it translates (Claude's permission asks, the
        // app-server's approvals), so a message it takes is as good as taken: never cut while
        // queued, which could leave its agent waiting on an ask the translator let go of; a cut
        // ends that agent instead (review 88 of #23322).
        if (self.codex.is_some() || self.translator.is_some()) && fence.is_some_and(|f| !f.begin())
        {
            return Err(anyhow!("agent {}: {FENCE_CUT}", self.name));
        }
        if let Some(cx) = &self.codex {
            let safe = crate::codex_app_server::redact(&msg.to_value());
            let safe_message = Message::from_value(safe).unwrap_or_else(|_| msg.clone());
            (self.tap)(Direction::Out, &safe_message, None);
            let order = cx.order.lock().await;
            let split = crate::codex_app_server::split(cx.tr.from_client(&msg.to_value()));
            let written = self.codex_lines(split.server, fence).await;
            drop(order);
            if !written {
                return Err(anyhow!("agent {} stdin closed", self.name));
            }
            self.codex_to_hub(cx, split.hub).await;
            return Ok(());
        }
        (self.tap)(Direction::Out, msg, None);
        if let Some(tr) = &self.translator {
            match tr.outbound(msg).await {
                crate::claude_stdio::Outbound::Lines(lines) => {
                    self.claude_lines(lines, fence).await
                }
                crate::claude_stdio::Outbound::Reply(reply) => {
                    if let Some(f) = fence.filter(|f| f.begin()) {
                        f.written();
                    }
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
                .send((msg.to_line(), fence.cloned()))
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
                    let _ = cx
                        .inbound
                        .send(Inbound::Request {
                            id,
                            method,
                            params,
                            host_seq: None,
                            host_incarnation: Some(self.direct_incarnation()),
                        })
                        .await;
                }
                Message::Notification { method, params } => {
                    let _ = cx
                        .inbound
                        .send(Inbound::Notification {
                            method,
                            params,
                            host_seq: None,
                            host_incarnation: Some(self.direct_incarnation()),
                            persisted: None,
                            agent: self.generation,
                        })
                        .await;
                }
            }
        }
    }

    /// Writes the Claude translator's stream-json lines to the agent's stdin, each logged.
    async fn claude_lines(&self, lines: Vec<Value>, fence: Option<&Fence>) -> Result<()> {
        // Nothing for the agent (a late answer to a withdrawn elicitation): nothing is queued,
        // as before the fence (review 82 of #23322), and a fenced one is settled.
        if lines.is_empty() {
            if let Some(f) = fence.filter(|f| f.begin()) {
                f.written();
            }
            return Ok(());
        }
        let mut s = String::new();
        for l in lines {
            (self.tap)(Direction::Out, &Message::notification("claude.stdin", l.clone()), None);
            s.push_str(&format!("{l}\n"));
        }
        self.stdin_tx
            .send((s, fence.cloned()))
            .await
            .map_err(|_| anyhow!("agent {} stdin closed", self.name))
    }

    /// Writes translator lines to the app-server's stdin, each logged.
    /// Returns false once stdin is closed.
    async fn codex_lines(&self, lines: Vec<Value>, fence: Option<&Fence>) -> bool {
        // Nothing for the app-server (the translator answered itself): nothing is queued, so
        // this never waits on a full stdin (review 81 of #23322), and a fenced message is
        // settled, as nothing of it is left to write.
        if lines.is_empty() {
            if let Some(f) = fence.filter(|f| f.begin()) {
                f.written();
            }
            return true;
        }
        let mut s = String::new();
        for l in lines {
            let safe = crate::codex_app_server::redact(&l);
            (self.tap)(
                Direction::Out,
                &Message::notification(crate::codex_app_server::STDIN_KIND, safe),
                None,
            );
            s.push_str(&crate::codex_app_server::line(&l));
        }
        self.stdin_tx.send((s, fence.cloned())).await.is_ok()
    }

    /// Queue [`Inbound::ReplayDone`] behind what the reader queued so far, waiting for room.
    /// False when the queue is closed.
    pub async fn queue_replay_done(&self) -> bool {
        self.inbound.send(Inbound::ReplayDone { agent: self.generation }).await.is_ok()
    }

    /// Send a request and wait for its response.
    pub async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        self.request_with_hook(method, params, None, || {}).await
    }

    /// Send a request and run `on_written` only after its frame reached the agent write path.
    /// Used by first-message title generation to start beside the turn, after the harness can
    /// publish its own session title. `fence`: held to the request's write; once cut, the
    /// request fails.
    pub async fn request_with_hook<F: FnOnce()>(
        &self,
        method: &str,
        params: Value,
        fence: Option<&Fence>,
        on_written: F,
    ) -> Result<Value, RpcError> {
        self.request_hook(method, params, fence, false, on_written).await
    }

    /// Like `request_with_hook`, but the callback requires confirmation from the stdin writer
    /// (or hosted harness receipt), not acceptance into the transport queue.
    pub(crate) async fn request_with_confirmed_hook<F: FnOnce()>(
        &self,
        method: &str,
        params: Value,
        fence: Option<&Fence>,
        on_written: F,
    ) -> Result<Value, RpcError> {
        let own_fence = Fence::default();
        let fence = fence.unwrap_or(&own_fence);
        let _unsent = CutOnDrop(Some(fence));
        self.request_hook(method, params, Some(fence), true, on_written).await
    }

    async fn request_hook<F: FnOnce()>(
        &self,
        method: &str,
        params: Value,
        fence: Option<&Fence>,
        confirmed: bool,
        on_written: F,
    ) -> Result<Value, RpcError> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.map.insert(key(&Value::from(id)), tx);
        let msg = Message::request(id, method, params);
        let answer = async {
            // Dropped before its message is handed on (a turn that ends first): it is cut, so
            // no holder waits on it.
            let mut unhanded = CutOnDrop(fence);
            self.write_fenced(&msg, fence).await.map_err(|e| RpcError::internal(e.to_string()))?;
            unhanded.0 = None;
            let mut rx = rx;
            if confirmed && let Some(fence) = fence {
                // A legacy host may answer without a write receipt. Return its answer, but
                // never consume information or report read from an unconfirmed transport.
                tokio::select! {
                    () = fence.settled() => {}
                    answer = &mut rx => {
                        if fence.now() == Fence::WRITTEN { on_written(); }
                        return answer.unwrap_or_else(|_| Err(RpcError::internal("agent response channel dropped")));
                    }
                }
                if fence.now() != Fence::WRITTEN {
                    return Err(RpcError::internal(
                        "agent process closed before the prompt write was confirmed",
                    ));
                }
            }
            on_written();
            let answer = rx.await;
            // No answer proves its line was written: an error may be this side's own "closed" or
            // made up by a translator once its harness's output ended, and a translator answers
            // prompts it gave up on too (Claude's `cancelled`). A direct agent's writer, a host's
            // receipt or its end settle it (review 87 of #23322).
            answer.unwrap_or_else(|_| Err(RpcError::internal("agent response channel dropped")))
        };
        let cut = async {
            match fence {
                Some(f) => f.was_cut().await,
                None => std::future::pending().await,
            }
        };
        let answer = tokio::select! {
            answer = answer => answer,
            () = cut => Err(RpcError::internal(FENCE_CUT)),
        };
        if answer.is_err() {
            // Not written by now, it never is: its answer is not awaited.
            if let Some(f) = fence {
                f.cut();
            }
            self.pending.lock().await.map.remove(&key(&Value::from(id)));
        }
        answer
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
        self.respond_fenced(id, result, None).await
    }

    /// [`Self::respond`], `fence` held to the answer's write.
    pub async fn respond_fenced(
        &self,
        id: Id,
        result: Result<Value, RpcError>,
        fence: Option<&Fence>,
    ) -> Result<()> {
        let msg = match result {
            Ok(v) => Message::ok(id, v),
            Err(e) => Message::err(id, e),
        };
        self.write_fenced(&msg, fence).await
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

    /// The CPU class its harness runs at once its session's start is over (`cpu_class.rs`): the
    /// start that attached a hosted harness sets it (a direct one has it from its spawn). Only
    /// the first value counts.
    pub fn set_run_class(&self, class: crate::cpu_class::CpuClass) {
        let _ = self.run_class.set(class);
    }

    /// Its session's start is over: its harness goes to its run class, once (`cpu_class.rs`).
    /// True when this call lowered it. A harness with no class set (another daemon started it)
    /// or one that ended is left alone.
    pub async fn enter_run_class(&self) -> bool {
        let Some(class) = self.run_class.get().copied() else { return false };
        if self.run_class_entered.swap(true, Ordering::SeqCst) {
            return false;
        }
        self.with_live_harness(|pid| class.enter(pid)).await.unwrap_or(false)
    }

    /// What its harness is doing now (`cpu_class::HarnessSeen`): ended, unread or its state.
    pub async fn harness_seen(&self) -> crate::cpu_class::HarnessSeen {
        use crate::cpu_class::HarnessSeen;
        match self.with_live_harness(crate::cpu_class::harness_state).await {
            None => HarnessSeen::Ended,
            Some(None) => HarnessSeen::Unread,
            Some(Some(state)) => HarnessSeen::Running(state),
        }
    }

    /// `f` of its harness's pid while that pid is still its harness: a direct child not reaped
    /// (its slot locked across `f`, so no reap can free the pid meanwhile), or a hosted one its
    /// host has not reported ended. None otherwise.
    async fn with_live_harness<T>(&self, f: impl FnOnce(u32) -> T) -> Option<T> {
        let pid = self.pid?;
        if self.hosted.is_some() {
            return self.is_alive().await.then(|| f(pid));
        }
        let mut guard = self.child.lock().await;
        let child = guard.as_mut()?;
        matches!(child.try_wait(), Ok(None)).then(|| f(pid))
    }

    /// The host record when this agent runs under a host.
    pub fn host_record(&self) -> Option<crate::agent_host::HostRecord> {
        self.hosted.as_ref().map(|h| h.link().record.clone())
    }

    /// The hosted harness exited (its host is finishing).
    /// Tests only: its child's slot, which its reaper locks (`Fence::cut_or_end`).
    #[cfg(test)]
    pub(crate) fn child_slot(&self) -> Arc<Mutex<Option<Child>>> {
        self.child.clone()
    }

    pub fn has_exited(&self) -> bool {
        self.hosted.as_ref().is_some_and(|h| h.exited.load(Ordering::SeqCst))
    }

    /// The reader stopped because an entry could not be logged.
    pub fn is_broken(&self) -> bool {
        self.hosted.as_ref().is_some_and(|h| h.broken.load(Ordering::SeqCst))
    }

    /// The reader of the current host link stopped otherwise (`Hosted::stopped`): what the host
    /// reports is not heard until a reattach.
    pub fn is_stopped(&self) -> bool {
        self.hosted.as_ref().is_some_and(|h| h.stopped.load(Ordering::SeqCst))
    }

    /// Reconnect to the same host after the reader stopped, keeping every
    /// open request, answer waiter and turn of this process: resume after
    /// the last logged entry on a new owner connection. No recovery runs:
    /// this process still holds the state the recovery would rebuild.
    /// Its replay counts as pending until `learn_replay_end` learns how far it goes.
    pub async fn reattach(self: &Arc<Self>) -> Result<()> {
        use crate::agent_host::link::{Connect, connect};
        let Some(h) = &self.hosted else { return Ok(()) };
        let record = h.link().record.clone();
        let after = *h.logged.borrow();
        let link: Arc<crate::agent_host::link::Link> = match connect(record, after).await? {
            Connect::Ready(link, _) => Arc::from(link),
            Connect::Incompatible { .. } => return Err(anyhow!("agent host refused this build")),
        };
        {
            // Under the requests' lock: `fail_pending_if_unheard` sees the link whole or not, and
            // the old link's reader marks it unheard before this or not at all
            // (`mark_link_unheard`, reviews 2 and 3 of #26059). And under the link's lock, which
            // `learn_replay_end` keeps an end under: an end learned through the old link never
            // stands for this one.
            let _pending = self.pending.lock().await;
            let mut current = h.link.write_or_recover();
            h.replay_to.store(u64::MAX, Ordering::SeqCst);
            *current = link.clone();
            drop(current);
            h.broken.store(false, Ordering::SeqCst);
            h.stopped.store(false, Ordering::SeqCst);
        }
        self.start_reader(link);
        Ok(())
    }

    /// An adopted host's replay counts as pending until `learn_replay_end` learns how far it goes.
    pub fn mark_replay_unknown(&self) {
        if let Some(h) = &self.hosted {
            let _current = h.link.write_or_recover();
            h.replay_to.store(u64::MAX, Ordering::SeqCst);
        }
    }

    /// Learns how far the host replays on its current link (`Link::replay_end_within`), and keeps
    /// it for `replay_pending` while that link is current. None when the host did not answer
    /// within `budget`: the replay then never counts as complete through this link. A direct
    /// child replays nothing.
    pub async fn learn_replay_end(&self, budget: std::time::Duration) -> Option<u64> {
        let Some(h) = &self.hosted else { return Some(0) };
        let link = h.link();
        let end = link.replay_end_within(budget).await.ok()?;
        let current = h.link.read_or_recover();
        if Arc::ptr_eq(&current, &link) {
            h.replay_to.store(end, Ordering::SeqCst);
        }
        Some(end)
    }

    /// Whether a reattached or adopted host's replay is not all in the session log yet, or not
    /// known to be (`learn_replay_end`).
    pub fn replay_pending(&self) -> bool {
        #[cfg(test)]
        if TEST_REPLAYING.load(Ordering::SeqCst) == self.generation {
            return true;
        }
        self.hosted
            .as_ref()
            .is_some_and(|h| *h.logged.borrow() < h.replay_to.load(Ordering::SeqCst))
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
        let (stdin_tx, _unused) = mpsc::channel(1);
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
            child: Arc::new(Mutex::new(None)),
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
                replay_to: std::sync::atomic::AtomicU64::new(0),
                stopped: std::sync::atomic::AtomicBool::new(false),
                exited: std::sync::atomic::AtomicBool::new(false),
                exit_seen: std::sync::atomic::AtomicBool::new(false),
                exit: tokio::sync::Notify::new(),
            }),
            all_tools: std::sync::atomic::AtomicBool::new(false),
            given_servers: std::sync::Mutex::new(None),
            launch: std::sync::Mutex::new(None),
            retired: std::sync::Mutex::new(false),
            ended_on_purpose: std::sync::atomic::AtomicBool::new(false),
            generation: NEXT_GENERATION.fetch_add(1, Ordering::Relaxed),
            preview_format: None,
            run_class: std::sync::OnceLock::new(),
            run_class_entered: std::sync::atomic::AtomicBool::new(false),
            writer_stop: std::sync::OnceLock::new(),
            #[cfg(test)]
            input_seam: InputSeam::default(),
            #[cfg(windows)]
            job: None,
        });
        agent.start_reader(link);
        (agent, responses)
    }

    /// Sets `flag` (`Hosted::broken` or `stopped`) while `link` is still this agent's link, under
    /// the requests' lock a reattach replaces the link and clears those flags under (`reattach`):
    /// a reader of a replaced link marks nothing on the one that replaced it (review 3 of #26059).
    /// False once the link was replaced or the agent detached.
    async fn mark_link_unheard(
        &self,
        hosted: &Hosted,
        link: &Arc<crate::agent_host::link::Link>,
        flag: &std::sync::atomic::AtomicBool,
    ) -> bool {
        let _pending = self.pending.lock().await;
        if hosted.detached.load(Ordering::SeqCst) || !Arc::ptr_eq(&hosted.link(), link) {
            return false;
        }
        flag.store(true, Ordering::SeqCst);
        true
    }

    /// Read `link`'s entries: log each, act on it, then acknowledge it.
    fn start_reader(self: &Arc<Self>, link: Arc<crate::agent_host::link::Link>) {
        let reader = self.clone();
        tokio::spawn(async move {
            let Some(hosted) = reader.hosted.as_ref() else { return };
            let mut entries = link.entries.lock().await;
            while let Some((h, entry)) = entries.recv().await {
                let is_exit = matches!(entry, crate::agent_host::Entry::Exit { .. });
                #[cfg(debug_assertions)]
                let ack_fails = ack_fails_once(&entry);
                #[cfg(not(debug_assertions))]
                let ack_fails = false;
                if !reader.on_host_entry(h, entry, &hosted.inbound).await {
                    // Not stored: never acknowledge it or anything after it.
                    // Open requests stay open; the next request reattaches.
                    tracing::warn!(agent = %reader.name, "agent host entry {h} not logged; acks stop");
                    if !reader.mark_link_unheard(hosted, &link, &hosted.broken).await {
                        return;
                    }
                    // Debug builds only: `ACPMUX_TEST_LINK_BROKEN_DELAY_MS` holds the notice of a
                    // broken link before it is sent, as a busy inbound loop does, so the daemon's
                    // integration tests can reattach the link first. Bounded; release builds have
                    // no seam.
                    #[cfg(debug_assertions)]
                    if let Some(ms) = std::env::var("ACPMUX_TEST_LINK_BROKEN_DELAY_MS")
                        .ok()
                        .and_then(|v| v.parse::<u64>().ok())
                    {
                        tokio::time::sleep(std::time::Duration::from_millis(ms.min(10_000))).await;
                    }
                    let _ =
                        hosted.inbound.send(Inbound::LinkBroken { agent: reader.generation }).await;
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
                if ack_fails || link.ack(h).await.is_err() {
                    break;
                }
            }
            #[cfg(debug_assertions)]
            reader_stop_hold().await;
            // The host died or another owner took it, or an acknowledgement failed: the link is
            // not heard from here, before anything is told. A detach hands the agent and its open
            // requests to the next daemon; a replaced link hands them to its own reader.
            {
                let mut p = reader.pending.lock().await;
                if hosted.detached.load(Ordering::SeqCst) || !Arc::ptr_eq(&hosted.link(), &link) {
                    return;
                }
                hosted.stopped.store(true, Ordering::SeqCst);
                for (_, tx) in p.map.drain() {
                    let _ = tx.send(Err(RpcError::internal(AGENT_CLOSED)));
                }
            }
            let _ = hosted.inbound.send(Inbound::LinkBroken { agent: reader.generation }).await;
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
                let host_incarnation =
                    self.hosted.as_ref().map(|host| host.link().record.incarnation.clone());
                let needs_durable_cancel = matches!(
                    &m,
                    Message::Notification { method, params }
                        if method == crate::rpc::method::CANCEL_REQUEST
                            && params.as_ref().and_then(|p| p.get("requestId")).is_some()
                );
                // The incarnation-bearing marker is this entry's durable
                // checkpoint. Store it before acknowledging the cancellation.
                if needs_durable_cancel {
                    let Message::Notification { method, params } = &m else { return false };
                    let (done, persisted) = oneshot::channel();
                    if inbound
                        .send(Inbound::Notification {
                            method: method.clone(),
                            params: params.clone(),
                            host_seq: Some(h),
                            host_incarnation: host_incarnation.clone(),
                            persisted: Some(done),
                            agent: self.generation,
                        })
                        .await
                        .is_err()
                    {
                        return false;
                    }
                    if !persisted.await.unwrap_or(false) {
                        return false;
                    }
                }
                // The incarnation-bearing durable marker owns a cancellation's
                // checkpoint. Its delayed raw copy must never advance a new host.
                let raw_seq = (!needs_durable_cancel).then_some(h);
                match self.tap_live(&m, || (self.tap)(Direction::In, &m, raw_seq)) {
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
                        let _ = inbound
                            .send(Inbound::Request {
                                id,
                                method,
                                params,
                                host_seq: Some(h),
                                host_incarnation,
                            })
                            .await;
                    }
                    Message::Notification { method, params } => {
                        if needs_durable_cancel {
                            return true;
                        }
                        let _ = inbound
                            .send(Inbound::Notification {
                                method,
                                params,
                                host_seq: Some(h),
                                host_incarnation: host_incarnation.clone(),
                                persisted: None,
                                agent: self.generation,
                            })
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
                let _ = inbound
                    .send(Inbound::Stderr(
                        line,
                        Some(h),
                        Some((self.generation, StderrPipe::Stderr)),
                    ))
                    .await;
                true
            }
            Entry::Exit { code } => {
                let note = Message::notification(HOST_EXIT, serde_json::json!({"code": code}));
                if !(self.tap)(Direction::In, &note, Some(h)) {
                    return false;
                }
                // Not alive from here: no turn may set the session ready on
                // a harness that is gone while the ack is still being written.
                // What its host had for it is never written now (its link settled it).
                if let Some(hosted) = &self.hosted {
                    hosted.exit_seen.store(true, Ordering::SeqCst);
                }
                let mut p = self.pending.lock().await;
                for (_, tx) in p.map.drain() {
                    let _ = tx.send(Err(RpcError::internal(AGENT_CLOSED)));
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

/// Debug builds only: `ACPMUX_TEST_READER_STOP_HOLD_MS` holds a host link's reader once it stopped,
/// before it marks the link stopped, as a busy runtime does, so the daemon's integration tests
/// can reattach the link meanwhile. Bounded; release builds have no seam.
#[cfg(debug_assertions)]
async fn reader_stop_hold() {
    if let Some(ms) =
        std::env::var("ACPMUX_TEST_READER_STOP_HOLD_MS").ok().and_then(|v| v.parse::<u64>().ok())
    {
        tokio::time::sleep(std::time::Duration::from_millis(ms.min(10_000))).await;
    }
}

/// Debug builds only: `ACPMUX_TEST_ACK_FAILS_ONCE=TEXT` fails the acknowledgement of the first
/// host entry whose text holds TEXT, once per process, as a link whose writer stopped first does:
/// the reader stops while the socket still looks open. Release builds have no seam.
#[cfg(debug_assertions)]
fn ack_fails_once(entry: &crate::agent_host::Entry) -> bool {
    use crate::agent_host::Entry;
    static FIRED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    let Ok(text) = std::env::var("ACPMUX_TEST_ACK_FAILS_ONCE") else { return false };
    let msg = match entry {
        Entry::Tap { msg, .. } | Entry::In { msg } => msg.to_string(),
        _ => return false,
    };
    msg.contains(&text) && !FIRED.swap(true, Ordering::SeqCst)
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

    #[tokio::test]
    async fn a_durable_withdrawal_never_logs_an_unscoped_raw_cursor() -> anyhow::Result<()> {
        let profile: HarnessProfile = serde_json::from_value(serde_json::json!({
            "argv": ["python3", "-c", "import sys; sys.stdin.read()"]
        }))?;
        let cursors = Arc::new(std::sync::Mutex::new(Vec::new()));
        let recorded = cursors.clone();
        let tap: Tap = Arc::new(move |_, _, seq| {
            recorded.lock().unwrap_or_else(|e| e.into_inner()).push(seq);
            true
        });
        let (tx, mut rx) = mpsc::channel(8);
        let agent =
            ChildAgent::spawn("old", &profile, &std::env::temp_dir(), tx.clone(), tap).await?;
        let cancel = Message::notification(
            crate::rpc::method::CANCEL_REQUEST,
            serde_json::json!({"requestId": 7}),
        );
        let pending =
            agent.on_host_entry(900, crate::agent_host::Entry::In { msg: cancel.to_value() }, &tx);
        let persist = async {
            if let Some(Inbound::Notification { persisted: Some(done), host_seq, .. }) =
                rx.recv().await
            {
                assert_eq!(host_seq, Some(900), "the durable marker owns the checkpoint");
                assert!(cursors.lock().unwrap_or_else(|e| e.into_inner()).is_empty());
                let _ = done.send(true);
            }
        };
        let result = tokio::time::timeout(std::time::Duration::from_secs(10), async {
            tokio::join!(pending, persist).0
        })
        .await;
        agent.kill().await;
        assert!(result?, "the cancellation was not stored");
        assert_eq!(
            *cursors.lock().unwrap_or_else(|e| e.into_inner()),
            vec![None],
            "raw cancellation has no incarnation fence"
        );
        Ok(())
    }

    #[tokio::test]
    async fn direct_children_give_withdrawals_distinct_request_owners() -> anyhow::Result<()> {
        let ask = Message::request(7, crate::rpc::method::SESSION_REQUEST_PERMISSION, Value::Null);
        let cancel = Message::notification(
            crate::rpc::method::CANCEL_REQUEST,
            serde_json::json!({"requestId": 7}),
        );
        let script = format!(
            "import sys; print({:?}, flush=True); print({:?}, flush=True); sys.stdin.read()",
            ask.to_line().trim(),
            cancel.to_line().trim()
        );
        let profile: HarnessProfile = serde_json::from_value(serde_json::json!({
            "argv": ["python3", "-c", script]
        }))?;
        let mut owners = Vec::new();
        for _ in 0..2 {
            let (inbound, mut rx) = mpsc::channel(8);
            let agent = ChildAgent::spawn(
                "direct",
                &profile,
                &std::env::temp_dir(),
                inbound,
                Arc::new(|_, _, _| true),
            )
            .await?;
            let messages = tokio::time::timeout(std::time::Duration::from_secs(10), async {
                (rx.recv().await, rx.recv().await)
            })
            .await;
            agent.kill().await;
            let (
                Some(Inbound::Request { host_incarnation: request, .. }),
                Some(Inbound::Notification { host_incarnation: cancel, .. }),
            ) = messages?
            else {
                anyhow::bail!("the direct child did not ask and withdraw its request");
            };
            assert!(request.is_some(), "a direct request needs its child's identity");
            assert_eq!(request, cancel, "a withdrawal must carry its request's owner");
            owners.push(request);
        }
        assert_ne!(owners[0], owners[1], "a replacement child reused its predecessor's owner");
        Ok(())
    }

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

#[cfg(all(test, unix))]
mod fence_tests {
    use super::*;

    /// Review 81 of #23322: the Codex bridge's empty batch (a translation that gives the
    /// app-server nothing) queues nothing on the agent's stdin, so the reader that sends one
    /// before it hands on an answer never waits on a full stdin queue.
    #[tokio::test]
    async fn an_empty_batch_of_server_lines_queues_nothing() {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let profile: HarnessProfile =
            serde_json::from_value(serde_json::json!({"argv": ["/usr/bin/env", "python3", fake]}))
                .unwrap();
        let (inbound, _rx) = mpsc::channel(16);
        let tap: Tap = Arc::new(|_, _, _| true);
        let agent = ChildAgent::spawn("fake", &profile, &std::env::temp_dir(), inbound, tap)
            .await
            .expect("the stand-in agent starts");
        // Its writer holds one line, so what is queued after it stays queued.
        let (arrived_tx, arrived) = oneshot::channel();
        let (release, release_rx) = oneshot::channel();
        *agent.input_seam.lock().unwrap() =
            Some(("held-line".to_owned(), false, arrived_tx, release_rx));
        agent.stdin_tx.send(("\"held-line\"\n".to_owned(), None)).await.unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(10), arrived)
            .await
            .expect("the writer holds the line")
            .unwrap();
        let room = agent.stdin_tx.capacity();
        assert!(agent.codex_lines(Vec::new(), None).await);
        assert_eq!(agent.stdin_tx.capacity(), room, "an empty batch took a place on stdin");
        // Review 82: Claude's translator gives no line too (a late answer to a withdrawn
        // elicitation, `claude_stdio/outbound.rs`).
        agent.claude_lines(Vec::new(), None).await.unwrap();
        assert_eq!(agent.stdin_tx.capacity(), room, "an empty Claude batch took a place on stdin");
        let _ = release.send(());
        agent.kill().await;
    }

    /// Review 87 of #23322: an agent whose leader exited and left a descendant holding its
    /// stdin: a cut of the message its writer has stops that writer, so nothing more of the
    /// message reaches the descendant after the cut.
    #[tokio::test]
    async fn a_cut_stops_the_writer_of_a_stdin_a_descendant_kept() {
        let out = std::env::temp_dir().join(format!("acpmux-kept-{}", std::process::id()));
        let _ = std::fs::remove_file(&out);
        // A background job gets /dev/null for stdin unless it is passed on explicitly; the
        // descendant leaves the agent's process group, so only a stopped writer keeps it out.
        let copy = "import os, time; os.setsid(); time.sleep(3); os.execvp('cat', ['cat'])";
        let script =
            format!("exec 3<&0; python3 -c \"{copy}\" <&3 3<&- > '{}' & exit 0", out.display());
        let argv = serde_json::json!({"argv": ["/bin/sh", "-c", script]});
        let profile: HarnessProfile = serde_json::from_value(argv).unwrap();
        let (inbound, _rx) = mpsc::channel(16);
        let tap: Tap = Arc::new(|_, _, _| true);
        let agent = ChildAgent::spawn("kept", &profile, &std::env::temp_dir(), inbound, tap)
            .await
            .expect("the agent starts");
        let fence = Fence::default();
        let line = "x".repeat(1 << 20);
        let note = Message::notification("note", serde_json::json!({"text": line}));
        agent.write_fenced(&note, Some(&fence)).await.unwrap();
        // The pipe is full and its leader is gone.
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        assert!(fence.cut_or_end(std::time::Duration::from_secs(1)).await, "the cut is proven");
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        let read = std::fs::metadata(&out).map(|m| m.len()).unwrap_or(0);
        let _ = std::fs::remove_file(&out);
        assert!(read < (1 << 20), "a cut message reached the agent after the cut ({read} bytes)");
    }

    /// Review 87 of #23322, round 2: a direct agent whose leader exited while a descendant that
    /// never reads kept its stdin: the message its writer has settles once the agent ended,
    /// with no cut, so a family hold on it is not held for ever.
    #[tokio::test]
    async fn a_message_a_descendant_never_reads_settles_once_its_agent_ended() {
        let pid_file = std::env::temp_dir().join(format!("acpmux-stuck-{}", std::process::id()));
        let _ = std::fs::remove_file(&pid_file);
        let hold = format!(
            "import os, time; os.setsid(); open('{}', 'w').write(str(os.getpid())); time.sleep(30)",
            pid_file.display()
        );
        let script = format!("exec 3<&0; python3 -c \"{hold}\" <&3 3<&- >/dev/null 2>&1 & exit 0");
        let argv = serde_json::json!({"argv": ["/bin/sh", "-c", script]});
        let profile: HarnessProfile = serde_json::from_value(argv).unwrap();
        let (inbound, _rx) = mpsc::channel(16);
        let tap: Tap = Arc::new(|_, _, _| true);
        let agent = ChildAgent::spawn("stuck", &profile, &std::env::temp_dir(), inbound, tap)
            .await
            .expect("the agent starts");
        let fence = Fence::default();
        let line = "x".repeat(1 << 20);
        let note = Message::notification("note", serde_json::json!({"text": line}));
        agent.write_fenced(&note, Some(&fence)).await.unwrap();
        let settled =
            tokio::time::timeout(std::time::Duration::from_secs(10), fence.settled()).await;
        if let Some(pid) = std::fs::read_to_string(&pid_file).ok().and_then(|p| p.parse().ok()) {
            // SAFETY: the descendant this test started, still holding its pid while it sleeps.
            unsafe { libc::kill(pid, libc::SIGKILL) };
        }
        let _ = std::fs::remove_file(&pid_file);
        assert!(settled.is_ok(), "a message its ended agent never took was still unsettled");
        assert!(!fence.is_cut(), "it was written in part, so it is not a cut");
    }

    /// Review 88 of #23322: Claude's translator lets go of a permission ask once it translated
    /// the answer, so a translated answer is as good as taken: a cut never drops it while it is
    /// queued, which would leave Claude waiting on an ask nothing can answer again; the cut
    /// ends that agent instead.
    #[tokio::test]
    async fn an_answer_a_translator_took_is_not_cut_while_queued() {
        let ask = serde_json::json!({"type": "control_request", "request_id": "ask-1",
            "request": {"subtype": "can_use_tool", "tool_name": "Bash", "input": {}}});
        let script = format!("echo '{ask}'; exec sleep 30");
        let argv = serde_json::json!({"argv": ["/bin/sh"]});
        let profile: HarnessProfile = serde_json::from_value(argv).unwrap();
        let (inbound, mut rx) = mpsc::channel(16);
        let tap: Tap = Arc::new(|_, _, _| true);
        let tr =
            crate::claude_stdio::Translator::new("acp-1".into(), "default", "haiku", "default");
        let command = Some(("/bin/sh".to_owned(), vec!["-c".to_owned(), script]));
        let agent = ChildAgent::spawn_with(
            "translated",
            &profile,
            &std::env::temp_dir(),
            inbound,
            tap,
            command,
            Some(tr),
            None,
        )
        .await
        .expect("the agent starts");
        let id = tokio::time::timeout(std::time::Duration::from_secs(10), async {
            loop {
                match rx.recv().await {
                    Some(Inbound::Request { id, .. }) => break id,
                    Some(_) => continue,
                    None => panic!("the agent ended before it asked"),
                }
            }
        })
        .await
        .expect("Claude's ask reaches the hub");
        // Its writer holds one line, so the answer stays queued behind it.
        let (arrived_tx, arrived) = oneshot::channel();
        let (release, release_rx) = oneshot::channel();
        *agent.input_seam.lock().unwrap() =
            Some(("held-line".to_owned(), false, arrived_tx, release_rx));
        agent.stdin_tx.send(("\"held-line\"\n".to_owned(), None)).await.unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(10), arrived)
            .await
            .expect("the writer holds the line")
            .unwrap();
        let fence = Fence::default();
        let allow =
            serde_json::json!({"outcome": {"outcome": "selected", "optionId": "allow_once"}});
        agent.respond_fenced(id, Ok(allow), Some(&fence)).await.unwrap();
        fence.cut();
        assert!(!fence.is_cut(), "a cut dropped an answer its translator had already let go of");
        assert!(fence.cut_or_end(std::time::Duration::from_secs(1)).await, "its agent ended");
        assert!(!agent.is_alive().await, "the agent of a translated answer was left running");
        let _ = release.send(());
    }

    /// Review 87 of #23322, round 3: a direct agent's message is written only once its writer
    /// wrote it. An answer that came first (one the Codex bridge makes up once its app-server
    /// exits) does not settle it while its writer still has it.
    #[tokio::test]
    async fn only_its_writer_settles_a_direct_agents_message() {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let profile: HarnessProfile =
            serde_json::from_value(serde_json::json!({"argv": ["/usr/bin/env", "python3", fake]}))
                .unwrap();
        let (inbound, _rx) = mpsc::channel(16);
        let tap: Tap = Arc::new(|_, _, _| true);
        let agent = ChildAgent::spawn("fake", &profile, &std::env::temp_dir(), inbound, tap)
            .await
            .expect("the stand-in agent starts");
        // Its writer holds the request while it writes it.
        let (arrived_tx, arrived) = oneshot::channel();
        let (release, release_rx) = oneshot::channel();
        *agent.input_seam.lock().unwrap() =
            Some(("held-request".to_owned(), true, arrived_tx, release_rx));
        let fence = Fence::default();
        let request = {
            let (agent, fence) = (agent.clone(), fence.clone());
            tokio::spawn(async move {
                let params = serde_json::json!({});
                agent.request_with_hook("held-request", params, Some(&fence), || {}).await
            })
        };
        tokio::time::timeout(std::time::Duration::from_secs(10), arrived)
            .await
            .expect("the writer holds the request")
            .unwrap();
        let waiting: Vec<_> = agent.pending.lock().await.map.drain().map(|(_, tx)| tx).collect();
        for tx in waiting {
            let _ = tx.send(Err(RpcError::internal("the app-server exited")));
        }
        let _ = tokio::time::timeout(std::time::Duration::from_secs(5), request).await;
        let settled = fence.is_settled();
        let _ = release.send(());
        agent.kill().await;
        assert!(!settled, "an answer settled a message its writer had not written");
    }

    /// Review 87 of #23322, round 3: a message a translator took (`hand_on`) that its agent's
    /// closed writer never takes settles, so no holder waits on it.
    #[tokio::test]
    async fn a_translated_message_its_closed_writer_never_took_settles() {
        let argv = serde_json::json!({"argv": ["/bin/sh"]});
        let profile: HarnessProfile = serde_json::from_value(argv).unwrap();
        let (inbound, _rx) = mpsc::channel(16);
        let tap: Tap = Arc::new(|_, _, _| true);
        let tr =
            crate::claude_stdio::Translator::new("acp-1".into(), "default", "haiku", "default");
        let command = Some(("/bin/sh".to_owned(), vec!["-c".to_owned(), "exit 0".to_owned()]));
        let agent = ChildAgent::spawn_with(
            "gone",
            &profile,
            &std::env::temp_dir(),
            inbound,
            tap,
            command,
            Some(tr),
            None,
        )
        .await
        .expect("the agent starts");
        tokio::time::timeout(std::time::Duration::from_secs(10), agent.stdin_tx.closed())
            .await
            .expect("its writer stops once it ended");
        let fence = Fence::default();
        // Claude's translator turns a cancel into an interrupt line for its stdin.
        let params = serde_json::json!({"sessionId": "acp-1"});
        let cancel = Message::notification(crate::rpc::method::SESSION_CANCEL, params);
        assert!(agent.write_fenced(&cancel, Some(&fence)).await.is_err());
        assert!(fence.is_settled(), "a message its closed writer never took was left unsettled");
    }

    /// Review 87 of #23322, round 4: a cut that stops a writer before it ever ran still settles
    /// what that writer had queued, one a translator took included.
    #[tokio::test]
    async fn a_writer_stopped_before_it_ran_settles_its_queue() {
        let argv = serde_json::json!({"argv": ["/bin/sh"]});
        let profile: HarnessProfile = serde_json::from_value(argv).unwrap();
        let (inbound, _rx) = mpsc::channel(16);
        let tap: Tap = Arc::new(|_, _, _| true);
        let tr =
            crate::claude_stdio::Translator::new("acp-1".into(), "default", "haiku", "default");
        let command =
            Some(("/bin/sh".to_owned(), vec!["-c".to_owned(), "exec sleep 30".to_owned()]));
        let agent = ChildAgent::spawn_with(
            "unpolled",
            &profile,
            &std::env::temp_dir(),
            inbound,
            tap,
            command,
            Some(tr),
            None,
        )
        .await
        .expect("the agent starts");
        // Two translated messages, queued before the writer first runs (this runtime has one
        // thread, and nothing here yields to it).
        let params = serde_json::json!({"sessionId": "acp-1"});
        let cancel = Message::notification(crate::rpc::method::SESSION_CANCEL, params);
        let (first, second) = (Fence::default(), Fence::default());
        agent.write_fenced(&cancel, Some(&first)).await.unwrap();
        agent.write_fenced(&cancel, Some(&second)).await.unwrap();
        assert!(second.cut_or_end(std::time::Duration::from_secs(1)).await, "the cut is proven");
        let settled = first.is_settled();
        agent.kill().await;
        assert!(settled, "a message its unstarted writer had queued was left unsettled");
    }
}
