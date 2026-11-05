//! The VM provisioning exec gives the RUNNING daemon the person key (Cloud machines, M3 of
//! cmuxterm-hq `plans/cloud/ARCHITECTURE-2026-11.md`).
//!
//! Before, the provisioning exec stopped acpmux.service and the daemon, then started a keyed
//! daemon of its own (`start_keyed`): two Freestyle execs, and the unit (`Restart=always`,
//! `daemon run --take-over`) came back and competed with the keyed daemon for the socket. Now the
//! exec, which runs as root, hands the key to the daemon that already runs, over its unix socket
//! (`acpmux daemon enroll --person-key-fd 0`): one exec, one owner, no restart, and the agents keep
//! running.
//!
//! The rules of `--person-key-fd` hold (`hub/person.rs`):
//! - Cloud machines only: a daemon is [`provisionable`] when it runs on Linux with the image's
//!   root-owned `/etc/cmux/daemon-layout`, is not root (its agents are not root) and is not
//!   Team-signed (a signed daemon enrolls the signed app by its signature only).
//! - Not dumpable for its whole run: a provisionable daemon makes itself not dumpable at start,
//!   before it spawns anything ([`at_start`]), so an agent of the same user can neither ptrace it nor
//!   read its memory, before or after it holds the key. The key never reaches a child.
//! - Only root may give it. The daemon takes `_acpmux/person_enroll` without the app's signature only
//!   on a connection whose peer uid (`SO_PEERCRED`) is 0 ([`accept_provisioner`]). An agent runs as
//!   the daemon's user, so it cannot.
//! - The key goes only to the real daemon. The provisioner turns on `SO_PASSCRED`, so the kernel
//!   names the process that WROTE each reply it reads (not only the one that called `listen`, which a
//!   squatter can fork away from). Before it writes the key, every reply so far must come from the
//!   socket's listener, and that process must be the real daemon ([`check_daemon`]): not root, the
//!   owner of the acpmux home, this same executable file, holding the home's daemon lock, not
//!   dumpable (its /proc files are root's), not traced, and every executable mapping an unwritten
//!   page of a root-owned file (no preloaded library of the user's, no patched or anonymous code). A
//!   squatter, a relay, or a daemon too old to have made itself not dumpable gets nothing, and the
//!   exec falls back to the keyed restart.
//!
//! The threat model is `_acpmux/person_holds`'s (docs/acpmux-schema.json): it stops agents and
//! scripts of the daemon's user that cannot write that user's home or binary. One that can, on a
//! kernel that lets it ptrace its own processes, could still tamper with the data of a daemon it
//! started before that daemon made itself not dumpable; so could it with the keyed restart this
//! replaces, which a same-user process can race the same way.

#[cfg(target_os = "linux")]
use anyhow::{Context, Result, anyhow};
#[cfg(target_os = "linux")]
use serde_json::Value;
#[cfg(target_os = "linux")]
use std::time::Duration;

/// How long `daemon enroll` waits for a daemon to answer on the socket (the unit may have just
/// been started): under the provisioning exec's 4.5 s budget.
#[cfg(target_os = "linux")]
const ANSWER_WAIT: Duration = Duration::from_millis(3_000);
/// How long one request on the provisioner's connection may take.
#[cfg(target_os = "linux")]
const REPLY_WAIT: Duration = Duration::from_millis(2_000);
/// The image's daemon layout marker: root-owned, present on Cloud machines only.
#[cfg(target_os = "linux")]
const CLOUD_MARKER: &str = "/etc/cmux/daemon-layout";

/// Whether this daemon may take a provisioned key, and made itself not dumpable for it.
#[cfg(target_os = "linux")]
static PROVISIONABLE: std::sync::OnceLock<bool> = std::sync::OnceLock::new();

/// At daemon start, before anything is spawned: a [`provisionable`] daemon makes itself not dumpable
/// for its whole run. When that fails, it takes no provisioned key.
#[cfg(target_os = "linux")]
pub(crate) fn at_start() {
    let _ = PROVISIONABLE.get_or_init(|| {
        // SAFETY: geteuid has no preconditions.
        let own = unsafe { libc::geteuid() };
        if !provisionable(
            own,
            cmux_link::app_caller::signed_app_build(),
            std::path::Path::new(CLOUD_MARKER).is_file(),
        ) {
            return false;
        }
        match super::not_dumpable() {
            Ok(()) => true,
            Err(e) => {
                tracing::warn!(
                    "this daemon takes no provisioned person key: not dumpable failed: {e}"
                );
                false
            }
        }
    });
}

#[cfg(not(target_os = "linux"))]
pub(crate) fn at_start() {}

/// Whether the peer of a socket connection the daemon just accepted is the provisioner: uid 0, on a
/// daemon that made itself not dumpable at start for it ([`at_start`]).
#[cfg(target_os = "linux")]
pub(crate) fn accept_provisioner(stream: &tokio::net::UnixStream) -> bool {
    PROVISIONABLE.get().copied().unwrap_or(false) && stream.peer_cred().is_ok_and(|c| c.uid() == 0)
}

#[cfg(not(target_os = "linux"))]
pub(crate) fn accept_provisioner(_stream: &tokio::net::UnixStream) -> bool {
    false
}

/// The rule for a daemon that may take a provisioned key: not root, not signed, on a Cloud machine.
pub(crate) fn provisionable(own_uid: u32, signed: bool, cloud_machine: bool) -> bool {
    own_uid != 0 && !signed && cloud_machine
}

/// `acpmux daemon enroll --person-key-fd FD`: as root, give the daemon that runs at this home's
/// socket the person key read from `fd`, and return its status (`personKey`, `personInstance`).
/// Never starts a daemon (as root it would make root-owned state in the user's home).
#[cfg(target_os = "linux")]
pub async fn enroll_running(fd: i32) -> Result<Value> {
    // SAFETY: geteuid has no preconditions.
    anyhow::ensure!(
        unsafe { libc::geteuid() } == 0,
        "`daemon enroll` is the VM provisioning exec's and runs as root; the app's own exec uses `daemon start --person-key-fd`"
    );
    super::not_dumpable()
        .context("make the provisioner not dumpable before it reads the person key")?;
    let key = super::read_key_line(fd)?;
    let home = crate::config::home();
    let path = crate::config::socket_path();
    tokio::task::spawn_blocking(move || enroll_blocking(&key, &home, &path))
        .await
        .map_err(|e| anyhow!("{e}"))?
}

#[cfg(target_os = "linux")]
fn enroll_blocking(key: &str, home: &std::path::Path, path: &std::path::Path) -> Result<Value> {
    use std::fmt::Write as _;
    let mut conn = Conn::connect(path)?;
    conn.call(
        r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"#,
        1,
    )
    .context("initialize")?;
    let daemon = conn.daemon()?;
    check_daemon(daemon, home, path)?;
    let mut line = zeroize::Zeroizing::new(String::with_capacity(160));
    // `key` is 64 lowercase hex characters (read_key_line checked): nothing to escape.
    let _ = write!(
        line,
        r#"{{"jsonrpc":"2.0","id":2,"method":"{}","params":{{"key":"{}"}}}}"#,
        crate::rpc::method::MUX_PERSON_ENROLL,
        key
    );
    let enrolled = conn.call(&line, 2).context("person_enroll")?;
    drop(line);
    if enrolled.get("via").and_then(Value::as_str) != Some("provisioner") {
        return Err(anyhow!(
            "the daemon at {} did not take the key from the provisioner",
            path.display()
        ));
    }
    let status = format!(
        r#"{{"jsonrpc":"2.0","id":3,"method":"{}","params":{{}}}}"#,
        crate::rpc::method::MUX_STATUS
    );
    conn.call(&status, 3).context("status")
}

/// The daemon's process: the one that listens on the socket and wrote every reply so far.
#[cfg(target_os = "linux")]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Peer {
    pub uid: u32,
    pub pid: i32,
}

/// Whether `peer` is the real daemon of `home`, before the key goes to it (module docs).
#[cfg(target_os = "linux")]
fn check_daemon(peer: Peer, home: &std::path::Path, socket: &std::path::Path) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    let at = socket.display();
    let pid = peer.pid;
    anyhow::ensure!(peer.uid != 0, "the daemon at {at} runs as root: it takes no provisioned key");
    let owner = std::fs::metadata(home).with_context(|| format!("read {}", home.display()))?.uid();
    anyhow::ensure!(
        peer.uid == owner,
        "the daemon at {at} runs as uid {}, not as the owner of {} (uid {owner})",
        peer.uid,
        home.display()
    );
    let proc = std::path::PathBuf::from(format!("/proc/{pid}"));
    let theirs = std::fs::metadata(proc.join("exe")).context("read the daemon's executable")?;
    let ours = std::fs::metadata("/proc/self/exe").context("read this executable")?;
    anyhow::ensure!(
        (theirs.dev(), theirs.ino()) == (ours.dev(), ours.ino()),
        "the daemon at {at} (pid {pid}) runs another executable than this one"
    );
    let status = proc.join("status");
    let owned = std::fs::metadata(&status).context("read the daemon's status")?.uid();
    anyhow::ensure!(
        owned == 0,
        "the daemon at {at} (pid {pid}) did not make itself not dumpable: an older acpmux, which takes no provisioned key"
    );
    let text = std::fs::read_to_string(&status).context("read the daemon's status")?;
    anyhow::ensure!(not_traced(&text), "the daemon at {at} (pid {pid}) is being traced");
    // Its code: every executable mapping an unmodified page of a root-owned file.
    let smaps =
        std::fs::read_to_string(proc.join("smaps")).context("read the daemon's mappings")?;
    for code in executable_mappings(&smaps) {
        let file = code.path;
        anyhow::ensure!(
            code.unmodified,
            "the daemon at {at} (pid {pid}) runs modified or anonymous code ({file})"
        );
        if code.kernel() {
            continue;
        }
        let ok = std::fs::metadata(file).is_ok_and(|m| {
            m.uid() == 0
                && m.mode() & 0o022 == 0
                && Some((libc::major(m.dev()), libc::minor(m.dev()), m.ino())) == code.file
        });
        anyhow::ensure!(
            ok,
            "the daemon at {at} (pid {pid}) runs code from {file}, which is not that root-owned file"
        );
    }
    // It serves this home: it holds the home's daemon lock.
    let lock =
        std::fs::metadata(home.join("daemon.lock")).context("read the home's daemon lock")?;
    let holds =
        std::fs::read_dir(proc.join("fd")).context("read the daemon's descriptors")?.any(|fd| {
            fd.ok()
                .and_then(|fd| std::fs::metadata(fd.path()).ok())
                .is_some_and(|m| (m.dev(), m.ino()) == (lock.dev(), lock.ino()))
        });
    anyhow::ensure!(
        holds,
        "the daemon at {at} (pid {pid}) does not hold the lock of {}",
        home.display()
    );
    Ok(())
}

/// Whether a /proc status text says no tracer is attached.
pub(crate) fn not_traced(status: &str) -> bool {
    status.lines().find_map(|l| l.strip_prefix("TracerPid:")).is_some_and(|v| v.trim() == "0")
}

/// One executable mapping of a /proc smaps text.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Code<'a> {
    /// Its path field (empty for an anonymous mapping).
    pub path: &'a str,
    /// (major, minor, inode) of the file it maps.
    pub file: Option<(u32, u32, u64)>,
    /// A file mapping (or the kernel's `[vdso]`/`[vsyscall]`) with no private or anonymous page:
    /// nothing wrote to its code.
    pub unmodified: bool,
}

impl Code<'_> {
    /// The kernel's own code pages, not a file.
    pub fn kernel(&self) -> bool {
        matches!(self.path, "[vdso]" | "[vsyscall]")
    }
}

/// The executable mappings of a /proc smaps text: each header line (`start-end perms offset dev
/// inode path`) whose perms hold `x`, with whether its block says no page was written.
pub(crate) fn executable_mappings(smaps: &str) -> Vec<Code<'_>> {
    let mut out: Vec<Code<'_>> = Vec::new();
    let mut current: Option<Code<'_>> = None;
    for line in smaps.lines() {
        let mut fields = line.split_whitespace();
        let (Some(first), Some(second)) = (fields.next(), fields.next()) else { continue };
        let header = first.contains('-') && !first.ends_with(':') && second.len() == 4;
        if header {
            out.extend(current.take());
            let (Some(dev), Some(inode)) = (fields.nth(1), fields.next()) else { continue };
            if second.contains('x') {
                let path = path_field(line);
                let file = dev.split_once(':').and_then(|(major, minor)| {
                    Some((
                        u32::from_str_radix(major, 16).ok()?,
                        u32::from_str_radix(minor, 16).ok()?,
                        inode.parse::<u64>().ok()?,
                    ))
                });
                let named = !path.is_empty()
                    && !path.ends_with(" (deleted)")
                    && (!path.starts_with('[') || matches!(path, "[vdso]" | "[vsyscall]"));
                current = Some(Code { path, file, unmodified: named });
            }
            continue;
        }
        if let Some(code) = current.as_mut()
            && matches!(first, "Private_Dirty:" | "Anonymous:")
            && second != "0"
        {
            code.unmodified = false;
        }
    }
    out.extend(current);
    out
}

/// The path field of a /proc maps or smaps header line: everything after the inode, trimmed.
fn path_field(line: &str) -> &str {
    let mut rest = line;
    for _ in 0..5 {
        rest = rest.trim_start();
        rest = rest.find(char::is_whitespace).and_then(|at| rest.get(at..)).unwrap_or("");
    }
    rest.trim()
}

/// Newline-delimited JSON-RPC over the provisioner's one connection, reading each reply with the
/// kernel's credentials of the process that wrote it (`SO_PASSCRED`).
#[cfg(target_os = "linux")]
struct Conn {
    stream: std::os::unix::net::UnixStream,
    buf: Vec<u8>,
    /// The listener (`SO_PEERCRED`).
    listener: Peer,
    /// Every process that wrote a byte read so far.
    writers: Vec<Peer>,
}

#[cfg(target_os = "linux")]
impl Conn {
    /// Connect to `path`, retrying while nothing listens yet for at most [`ANSWER_WAIT`].
    fn connect(path: &std::path::Path) -> Result<Self> {
        use std::os::fd::AsRawFd;
        let deadline = std::time::Instant::now() + ANSWER_WAIT;
        let stream = loop {
            match std::os::unix::net::UnixStream::connect(path) {
                Ok(stream) => break stream,
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
                    ) && std::time::Instant::now() < deadline =>
                {
                    std::thread::sleep(Duration::from_millis(50));
                }
                Err(e) => return Err(anyhow!("no daemon answers at {}: {e}", path.display())),
            }
        };
        let fd = stream.as_raw_fd();
        let on: libc::c_int = 1;
        // SAFETY: a valid socket descriptor and a c_int option of its size. Before anything is sent:
        // every reply then carries its writer's credentials.
        let set = unsafe {
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_PASSCRED,
                (&on as *const libc::c_int).cast(),
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            )
        };
        anyhow::ensure!(set == 0, "SO_PASSCRED: {}", std::io::Error::last_os_error());
        stream.set_read_timeout(Some(REPLY_WAIT))?;
        stream.set_write_timeout(Some(REPLY_WAIT))?;
        let listener = peer_cred(fd)?;
        Ok(Self { stream, buf: Vec::new(), listener, writers: Vec::new() })
    }

    /// The daemon, when the listener wrote every reply read so far.
    fn daemon(&self) -> Result<Peer> {
        anyhow::ensure!(!self.writers.is_empty(), "the daemon's replies carried no credentials");
        anyhow::ensure!(
            self.writers.iter().all(|w| *w == self.listener),
            "another process than the socket's listener answered (pid {} listens)",
            self.listener.pid
        );
        Ok(self.listener)
    }

    /// Send `line` and wait for the reply whose id is `id`; its result, or its error.
    fn call(&mut self, line: &str, id: u64) -> Result<Value> {
        use std::io::Write;
        (&self.stream).write_all(line.as_bytes())?;
        (&self.stream).write_all(b"\n")?;
        loop {
            while let Some(end) = self.buf.iter().position(|b| *b == b'\n') {
                let text: Vec<u8> = self.buf.drain(..=end).collect();
                let Ok(reply) = serde_json::from_slice::<Value>(&text) else { continue };
                if reply.get("id").and_then(Value::as_u64) != Some(id) {
                    continue;
                }
                // Only a reply the listener wrote counts (the key goes out only after this held).
                self.daemon()?;
                if let Some(error) = reply.get("error") {
                    let message = error.get("message").and_then(Value::as_str).unwrap_or("error");
                    return Err(anyhow!("{message}"));
                }
                return Ok(reply.get("result").cloned().unwrap_or(Value::Null));
            }
            self.recv()?;
        }
    }

    /// One `recvmsg`: its bytes go to the buffer, its writer's credentials to `writers`.
    fn recv(&mut self) -> Result<()> {
        use std::os::fd::AsRawFd;
        let mut data = [0u8; 16 << 10];
        // u64 elements: aligned for cmsghdr.
        let mut control = [0u64; 16];
        let mut iov = libc::iovec { iov_base: data.as_mut_ptr().cast(), iov_len: data.len() };
        // SAFETY: zeroed msghdr is valid; the pointers set below outlive the call.
        let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        msg.msg_control = control.as_mut_ptr().cast();
        msg.msg_controllen = std::mem::size_of_val(&control) as _;
        // SAFETY: a valid socket descriptor and a msghdr whose buffers are live and sized.
        let n = unsafe { libc::recvmsg(self.stream.as_raw_fd(), &mut msg, libc::MSG_CMSG_CLOEXEC) };
        if n < 0 {
            let e = std::io::Error::last_os_error();
            return Err(
                if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut)
                {
                    anyhow!("the daemon did not answer within {REPLY_WAIT:?}")
                } else {
                    anyhow!("read the daemon's reply: {e}")
                },
            );
        }
        anyhow::ensure!(n > 0, "the daemon closed the connection");
        let mut writer = None;
        // SAFETY: CMSG_* walk the control buffer recvmsg filled, within msg_controllen.
        unsafe {
            let mut cmsg = libc::CMSG_FIRSTHDR(&msg);
            while !cmsg.is_null() {
                if (*cmsg).cmsg_level == libc::SOL_SOCKET
                    && (*cmsg).cmsg_type == libc::SCM_CREDENTIALS
                {
                    let cred =
                        std::ptr::read_unaligned(libc::CMSG_DATA(cmsg).cast::<libc::ucred>());
                    writer = Some(Peer { uid: cred.uid, pid: cred.pid });
                }
                cmsg = libc::CMSG_NXTHDR(&msg, cmsg);
            }
        }
        // A read without credentials names no writer: it never counts as the daemon's.
        self.writers.push(writer.unwrap_or(Peer { uid: u32::MAX, pid: -1 }));
        self.buf.extend_from_slice(data.get(..n as usize).unwrap_or_default());
        Ok(())
    }
}

/// The socket's listener (`SO_PEERCRED`).
#[cfg(target_os = "linux")]
fn peer_cred(fd: std::os::fd::RawFd) -> Result<Peer> {
    // SAFETY: zeroed ucred is valid.
    let mut cred: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: a valid socket descriptor and an output buffer of `len` bytes.
    let got = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut cred as *mut libc::ucred).cast(),
            &mut len,
        )
    };
    anyhow::ensure!(got == 0, "SO_PEERCRED: {}", std::io::Error::last_os_error());
    Ok(Peer { uid: cred.uid, pid: cred.pid })
}

#[cfg(test)]
mod tests {
    use super::{Code, executable_mappings, not_traced, provisionable};

    #[test]
    fn only_an_unsigned_user_daemon_on_a_cloud_machine_takes_a_provisioned_key() {
        assert!(provisionable(1000, false, true));
        // A root daemon's agents are root.
        assert!(!provisionable(0, false, true));
        // A signed daemon enrolls the app by its signature only.
        assert!(!provisionable(1000, true, true));
        // Not a Cloud machine (a developer's Linux box): the app's own keyed start only.
        assert!(!provisionable(1000, false, false));
    }

    #[test]
    fn a_traced_daemon_is_refused() {
        assert!(not_traced("Name:\tacpmux\nTracerPid:\t0\nUid:\t1000\n"));
        assert!(!not_traced("Name:\tacpmux\nTracerPid:\t4242\n"));
        assert!(!not_traced("Name:\tacpmux\n"));
    }

    #[test]
    fn executable_mappings_say_what_runs_and_whether_its_code_was_written() {
        let smaps = "\
55d0c0000000-55d0c1000000 r--p 00000000 fd:01 123                        /opt/cmux/store/abc/cmux-tui
Size:               4096 kB
Private_Dirty:         8 kB
55d0c1000000-55d0c2000000 r-xp 01000000 fd:01 123                        /opt/cmux/store/abc/cmux-tui
Size:              16384 kB
Private_Dirty:         0 kB
Anonymous:             0 kB
7f0000000000-7f0000100000 r-xp 00000000 fd:01 456                        /usr/lib/x86_64-linux-gnu/libc.so.6
Private_Dirty:         4 kB
Anonymous:             4 kB
7f0000400000-7f0000500000 rwxp 00000000 00:00 0
Private_Dirty:         0 kB
7ffc00000000-7ffc00002000 r-xp 00000000 00:00 0                          [vdso]
Private_Dirty:         0 kB
Anonymous:             0 kB
7f0000600000-7f0000700000 r-xp 00000000 00:01 99                         /memfd:x (deleted)
Private_Dirty:         0 kB
";
        let code = executable_mappings(smaps);
        assert_eq!(
            code,
            vec![
                Code {
                    path: "/opt/cmux/store/abc/cmux-tui",
                    file: Some((0xfd, 1, 123)),
                    unmodified: true
                },
                // A patched copy-on-write page of a real file.
                Code {
                    path: "/usr/lib/x86_64-linux-gnu/libc.so.6",
                    file: Some((0xfd, 1, 456)),
                    unmodified: false
                },
                // Anonymous executable memory.
                Code { path: "", file: Some((0, 0, 0)), unmodified: false },
                Code { path: "[vdso]", file: Some((0, 0, 0)), unmodified: true },
                Code { path: "/memfd:x (deleted)", file: Some((0, 1, 99)), unmodified: false },
            ]
        );
        assert!(code[3].kernel());
        assert!(!code[0].kernel());
    }
}
