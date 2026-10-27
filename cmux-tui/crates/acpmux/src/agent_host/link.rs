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
    pub fn current() -> Result<Self> {
        let this = crate::self_command::SelfCommand::current()?;
        Ok(Self { exe: this.exe, prefix: this.prefix })
    }
}

/// Start a host for `spec` and return its record once the harness runs, or
/// fail with [`HostTimeout`] after [`BOOTSTRAP_BUDGET`].
pub async fn spawn(launcher: &HostLauncher, spec: &SpawnSpec) -> Result<HostRecord> {
    spawn_within(launcher, spec, BOOTSTRAP_BUDGET).await
}

/// [`spawn`] with the bootstrap deadline given by the caller.
#[cfg(unix)]
pub async fn spawn_within(
    launcher: &HostLauncher,
    spec: &SpawnSpec,
    budget: std::time::Duration,
) -> Result<HostRecord> {
    // The build-session kill switch: no host and no harness (cx-9ettq).
    crate::launch_policy::refuse_if_disabled()?;
    let mut cmd = tokio::process::Command::new(&launcher.exe);
    cmd.args(&launcher.prefix)
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
    let mut child = cmd
        .spawn()
        .map_err(|e| crate::agent::spawn_error(&format!("start {}", launcher.exe.display()), e))?;
    let mut stdin = child.stdin.take().context("host stdin")?;
    let mut stdout = child.stdout.take().context("host stdout")?;
    // The host moves into its own scope before the spec: it starts its
    // harness only once it has it, so the harness starts there too
    // (`scope.rs`).
    let pid = child.id();
    // A host that never reports ready must not hold the session's spawn.
    let bootstrap = within("start", budget, async {
        if let Some(pid) = pid {
            super::scope::place(pid).await;
        }
        write_frame(&mut stdin, spec).await?;
        read_frame::<_, BootstrapReply>(&mut stdout).await
    })
    .await;
    if bootstrap.is_err() {
        // Not ready in time: it is still this process's child, so end it.
        let _ = child.start_kill();
    }
    // The host is not this process's child for long: reap it in the
    // background so it never lingers as a zombie of the controller.
    tokio::spawn(async move {
        let _ = child.wait().await;
    });
    let reply = bootstrap??;
    match reply {
        Some(BootstrapReply::Ready { record }) => Ok(record),
        Some(BootstrapReply::SpawnFailed { message }) => Err(anyhow!(message)),
        None => Err(anyhow!("agent host exited before it was ready")),
    }
}
/// Windows port: agent hosts start through CreateProcess there (a later
/// landing).
#[cfg(not(unix))]
pub async fn spawn_within(
    _launcher: &HostLauncher,
    _spec: &SpawnSpec,
    _budget: std::time::Duration,
) -> Result<HostRecord> {
    Err(crate::platform::unsupported("agent hosts"))
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
/// until its end (`settle_receipts_of`) or their request's answer settles them: a host says
/// nothing of when its harness has a line (review 83 of #23322). Shared by every connection
/// this daemon makes, so a reattach keeps them (review 82).
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

/// Keeps `fence`, its host's end watched, until its host's end settles it: its receipt.
fn await_receipt(host: &HostRecord, fence: &crate::agent::Fence) -> u64 {
    let receipt = NEXT_RECEIPT.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let mut receipts = RECEIPTS.lock_or_recover();
    // Settled ones another way (an answered request) go.
    receipts.retain(|_, (_, f)| !f.is_settled());
    receipts.insert(receipt, (host.incarnation.clone(), fence.clone()));
    drop(receipts);
    if WATCHED.lock_or_recover().insert(host.incarnation.clone()) {
        // task-owner: ends with the host, or when its lock can not be watched.
        tokio::spawn(watch_host_end(host.clone()));
    }
    receipt
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

#[cfg(unix)]
async fn connect_inner(record: HostRecord, resume_after: u64) -> Result<Connect> {
    let stream = UnixStream::connect(&record.socket)
        .await
        .with_context(|| format!("connect {}", record.socket.display()))?;
    let (mut rd, mut wr) = stream.into_split();
    write_frame(
        &mut wr,
        &ControllerFrame::Hello {
            min: PROTOCOL_MIN,
            max: PROTOCOL_MAX,
            token: record.owner_token.clone(),
            controller_build: crate::hub::BUILD.to_owned(),
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
    let (tx, mut rx) = mpsc::channel::<Outgoing>(1024);
    let (entries_tx, entries_rx) = mpsc::channel::<(u64, Entry)>(4096);
    let (detach_tx, detach_rx) = oneshot::channel();
    let closed = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let queries: Queries = Arc::default();
    // A host says nothing of when its harness has a fenced line: it stays unsettled until its
    // host ends or its request is answered (review 83 of #23322).
    let host = record.clone();
    tokio::spawn(async move {
        while let Some((frame, written, fence)) = rx.recv().await {
            if fence.as_ref().is_some_and(|f| !f.begin()) {
                continue;
            }
            let mut receipt = None;
            if let (Some(f), ControllerFrame::Line { .. }) = (&fence, &frame) {
                receipt = Some(await_receipt(&host, f));
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
    {
        let closed = closed.clone();
        let queries = queries.clone();
        tokio::spawn(async move {
            let mut detach_tx = Some(detach_tx);
            loop {
                match read_frame::<_, HostFrame>(&mut rd).await {
                    Ok(Some(HostFrame::Entry { h, e })) => {
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
        let frame = ControllerFrame::Line { msg };
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

    pub fn is_closed(&self) -> bool {
        self.closed.load(std::sync::atomic::Ordering::SeqCst)
    }
}
