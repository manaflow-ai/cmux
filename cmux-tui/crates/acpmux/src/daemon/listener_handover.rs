//! Make-before-break for the daemon's listeners (RFD 0082, Leo 2026-11-23: "we ought to have more
//! graceful handoffs... similar to network drains"). Before this, a take-over closed the unix
//! socket and the WebSocket port with the old daemon and bound them again in the new one: in
//! between a connect was refused, and every client redialed with its backoff.
//!
//! Now the old daemon hands its listening sockets to the new one by descriptor (`SCM_RIGHTS`),
//! so the listen queue never closes:
//!
//! 1. The `--take-over` start opens a private side socket in the home ([`Side::open`]) and sends
//!    its path with the `_acpmux/shutdown` it already sends (`handListeners`). A daemon from
//!    before this ignores the key and stops as it always did: the new one then binds as before
//!    (both directions of an update interoperate; an older new daemon never sends the key).
//! 2. The old daemon, on the unix socket only, connects to that path, checks that the process
//!    listening there is the one that asked, sends a copy of each listener ([`hand`]), and only
//!    then begins its stop.
//! 3. The old daemon stops accepting at once ([`handed_to_live`]), answers the requests in
//!    flight (`server/shutdown_drain.rs`), closes its WebSockets with 1012 (service restart: redial
//!    now), and leaves the socket file in place, since the new daemon serves that same socket.
//! 4. A connect in between waits in the kernel's queue, which the new daemon's copy keeps open,
//!    and is accepted once the new daemon holds the lock and serves ([`take_received`]).

use std::io;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, OwnedFd};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

/// The `_acpmux/shutdown` key that names the side socket.
pub(crate) const PARAM: &str = "handListeners";
/// The answer's key: the listeners the old daemon sent, in order.
pub(crate) const ANSWER: &str = "listenersHanded";
/// The side socket's file name prefix, in the home.
const SIDE_PREFIX: &str = "handover-";
/// Each message's payload: which listener its descriptor is.
const UNIX: &[u8; 4] = b"unix";
const WS: &[u8; 4] = b"ws\0\0";
/// How long either side waits on the other over the side socket.
// timeout: a peer that stops mid-handover; the new daemon then binds as before.
const SIDE_WITHIN: Duration = Duration::from_secs(3);

/// Copies of this daemon's listening sockets, kept to hand over.
static OFFERED: Mutex<Option<(OwnedFd, Option<OwnedFd>)>> = Mutex::new(None);
/// The pid this daemon handed its listeners to (0: none).
static HANDED_TO: AtomicU32 = AtomicU32::new(0);
/// The listeners this start received from the daemon it took over from.
static RECEIVED: Mutex<Option<Received>> = Mutex::new(None);

/// Listeners received from the old daemon.
#[derive(Debug, Default)]
pub(crate) struct Received {
    pub unix: Option<std::os::unix::net::UnixListener>,
    pub ws: Option<std::net::TcpListener>,
}

/// Keep copies of the listeners this daemon serves, to hand to a successor.
pub(crate) fn offer(unix: BorrowedFd<'_>, ws: Option<BorrowedFd<'_>>) {
    let copy = |fd: BorrowedFd<'_>| fd.try_clone_to_owned();
    let Ok(unix) = copy(unix) else { return };
    let ws = ws.and_then(|fd| copy(fd).ok());
    *OFFERED.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some((unix, ws));
}

/// A re-bound unix socket replaces the copy kept to hand over (`daemon/socket_rebind.rs`).
pub(crate) fn offer_unix(unix: BorrowedFd<'_>) {
    let Ok(unix) = unix.try_clone_to_owned() else { return };
    let mut offered = OFFERED.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let ws = offered.take().and_then(|(_, ws)| ws);
    *offered = Some((unix, ws));
}

/// Whether this daemon handed its listeners to a process that still runs: it then stops accepting
/// and leaves the socket file, which that process serves.
pub(crate) fn handed_to_live() -> bool {
    let pid = HANDED_TO.load(Ordering::SeqCst);
    pid != 0 && alive(pid)
}

fn alive(pid: u32) -> bool {
    let Ok(pid) = i32::try_from(pid) else { return false };
    // SAFETY: signal 0 only checks that the pid exists.
    let signalled = unsafe { libc::kill(pid, 0) == 0 };
    signalled || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// The old daemon's side: send copies of its listeners to the side socket at `path`, which must
/// be in `home`, named as [`Side::open`] names it, and listened on by `asker` (the pid of the unix
/// socket peer that asked). The kinds sent, in order.
pub(crate) fn hand(home: &Path, path: &Path, asker: u32) -> Result<Vec<&'static str>, String> {
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default();
    if path.parent() != Some(home) || !name.starts_with(SIDE_PREFIX) || !name.ends_with(".sock") {
        return Err(format!("{} is not a handover socket of this home", path.display()));
    }
    let offered = OFFERED.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some((unix, ws)) = offered.as_ref() else {
        return Err("no listener to hand over".into());
    };
    let stream = UnixStream::connect(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let _ = stream.set_write_timeout(Some(SIDE_WITHIN));
    if peer_pid(&stream) != Some(asker) {
        return Err(format!("{} is not served by the asking pid {asker}", path.display()));
    }
    let mut sent = Vec::new();
    cmux_unix_socket::descriptor::send(&stream, UNIX, unix.as_raw_fd())
        .map_err(|e| format!("send the unix listener: {e}"))?;
    sent.push("unix");
    if let Some(ws) = ws {
        cmux_unix_socket::descriptor::send(&stream, WS, ws.as_raw_fd())
            .map_err(|e| format!("send the web listener: {e}"))?;
        sent.push("ws");
    }
    HANDED_TO.store(asker, Ordering::SeqCst);
    Ok(sent)
}

/// The pid of the process at the other end of `stream`.
fn peer_pid(stream: &UnixStream) -> Option<u32> {
    let fd = stream.as_fd().as_raw_fd();
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        let mut cred: libc::ucred = unsafe { std::mem::zeroed() };
        let mut len = size_of::<libc::ucred>() as libc::socklen_t;
        // SAFETY: a valid socket and an out buffer of the stated size.
        let rc = unsafe {
            libc::getsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_PEERCRED,
                (&raw mut cred).cast(),
                &raw mut len,
            )
        };
        (rc == 0).then(|| u32::try_from(cred.pid).ok()).flatten()
    }
    #[cfg(target_os = "macos")]
    {
        let mut pid: libc::pid_t = 0;
        let mut len = size_of::<libc::pid_t>() as libc::socklen_t;
        // SAFETY: a valid socket and an out buffer of the stated size.
        let rc = unsafe {
            libc::getsockopt(
                fd,
                libc::SOL_LOCAL,
                libc::LOCAL_PEERPID,
                (&raw mut pid).cast(),
                &raw mut len,
            )
        };
        (rc == 0).then(|| u32::try_from(pid).ok()).flatten()
    }
    #[cfg(not(any(target_os = "linux", target_os = "android", target_os = "macos")))]
    {
        let _ = fd;
        None
    }
}

/// The new daemon's side socket, open while it asks the old daemon to hand over.
pub(crate) struct Side {
    listener: UnixListener,
    path: PathBuf,
}

impl Side {
    /// A side socket in `home`, owner-only. `None` when it cannot be made (a home path too long
    /// for a socket): the take-over then goes on as before.
    pub(crate) fn open(home: &Path) -> Option<Side> {
        let path = home.join(format!("{SIDE_PREFIX}{}.sock", std::process::id()));
        if !cmux_unix_socket::fits(&path) {
            return None;
        }
        let _ = crate::home_fs::remove_file(&path);
        let listener = match UnixListener::bind(&path) {
            Ok(l) => l,
            Err(e) => {
                tracing::warn!("no listener handover: {}: {e}", path.display());
                return None;
            }
        };
        use std::os::unix::fs::PermissionsExt as _;
        let _ = crate::home_fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
        Some(Side { listener, path })
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    /// Receive the listeners the old daemon (`from`, its pid) said it sent (`kinds`), and keep
    /// them for this start ([`take_received`]). Anything wrong keeps none: this start binds.
    pub(crate) fn receive(self, kinds: &[String], from: Option<u32>) {
        if kinds.is_empty() {
            return;
        }
        match self.read(kinds.len(), from) {
            Ok(received) => {
                tracing::info!(
                    unix = received.unix.is_some(),
                    ws = received.ws.is_some(),
                    "the daemon this start takes over from handed it its listeners"
                );
                *RECEIVED.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
                    Some(received);
            }
            Err(e) => tracing::warn!("the listener handover failed, binding instead: {e}"),
        }
    }

    fn read(&self, count: usize, from: Option<u32>) -> io::Result<Received> {
        self.listener.set_nonblocking(true)?;
        let deadline = Instant::now() + SIDE_WITHIN;
        let stream = loop {
            match self.listener.accept() {
                Ok((stream, _)) => break stream,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock && Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(e) => return Err(e),
            }
        };
        stream.set_nonblocking(false)?;
        stream.set_read_timeout(Some(SIDE_WITHIN))?;
        if from.is_some() && peer_pid(&stream) != from {
            return Err(io::Error::other("the handover came from another process"));
        }
        let mut received = Received::default();
        for _ in 0..count {
            let (kind, fd) = cmux_unix_socket::descriptor::receive(&stream, 4)?;
            let fd = fd.ok_or_else(|| io::Error::other("a handover message without a listener"))?;
            if kind.as_slice() == UNIX {
                received.unix = Some(UnixListener::from(fd));
            } else if kind.as_slice() == WS {
                received.ws = Some(std::net::TcpListener::from(fd));
            }
        }
        Ok(received)
    }
}

impl Drop for Side {
    fn drop(&mut self) {
        let _ = crate::home_fs::remove_file(&self.path);
    }
}

/// The listeners this start received, once: the daemon serves them instead of binding.
pub(crate) fn take_received() -> Received {
    RECEIVED.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take().unwrap_or_default()
}

/// A received unix listener serves `socket` only when it is bound at that path.
pub(crate) fn serves_path(listener: &UnixListener, socket: &Path) -> bool {
    listener
        .local_addr()
        .ok()
        .and_then(|a| a.as_pathname().map(Path::to_path_buf))
        .is_some_and(|bound| super::same_path(&bound, socket))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One process stands in for both daemons: the listeners it offers come back through the side
    /// socket as the same sockets (a connect to the original path is accepted by the copy).
    #[test]
    fn listeners_go_through_the_side_socket() {
        let dir = cmux_unix_socket::short_test_dir("lho");
        let home = dir.path().to_path_buf();
        let sock = home.join("a.sock");
        let unix = UnixListener::bind(&sock).unwrap();
        let tcp = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = tcp.local_addr().unwrap();
        offer(unix.as_fd(), Some(tcp.as_fd()));
        let side = Side::open(&home).unwrap();
        let path = side.path().to_path_buf();
        assert!(hand(&home, &home.join("elsewhere.sock"), std::process::id()).is_err());
        let sent = hand(&home, &path, std::process::id()).unwrap();
        assert_eq!(sent, ["unix", "ws"]);
        side.receive(&["unix".into(), "ws".into()], Some(std::process::id()));
        assert!(!path.exists(), "the side socket is removed once used");
        let got = take_received();
        drop((unix, tcp));
        let got_unix = got.unix.unwrap();
        assert!(serves_path(&got_unix, &sock));
        let _c = UnixStream::connect(&sock).unwrap();
        got_unix.accept().unwrap();
        let _t = std::net::TcpStream::connect(port).unwrap();
        got.ws.unwrap().accept().unwrap();
        HANDED_TO.store(0, Ordering::SeqCst);
    }
}
