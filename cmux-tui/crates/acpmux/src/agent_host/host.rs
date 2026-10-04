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
use tokio::process::Command;
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
    let nonce = random_hex(16);
    let live = lock_live_file(&live_path(&spec.hosts_dir, &spec.session_id, &nonce))?;
    let mut cmd = Command::new(&spec.program);
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
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&spec.socket, std::fs::Permissions::from_mode(0o600))?;
    }
    let mut child =
        cmd.spawn().with_context(|| format!("spawn {} {}", spec.program, spec.args.join(" ")))?;
    let record = HostRecord {
        record_version: RECORD_VERSION,
        session_id: spec.session_id.clone(),
        incarnation: random_hex(16),
        host_pid: std::process::id(),
        start_nonce: nonce,
        harness_pid: child.id(),
        owner_token: random_hex(32),
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
        let _ = std::fs::remove_file(&spec.socket);
        return Err(e);
    }
    Ok(Started { record, listener, child, _live: live })
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
        bail!("lock {}", path.display());
    }
    Ok(file)
}

/// What the event loop reacts to.
enum Event {
    Stdout(Option<String>),
    Stderr(Option<String>),
    Exited(Option<i32>),
    Accepted(tokio::net::UnixStream),
    Frame(u64, Option<ControllerFrame>),
    /// SIGTERM: end the harness and the host.
    Term,
}

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
    stdin_tx: mpsc::UnboundedSender<String>,
    translator: Option<Arc<Translator>>,
    pgid: Option<i32>,
    /// The harness leader has not been reaped: its group id is still ours.
    leader_alive: Arc<std::sync::atomic::AtomicBool>,
    /// Stderr lines not kept while over the buffer cap.
    stderr_dropped: u64,
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
        let (stdin_tx, mut stdin_rx) = mpsc::unbounded_channel::<String>();
        tokio::spawn(async move {
            let mut stdin = stdin;
            while let Some(line) = stdin_rx.recv().await {
                if stdin.write_all(line.as_bytes()).await.is_err() || stdin.flush().await.is_err() {
                    break;
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
            if let Some(sid) = &t.claude_session_id
                && let Ok(mut slot) = tr.session_id.try_lock()
            {
                *slot = Some(sid.clone());
            }
            tr
        });
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
            pgid,
            leader_alive,
            stderr_dropped: 0,
        };
        let mut next_conn = 0u64;
        let mut permit_out = pace_tx.try_send(()).is_ok();

        while let Some(event) = events.recv().await {
            match event {
                Event::Stdout(Some(line)) => {
                    permit_out = false;
                    state.on_stdout(line).await;
                }
                Event::Stdout(None) => {
                    permit_out = false;
                    state.stdout_done = true;
                    state.maybe_push_exit();
                }
                Event::Stderr(Some(line)) => state.on_stderr(line),
                Event::Stderr(None) => {
                    state.stderr_done = true;
                    state.maybe_push_exit();
                }
                Event::Exited(code) => {
                    state.leader_code = Some(code);
                    // Stop what the agent left running so its pipes close.
                    // The group outlives its reaped leader while members
                    // remain, so its id is not reused yet.
                    state.leader_alive.store(false, std::sync::atomic::Ordering::SeqCst);
                    if let Some(pg) = state.pgid {
                        // SAFETY: the harness led this process group.
                        unsafe { libc::killpg(pg, libc::SIGKILL) };
                    }
                    state.maybe_push_exit();
                }
                Event::Term => {
                    // The frozen end path (`terminate_unadoptable`): end the
                    // harness while its group is still ours, then the host.
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
            }
            if state.finished() {
                break;
            }
            let wanted = !state.stdout_done && state.weight <= state.spec.buffer_cap;
            if wanted && !permit_out && pace_tx.try_send(()).is_ok() {
                permit_out = true;
            }
        }
        remove_artifacts(&state.spec.hosts_dir, &state.record);
        Ok(())
    }
}

impl State {
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
            if let Some(tr) = self.translator.clone() {
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
        let kind = format!(
            "claude.{}{}",
            raw.get("type").and_then(Value::as_str).unwrap_or("?"),
            raw.get("subtype").and_then(Value::as_str).map(|s| format!(".{s}")).unwrap_or_default()
        );
        self.push(Entry::Tap {
            dir: TapDir::In,
            msg: Message::notification(&kind, raw.clone()).to_value(),
        });
        let translated = tr.inbound(&raw).await;
        for l in tr.take_stdin_replies().await {
            self.write_claude_line(l);
        }
        for m in translated {
            self.push(Entry::In { msg: m.to_value() });
        }
    }

    fn write_claude_line(&mut self, line: Value) {
        self.push(Entry::Tap {
            dir: TapDir::Out,
            msg: Message::notification("claude.stdin", line.clone()).to_value(),
        });
        let mut s = line.to_string();
        s.push('\n');
        let _ = self.stdin_tx.send(s);
    }

    async fn on_line(&mut self, msg: Value) {
        let Ok(message) = Message::from_value(msg) else { return };
        if let Message::Request { id, .. } = &message
            && let Some(n) = id.as_i64()
        {
            self.max_out_id = self.max_out_id.max(n);
        }
        let Some(tr) = self.translator.clone() else {
            self.push(Entry::Tap { dir: TapDir::Out, msg: message.to_value() });
            let _ = self.stdin_tx.send(message.to_line());
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
            self.pending_conns.retain(|(pid, _)| *pid != id);
            return;
        };
        if let ControllerFrame::Hello { min, max, token, .. } = &frame {
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
            ControllerFrame::Line { msg } => self.on_line(msg).await,
            ControllerFrame::Ack { h } => self.drop_through(h),
            ControllerFrame::Terminate { grace_ms } => {
                if let Some(pg) = self
                    .pgid
                    .filter(|_| self.leader_alive.load(std::sync::atomic::Ordering::SeqCst))
                {
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
