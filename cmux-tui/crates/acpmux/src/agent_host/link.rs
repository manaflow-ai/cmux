//! The controller side of an agent host: start one, or adopt one a previous
//! controller started, and exchange frames with it.

use super::*;
use std::ffi::OsString;
use std::sync::Arc;
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
        Ok(Self { exe: std::env::current_exe()?, prefix: crate::daemon::daemon_prefix() })
    }
}

/// Start a host for `spec` and return its record once the harness runs, or
/// fail with [`HostTimeout`] after [`BOOTSTRAP_BUDGET`].
pub async fn spawn(launcher: &HostLauncher, spec: &SpawnSpec) -> Result<HostRecord> {
    spawn_within(launcher, spec, BOOTSTRAP_BUDGET).await
}

/// [`spawn`] with the bootstrap deadline given by the caller.
pub async fn spawn_within(
    launcher: &HostLauncher,
    spec: &SpawnSpec,
    budget: std::time::Duration,
) -> Result<HostRecord> {
    let mut cmd = tokio::process::Command::new(&launcher.exe);
    cmd.args(&launcher.prefix)
        .arg(HOST_ARG)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(false);
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
    let mut child = cmd.spawn().with_context(|| format!("start {}", launcher.exe.display()))?;
    let mut stdin = child.stdin.take().context("host stdin")?;
    let mut stdout = child.stdout.take().context("host stdout")?;
    // A host that never reports ready must not hold the session's spawn.
    let bootstrap = within("start", budget, async {
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

pub struct Link {
    tx: mpsc::Sender<(ControllerFrame, Option<oneshot::Sender<()>>)>,
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
    let (tx, mut rx) = mpsc::channel::<(ControllerFrame, Option<oneshot::Sender<()>>)>(1024);
    let (entries_tx, entries_rx) = mpsc::channel::<(u64, Entry)>(4096);
    let (detach_tx, detach_rx) = oneshot::channel();
    let closed = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let queries: Queries = Arc::default();
    tokio::spawn(async move {
        while let Some((frame, written)) = rx.recv().await {
            if write_frame(&mut wr, &frame).await.is_err() {
                break;
            }
            // The frame is in the socket: a caller that must not outlive an
            // unsent frame (the Exit ack before the daemon exits) waits here.
            if let Some(written) = written {
                let _ = written.send(());
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
                        if let Some(reply) = queries.lock().unwrap().remove(&id) {
                            let _ =
                                reply.send(QueryReply { claude_session_id, modes, config_options });
                        }
                    }
                    Ok(Some(_)) | Ok(None) | Err(_) => break,
                }
            }
            closed.store(true, std::sync::atomic::Ordering::SeqCst);
            queries.lock().unwrap().clear();
        });
    }
    tx.send((ControllerFrame::Resume { after: resume_after }, None))
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

impl Link {
    async fn send(&self, frame: ControllerFrame) -> Result<()> {
        self.tx.send((frame, None)).await.map_err(|_| anyhow!("agent host connection closed"))
    }

    /// Hand one ACP message to the harness.
    pub async fn line(&self, msg: Value) -> Result<()> {
        self.send(ControllerFrame::Line { msg }).await
    }

    /// Entries through `h` are in the session log.
    pub async fn ack(&self, h: u64) -> Result<()> {
        self.send(ControllerFrame::Ack { h }).await
    }

    /// [`Link::ack`], returning once the frame is written to the host's
    /// socket (or the connection closed), at most `budget`.
    pub async fn ack_written(&self, h: u64, budget: std::time::Duration) -> Result<()> {
        let (written, done) = oneshot::channel();
        self.tx
            .send((ControllerFrame::Ack { h }, Some(written)))
            .await
            .map_err(|_| anyhow!("agent host connection closed"))?;
        within("ack", budget, done)
            .await?
            .map_err(|_| anyhow!("agent host connection closed before the ack was written"))
    }

    pub async fn terminate(&self, grace: std::time::Duration) -> Result<()> {
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
        self.queries.lock().unwrap().insert(id, tx);
        self.send(ControllerFrame::Query { id }).await?;
        match within("query", budget, rx).await {
            Ok(reply) => reply.map_err(|_| anyhow!("agent host closed before it answered")),
            Err(timeout) => {
                self.queries.lock().unwrap().remove(&id);
                Err(timeout.into())
            }
        }
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(std::sync::atomic::Ordering::SeqCst)
    }
}

/// A link with no host behind it, for tests: the test reads the frames the
/// link writes and feeds it host entries.
#[cfg(test)]
pub(crate) struct TestWire {
    frames: mpsc::Receiver<(ControllerFrame, Option<oneshot::Sender<()>>)>,
    pub entries: mpsc::Sender<(u64, Entry)>,
}

#[cfg(test)]
impl TestWire {
    /// The link and its wire. Nothing is written until `write_all`.
    pub(crate) fn link(record: HostRecord) -> (Link, TestWire) {
        let (tx, frames) = mpsc::channel(1024);
        let (entries, entries_rx) = mpsc::channel(4096);
        let link = Link {
            tx,
            queries: Arc::default(),
            next_query: std::sync::atomic::AtomicU64::new(1),
            record,
            entries: Mutex::new(entries_rx),
            detach_ack: Mutex::new(None),
            closed: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        };
        (link, TestWire { frames, entries })
    }

    /// Write every frame queued so far; returns them.
    pub(crate) fn write_all(&mut self) -> Vec<ControllerFrame> {
        let mut out = Vec::new();
        while let Ok((frame, written)) = self.frames.try_recv() {
            if let Some(written) = written {
                let _ = written.send(());
            }
            out.push(frame);
        }
        out
    }
}

