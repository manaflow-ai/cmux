//! The agent holder, step 1 (cmuxterm-hq `docs/design/process-sharing.md`, "Agent sessions"): a
//! SIGKILL of an `__agent-host` no longer cuts its harness's turn.
//!
//! The host was the only holder of the harness's stdio pipes and of every output line it had read
//! but the daemon had not logged yet. Killed, the harness died on its next write (EPIPE), and the
//! hub started a fresh agent with the "interrupted" auto-resume prompt. Now:
//!
//! - The host moves the harness's stdout into an output ring ([`Ring`]: a memfd on Linux, an
//!   unlinked file elsewhere) before it reads a byte of it, with `splice` on Linux, so no byte is
//!   ever only in the host's memory. Each entry made from a stdout line carries the ring offset
//!   after that line (`HostFrame::Entry::o`), and a ring range is released (hole-punched) once
//!   the daemon acknowledged its lines.
//! - The daemon keeps a dup of the harness's stdin, stdout and stderr, of the ring and (Linux) of
//!   a pidfd of the harness, taken over the host's socket with `SCM_RIGHTS` ([`take`]) after every
//!   connect, a daemon restart's adoption included. The harness never sees a pipe close when its
//!   host dies.
//! - When the host dies while the harness runs, the daemon starts a replacement host ([`respawn`])
//!   with those descriptors and [`Adopt`]: the same incarnation and owner token, numbering on from
//!   the last entry the daemon logged, and reading the ring again from the last line it logged.
//!   The daemon reattaches to it as to a lost link: every open request and the turn stay.
//!
//! The harness's parent is gone after its host dies, so the replacement watches it by the pidfd
//! the first host opened while the harness was its unreaped child (Linux), or by pid and start
//! time (macOS), never by name. Its exit status is not known then: the exit entry says `None`.
//!
//! Only a harness that speaks ACP itself gets custody in this step: the Claude stream-json
//! translator and the Codex bridge still run in the host, with state a replacement can not
//! rebuild yet. On by default; `ACPMUX_AGENT_HOLDER=0` in the daemon's environment turns it off
//! ([`holder_on`]), and then nothing here runs.

use super::*;
use std::io::{Read as _, Write as _};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};

/// The daemon's switch for the agent holder (`0`: off; on by default).
pub const HOLDER_ENV: &str = "ACPMUX_AGENT_HOLDER";

/// Whether this daemon gives its hosts' harnesses an agent holder ([`HOLDER_ENV`]).
pub fn holder_on() -> bool {
    static ON: std::sync::LazyLock<bool> =
        std::sync::LazyLock::new(|| !std::env::var(HOLDER_ENV).is_ok_and(|v| v.trim() == "0"));
    *ON
}

/// Where a replacement host finds its inherited descriptors: stdin, stdout, stderr, ring, pidfd.
pub(crate) const ADOPT_FD_BASE: RawFd = 3;

/// The host's answer to `ControllerFrame::Custody`, before its descriptors.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct CustodyReply {
    /// None: no custody (a translated harness, an exited one, no ring).
    pub spec: Option<SpawnSpec>,
    #[serde(default)]
    pub harness_start: Option<u64>,
    #[serde(default)]
    pub pidfd: bool,
    /// The ring offset after the last line whose entries the daemon acknowledged: a daemon that
    /// adopted this host (a restart) logged at least that far.
    #[serde(default)]
    pub acked_o: u64,
    /// [`Adopt::harness_mark`]: the nonce the harness carries as its `HOST_MARK`.
    #[serde(default)]
    pub harness_mark: Option<String>,
}

/// The harness's start time, for its identity next to its pid (macOS: seconds and microseconds
/// since the epoch in one number). None elsewhere: Linux names the harness by a pidfd.
pub(crate) fn start_time(pid: u32) -> Option<u64> {
    #[cfg(target_os = "macos")]
    {
        // SAFETY: an all-zero proc_bsdinfo is a valid out-parameter.
        let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
        let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
        // SAFETY: `info` is `size` bytes the call fills.
        let n = unsafe {
            libc::proc_pidinfo(
                pid as libc::c_int,
                libc::PROC_PIDTBSDINFO,
                0,
                (&mut info as *mut libc::proc_bsdinfo).cast(),
                size,
            )
        };
        (n == size).then(|| info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = pid;
        None
    }
}

/// A pidfd of `pid` (Linux 5.3+); None elsewhere or when the kernel has none.
pub(crate) fn pidfd_open(pid: u32) -> Option<OwnedFd> {
    #[cfg(target_os = "linux")]
    {
        let pid = libc::pid_t::try_from(pid).ok()?;
        // SAFETY: pidfd_open takes a pid and flags and returns a new descriptor or -1.
        let raw = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0 as libc::c_uint) };
        let raw = libc::c_int::try_from(raw).ok().filter(|fd| *fd >= 0)?;
        // SAFETY: a successful pidfd_open returns a new descriptor owned here.
        Some(unsafe { OwnedFd::from_raw_fd(raw) })
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = pid;
        None
    }
}

/// Whether the process a pidfd names has exited (it is readable then).
pub(crate) fn pidfd_exited(fd: &OwnedFd) -> bool {
    let mut poll = libc::pollfd { fd: fd.as_raw_fd(), events: libc::POLLIN, revents: 0 };
    // SAFETY: one valid pollfd, no wait.
    let n = unsafe { libc::poll(&mut poll, 1, 0) };
    n > 0 && poll.revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0
}

/// A close-on-exec dup of `fd` at 3 or above.
pub(crate) fn dup(fd: RawFd) -> std::io::Result<OwnedFd> {
    // SAFETY: fcntl F_DUPFD_CLOEXEC on a descriptor the caller holds open.
    let raw = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 3) };
    if raw < 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: a new descriptor owned here.
    Ok(unsafe { OwnedFd::from_raw_fd(raw) })
}

/// The harness's stdout as the host moved it out of its pipe ([module docs](self)).
pub(crate) struct Ring {
    fd: OwnedFd,
}

impl Ring {
    /// A new, empty ring. Linux: a memfd. Elsewhere: a file in `dir`, unlinked at once.
    pub(crate) fn create(dir: &Path) -> std::io::Result<Self> {
        #[cfg(target_os = "linux")]
        {
            let _ = dir;
            // SAFETY: a NUL-terminated name and flags; returns a new descriptor or -1.
            let raw =
                unsafe { libc::memfd_create(c"acpmux-agent-ring".as_ptr(), libc::MFD_CLOEXEC) };
            if raw < 0 {
                return Err(std::io::Error::last_os_error());
            }
            // SAFETY: a new descriptor owned here.
            Ok(Self { fd: unsafe { OwnedFd::from_raw_fd(raw) } })
        }
        #[cfg(not(target_os = "linux"))]
        {
            let tag = random_hex(8).map_err(std::io::Error::other)?;
            let path = dir.join(format!(".ring-{}-{tag}", std::process::id()));
            let file = crate::home_fs::OpenOptions::new()
                .read(true)
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&path)?;
            let _ = crate::home_fs::remove_file(&path);
            Ok(Self { fd: OwnedFd::from(file) })
        }
    }

    pub(crate) fn from_fd(fd: OwnedFd) -> Self {
        Self { fd }
    }

    pub(crate) fn raw(&self) -> RawFd {
        self.fd.as_raw_fd()
    }

    /// Bytes ever appended: the next byte's offset.
    pub(crate) fn end(&self) -> std::io::Result<u64> {
        // SAFETY: an all-zero stat is a valid out-parameter.
        let mut st: libc::stat = unsafe { std::mem::zeroed() };
        // SAFETY: fstat on a descriptor owned here.
        if unsafe { libc::fstat(self.fd.as_raw_fd(), &mut st) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(st.st_size as u64)
    }

    fn read_at(&self, buf: &mut [u8], at: u64) -> std::io::Result<usize> {
        loop {
            // SAFETY: `buf` is valid for `buf.len()` bytes.
            let n = unsafe {
                libc::pread(
                    self.fd.as_raw_fd(),
                    buf.as_mut_ptr().cast(),
                    buf.len(),
                    at as libc::off_t,
                )
            };
            if n >= 0 {
                return Ok(n as usize);
            }
            let e = std::io::Error::last_os_error();
            if e.kind() != std::io::ErrorKind::Interrupted {
                return Err(e);
            }
        }
    }

    /// Moves at most `max` bytes from the nonblocking `pipe` to offset `at`: 0 at the pipe's end,
    /// `WouldBlock` when it is empty. Linux moves them in the kernel (`splice`): a SIGKILL never
    /// finds bytes read from the pipe and not in the ring.
    fn append_from(&self, pipe: RawFd, at: u64, max: usize) -> std::io::Result<usize> {
        #[cfg(target_os = "linux")]
        {
            let mut off = at as libc::loff_t;
            loop {
                // SAFETY: valid descriptors and an offset owned here.
                let n = unsafe {
                    libc::splice(
                        pipe,
                        std::ptr::null_mut(),
                        self.fd.as_raw_fd(),
                        &mut off,
                        max,
                        libc::SPLICE_F_NONBLOCK,
                    )
                };
                if n >= 0 {
                    return Ok(n as usize);
                }
                let e = std::io::Error::last_os_error();
                match e.raw_os_error() {
                    Some(libc::EINTR) => continue,
                    // A kernel or file without splice to it: the copy below.
                    Some(libc::EINVAL) | Some(libc::ENOSYS) => break,
                    _ => return Err(e),
                }
            }
        }
        let mut buf = vec![0u8; max.min(64 << 10)];
        let n = loop {
            // SAFETY: `buf` is valid for its length.
            let n = unsafe { libc::read(pipe, buf.as_mut_ptr().cast(), buf.len()) };
            if n >= 0 {
                break n as usize;
            }
            let e = std::io::Error::last_os_error();
            if e.kind() != std::io::ErrorKind::Interrupted {
                return Err(e);
            }
        };
        let mut done = 0;
        while done < n {
            // SAFETY: the filled part of `buf`.
            let w = unsafe {
                libc::pwrite(
                    self.fd.as_raw_fd(),
                    buf[done..n].as_ptr().cast(),
                    n - done,
                    (at + done as u64) as libc::off_t,
                )
            };
            if w < 0 {
                let e = std::io::Error::last_os_error();
                if e.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(e);
            }
            done += w as usize;
        }
        Ok(n)
    }

    /// Frees the ring's bytes before `to` (rounded down to a page) that are not freed yet
    /// (`released`): the daemon logged every line in them. Best effort: the bytes stay otherwise.
    pub(crate) fn release_through(&self, released: &mut u64, to: u64) {
        let to = to & !4095;
        if to <= *released {
            return;
        }
        #[cfg(target_os = "linux")]
        // SAFETY: fallocate on a descriptor owned here; KEEP_SIZE leaves the end where it is.
        unsafe {
            libc::fallocate(
                self.fd.as_raw_fd(),
                libc::FALLOC_FL_PUNCH_HOLE | libc::FALLOC_FL_KEEP_SIZE,
                *released as libc::off_t,
                (to - *released) as libc::off_t,
            );
        }
        #[cfg(target_os = "macos")]
        {
            let hole = libc::fpunchhole_t {
                fp_flags: 0,
                reserved: 0,
                fp_offset: *released as libc::off_t,
                fp_length: (to - *released) as libc::off_t,
            };
            // SAFETY: fcntl F_PUNCHHOLE with a valid argument on a descriptor owned here.
            unsafe { libc::fcntl(self.fd.as_raw_fd(), libc::F_PUNCHHOLE, &hole) };
        }
        *released = to;
    }
}

/// The harness's stdout through the ring: bytes from `read_off` on, read back from the ring, and
/// moved there from the pipe as the reader needs more.
pub(crate) struct RingPipe {
    pipe: tokio::io::unix::AsyncFd<OwnedFd>,
    ring: std::sync::Arc<Ring>,
    read_off: u64,
    end: u64,
    eof: bool,
}

impl RingPipe {
    /// Reads from `from` on: a replacement host re-reads what its daemon did not log.
    pub(crate) fn new(
        pipe: OwnedFd,
        ring: std::sync::Arc<Ring>,
        from: u64,
    ) -> std::io::Result<Self> {
        set_nonblocking(pipe.as_raw_fd())?;
        let end = ring.end()?;
        let pipe = tokio::io::unix::AsyncFd::with_interest(pipe, tokio::io::Interest::READABLE)?;
        Ok(Self { pipe, ring, read_off: from.min(end), end, eof: false })
    }
}

impl tokio::io::AsyncRead for RingPipe {
    fn poll_read(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        use std::task::Poll;
        let this = self.get_mut();
        loop {
            if this.read_off < this.end {
                let want = (buf.remaining() as u64).min(this.end - this.read_off) as usize;
                let dst = buf.initialize_unfilled_to(want);
                let n = this.ring.read_at(dst, this.read_off)?;
                buf.advance(n);
                this.read_off += n as u64;
                return Poll::Ready(Ok(()));
            }
            if this.eof {
                return Poll::Ready(Ok(()));
            }
            let mut guard = match this.pipe.poll_read_ready(cx) {
                Poll::Ready(g) => g?,
                Poll::Pending => return Poll::Pending,
            };
            match this.ring.append_from(this.pipe.get_ref().as_raw_fd(), this.end, 256 << 10) {
                Ok(0) => this.eof = true,
                Ok(n) => this.end += n as u64,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => guard.clear_ready(),
                Err(e) => return Poll::Ready(Err(e)),
            }
        }
    }
}

pub(crate) fn set_nonblocking(fd: RawFd) -> std::io::Result<()> {
    // SAFETY: fcntl on a descriptor the caller holds open.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    // SAFETY: as above.
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

/// What the host keeps to hand custody over: dups of the harness's pipes, its ring, its pidfd.
pub(crate) struct HostFds {
    pub stdin: OwnedFd,
    pub stdout: OwnedFd,
    pub stderr: OwnedFd,
    pub ring: std::sync::Arc<Ring>,
    pub pidfd: Option<OwnedFd>,
    pub harness_start: Option<u64>,
}

impl HostFds {
    /// Sends the reply and the descriptors on `socket` (a dup of a connection that said only
    /// `Custody`): a length-prefixed JSON reply, then one descriptor per message.
    pub(crate) fn send(
        &self,
        socket: OwnedFd,
        spec: &SpawnSpec,
        acked_o: u64,
        harness_mark: &str,
    ) -> std::io::Result<()> {
        let stream = std::os::unix::net::UnixStream::from(socket);
        let reply = CustodyReply {
            spec: Some(spec.clone()),
            harness_start: self.harness_start,
            pidfd: self.pidfd.is_some(),
            acked_o,
            harness_mark: Some(harness_mark.to_owned()),
        };
        write_sync_frame(&stream, &reply)?;
        let mut fds = vec![
            self.stdin.as_raw_fd(),
            self.stdout.as_raw_fd(),
            self.stderr.as_raw_fd(),
            self.ring.raw(),
        ];
        fds.extend(self.pidfd.as_ref().map(AsRawFd::as_raw_fd));
        for fd in fds {
            cmux_unix_socket::descriptor::send(&stream, b"f", fd)?;
        }
        Ok(())
    }
}

/// Refuses custody on `socket`: the daemon then keeps none.
pub(crate) fn refuse(socket: OwnedFd) {
    let stream = std::os::unix::net::UnixStream::from(socket);
    let _ = write_sync_frame(
        &stream,
        &CustodyReply {
            spec: None,
            harness_start: None,
            pidfd: false,
            acked_o: 0,
            harness_mark: None,
        },
    );
}

fn write_sync_frame<T: Serialize>(
    mut stream: &std::os::unix::net::UnixStream,
    v: &T,
) -> std::io::Result<()> {
    let body = serde_json::to_vec(v)?;
    let mut buf = Vec::with_capacity(body.len() + 4);
    buf.extend_from_slice(&(body.len() as u32).to_be_bytes());
    buf.extend_from_slice(&body);
    // The connection's description is nonblocking (tokio owns it): a full socket is retried.
    let mut done = 0;
    let mut tries = 0;
    while done < buf.len() {
        match stream.write(&buf[done..]) {
            Ok(n) => done += n,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock && tries < 200 => {
                tries += 1;
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

/// The daemon's copy of a harness's stdio, ring and pidfd, with what a replacement host needs.
pub struct Custody {
    pub spec: SpawnSpec,
    /// The host it came from.
    pub record: HostRecord,
    /// [`CustodyReply::acked_o`].
    pub acked_o: u64,
    /// [`CustodyReply::harness_mark`].
    pub harness_mark: Option<String>,
    harness_start: Option<u64>,
    stdin: OwnedFd,
    stdout: OwnedFd,
    stderr: OwnedFd,
    ring: OwnedFd,
    pidfd: Option<OwnedFd>,
}

impl std::fmt::Debug for Custody {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Custody").field("session", &self.record.session_id).finish()
    }
}

impl Custody {
    /// Whether the harness still runs: by its pidfd, else by pid and start time.
    pub fn harness_alive(&self) -> bool {
        let Some(pid) = self.record.harness_pid else { return false };
        if let Some(fd) = &self.pidfd {
            return !pidfd_exited(fd);
        }
        // SAFETY: signal 0 only checks existence.
        let exists = unsafe { libc::kill(pid as i32, 0) } == 0;
        exists && (self.harness_start.is_none() || start_time(pid) == self.harness_start)
    }
}

/// Takes custody of `record`'s harness from its host (a blocking call: run it off the runtime).
/// None when the host keeps none (a translated harness, an older build, the holder off there).
pub fn take(record: &HostRecord) -> Result<Option<Custody>> {
    let timeout = Some(std::time::Duration::from_secs(10));
    let mut stream = std::os::unix::net::UnixStream::connect(&record.socket)
        .with_context(|| format!("connect {}", record.socket.display()))?;
    stream.set_read_timeout(timeout)?;
    stream.set_write_timeout(timeout)?;
    let frame = ControllerFrame::Custody { token: record.owner_token.clone() };
    write_sync_frame(&stream, &frame)?;
    let mut len = [0u8; 4];
    stream.read_exact(&mut len)?;
    let len = u32::from_be_bytes(len) as usize;
    if len > MAX_FRAME {
        bail!("custody reply of {len} bytes is over the limit");
    }
    let mut body = vec![0u8; len];
    stream.read_exact(&mut body)?;
    let reply: CustodyReply = serde_json::from_slice(&body)?;
    let Some(spec) = reply.spec else { return Ok(None) };
    let count = if reply.pidfd { 5 } else { 4 };
    let mut fds = Vec::with_capacity(count);
    for _ in 0..count {
        let (_, fd) = cmux_unix_socket::descriptor::receive(&stream, 1)?;
        fds.push(fd.ok_or_else(|| anyhow!("custody message without its descriptor"))?);
    }
    let mut fds = fds.into_iter();
    let mut next = || fds.next().ok_or_else(|| anyhow!("custody descriptor missing"));
    Ok(Some(Custody {
        spec,
        record: record.clone(),
        acked_o: reply.acked_o,
        harness_mark: reply.harness_mark,
        harness_start: reply.harness_start,
        stdin: next()?,
        stdout: next()?,
        stderr: next()?,
        ring: next()?,
        pidfd: if reply.pidfd { Some(next()?) } else { None },
    }))
}

/// Starts a replacement host for `custody`'s harness (its host died), numbering on after
/// `last_h` and reading the ring again from `replay_from`. Its record, once it runs.
#[cfg(unix)]
pub async fn respawn(
    launcher: &link::HostLauncher,
    custody: &Custody,
    last_h: u64,
    max_out_id: i64,
    replay_from: u64,
) -> Result<HostRecord> {
    let record = &custody.record;
    let harness_pid = record.harness_pid.ok_or_else(|| anyhow!("no harness pid"))?;
    let mut spec = custody.spec.clone();
    // A pooled host's record moved to the hosts directory when its session took it.
    if spec.hosts_dir.file_name().and_then(|n| n.to_str()) == Some(POOL_DIR_NAME)
        && !record_path(&spec.hosts_dir, &spec.session_id).exists()
        && let Some(hosts) = spec.hosts_dir.parent()
    {
        spec.hosts_dir = hosts.to_path_buf();
    }
    spec.holder = Some(HolderSpec {
        adopt: Some(Adopt {
            harness_pid,
            harness_start: custody.harness_start,
            incarnation: record.incarnation.clone(),
            owner_token: record.owner_token.clone(),
            caller_token: record.caller_token.clone(),
            last_h,
            max_out_id,
            replay_from,
            pidfd: custody.pidfd.is_some(),
            harness_mark: custody.harness_mark.clone(),
        }),
    });
    let mut fds = vec![
        custody.stdin.as_raw_fd(),
        custody.stdout.as_raw_fd(),
        custody.stderr.as_raw_fd(),
        custody.ring.as_raw_fd(),
    ];
    fds.extend(custody.pidfd.as_ref().map(AsRawFd::as_raw_fd));
    link::spawn_with_fds(launcher, &spec, &fds).await
}

/// A replacement host's inherited descriptors ([`ADOPT_FD_BASE`] on), owned.
pub(crate) fn inherited(
    adopt: &Adopt,
) -> Result<(OwnedFd, OwnedFd, OwnedFd, Ring, Option<OwnedFd>)> {
    let take = |i: RawFd| -> Result<OwnedFd> {
        let fd = ADOPT_FD_BASE + i;
        // SAFETY: fcntl F_GETFD only checks that the descriptor is open.
        if unsafe { libc::fcntl(fd, libc::F_GETFD) } < 0 {
            bail!("inherited descriptor {fd} is not open");
        }
        // SAFETY: the launch put this descriptor here for this process alone.
        let owned = unsafe { OwnedFd::from_raw_fd(fd) };
        // Not into the harness's children: close-on-exec from here.
        // SAFETY: fcntl on the descriptor just owned.
        unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
        Ok(owned)
    };
    let (stdin, stdout, stderr, ring) = (take(0)?, take(1)?, take(2)?, take(3)?);
    let pidfd = if adopt.pidfd { Some(take(4)?) } else { None };
    Ok((stdin, stdout, stderr, Ring::from_fd(ring), pidfd))
}
