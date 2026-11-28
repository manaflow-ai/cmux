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
//! 5. The connections the old daemon had accepted that hold no state go the same way, on the
//!    same side socket, late in its stop ([`hand_connections`],
//!    `server/conn_handover.rs`): their clients read no end of file and redial nothing.

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
/// The `_acpmux/shutdown` key by which the asking start says it also takes the accepted
/// connections that hold no state (`server/conn_handover.rs`), on the same side socket after
/// the listeners. A start from before this never sends it, and the old daemon then keeps none.
pub(crate) const PARAM_CONNS: &str = "handConnections";
/// A moved connection's payload.
const CONN: &[u8; 4] = b"conn";
/// How long the new daemon waits for the old one's connections after it serves.
// timeout: an old daemon that never closes its side; the connections it kept end with it.
const CONNS_WITHIN: Duration = Duration::from_secs(10);
/// The side socket's file name prefix, in the home.
const SIDE_PREFIX: &str = "handover-";
/// Each message's payload: which listener its descriptor is.
const UNIX: &[u8; 4] = b"unix";
const WS: &[u8; 4] = b"ws\0\0";
const EGRESS: &[u8; 4] = b"egrs";
/// How long either side waits on the other over the side socket.
// timeout: a peer that stops mid-handover; the new daemon then binds as before.
const SIDE_WITHIN: Duration = Duration::from_secs(3);

/// Copies of this daemon's listening sockets, kept to hand over.
static OFFERED: Mutex<Option<(OwnedFd, Option<OwnedFd>)>> = Mutex::new(None);
/// A copy of the vault egress proxy's listener (`vault/egress.rs`), offered once it is bound.
static OFFERED_EGRESS: Mutex<Option<OwnedFd>> = Mutex::new(None);
/// The pid this daemon handed its listeners to (0: none).
static HANDED_TO: AtomicU32 = AtomicU32::new(0);
/// The listeners this start received from the daemon it took over from.
static RECEIVED: Mutex<Option<Received>> = Mutex::new(None);
/// The side socket to the daemon that takes over, kept to send it the connections.
static SUCCESSOR: Mutex<Option<UnixStream>> = Mutex::new(None);

/// Listeners received from the old daemon.
#[derive(Debug, Default)]
pub(crate) struct Received {
    pub unix: Option<std::os::unix::net::UnixListener>,
    pub ws: Option<std::net::TcpListener>,
    pub egress: Option<std::net::TcpListener>,
    /// The side socket, on which the old daemon sends its plain connections before it ends.
    pub conns: Option<UnixStream>,
}

/// Keep copies of the listeners this daemon serves, to hand to a successor.
pub(crate) fn offer(unix: BorrowedFd<'_>, ws: Option<BorrowedFd<'_>>) {
    let copy = |fd: BorrowedFd<'_>| fd.try_clone_to_owned();
    let Ok(unix) = copy(unix) else { return };
    let ws = ws.and_then(|fd| copy(fd).ok());
    *OFFERED.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some((unix, ws));
}

/// Keep a copy of the vault egress proxy's listener to hand to a successor.
pub(crate) fn offer_egress(egress: BorrowedFd<'_>) {
    let Ok(egress) = egress.try_clone_to_owned() else { return };
    *OFFERED_EGRESS.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(egress);
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

/// A keeper (`daemon/listener_keeper.rs`) holds copies of the listeners for the next daemon.
static KEPT: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub(crate) fn mark_kept() {
    KEPT.store(true, Ordering::SeqCst);
}

/// Whether another process holds this daemon's listening sockets for the next daemon: a live
/// successor it handed them to, or a keeper. A shutdown of the socket would stop that process's
/// copy too (Linux stops a listening socket on `shutdown`, whatever copies remain).
pub(crate) fn listeners_live_on() -> bool {
    KEPT.load(Ordering::SeqCst) || handed_to_live()
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
pub(crate) fn hand(
    home: &Path,
    path: &Path,
    asker: u32,
    conns: bool,
) -> Result<Vec<&'static str>, String> {
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
    if let Some(egress) =
        OFFERED_EGRESS.lock().unwrap_or_else(std::sync::PoisonError::into_inner).as_ref()
    {
        cmux_unix_socket::descriptor::send(&stream, EGRESS, egress.as_raw_fd())
            .map_err(|e| format!("send the egress listener: {e}"))?;
        sent.push("egress");
    }
    HANDED_TO.store(asker, Ordering::SeqCst);
    if conns {
        *SUCCESSOR.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(stream);
    }
    Ok(sent)
}

/// Copies of this daemon's TCP listeners (the web listener, the egress proxy's), with the kind
/// each goes by: what a listener keeper holds across a restart (`daemon/listener_keeper.rs`).
pub(crate) fn offered_tcp() -> Vec<(&'static [u8; 4], OwnedFd)> {
    let mut held = Vec::new();
    let offered = OFFERED.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(ws) = offered.as_ref().and_then(|(_, ws)| ws.as_ref()?.try_clone().ok()) {
        held.push((WS, ws));
    }
    drop(offered);
    let egress = OFFERED_EGRESS.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(egress) = egress.as_ref().and_then(|fd| fd.try_clone().ok()) {
        held.push((EGRESS, egress));
    }
    held
}

/// The listener a kind names, as [`Side::read`] takes it.
pub(crate) fn add_received(received: &mut Received, kind: &[u8], fd: OwnedFd) {
    if kind == UNIX {
        received.unix = Some(UnixListener::from(fd));
    } else if kind == WS {
        received.ws = Some(std::net::TcpListener::from(fd));
    } else if kind == EGRESS {
        received.egress = Some(std::net::TcpListener::from(fd));
    }
}

/// Whether the daemon that takes over asked for this one's plain connections too.
pub(crate) fn takes_connections() -> bool {
    handed_to_live()
        && SUCCESSOR.lock().unwrap_or_else(std::sync::PoisonError::into_inner).is_some()
}

/// The old daemon's side, at its stop: send the parked connections to the daemon that takes
/// over, and close the side socket, which tells it there are no more. How many went.
pub(crate) async fn hand_connections(parked: crate::server::conn_handover::Parked) -> usize {
    let Some(stream) = SUCCESSOR.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take()
    else {
        return 0;
    };
    // A few bytes each into the side socket's buffer, bounded by its write timeout.
    crate::server::conn_handover::hand(parked, |fd| {
        cmux_unix_socket::descriptor::send(&stream, CONN, fd.as_raw_fd())
    })
    .await
}

/// The new daemon's side, once it serves: read the connections the old daemon sends on `side`
/// until it closes it, and give each to `serve`. A thread of its own, so a daemon that stops
/// meanwhile never waits for it.
pub(crate) fn receive_connections(
    side: UnixStream,
    serve: impl Fn(tokio::net::UnixStream) + Send + 'static,
) {
    let runtime = tokio::runtime::Handle::current();
    let _ = std::thread::Builder::new().name("conn-handover".into()).spawn(move || {
        let _ = side.set_read_timeout(Some(CONNS_WITHIN));
        let mut served = 0usize;
        while let Ok((kind, Some(fd))) = cmux_unix_socket::descriptor::receive(&side, 4) {
            if kind.as_slice() != CONN {
                continue;
            }
            let stream = UnixStream::from(fd);
            if stream.set_nonblocking(true).is_err() {
                continue;
            }
            let _entered = runtime.enter();
            if let Ok(stream) = tokio::net::UnixStream::from_std(stream) {
                serve(stream);
                served += 1;
            }
        }
        if served > 0 {
            tracing::info!(served, "serving connections the previous daemon handed over");
        }
    });
}

/// The pid of the process at the other end of `stream`.
pub(crate) fn peer_pid(stream: &UnixStream) -> Option<u32> {
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
                    egress = received.egress.is_some(),
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
            add_received(&mut received, &kind, fd);
        }
        received.conns = Some(stream);
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

<<<<<<< ours
/// The received unix listener, ready to serve `socket`; else why not.
pub(crate) fn usable(listener: UnixListener, socket: &Path) -> Result<UnixListener, String> {
    if !serves_path(&listener, socket) {
        let bound =
            listener.local_addr().map(|a| format!("{a:?}")).unwrap_or_else(|e| e.to_string());
        return Err(format!("it is bound at {bound}, not {}", socket.display()));
    }
    if !socket.exists() {
        return Err(format!("{} is gone", socket.display()));
    }
    listener.set_nonblocking(true).map_err(|e| format!("set_nonblocking: {e}"))?;
    Ok(listener)
}

/// A received unix listener serves `socket` only when it is bound at that path, or at the staged
/// name `server/unix_bind.rs` binds before it moves the socket into place (`<dir>/.b<hex>/s`, the
/// name the kernel keeps reporting). Before, every listener the daemon bound that way was refused
/// here, so a take-over bound again while the old daemon's handed queue was still open, met it
/// ("another acpmux daemon owns ..."), and exited after the old daemon had stopped: an update's
/// swap left no daemon.
=======
/// A received unix listener serves `socket` when it is bound at that path, or at the staging name
/// `server::bind_unix` binds it at before it renames it into place (`<dir>/.b<hex>/s`, `dir` the
/// socket's own folder): the kernel keeps the name a socket was bound at, so every listener the
/// daemon bound that way names its staging path. Comparing only the bound name refused every
/// handed listener, and the start that took over then bound again, met its own copy at the socket
/// and exited with "another acpmux daemon owns" (18 of 19 daemon deaths in one home, 11-24 to
/// 11-27).
>>>>>>> theirs
pub(crate) fn serves_path(listener: &UnixListener, socket: &Path) -> bool {
<<<<<<< ours
    let Some(bound) =
        listener.local_addr().ok().and_then(|a| a.as_pathname().map(Path::to_path_buf))
    else {
        return false;
    };
    super::same_path(&bound, socket) || staged_for(&bound, socket)
}

/// Whether `bound` is `server/unix_bind.rs`'s staging name for `socket`: `s` in a `.b<hex>`
/// folder beside it.
fn staged_for(bound: &Path, socket: &Path) -> bool {
    let (Some(stage), Some(dir)) = (bound.parent(), socket.parent()) else { return false };
    let stage_name = stage.file_name().and_then(|n| n.to_str()).unwrap_or_default();
    bound.file_name() == Some(std::ffi::OsStr::new("s"))
        && stage_name
            .strip_prefix(".b")
            .is_some_and(|hex| !hex.is_empty() && hex.bytes().all(|b| b.is_ascii_hexdigit()))
        && stage.parent().is_some_and(|p| super::same_path(p, dir))
=======
    listener
        .local_addr()
        .ok()
        .and_then(|a| a.as_pathname().map(Path::to_path_buf))
        .is_some_and(|bound| super::same_path(&bound, socket) || staged_for(&bound, socket))
}

/// Whether `bound` is a staging name of `socket`: `s` in a `.b<hex>` folder beside it.
fn staged_for(bound: &Path, socket: &Path) -> bool {
    fn name(p: Option<&Path>) -> Option<&str> {
        p.and_then(Path::file_name).and_then(|n| n.to_str())
    }
    let stage = bound.parent();
    let hex = |n: &str| {
        n.strip_prefix(".b")
            .is_some_and(|h| !h.is_empty() && h.bytes().all(|b| b.is_ascii_hexdigit()))
    };
    name(Some(bound)) == Some("s")
        && name(stage).is_some_and(hex)
        && stage
            .and_then(Path::parent)
            .zip(socket.parent())
            .is_some_and(|(dir, want)| super::same_path(dir, want))
}

/// The pid of the daemon this start asked to hand over (0: none). Its listener may still answer a
/// connect for a moment after it gave up the lock, and that is no other daemon
/// (`server::bind_daemon_unix`).
static TOOK_OVER_FROM: AtomicU32 = AtomicU32::new(0);

pub(crate) fn note_took_over_from(pid: u32) {
    TOOK_OVER_FROM.store(pid, Ordering::SeqCst);
}

/// Whether the process listening behind a connect to this daemon's socket is no other daemon: this
/// process (a handed copy), the daemon it took over from (stopped: this start holds the lock), or
/// a process that no longer runs (a copy something else kept open).
pub(crate) fn listener_is_ours_or_gone(pid: u32) -> bool {
    pid == std::process::id() || pid == TOOK_OVER_FROM.load(Ordering::SeqCst) || !alive(pid)
>>>>>>> theirs
}

#[cfg(test)]
#[path = "listener_handover_tests.rs"]
mod tests;
