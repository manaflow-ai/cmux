//! The controller side of an agent host: start one, or adopt one a previous
//! controller started, and exchange frames with it.

use super::*;
use crate::no_panic::LockExt;
use std::ffi::OsString;
use std::sync::Arc;
#[cfg(unix)]
use tokio::net::UnixStream;
use tokio::sync::{Mutex, mpsc, oneshot};

/// How to start `__agent-host`: the acpmux binary and the arguments before the
/// host word (`cmux acp …` inside the cmux multicall binary).
#[derive(Debug, Clone)]
pub struct HostLauncher {
    pub exe: PathBuf,
    pub prefix: Vec<OsString>,
}

impl HostLauncher {
    /// This process's own binary, with the prefix it starts its daemon with.
    /// On Linux `exe` is the path without the ` (deleted)` that `current_exe`
    /// adds once an update replaced the file ([`Self::program`] still starts
    /// this build).
    pub fn current() -> Result<Self> {
        let this = crate::self_command::SelfCommand::current()?;
        Ok(Self { exe: undeleted(this.exe), prefix: this.prefix })
    }

    /// The program [`spawn`] execs; `exe` stays the host's argv0. On Linux,
    /// for this process's own binary, the open inode `/proc/self/exe`: once an
    /// update replaces the file a long-lived daemon runs from (a Cloud VM's
    /// `~/.cmux/bin/cmux-tui`), the path is gone or holds another build, and
    /// every new chat failed with "start PATH (deleted): No such file or
    /// directory" (the app's `agent_session.refused`). The host then runs the
    /// daemon's own build, as cmux-tui's terminal hosts do
    /// (`self_exe_for_spawn`). argv0 stays the path: a cmux-tui copy named
    /// `acpmux` (a peer's `~/.local/bin/acpmux`) runs as acpmux by that name.
    fn program(&self) -> PathBuf {
        let own = cfg!(target_os = "linux")
            && std::env::current_exe().is_ok_and(|exe| undeleted(exe) == self.exe);
        if own { PathBuf::from("/proc/self/exe") } else { self.exe.clone() }
    }
}

/// `path` without the ` (deleted)` Linux appends to a replaced executable.
fn undeleted(path: PathBuf) -> PathBuf {
    match path.to_str().and_then(|p| p.strip_suffix(" (deleted)")) {
        Some(p) => PathBuf::from(p),
        None => path,
    }
}

/// Start a host for `spec` and return its record once the harness runs.
///
/// The start has no time budget (P-AUSTIN B10). It ends on a signal from the
/// host: its answer on the bootstrap pipe, or the pipe's end, which only the
/// host's exit closes before it answers; or when the caller drops it, which
/// ends the host (it is still this process's child). A busy Mac makes a host
/// slow, never wrong, so time alone never ends it; a caller with a deadline
/// of its own (`agent_start`, the pool's `START_BUDGET`) drops the start.
#[cfg(unix)]
pub async fn spawn(launcher: &HostLauncher, spec: &SpawnSpec) -> Result<HostRecord> {
    // The build-session kill switch: no host and no harness (cx-9ettq).
    crate::launch_policy::refuse_if_disabled()?;
    let mut cmd = tokio::process::Command::new(launcher.program());
    cmd.arg0(&launcher.exe)
        .args(&launcher.prefix)
        .arg(HOST_ARG)
        // The host itself is inspectable by its same-uid harness child on
        // some platforms. It needs only OS identity/locale; the complete
        // child environment arrives over the private bootstrap pipe.
        .env_clear()
        .envs(crate::agent::host_environment())
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(false);
    // Debug builds only: the hello-stall test seam (`host.rs`) names a folder
    // of marker files and carries no authority; release builds have no seam.
    #[cfg(debug_assertions)]
    if let Some(dir) = std::env::var_os(super::host::HELLO_STALL_DIR_ENV) {
        cmd.env(super::host::HELLO_STALL_DIR_ENV, dir);
    }
    #[cfg(debug_assertions)]
    if let Some(ms) = std::env::var_os(super::host::POOLED_OWNER_WAIT_ENV) {
        cmd.env(super::host::POOLED_OWNER_WAIT_ENV, ms);
    }
    // SAFETY: setsid is async-signal-safe and touches no Rust state. The host
    // leads its own session so it outlives the controller and its group.
    unsafe {
        cmd.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let child = cmd
        .spawn()
        .map_err(|e| crate::agent::spawn_error(&format!("start {}", launcher.exe.display()), e))?;
    // Until it answers, the host is ended with this start: a caller that
    // stops waiting leaves no host behind.
    let mut host = Bootstrapping::new(child)?;
    // The host moves into its own scope before the spec: it starts its
    // harness only once it has it, so the harness starts there too
    // (`scope.rs`).
    if let Some(pid) = host.pid() {
        super::scope::place(pid).await;
    }
    let bootstrap = async {
        let (stdin, stdout) = host.pipes();
        write_frame(stdin, spec).await?;
        read_frame::<_, BootstrapReply>(stdout).await
    }
    .await;
    let reply = match bootstrap {
        Ok(Some(reply)) => reply,
        // The pipe ended without an answer: only the host's exit closes it
        // before it answers. Say how it ended.
        Ok(None) => {
            let status = host.exited().await;
            return Err(match status {
                Some(status) => anyhow!("agent host exited before it was ready ({status})"),
                None => anyhow!("agent host exited before it was ready"),
            });
        }
        // A broken pipe or an unreadable answer: end the host with it.
        Err(e) => return Err(e.context("agent host start")),
    };
    // The host is not this process's child for long: reap it in the
    // background so it never lingers as a zombie of the controller.
    if let Some(mut host) = host.answered() {
        tokio::spawn(async move {
            let _ = host.wait().await;
        });
    }
    match reply {
        BootstrapReply::Ready { record } => Ok(record),
        BootstrapReply::SpawnFailed { message } => Err(anyhow!(message)),
    }
}
/// Windows port: agent hosts start through CreateProcess there (a later
/// landing).
#[cfg(not(unix))]
pub async fn spawn(_launcher: &HostLauncher, _spec: &SpawnSpec) -> Result<HostRecord> {
    Err(crate::platform::unsupported("agent hosts"))
}

/// A host that has not answered its bootstrap yet, with its bootstrap pipes.
/// Dropped, it ends the host (SIGKILL; it is still this process's unreaped
/// child, so its pid is ours) before its pipes close, so the host never sees
/// its start given up and runs on; tokio reaps it in the background.
#[cfg(unix)]
struct Bootstrapping {
    child: Option<tokio::process::Child>,
    stdin: tokio::process::ChildStdin,
    stdout: tokio::process::ChildStdout,
}

#[cfg(unix)]
impl Bootstrapping {
    fn new(mut child: tokio::process::Child) -> Result<Self> {
        let pipes = child.stdin.take().zip(child.stdout.take());
        let Some((stdin, stdout)) = pipes else {
            let _ = child.start_kill();
            bail!("agent host started without its bootstrap pipes");
        };
        Ok(Self { child: Some(child), stdin, stdout })
    }

    fn pid(&self) -> Option<u32> {
        self.child.as_ref().and_then(tokio::process::Child::id)
    }

    fn pipes(&mut self) -> (&mut tokio::process::ChildStdin, &mut tokio::process::ChildStdout) {
        (&mut self.stdin, &mut self.stdout)
    }

    /// The host closed its pipe without an answer: its exit status, once it
    /// is reaped (it closes the pipe only by exiting).
    /// The guard keeps the host while it waits, so a caller drop meanwhile
    /// still ends it.
    async fn exited(mut self) -> Option<std::process::ExitStatus> {
        self.child.as_mut()?.wait().await.ok()
    }

    /// The host answered: it is no longer ended with this start.
    fn answered(mut self) -> Option<tokio::process::Child> {
        self.child.take()
    }
}

#[cfg(unix)]
impl Drop for Bootstrapping {
    fn drop(&mut self) {
        // Runs before the fields drop: the kill comes before the pipes close.
        if let Some(child) = self.child.as_mut() {
            let _ = child.start_kill();
        }
    }
}

/// What the host said when it was adopted.
#[derive(Debug, Clone, PartialEq)]
pub struct Adopted {
    pub version: u16,
    pub host_build: String,
    pub incarnation: String,
    pub harness_pid: Option<u32>,
    pub last_h: u64,
    pub acked_h: u64,
    pub max_out_id: i64,
    pub exited: Option<Option<i32>>,
}

pub enum Connect {
    Ready(Box<Link>, Adopted),
    /// No protocol version in common: the host keeps running.
    Incompatible {
        min: u16,
        max: u16,
        host_build: String,
    },
}

/// One owner connection to a host. Entries arrive on `entries`; the owner
/// acknowledges each with [`Link::ack`] once it is in the session log.
/// Translator state reported by [`Link::query`].
#[derive(Debug, Clone, Default, PartialEq)]
pub struct QueryReply {
    pub claude_session_id: Option<String>,
    pub modes: Option<Value>,
    pub config_options: Option<Value>,
}

type Queries = Arc<std::sync::Mutex<std::collections::HashMap<u64, oneshot::Sender<QueryReply>>>>;

/// The fences of the lines sent to a host (`ControllerFrame::Line`), with its incarnation,
/// until its receipt (`WRITTEN_METHOD`, `settle_receipt`) or its end (`settle_receipts_of`)
/// settles them. Shared by every connection this daemon makes, so a receipt a later connection
/// to the same host gets settles its line (review 82 of #23322). A protocol-1 host gives no
/// receipt: its lines wait here for its end, or for their request's answer (review 83).
type Receipts = std::sync::Mutex<std::collections::HashMap<u64, (String, crate::agent::Fence)>>;

static RECEIPTS: std::sync::LazyLock<Receipts> = std::sync::LazyLock::new(Default::default);

/// This daemon's next receipt: random high bits, so a receipt a previous daemon left in a
/// host's queue never names a line of this one.
static NEXT_RECEIPT: std::sync::LazyLock<std::sync::atomic::AtomicU64> =
    std::sync::LazyLock::new(|| {
        let mut high = [0u8; 4];
        let _ = getrandom::fill(&mut high);
        std::sync::atomic::AtomicU64::new(u64::from(u32::from_le_bytes(high)) << 32)
    });

/// The receipts that came while no fence waited for them (a previous daemon's, or one settled
/// another way), newest last, at most [`UNCLAIMED_CAP`]: a line held again at adoption
/// (`adopt_receipt`) whose receipt came between the log's read and its hold is settled by it.
/// Locked only under `RECEIPTS`.
static UNCLAIMED: std::sync::LazyLock<std::sync::Mutex<std::collections::VecDeque<(u64, bool)>>> =
    std::sync::LazyLock::new(Default::default);

const UNCLAIMED_CAP: usize = 4096;

/// A host's receipt (`WRITTEN_METHOD`) for the line it names: written, or never (`written`
/// false: its harness's stdin closed). An unknown one (a previous daemon's) is kept for an
/// adoption that holds its line again (`adopt_receipt`).
pub fn settle_receipt(receipt: u64, written: bool) {
    let mut receipts = RECEIPTS.lock_or_recover();
    let fence = receipts.remove(&receipt).map(|(_, f)| f);
    if fence.is_none() {
        let mut unclaimed = UNCLAIMED.lock_or_recover();
        if unclaimed.len() >= UNCLAIMED_CAP {
            unclaimed.pop_front();
        }
        unclaimed.push_back((receipt, written));
    }
    drop(receipts);
    match fence {
        Some(f) if written => f.written(),
        Some(f) => f.failed(),
        None => {}
    }
}

/// Keeps `fence`, its host's end watched, until a receipt or its host's end settles it: its
/// receipt.
fn await_receipt(host: &HostRecord, fence: &crate::agent::Fence) -> u64 {
    let receipt = NEXT_RECEIPT.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    hold_receipt(host, receipt, fence);
    receipt
}

/// `fence` waits in `RECEIPTS` for `receipt`, or for its host's end, which is watched.
fn hold_receipt(host: &HostRecord, receipt: u64, fence: &crate::agent::Fence) {
    let mut receipts = RECEIPTS.lock_or_recover();
    // Settled ones another way (an answered request) go.
    receipts.retain(|_, (_, f)| !f.is_settled());
    receipts.insert(receipt, (host.incarnation.clone(), fence.clone()));
    drop(receipts);
    watch_end(host);
}

/// Watches `host`'s end once, from its first held line.
fn watch_end(host: &HostRecord) {
    if WATCHED.lock_or_recover().insert(host.incarnation.clone()) {
        // task-owner: ends with the host, or when its lock can not be watched.
        tokio::spawn(watch_host_end(host.clone()));
    }
}

/// A fenced line a previous daemon sent `host` under `receipt` whose receipt its log does not
/// have (`QUEUED_METHOD` with no `WRITTEN_METHOD`): its harness may not have it yet, so it is
/// held again until that receipt or its host's end settles it, and a cut ends its host
/// (`Fence::held_by_host`). A receipt that came before this hold settles it at once; a line
/// this daemon sent itself (a later adoption of the same host) keeps the fence it has.
pub fn adopt_receipt(host: &HostRecord, receipt: u64) -> crate::agent::Fence {
    // One lock across the look and the hold: its receipt is either kept already or finds it.
    let mut receipts = RECEIPTS.lock_or_recover();
    if let Some((_, own)) = receipts.get(&receipt) {
        return own.clone();
    }
    let fence = crate::agent::Fence::held_by_host(host.clone());
    let came = {
        let mut unclaimed = UNCLAIMED.lock_or_recover();
        let at = unclaimed.iter().position(|(r, _)| *r == receipt);
        at.and_then(|at| unclaimed.remove(at)).map(|(_, written)| written)
    };
    if came.is_none() {
        receipts.insert(receipt, (host.incarnation.clone(), fence.clone()));
    }
    drop(receipts);
    match came {
        Some(true) => fence.written(),
        Some(false) => fence.failed(),
        None => watch_end(host),
    }
    fence
}

/// What `host`'s log can not tell apart (a host older than protocol 3 logs no
/// `QUEUED_METHOD`): a line a previous daemon fenced that its harness may not have yet. Held
/// until `host` ends, as a line to a host that gives no receipt is (fail closed); a cut ends
/// `host`.
pub fn adopt_untold(host: &HostRecord) -> crate::agent::Fence {
    let fence = crate::agent::Fence::held_by_host(host.clone());
    // A receipt of this daemon's that `host` was never sent: only its end settles it.
    let receipt = NEXT_RECEIPT.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    hold_receipt(host, receipt, &fence);
    fence
}

/// The host incarnations whose end is watched (`watch_host_end`), one watch each.
static WATCHED: std::sync::LazyLock<std::sync::Mutex<std::collections::HashSet<String>>> =
    std::sync::LazyLock::new(Default::default);

/// Settles what host `record` had once its live lock proves it gone, whatever logs its entries
/// or holds its connection: a killed host leaves no `Exit` (review 87 of #23322). Ends with the
/// host, or at once when its lock can not be watched, which leaves its lines to their answer,
/// receipt or `Exit` (fail closed).
async fn watch_host_end(record: HostRecord) {
    let (sid, nonce) = (&record.session_id, &record.start_nonce);
    let gone = loop {
        let dirs = live_lock_dirs(&record);
        let states: Vec<_> = dirs.iter().map(|d| (d, liveness(d, sid, nonce))).collect();
        if states.iter().any(|(_, l)| *l == Liveness::Unknown) {
            break false;
        }
        // Gone once no directory holds it live; a move from the pool wakes the watch, which
        // looks again.
        let Some((dir, _)) = states.into_iter().find(|(_, l)| *l == Liveness::Live) else {
            break true;
        };
        if !dead(dir, sid, nonce).await {
            break false;
        }
    };
    WATCHED.lock_or_recover().remove(&record.incarnation);
    if gone {
        settle_receipts_of(&record.incarnation);
    }
}

/// The host incarnation `incarnation` ended: what it had is never written now.
pub fn settle_receipts_of(incarnation: &str) {
    let ended: Vec<_> = {
        let mut receipts = RECEIPTS.lock_or_recover();
        let ids: Vec<u64> =
            receipts.iter().filter(|(_, (i, _))| i == incarnation).map(|(r, _)| *r).collect();
        ids.into_iter().filter_map(|r| receipts.remove(&r)).collect()
    };
    for (_, fence) in ended {
        fence.failed();
    }
}

/// A frame, a receipt once it is in the socket, and the fence of the message it carries.
type Outgoing = (ControllerFrame, Option<oneshot::Sender<()>>, Option<crate::agent::Fence>);

pub struct Link {
    tx: mpsc::Sender<Outgoing>,
    queries: Queries,
    next_query: std::sync::atomic::AtomicU64,
    pub record: HostRecord,
    pub entries: Mutex<mpsc::Receiver<(u64, Entry)>>,
    detach_ack: Mutex<Option<oneshot::Receiver<()>>>,
    /// Set when the host closed the connection or another owner took over.
    pub closed: Arc<std::sync::atomic::AtomicBool>,
    /// The last entry the host sent on this link (`replay_end_within`).
    highest: Arc<std::sync::atomic::AtomicU64>,
}

/// Connect as owner and resume after `resume_after` (the last entry already
/// in this session's log).
pub async fn connect(record: HostRecord, resume_after: u64) -> Result<Connect> {
    // A wedged host must not hold up the daemon: the handshake is bounded.
    const HELLO_BUDGET: std::time::Duration = std::time::Duration::from_secs(5);
    tokio::time::timeout(HELLO_BUDGET, connect_inner(record, resume_after))
        .await
        .map_err(|_| anyhow!("agent host did not answer hello within {HELLO_BUDGET:?}"))?
}

/// [`connect`], speaking at most protocol `max`, as a daemon of an older build does. For tests.
#[doc(hidden)]
pub async fn connect_with_max(record: HostRecord, resume_after: u64, max: u16) -> Result<Connect> {
    connect_inner_max(record, resume_after, max).await
}

#[cfg(unix)]
async fn connect_inner(record: HostRecord, resume_after: u64) -> Result<Connect> {
    // Debug builds only: `ACPMUX_TEST_CONTROLLER_PROTOCOL_MAX` makes this daemon speak at most that
    // protocol, so a host it finds can refuse it (`0`: every host does), as a host of a build it
    // cannot speak to does. Release builds have no seam.
    #[cfg(debug_assertions)]
    if let Some(max) = std::env::var("ACPMUX_TEST_CONTROLLER_PROTOCOL_MAX")
        .ok()
        .and_then(|v| v.parse::<u16>().ok())
    {
        return connect_inner_max(record, resume_after, max).await;
    }
    connect_inner_max(record, resume_after, PROTOCOL_MAX).await
}

#[cfg(not(unix))]
async fn connect_inner_max(record: HostRecord, resume_after: u64, _max: u16) -> Result<Connect> {
    connect_inner(record, resume_after).await
}

#[cfg(unix)]
async fn connect_inner_max(record: HostRecord, resume_after: u64, max: u16) -> Result<Connect> {
    let stream = UnixStream::connect(&record.socket)
        .await
        .with_context(|| format!("connect {}", record.socket.display()))?;
    let (mut rd, mut wr) = stream.into_split();
    write_frame(
        &mut wr,
        &ControllerFrame::Hello {
            min: PROTOCOL_MIN,
            max,
            token: record.owner_token.clone(),
            controller_build: crate::hub::build().to_owned(),
        },
    )
    .await?;
    let adopted = match read_frame::<_, HostFrame>(&mut rd).await? {
        Some(HostFrame::HostHello {
            version,
            host_build,
            incarnation,
            harness_pid,
            last_h,
            acked_h,
            max_out_id,
            exited,
        }) => Adopted {
            version,
            host_build,
            incarnation,
            harness_pid,
            last_h,
            acked_h,
            max_out_id,
            exited,
        },
        Some(HostFrame::Incompatible { min, max, host_build }) => {
            return Ok(Connect::Incompatible { min, max, host_build });
        }
        Some(other) => bail!("agent host answered hello with {other:?}"),
        None => bail!("agent host closed the connection during hello"),
    };
    if adopted.incarnation != record.incarnation {
        bail!("agent host incarnation does not match its record");
    }
    // Debug builds only: when the file `ACPMUX_TEST_BEFORE_RESUME_FILE` names says "arm", it is
    // renamed to `<file>.fired` here, after the host's hello and before `Resume`, and the connect
    // waits 1 s, so a harness that waits for that name reports meanwhile: its host numbers an entry
    // after its hello. The first entry numbered after the hello then reaches this link 1.5 s late,
    // as from a busy host (review 3 of #26057). Release builds have no seam.
    #[cfg(debug_assertions)]
    let mut late = None;
    #[cfg(debug_assertions)]
    if let Some(file) = std::env::var_os("ACPMUX_TEST_BEFORE_RESUME_FILE")
        && std::fs::read_to_string(&file).is_ok_and(|s| s.trim() == "arm")
    {
        let mut fired = file.clone();
        fired.push(".fired");
        if std::fs::rename(&file, &fired).is_ok() {
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            late = Some(adopted.last_h);
        }
    }
    let (tx, mut rx) = mpsc::channel::<Outgoing>(1024);
    let (entries_tx, entries_rx) = mpsc::channel::<(u64, Entry)>(4096);
    let (detach_tx, detach_rx) = oneshot::channel();
    let closed = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let queries: Queries = Arc::default();
    // A host from protocol 2 says when the harness has a fenced line (`WRITTEN_METHOD`); an
    // older one says nothing, and its line stays unsettled until its host ends or its request
    // is answered (review 83 of #23322).
    let receipted = adopted.version >= RECEIPT_VERSION;
    let host = record.clone();
    tokio::spawn(async move {
        while let Some((mut frame, written, fence)) = rx.recv().await {
            if fence.as_ref().is_some_and(|f| !f.begin()) {
                continue;
            }
            let mut receipt = None;
            if let (Some(f), ControllerFrame::Line { receipt: asked, .. }) = (&fence, &mut frame) {
                let r = await_receipt(&host, f);
                if receipted {
                    *asked = Some(r);
                }
                receipt = Some(r);
            }
            if write_frame(&mut wr, &frame).await.is_err() {
                if let Some(r) = receipt {
                    RECEIPTS.lock_or_recover().remove(&r);
                }
                if let Some(f) = fence {
                    f.failed();
                }
                break;
            }
            if let Some(f) = fence.filter(|_| receipt.is_none()) {
                f.written();
            }
            // The frame is in the socket: a caller that must not outlive an
            // unsent frame (the Exit ack before the daemon exits) waits here.
            if let Some(written) = written {
                let _ = written.send(());
            }
        }
        // Never sent now: what it still queues is cut, so no holder waits on it.
        rx.close();
        while let Ok((_, _, fence)) = rx.try_recv() {
            if let Some(f) = fence {
                f.cut();
            }
        }
    });
    let highest = Arc::new(std::sync::atomic::AtomicU64::new(0));
    {
        let closed = closed.clone();
        let queries = queries.clone();
        let highest = highest.clone();
        tokio::spawn(async move {
            let mut detach_tx = Some(detach_tx);
            loop {
                match read_frame::<_, HostFrame>(&mut rd).await {
                    Ok(Some(HostFrame::Entry { h, e })) => {
                        #[cfg(debug_assertions)]
                        if late.is_some_and(|last_h| h > last_h) {
                            late = None;
                            tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
                        }
                        // Before a query answer that comes behind it (`replay_end_within`).
                        highest.fetch_max(h, std::sync::atomic::Ordering::SeqCst);
                        // A line's receipt settles as it arrives: a fact of the host, true
                        // whether or not the entry is logged (review 85). Its harness's end
                        // does not: its host may still write a line to a descendant that kept
                        // the harness's stdin; its host's own end does (review 87).
                        if let Entry::Tap { dir: TapDir::Out, msg } = &e
                            && msg["method"] == WRITTEN_METHOD
                            && let Some(r) = msg["params"]["receipt"].as_u64()
                        {
                            settle_receipt(r, msg["params"]["written"] == true);
                        }
                        if entries_tx.send((h, e)).await.is_err() {
                            break;
                        }
                    }
                    Ok(Some(HostFrame::DetachAck)) => {
                        if let Some(t) = detach_tx.take() {
                            let _ = t.send(());
                        }
                        break;
                    }
                    Ok(Some(HostFrame::TerminateAck)) => {}
                    Ok(Some(HostFrame::QueryReply {
                        id,
                        claude_session_id,
                        modes,
                        config_options,
                    })) => {
                        if let Some(reply) = queries.lock_or_recover().remove(&id) {
                            let _ =
                                reply.send(QueryReply { claude_session_id, modes, config_options });
                        }
                    }
                    Ok(Some(_)) | Ok(None) | Err(_) => break,
                }
            }
            closed.store(true, std::sync::atomic::Ordering::SeqCst);
            queries.lock_or_recover().clear();
        });
    }
    tx.send((ControllerFrame::Resume { after: resume_after }, None, None))
        .await
        .map_err(|_| anyhow!("agent host connection closed"))?;
    Ok(Connect::Ready(
        Box::new(Link {
            tx,
            queries,
            next_query: std::sync::atomic::AtomicU64::new(1),
            record,
            entries: Mutex::new(entries_rx),
            detach_ack: Mutex::new(Some(detach_rx)),
            closed,
            highest,
        }),
        adopted,
    ))
}
/// Windows port: the host socket is `cmux::local_socket` there (a later
/// landing).
#[cfg(not(unix))]
async fn connect_inner(_record: HostRecord, _resume_after: u64) -> Result<Connect> {
    Err(crate::platform::unsupported("agent hosts"))
}

impl Link {
    async fn send(&self, frame: ControllerFrame) -> Result<()> {
        self.tx.send((frame, None, None)).await.map_err(|_| anyhow!("agent host connection closed"))
    }

    /// Hand one ACP message to the harness.
    pub async fn line(&self, msg: Value) -> Result<()> {
        self.line_fenced(msg, None).await
    }

    /// [`Link::line`], `fence` held to its frame.
    pub async fn line_fenced(&self, msg: Value, fence: Option<crate::agent::Fence>) -> Result<()> {
        let frame = ControllerFrame::Line { msg, receipt: None };
        self.tx
            .send((frame, None, fence))
            .await
            .map_err(|_| anyhow!("agent host connection closed"))
    }

    /// Entries through `h` are in the session log.
    pub async fn ack(&self, h: u64) -> Result<()> {
        self.send(ControllerFrame::Ack { h }).await
    }

    /// [`Link::ack`], returning once the frame is written to the host's
    /// socket (or the connection closed), at most `budget`.
    pub async fn ack_written(&self, h: u64, budget: std::time::Duration) -> Result<()> {
        let (written, done) = oneshot::channel();
        // The whole wait is bounded: a writer stuck on a full socket also
        // fills the queue, so the send itself can wait.
        within("ack", budget, async {
            self.tx
                .send((ControllerFrame::Ack { h }, Some(written), None))
                .await
                .map_err(|_| anyhow!("agent host connection closed"))?;
            done.await
                .map_err(|_| anyhow!("agent host connection closed before the ack was written"))
        })
        .await?
    }

    pub async fn terminate(&self, grace: std::time::Duration) -> Result<()> {
        // Debug builds only: `ACPMUX_TEST_STALL_HOST_TERMINATE` makes the terminate wait forever,
        // as one does on a host whose link stopped reading (its queue full), so the daemon's
        // integration tests can drive that path. Release builds have no seam.
        #[cfg(debug_assertions)]
        if std::env::var_os("ACPMUX_TEST_STALL_HOST_TERMINATE").is_some() {
            std::future::pending::<()>().await;
        }
        self.send(ControllerFrame::Terminate { grace_ms: grace.as_millis() as u64 }).await
    }

    /// Leave the harness running: returns once the host confirmed that no
    /// frame after this point goes to this connection.
    pub async fn detach(&self) -> Result<()> {
        self.send(ControllerFrame::Detach).await?;
        let rx = self.detach_ack.lock().await.take();
        if let Some(rx) = rx {
            rx.await.map_err(|_| anyhow!("agent host closed before it acknowledged detach"))?;
        }
        Ok(())
    }

    /// The translator's state inside the host, or [`HostTimeout`] after
    /// [`QUERY_BUDGET`].
    pub async fn query(&self) -> Result<QueryReply> {
        self.query_within(QUERY_BUDGET).await
    }

    /// [`Link::query`] with the deadline given by the caller.
    pub async fn query_within(&self, budget: std::time::Duration) -> Result<QueryReply> {
        let id = self.next_query.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        self.queries.lock_or_recover().insert(id, tx);
        self.send(ControllerFrame::Query { id }).await?;
        match within("query", budget, rx).await {
            Ok(reply) => reply.map_err(|_| anyhow!("agent host closed before it answered")),
            Err(timeout) => {
                self.queries.lock_or_recover().remove(&id);
                Err(timeout.into())
            }
        }
    }

    /// The last entry the host numbered before it answers a query sent now. The host handles this
    /// link's frames in order, the `Resume` sent at connect before this query, and sends its own in
    /// order: every entry it numbered before it handled that `Resume` (its hello's `last_h`, and
    /// any it numbered after the hello) reached this link before the answer. Once a reader logged
    /// through it, all the host kept as this link resumed is in the log (review 3 of #26057).
    pub async fn replay_end_within(&self, budget: std::time::Duration) -> Result<u64> {
        self.query_within(budget).await?;
        Ok(self.highest.load(std::sync::atomic::Ordering::SeqCst))
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(std::sync::atomic::Ordering::SeqCst)
    }
}

#[cfg(test)]
mod launcher_tests {
    use super::{HostLauncher, undeleted};
    use std::path::PathBuf;

    /// A daemon whose binary an update replaced still starts agent hosts: on
    /// Linux its own binary is exec'd from the open inode, never `PATH
    /// (deleted)`, and argv0 stays the path (a copy named `acpmux` runs as
    /// acpmux by it). Another binary is exec'd as given.
    #[test]
    fn the_host_starts_from_the_open_inode_on_linux() {
        let launcher = HostLauncher::current().expect("launcher");
        let exe = std::env::current_exe().expect("current exe");
        assert_eq!(launcher.exe, exe);
        if cfg!(target_os = "linux") {
            assert_eq!(launcher.program(), PathBuf::from("/proc/self/exe"));
        } else {
            assert_eq!(launcher.program(), exe);
        }
        let other = HostLauncher { exe: PathBuf::from("/opt/cmux/bin/acpmux"), prefix: Vec::new() };
        assert_eq!(other.program(), PathBuf::from("/opt/cmux/bin/acpmux"));
    }

    #[test]
    fn a_replaced_file_reads_as_its_path() {
        let path = "/home/cmux/.cmux/bin/cmux-tui";
        assert_eq!(undeleted(format!("{path} (deleted)").into()), PathBuf::from(path));
        assert_eq!(undeleted(path.into()), PathBuf::from(path));
    }
}
