//! The `__agent-host` process: runs one harness and keeps it, and every line
//! it produced, until a controller has logged them.

use super::*;
use crate::claude_stdio::{Outbound, Translator};
use crate::rpc::Message;
use std::collections::VecDeque;
use std::os::fd::AsRawFd;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::mpsc;

/// Entry point of `acpmux __agent-host`: read the spawn spec from stdin,
/// start the harness, answer on stdout, then serve controllers until the
/// harness ended and its exit was logged.
pub fn main() -> Result<()> {
    // The host must not die when a controller or the bootstrap parent goes
    // away mid-write.
    // SAFETY: setting a signal disposition has no memory-safety preconditions.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
        libc::signal(libc::SIGHUP, libc::SIG_IGN);
    }
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
    runtime.block_on(run())
}

async fn run() -> Result<()> {
    let mut stdin = tokio::io::stdin();
    let mut stdout = tokio::io::stdout();
    let spec: SpawnSpec =
        read_frame(&mut stdin).await?.ok_or_else(|| anyhow!("no spawn spec on stdin"))?;
    // The host owns its daemon's local router while it lives: a kept agent
    // keeps its router through a daemon restart. The path comes from the
    // daemon, whose home may be a tagged build's override.
    let _router_owner =
        spec.router_owner_fifo.as_deref().and_then(crate::daemon::open_router_owner);
    match start(&spec).await {
        Ok(started) => {
            write_frame(&mut stdout, &BootstrapReply::Ready { record: started.record.clone() })
                .await?;
            detach_stdio();
            started.serve(spec).await
        }
        Err(e) => {
            let message = format!("{e:#}");
            let _ = write_frame(&mut stdout, &BootstrapReply::SpawnFailed { message }).await;
            Err(e)
        }
    }
}

/// Point stdin and stdout at /dev/null so the bootstrap pipes close.
fn detach_stdio() {
    if let Ok(null) = std::fs::OpenOptions::new().read(true).write(true).open("/dev/null") {
        // SAFETY: dup2 onto the standard descriptors of this process.
        unsafe {
            libc::dup2(null.as_raw_fd(), 0);
            libc::dup2(null.as_raw_fd(), 1);
        }
    }
}

struct Started {
    record: HostRecord,
    listener: UnixListener,
    child: tokio::process::Child,
    /// Held for the life of the process: the liveness proof.
    _live: std::fs::File,
}

async fn start(spec: &SpawnSpec) -> Result<Started> {
    ensure_private_dir(&spec.hosts_dir)?;
    if let Some(parent) = spec.socket.parent() {
        ensure_private_dir(parent)?;
    }
    let nonce = random_hex(16)?;
    // Before anything starts, so a failure leaves nothing running.
    let (incarnation, owner_token) = (random_hex(16)?, random_hex(32)?);
    let live_file = live_path(&spec.hosts_dir, &spec.session_id, &nonce);
    let live = lock_live_file(&live_file)?;
    // Until the start succeeds, every early return removes what it created.
    let mut cleanup = StartCleanup { paths: vec![live_file] };
    let mut cmd = crate::cwd_pin::CwdPin::command(&spec.program, spec.cwd_pin);
    cmd.args(&spec.args)
        .env_clear()
        .envs(spec.env.iter().map(|(k, v)| (k, v)))
        .current_dir(&spec.cwd)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        // Own process group, so ending the session ends everything the agent
        // started (background shells included).
        .process_group(0)
        .kill_on_drop(false);
    // Bind before the harness starts, so a failure leaves nothing running.
    let _ = std::fs::remove_file(&spec.socket);
    let listener = UnixListener::bind(&spec.socket)
        .with_context(|| format!("bind {}", spec.socket.display()))?;
    cleanup.paths.push(spec.socket.clone());
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&spec.socket, std::fs::Permissions::from_mode(0o600))?;
    }
    let mut child = cmd.spawn().map_err(|e| {
        // Both a missing folder and a missing program fail as ENOENT: say which.
        if e.kind() == std::io::ErrorKind::NotFound && !spec.cwd.exists() {
            anyhow!("the folder {} does not exist", spec.cwd.display())
        } else {
            anyhow!(e).context(format!("spawn harness process {}", spec.program))
        }
    })?;
    let record = HostRecord {
        record_version: RECORD_VERSION,
        session_id: spec.session_id.clone(),
        incarnation,
        host_pid: std::process::id(),
        start_nonce: nonce,
        harness_pid: child.id(),
        owner_token,
        caller_token: spec.caller_token(),
        protocol_min: PROTOCOL_MIN,
        protocol_max: PROTOCOL_MAX,
        host_build: crate::hub::BUILD.to_owned(),
        socket: spec.socket.clone(),
    };
    if let Err(e) = write_record_atomic(&record_path(&spec.hosts_dir, &spec.session_id), &record) {
        if let Some(pg) = child.id() {
            // SAFETY: the harness just started as the leader of this group.
            unsafe { libc::killpg(pg as i32, libc::SIGKILL) };
        }
        let _ = child.start_kill();
        return Err(e);
    }
    cleanup.paths.clear();
    Ok(Started { record, listener, child, _live: live })
}

/// Files a host start created, removed on drop unless the start succeeded.
struct StartCleanup {
    paths: Vec<PathBuf>,
}

impl Drop for StartCleanup {
    fn drop(&mut self) {
        for path in &self.paths {
            let _ = std::fs::remove_file(path);
        }
    }
}

fn lock_live_file(path: &Path) -> Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .with_context(|| format!("create {}", path.display()))?;
    // SAFETY: flock on a descriptor this function owns.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        let _ = std::fs::remove_file(path);
        bail!("lock {}", path.display());
    }
    Ok(file)
}

/// What the event loop reacts to.
/// What the harness's stdin writer takes, in order.
enum Stdin {
    Line(String),
    /// A receipt (`ControllerFrame::Line`): answered once the lines before it are written.
    Receipt(u64),
}

enum Event {
    Stdout(Option<String>),
    Stderr(Option<String>),
    Exited(Option<i32>),
    Accepted(tokio::net::UnixStream),
    Frame(u64, Option<ControllerFrame>),
    /// The harness's stdin has every line queued before the receipt (`true`), or it closed
    /// before them (`false`).
    Written(u64, bool),
    /// SIGTERM: end the harness and the host. Also sent when no daemon
    /// can adopt this host any more (`watch_record`, a pooled host's lost
    /// controller).
    Term,
    /// A quiet drain period (its generation) ended: output pipes still open
    /// belong to processes that left the harness group (setsid).
    DrainOver(u64),
    /// [`POOLED_OWNER_WAIT`] passed since the host started serving.
    OwnerWaitOver,
}

/// How long a pooled host waits for its first controller. A daemon that
/// started it attaches within its pool start budget (90 s, `hub/pool`) or
/// ends it; one that died before it attached (SIGKILL right after the
/// spawn) never will, and a pooled host never waits for a next daemon, so it
/// ends. It never relied on the daemon's systemd unit for that: the host may
/// be in its own scope (`scope.rs`).
pub(crate) const POOLED_OWNER_WAIT: std::time::Duration = std::time::Duration::from_secs(120);

/// Debug builds only: [`POOLED_OWNER_WAIT`] in milliseconds, for the
/// lifetime test; passed on by the host launch (`link.rs`). Release builds
/// have no seam.
#[cfg(debug_assertions)]
pub(super) const POOLED_OWNER_WAIT_ENV: &str = "ACPMUX_TEST_POOLED_OWNER_WAIT_MS";

fn pooled_owner_wait() -> std::time::Duration {
    #[cfg(debug_assertions)]
    if let Some(ms) = std::env::var(POOLED_OWNER_WAIT_ENV).ok().and_then(|v| v.parse::<u64>().ok())
    {
        return std::time::Duration::from_millis(ms);
    }
    POOLED_OWNER_WAIT
}

/// A pooled host whose wait for its first controller ended with none.
fn pooled_without_owner(pooled: bool, last_owner: Option<u64>) -> bool {
    pooled && last_owner.is_none()
}

/// After the harness leader exited and its group was killed: how long the
/// pipes may stay open with the reader ready (a permit out) and no line
/// arriving. Output not yet read because of back-pressure is never cut: the
/// period runs only while the host is ready to read. A process that left the
/// group (setsid) can hold the pipes open forever; the exit is reported when
/// a quiet period passes.
const DRAIN_BUDGET: std::time::Duration = std::time::Duration::from_secs(2);

struct Controller {
    id: u64,
    tx: mpsc::UnboundedSender<HostFrame>,
    /// Entries flow only after `Resume`.
    resumed: bool,
}

struct State {
    record: HostRecord,
    spec: SpawnSpec,
    entries: VecDeque<(u64, Entry, usize)>,
    weight: usize,
    next_h: u64,
    acked_h: u64,
    max_out_id: i64,
    exit_h: Option<u64>,
    stdout_done: bool,
    stderr_done: bool,
    leader_code: Option<Option<i32>>,
    /// Connections that have not said `Hello` yet.
    pending_conns: Vec<(u64, mpsc::UnboundedSender<HostFrame>)>,
    controller: Option<Controller>,
    /// Unbounded: a harness that stops reading never blocks the loop; what
    /// waits here is bounded by the controller, which waits for answers.
    stdin_tx: mpsc::UnboundedSender<Stdin>,
    translator: Option<Arc<Translator>>,
    /// `codex app-server` bridged in process (`codex_app_server.rs`).
    codex: Option<Arc<crate::codex_app_server::Translator>>,
    pgid: Option<i32>,
    /// The harness leader has not been reaped: its group id is still ours.
    leader_alive: Arc<std::sync::atomic::AtomicBool>,
    /// Stderr lines not kept while over the buffer cap.
    stderr_dropped: u64,
    /// No daemon can adopt this host any more: end like SIGTERM.
    unadoptable: bool,
    /// The processes under this host when it was told to end: the ones a
    /// harness moved out of its group are ended with the host.
    under: Vec<super::tree::Started>,
    /// The connection of the last controller that said `Hello`, also when
    /// a failed send already dropped it as the controller.
    last_owner: Option<u64>,
    /// Never answer `Hello` (debug builds' test seam, [`claim_hello_stall`]).
    stall_hello: bool,
}

/// The debug builds' hello-stall seam's variable ([`claim_hello_stall`]):
/// the host launch passes it on (`link.rs`), since the host starts with a
/// cleared environment.
#[cfg(debug_assertions)]
pub(super) const HELLO_STALL_DIR_ENV: &str = "ACPMUX_TEST_HOST_HELLO_STALL_DIR";

/// Debug builds only: `ACPMUX_TEST_HOST_HELLO_STALL_DIR` names a directory of
/// `stall-*` marker files. A host that removes one never answers `Hello`, as
/// a wedged host does, so the daemon's integration tests can drive that
/// path; each marker stalls one host. Release builds have no seam.
fn claim_hello_stall() -> bool {
    #[cfg(debug_assertions)]
    if let Some(dir) = std::env::var_os(HELLO_STALL_DIR_ENV)
        && let Ok(entries) = std::fs::read_dir(dir)
    {
        return entries.flatten().any(|e| {
            e.file_name().to_string_lossy().starts_with("stall-")
                && std::fs::remove_file(e.path()).is_ok()
        });
    }
    false
}

/// Debug builds only: `ACPMUX_TEST_HOST_QUERY_STALL_DIR` in the harness's
/// environment (a profile's `env`; the host clears its own) names a directory
/// of `stall-*` marker files too. A host that removes one as a `Query` comes
/// leaves that query unanswered, as a host whose answer sits behind a backlog
/// nobody reads, so the daemon's integration tests can drive the query's
/// timeout; each marker stalls one query. Release builds have no seam.
#[cfg_attr(not(debug_assertions), allow(unused_variables))]
fn claim_query_stall(harness_env: &[(String, String)]) -> bool {
    #[cfg(debug_assertions)]
    if let Some((_, dir)) =
        harness_env.iter().find(|(k, _)| k == "ACPMUX_TEST_HOST_QUERY_STALL_DIR")
        && let Ok(entries) = std::fs::read_dir(dir)
    {
        return entries.flatten().any(|e| {
            e.file_name().to_string_lossy().starts_with("stall-")
                && std::fs::remove_file(e.path()).is_ok()
        });
    }
    false
}

impl Started {
    async fn serve(self, spec: SpawnSpec) -> Result<()> {
        let Started { record, listener, mut child, _live } = self;
        let (events_tx, mut events) = mpsc::channel::<Event>(1024);
        let stdout = child.stdout.take().context("harness stdout")?;
        let stderr = child.stderr.take().context("harness stderr")?;
        let stdin = child.stdin.take().context("harness stdin")?;
        let pgid = child.id().map(|p| p as i32);

        // stdin writer: a full pipe never blocks the event loop.
        let (stdin_tx, mut stdin_rx) = mpsc::unbounded_channel::<Stdin>();
        let written = events_tx.clone();
        // task-owner: ends with the queue (the host's state) or the harness's stdin.
        tokio::spawn(async move {
            let mut stdin = stdin;
            while let Some(item) = stdin_rx.recv().await {
                match item {
                    Stdin::Line(line) => {
                        if stdin.write_all(line.as_bytes()).await.is_err()
                            || stdin.flush().await.is_err()
                        {
                            break;
                        }
                    }
                    // Every line queued before it is written.
                    Stdin::Receipt(receipt) => {
                        if written.send(Event::Written(receipt, true)).await.is_err() {
                            return;
                        }
                    }
                }
            }
            // The harness's stdin closed: nothing queued now or later is written (review 83).
            stdin_rx.close();
            while let Some(item) = stdin_rx.recv().await {
                if let Stdin::Receipt(receipt) = item
                    && written.send(Event::Written(receipt, false)).await.is_err()
                {
                    return;
                }
            }
        });
        // stdout reader: one line per permit, so the loop stops reading (and
        // the harness blocks on its pipe) while the buffer is over its cap.
        let (pace_tx, mut pace_rx) = mpsc::channel::<()>(1);
        {
            let tx = events_tx.clone();
            tokio::spawn(async move {
                let mut lines = BufReader::new(stdout).lines();
                while pace_rx.recv().await.is_some() {
                    let next = lines.next_line().await.ok().flatten();
                    let done = next.is_none();
                    if tx.send(Event::Stdout(next)).await.is_err() || done {
                        break;
                    }
                }
            });
        }
        {
            let tx = events_tx.clone();
            tokio::spawn(async move {
                let mut lines = BufReader::new(stderr).lines();
                loop {
                    let next = lines.next_line().await.ok().flatten();
                    let done = next.is_none();
                    if tx.send(Event::Stderr(next)).await.is_err() || done {
                        break;
                    }
                }
            });
        }
        let leader_alive = Arc::new(std::sync::atomic::AtomicBool::new(true));
        {
            let tx = events_tx.clone();
            let alive = leader_alive.clone();
            tokio::spawn(async move {
                // End what the agent left running while the exited leader is
                // still a zombie: its group id cannot be reused yet, so the
                // kill reaches only this harness's group. Then reap it.
                if let Some(pg) = pgid
                    && tokio::task::spawn_blocking(move || wait_exit_unreaped(pg))
                        .await
                        .is_ok_and(|ok| ok)
                {
                    // SAFETY: the unreaped leader keeps this group id ours.
                    unsafe { libc::killpg(pg, libc::SIGKILL) };
                }
                let code = child.wait().await.ok().and_then(|s| s.code());
                // Reaped: from here the group id may be freed; nobody may
                // signal it on the strength of the leader being alive.
                alive.store(false, std::sync::atomic::Ordering::SeqCst);
                let _ = tx.send(Event::Exited(code)).await;
            });
        }
        {
            let tx = events_tx.clone();
            tokio::spawn(async move {
                let Ok(mut term) =
                    tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                else {
                    return;
                };
                if term.recv().await.is_some() {
                    let _ = tx.send(Event::Term).await;
                }
            });
        }
        // Held for the host's life: dropping it stops the watch.
        let _record_watch = watch_record(&spec, &record.start_nonce, events_tx.clone());
        {
            let tx = events_tx.clone();
            tokio::spawn(async move {
                while let Ok((stream, _)) = listener.accept().await {
                    if tx.send(Event::Accepted(stream)).await.is_err() {
                        break;
                    }
                }
            });
        }

        let translator = spec.translator.as_ref().map(|t| {
            let tr = Translator::new(t.acp_session_id.clone(), &t.mode, &t.model, &t.effort);
            if t.fast
                && let Ok(mut fast) = tr.fast.try_lock()
            {
                *fast = true;
            }
            if let Some(sid) = &t.claude_session_id
                && let Ok(mut slot) = tr.session_id.try_lock()
            {
                *slot = Some(sid.clone());
            }
            tr
        });
        let codex = (spec.translator.is_none() && spec.codex_bridge)
            .then(crate::codex_app_server::translator);
        let mut state = State {
            record,
            spec,
            entries: VecDeque::new(),
            weight: 0,
            next_h: 0,
            acked_h: 0,
            max_out_id: 0,
            exit_h: None,
            stdout_done: false,
            stderr_done: false,
            leader_code: None,
            pending_conns: Vec::new(),
            controller: None,
            stdin_tx,
            translator,
            codex,
            pgid,
            leader_alive,
            stderr_dropped: 0,
            unadoptable: false,
            under: Vec::new(),
            last_owner: None,
            stall_hello: claim_hello_stall(),
        };
        // The app-server's initialize goes out at spawn, before the hub's.
        if let Some(cx) = state.codex.clone() {
            state.codex_out(cx.start());
        }
        let mut next_conn = 0u64;
        let mut permit_out = pace_tx.try_send(()).is_ok();
        // The leader exited and its exit is not pushed yet.
        let mut draining = false;
        // Generation of the armed quiet period, if one is armed.
        let mut drain_gen = 0u64;
        let mut drain_armed = false;
        if still_pooled(&state.spec) {
            let tx = events_tx.clone();
            let wait = pooled_owner_wait();
            // task-owner: one bounded wait; the runtime ends it with the host.
            tokio::spawn(async move {
                tokio::time::sleep(wait).await;
                let _ = tx.send(Event::OwnerWaitOver).await;
            });
        }

        while let Some(event) = events.recv().await {
            match event {
                // Output after the Exit entry (an escaped process) is dropped.
                Event::Stdout(Some(_)) if state.exit_h.is_some() => {}
                Event::Stderr(Some(_)) if state.exit_h.is_some() => {}
                Event::Stdout(Some(line)) => {
                    permit_out = false;
                    drain_gen += 1;
                    drain_armed = false;
                    state.on_stdout(line).await;
                }
                Event::Stdout(None) => {
                    permit_out = false;
                    if state.exit_h.is_none() {
                        state.end_background_shells().await;
                        state.codex_closed();
                    }
                    state.stdout_done = true;
                    state.maybe_push_exit();
                }
                Event::Stderr(Some(line)) => {
                    drain_gen += 1;
                    drain_armed = false;
                    state.on_stderr(line);
                }
                Event::Stderr(None) => {
                    state.stderr_done = true;
                    state.maybe_push_exit();
                }
                Event::Exited(code) => {
                    state.leader_code = Some(code);
                    // The waiter already ended the group before it reaped
                    // the leader; the group id may be reused from here on.
                    state.leader_alive.store(false, std::sync::atomic::Ordering::SeqCst);
                    state.maybe_push_exit();
                    draining = state.exit_h.is_none();
                }
                Event::DrainOver(generation) => {
                    let ready = permit_out || state.stdout_done;
                    if draining && generation == drain_gen && ready && state.exit_h.is_none() {
                        tracing::warn!(
                            "harness output stays open after its exit; reporting the exit"
                        );
                        state.end_background_shells().await;
                        state.codex_closed();
                        state.stdout_done = true;
                        state.stderr_done = true;
                        state.maybe_push_exit();
                    }
                }
                Event::OwnerWaitOver => {
                    if pooled_without_owner(still_pooled(&state.spec), state.last_owner) {
                        tracing::warn!("no daemon attached to this pooled host; ending it");
                        state.unadoptable = true;
                    }
                }
                Event::Term => {
                    // The frozen end path (`terminate_unadoptable`): end the
                    // harness while its group is still ours, then the host.
                    state.note_under();
                    if state.leader_alive.load(std::sync::atomic::Ordering::SeqCst)
                        && let Some(pg) = state.pgid
                    {
                        // SAFETY: the leader is unreaped, so the group is ours.
                        unsafe { libc::killpg(pg, libc::SIGKILL) };
                    }
                    break;
                }
                Event::Accepted(stream) => {
                    next_conn += 1;
                    let id = next_conn;
                    let (mut rd, mut wr) = stream.into_split();
                    // Unbounded: the retained entries already bound it, and a
                    // slow owner must not be dropped (it would never return).
                    let (tx, mut rx) = mpsc::unbounded_channel::<HostFrame>();
                    tokio::spawn(async move {
                        while let Some(frame) = rx.recv().await {
                            if write_frame(&mut wr, &frame).await.is_err() {
                                break;
                            }
                        }
                    });
                    let events = events_tx.clone();
                    tokio::spawn(async move {
                        loop {
                            let frame =
                                read_frame::<_, ControllerFrame>(&mut rd).await.ok().flatten();
                            let done = frame.is_none();
                            if events.send(Event::Frame(id, frame)).await.is_err() || done {
                                break;
                            }
                        }
                    });
                    state.pending_conns.push((id, tx));
                }
                Event::Frame(id, frame) => state.on_frame(id, frame).await,
                Event::Written(receipt, written) => state.receipt(receipt, written),
            }
            if state.unadoptable {
                // As SIGTERM: end the harness while its group is ours, then the host.
                state.note_under();
                if state.leader_alive.load(std::sync::atomic::Ordering::SeqCst)
                    && let Some(pg) = state.pgid
                {
                    // SAFETY: the leader is unreaped, so the group is ours.
                    unsafe { libc::killpg(pg, libc::SIGKILL) };
                }
                break;
            }
            if state.finished() {
                break;
            }
            let wanted = !state.stdout_done && state.weight <= state.spec.buffer_cap;
            if wanted && !permit_out && pace_tx.try_send(()).is_ok() {
                permit_out = true;
            }
            // A quiet period runs only while the reader is ready (a permit
            // out) and the exit waits on open pipes.
            if draining && state.exit_h.is_some() {
                draining = false;
            }
            if draining && (permit_out || state.stdout_done) && !drain_armed {
                drain_armed = true;
                let tx = events_tx.clone();
                let generation = drain_gen;
                // task-owner: one bounded quiet period; a later line makes
                // its generation stale, the runtime ends it with the host.
                tokio::spawn(async move {
                    tokio::time::sleep(DRAIN_BUDGET).await;
                    let _ = tx.send(Event::DrainOver(generation)).await;
                });
            }
        }
        // What the harness moved out of its group outlives the group signal.
        super::tree::kill_still_running(&state.under);
        remove_own_artifacts(&state.spec.hosts_dir, &state.record);
        remove_promoted(&state.spec.hosts_dir, &state.record);
        Ok(())
    }
}

impl State {
    /// Note the processes under this host before its harness group is
    /// ended, while the harness still parents what it moved out of it.
    fn note_under(&mut self) {
        for p in super::tree::descendants(&[std::process::id()]) {
            if !self.under.contains(&p) {
                self.under.push(p);
            }
        }
    }

    /// Number and retain one entry, and send it to a resumed controller.
    fn push(&mut self, entry: Entry) {
        self.next_h += 1;
        let h = self.next_h;
        let weight = entry.weight();
        if matches!(entry, Entry::Exit { .. }) {
            self.exit_h = Some(h);
        }
        if let Some(c) = self.controller.as_ref().filter(|c| c.resumed)
            && c.tx.send(HostFrame::Entry { h, e: entry.clone() }).is_err()
        {
            // The connection closed; the next owner resumes from the buffer.
            self.controller = None;
        }
        self.entries.push_back((h, entry, weight));
        self.weight += weight;
    }

    fn on_stderr(&mut self, line: String) {
        // Diagnostics only: over the cap they are counted, not kept.
        if self.weight > self.spec.buffer_cap {
            self.stderr_dropped += 1;
            return;
        }
        if self.stderr_dropped > 0 {
            let n = std::mem::take(&mut self.stderr_dropped);
            self.push(Entry::Err {
                line: format!("[{n} stderr lines dropped while no controller read them]"),
            });
        }
        self.push(Entry::Err { line });
    }

    fn drop_through(&mut self, h: u64) {
        if h <= self.acked_h {
            return;
        }
        self.acked_h = h.min(self.next_h);
        while self.entries.front().is_some_and(|(eh, _, _)| *eh <= self.acked_h) {
            if let Some((_, _, w)) = self.entries.pop_front() {
                self.weight -= w;
            }
        }
    }

    /// Claude's background shells ended with it (cx-ncc.84): each still
    /// running is reported stopped, before the exit entry.
    async fn end_background_shells(&mut self) {
        if let Some(tr) = self.translator.clone() {
            for m in tr.end_background_shells().await {
                self.push(Entry::In { msg: m.to_value() });
            }
        }
    }

    /// The exit entry follows the last output line and stderr line.
    fn maybe_push_exit(&mut self) {
        if self.exit_h.is_none()
            && self.stdout_done
            && self.stderr_done
            && let Some(code) = self.leader_code
        {
            self.push(Entry::Exit { code });
        }
    }

    /// The harness ended and the controller logged its exit.
    fn finished(&self) -> bool {
        self.exit_h.is_some_and(|h| self.acked_h >= h)
    }

    async fn on_stdout(&mut self, line: String) {
        if line.trim().is_empty() {
            return;
        }
        // A line no frame can carry would wedge every replay.
        if line.len() > MAX_FRAME - 4096 {
            self.push(Entry::Err {
                line: format!(
                    "[stdout line of {} bytes dropped: over the frame limit]",
                    line.len()
                ),
            });
            // An answer that cannot be carried still ends its request.
            // For Claude only its final `result` (or a control answer) ends
            // requests; other oversized lines carry tool output and are
            // dropped with the note above.
            let claude_answer = serde_json::from_str::<Value>(&line)
                .ok()
                .and_then(|v| v.get("type").and_then(Value::as_str).map(str::to_owned))
                .is_some_and(|t| t == "result" || t == "control_response");
            if let Some(cx) = self.codex.clone() {
                // An answer to one of the translator's requests: it gets an
                // error in its place, so what waits on it is answered.
                if let Ok(v) = serde_json::from_str::<Value>(&line)
                    && let Some(id) = v.get("id").filter(|_| v.get("method").is_none())
                {
                    let err = serde_json::json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32603, "message": "codex app-server answer was over the size limit"}});
                    self.codex_out(cx.from_server(&err));
                }
            } else if let Some(tr) = self.translator.clone() {
                if claude_answer {
                    for m in tr.fail_pending("agent answer was over the size limit").await {
                        self.push(Entry::In { msg: m.to_value() });
                    }
                }
            } else if let Ok(v) = serde_json::from_str::<Value>(&line)
                && let Some(id) = v.get("id").filter(|_| v.get("method").is_none())
            {
                let err = crate::rpc::RpcError::internal("agent answer was over the size limit");
                self.push(Entry::In { msg: Message::err(id.clone(), err).to_value() });
            }
            return;
        }
        if let Some(cx) = self.codex.clone() {
            let raw: Value = match serde_json::from_str(&line) {
                Ok(v) => v,
                Err(_) => {
                    self.push(Entry::Err { line: format!("[non-json stdout] {line}") });
                    return;
                }
            };
            if let Some(kind) = crate::codex_app_server::tap_kind(&raw) {
                self.push(Entry::Tap {
                    dir: TapDir::In,
                    msg: Message::notification(&kind, crate::codex_app_server::redact(&raw))
                        .to_value(),
                });
            }
            self.codex_out(cx.from_server(&raw));
            return;
        }
        let Some(tr) = self.translator.clone() else {
            match Message::parse(&line) {
                Ok(m) => self.push(Entry::In { msg: m.to_value() }),
                Err(_) => self.push(Entry::Err { line: format!("[non-json stdout] {line}") }),
            }
            return;
        };
        let raw: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => {
                self.push(Entry::Err { line: format!("[non-json stdout] {line}") });
                return;
            }
        };
        // Keep the raw Claude line in the log under its own kind.
        self.push(Entry::Tap {
            dir: TapDir::In,
            msg: crate::claude_stdio::logged_line(&raw).to_value(),
        });
        let translated = tr.inbound(&raw).await;
        for l in tr.take_stdin_replies().await {
            self.write_claude_line(l);
        }
        for m in translated {
            self.push(Entry::In { msg: m.to_value() });
        }
    }

    /// What the Codex translator produced: lines for the app-server, ACP
    /// messages for the controller.
    fn codex_out(&mut self, outs: Vec<cmux_codex_acp::Out>) {
        let split = crate::codex_app_server::split(outs);
        for l in split.server {
            self.write_codex_line(l);
        }
        for m in split.hub {
            self.push(Entry::In { msg: crate::codex_app_server::into_value(m) });
        }
    }

    /// The app-server's output ended: the translator answers what waits on
    /// it, before the exit entry.
    fn codex_closed(&mut self) {
        if let Some(cx) = self.codex.clone() {
            self.codex_out(cx.server_closed("it exited"));
        }
    }

    fn write_codex_line(&mut self, line: Value) {
        self.push(Entry::Tap {
            dir: TapDir::Out,
            msg: Message::notification(
                crate::codex_app_server::STDIN_KIND,
                crate::codex_app_server::redact(&line),
            )
            .to_value(),
        });
        let _ = self.stdin_tx.send(Stdin::Line(crate::codex_app_server::line(&line)));
    }

    /// Logs a line's receipt (`WRITTEN_METHOD`) as an entry, which reaches this controller or
    /// the next one exactly once.
    fn receipt(&mut self, receipt: u64, written: bool) {
        let note = serde_json::json!({"receipt": receipt, "written": written});
        self.push(Entry::Tap {
            dir: TapDir::Out,
            msg: Message::notification(super::WRITTEN_METHOD, note).to_value(),
        });
    }

    fn write_claude_line(&mut self, line: Value) {
        self.push(Entry::Tap {
            dir: TapDir::Out,
            msg: Message::notification("claude.stdin", line.clone()).to_value(),
        });
        let mut s = line.to_string();
        s.push('\n');
        let _ = self.stdin_tx.send(Stdin::Line(s));
    }

    async fn on_line(&mut self, msg: Value) {
        let Ok(message) = Message::from_value(msg) else { return };
        if let Message::Request { id, .. } = &message
            && let Some(n) = id.as_i64()
        {
            self.max_out_id = self.max_out_id.max(n);
        }
        if let Some(cx) = self.codex.clone() {
            self.push(Entry::Tap {
                dir: TapDir::Out,
                msg: crate::codex_app_server::redact(&message.to_value()),
            });
            // Answers and updates the translator gives itself go out as if Codex sent them.
            self.codex_out(cx.from_client(&message.to_value()));
            return;
        }
        let Some(tr) = self.translator.clone() else {
            self.push(Entry::Tap { dir: TapDir::Out, msg: message.to_value() });
            let _ = self.stdin_tx.send(Stdin::Line(message.to_line()));
            return;
        };
        self.push(Entry::Tap { dir: TapDir::Out, msg: message.to_value() });
        match tr.outbound(&message).await {
            Outbound::Lines(lines) => {
                for l in lines {
                    self.write_claude_line(l);
                }
            }
            // An immediate local answer, as if Claude replied.
            Outbound::Reply(reply) => self.push(Entry::In { msg: reply.to_value() }),
        }
    }

    async fn on_frame(&mut self, id: u64, frame: Option<ControllerFrame>) {
        let is_owner = self.controller.as_ref().is_some_and(|c| c.id == id);
        let Some(frame) = frame else {
            if is_owner {
                self.controller = None;
            }
            if self.last_owner == Some(id) {
                // A pooled host nobody took yet belongs to that daemon alone
                // (a new daemon ends every one it finds): its controller
                // gone, it ends. A promoted host keeps the same link, and a
                // kept host waits for the next daemon.
                self.unadoptable |= still_pooled(&self.spec);
            }
            self.pending_conns.retain(|(pid, _)| *pid != id);
            return;
        };
        if let ControllerFrame::Hello { min, max, token, .. } = &frame {
            if self.stall_hello {
                return;
            }
            let Some(pos) = self.pending_conns.iter().position(|(pid, _)| *pid == id) else {
                return;
            };
            let (_, tx) = self.pending_conns.remove(pos);
            if !constant_time_eq(token.as_bytes(), self.record.owner_token.as_bytes()) {
                return;
            }
            let Some(version) = negotiate(*min, *max) else {
                let _ = tx.send(HostFrame::Incompatible {
                    min: PROTOCOL_MIN,
                    max: PROTOCOL_MAX,
                    host_build: self.record.host_build.clone(),
                });
                return;
            };
            if let Some(old) = self.controller.take() {
                let _ = old.tx.send(HostFrame::Superseded);
            }
            let exited = self.exit_h.map(|_| self.leader_code.unwrap_or(None));
            let _ = tx.send(HostFrame::HostHello {
                version,
                host_build: self.record.host_build.clone(),
                incarnation: self.record.incarnation.clone(),
                harness_pid: self.record.harness_pid,
                last_h: self.next_h,
                acked_h: self.acked_h,
                max_out_id: self.max_out_id,
                exited,
            });
            self.controller = Some(Controller { id, tx, resumed: false });
            self.last_owner = Some(id);
            return;
        }
        if !is_owner {
            return;
        }
        match frame {
            ControllerFrame::Hello { .. } => {}
            ControllerFrame::Resume { after } => {
                // The controller logged everything through `after`.
                self.drop_through(after);
                let backlog: Vec<HostFrame> = self
                    .entries
                    .iter()
                    .map(|(h, e, _)| HostFrame::Entry { h: *h, e: e.clone() })
                    .collect();
                let Some(c) = self.controller.as_mut() else { return };
                for frame in backlog {
                    if c.tx.send(frame).is_err() {
                        self.controller = None;
                        return;
                    }
                }
                c.resumed = true;
            }
            ControllerFrame::Line { msg, receipt } => {
                // Logged before any line of it is queued, so a log that has one of its lines has
                // this too, and a next daemon knows the line is fenced (`QUEUED_METHOD`).
                if let Some(receipt) = receipt {
                    let note = serde_json::json!({"receipt": receipt});
                    self.push(Entry::Tap {
                        dir: TapDir::Out,
                        msg: Message::notification(super::QUEUED_METHOD, note).to_value(),
                    });
                }
                self.on_line(msg).await;
                // Behind every line of it: the writer answers once they are written.
                // Its stdin writer stopped (the harness's stdin closed): never written.
                if let Some(receipt) = receipt
                    && self.stdin_tx.send(Stdin::Receipt(receipt)).is_err()
                {
                    self.receipt(receipt, false);
                }
            }
            ControllerFrame::Ack { h } => self.drop_through(h),
            ControllerFrame::Terminate { grace_ms } => {
                if let Some(pg) = self
                    .pgid
                    .filter(|_| self.leader_alive.load(std::sync::atomic::Ordering::SeqCst))
                {
                    self.under = tokio::task::spawn_blocking(|| {
                        super::tree::descendants(&[std::process::id()])
                    })
                    .await
                    .unwrap_or_default();
                    // SAFETY: the harness leads this process group.
                    unsafe { libc::killpg(pg, libc::SIGTERM) };
                    let grace = std::time::Duration::from_millis(grace_ms);
                    let alive = self.leader_alive.clone();
                    // A bounded kill deadline, not synchronization: the exit
                    // entry is the signal that the harness ended.
                    tokio::spawn(async move {
                        tokio::time::sleep(grace).await;
                        if alive.load(std::sync::atomic::Ordering::SeqCst) {
                            // SAFETY: the leader is unreaped, so the group is ours.
                            unsafe { libc::killpg(pg, libc::SIGKILL) };
                        }
                    });
                }
                if let Some(c) = self.controller.as_ref() {
                    let _ = c.tx.send(HostFrame::TerminateAck);
                }
            }
            ControllerFrame::Query { .. } if claim_query_stall(&self.spec.env) => {}
            ControllerFrame::Query { id } => {
                let (claude_session_id, modes, config_options) = match self.translator.clone() {
                    Some(tr) => (
                        tr.session_id.lock().await.clone(),
                        Some(tr.modes_value().await),
                        Some(tr.config_options_value().await),
                    ),
                    None => (None, None, None),
                };
                if let Some(c) = self.controller.as_ref() {
                    let _ = c.tx.send(HostFrame::QueryReply {
                        id,
                        claude_session_id,
                        modes,
                        config_options,
                    });
                }
            }
            ControllerFrame::Detach => {
                if let Some(c) = self.controller.take() {
                    let _ = c.tx.send(HostFrame::DetachAck);
                }
            }
        }
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// Block until process `pid` (a child of this process) has exited, without
/// reaping it: the zombie keeps its process group id from being reused.
/// Call it off the async runtime. False when the wait failed (for example
/// another reaper took the child): the group id is then not proven ours.
fn wait_exit_unreaped(pid: i32) -> bool {
    loop {
        // SAFETY: a zeroed siginfo_t is a valid out-parameter for waitid.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        // SAFETY: waits on this process's own child; WNOWAIT leaves it
        // waitable, so the reaper below still gets its status.
        let rc = unsafe {
            libc::waitid(libc::P_PID, pid as libc::id_t, &mut info, libc::WEXITED | libc::WNOWAIT)
        };
        if rc == 0 {
            return true;
        }
        if std::io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
            return false;
        }
    }
}

/// The host was started in the pool directory and its record is still
/// there (not promoted into the hosts directory).
fn still_pooled(spec: &SpawnSpec) -> bool {
    spec.hosts_dir.file_name().and_then(|n| n.to_str()) == Some(POOL_DIR_NAME)
        && record_path(&spec.hosts_dir, &spec.session_id).exists()
}

/// Whether a daemon can still find this host: its record (this incarnation's,
/// by start nonce) is in its hosts directory, or (a promoted pooled host) in
/// the parent hosts directory. A newer host of the same session that wrote
/// its own record makes this one unadoptable.
fn record_present(spec: &SpawnSpec, nonce: &str) -> bool {
    if names_this_host(&record_path(&spec.hosts_dir, &spec.session_id), nonce) {
        return true;
    }
    spec.hosts_dir.file_name().and_then(|n| n.to_str()) == Some(POOL_DIR_NAME)
        && spec
            .hosts_dir
            .parent()
            .is_some_and(|hosts| names_this_host(&record_path(hosts, &spec.session_id), nonce))
}

/// Watches the directories that hold this host's record (kqueue on macOS,
/// inotify on Linux; `record_watch.rs`; no polling). When the record is gone
/// (the daemon's home was deleted, or a daemon removed the record), no daemon
/// can ever adopt this host: it ends like SIGTERM. Every event only triggers a
/// stat; a record rewritten in place (write, then rename) is still present.
fn watch_record(
    spec: &SpawnSpec,
    nonce: &str,
    tx: mpsc::Sender<Event>,
) -> Option<super::record_watch::DirWatch> {
    let watched = spec.clone();
    let own = nonce.to_owned();
    let term = tx.clone();
    let mut dirs = vec![spec.hosts_dir.clone()];
    if spec.hosts_dir.file_name().and_then(|n| n.to_str()) == Some(POOL_DIR_NAME)
        && let Some(hosts) = spec.hosts_dir.parent()
    {
        dirs.push(hosts.to_path_buf());
    }
    let watch = super::record_watch::DirWatch::start(&dirs, move || {
        if record_present(&watched, &own) {
            return false;
        }
        // The watch thread is not a runtime thread: a blocking send never
        // drops the end when the event queue is full.
        let _ = term.blocking_send(Event::Term);
        true
    });
    // The record may have gone before the watch began (the home deleted
    // right after the start): check once now.
    if !record_present(spec, nonce) {
        let _ = tx.try_send(Event::Term);
    }
    watch
}

#[cfg(test)]
mod tests {
    /// A pooled host ends at the end of its wait only when no controller
    /// ever said `Hello`; a session's host never ends this way.
    #[test]
    fn only_a_pooled_host_with_no_controller_yet_ends_after_its_wait() {
        assert!(super::pooled_without_owner(true, None));
        assert!(!super::pooled_without_owner(true, Some(1)));
        assert!(!super::pooled_without_owner(false, None));
    }

    /// The leader is waited for without being reaped: while it is a zombie
    /// its process group id cannot be reused, so ending the group then can
    /// never signal another process group.
    #[test]
    fn waiting_for_the_leader_leaves_it_unreaped() {
        let mut child =
            std::process::Command::new("/bin/sh").args(["-c", "exit 3"]).spawn().unwrap();
        let pid = child.id() as i32;
        assert!(super::wait_exit_unreaped(pid), "the wait failed");
        // SAFETY: signal 0 to this test's own child only checks existence.
        assert_eq!(unsafe { libc::kill(pid, 0) }, 0, "the leader was reaped by the wait");
        assert_eq!(child.wait().unwrap().code(), Some(3), "the exit status is kept for the reaper");
    }
}
