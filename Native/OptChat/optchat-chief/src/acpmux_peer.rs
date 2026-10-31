//! Who answers on the acpmux socket (cx-ggai, the rule of the app's
//! `AcpmuxServerPeer`). Any same-uid process can stop the daemon and bind
//! its path; the Chief would then send it every turn, its prompts and its
//! subagents' traffic. So before the first byte, at every connect and
//! reconnect (the handoff wait included), the host checks the server peer of
//! its own connection:
//!
//! - its uid is this process's uid (another user is refused);
//! - its executable (symlinks resolved) is the acpmux this host runs:
//!   `ACPMUX_BIN`, else the `acpmux` beside this executable;
//! - or, when its executable is gone (an app update moved and deleted the
//!   bundle a running acpmux came from), the kernel's code signature of the
//!   running process is Apple-anchored and has the team ID and identifier of
//!   that acpmux (`code_signature`, macOS only). A path that still exists and
//!   is another file is refused as before.
//!
//! No code-signing gate on the peer: "acpmux is too belt and suspenders
//! there" (Leo, 2026-10-23). A same-user socket is usable whatever signs the
//! binary behind it, as in `AcpmuxServerPeer`.
//!
//! With the tests' feature `test-in-process-peer` only, a peer that is this
//! process itself (an in-process fake daemon) passes. Any other peer is refused: nothing is written, and the caller gets a
//! `PermissionDenied` error naming the reason.

use std::io;
use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::rpc::{Notification, RpcClient};

/// Connects to the acpmux socket at `path`, checks its server peer, and
/// only then speaks JSON-RPC on it.
pub fn connect(
    path: &Path,
    on_notification: impl Fn(Notification) + Send + 'static,
) -> io::Result<Arc<RpcClient>> {
    let stream = UnixStream::connect(path)?;
    check(&stream, expected().as_deref()).map_err(|why| {
        io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("refused the acpmux socket peer: {why}"),
        )
    })?;
    RpcClient::over(stream, on_notification)
}

/// The acpmux executable this host runs, symlinks resolved.
pub fn expected() -> Option<PathBuf> {
    let configured = match crate::cli::env("ACPMUX_BIN") {
        Some(bin) => PathBuf::from(bin),
        // The bundled layout: acpmux beside this executable, symlinks resolved first.
        None => std::fs::canonicalize(std::env::current_exe().ok()?)
            .ok()?
            .parent()?
            .join("acpmux"),
    };
    std::fs::canonicalize(configured).ok()
}

/// Checks the server peer of `stream` against `expected` (None: refused).
pub fn check(stream: &UnixStream, expected: Option<&Path>) -> Result<(), String> {
    let peer = peer(stream)?;
    // Tests only (feature test-in-process-peer): an in-process fake daemon.
    #[cfg(feature = "test-in-process-peer")]
    if peer.pid == std::process::id() as i32 {
        return Ok(());
    }
    // SAFETY: getuid has no preconditions.
    let me = unsafe { libc::getuid() };
    if peer.uid != me {
        return Err(format!("uid {} is not this user's ({me})", peer.uid));
    }
    let Some(expected) = expected else {
        return Err("ACPMUX_BIN is not set and no acpmux is beside this executable".into());
    };
    let gone = match executable(peer.pid) {
        Ok(exe) if exe == expected => return Ok(()),
        Ok(exe) if exe.exists() => {
            return Err(format!(
                "pid {} runs {}, not {}",
                peer.pid,
                exe.display(),
                expected.display()
            ));
        }
        Ok(exe) => format!("pid {} runs {}, which is gone", peer.pid, exe.display()),
        Err(why) => why,
    };
    // Its executable is gone (an app update moved and deleted the bundle it
    // runs from): only the kernel's signature can name it (code_signature).
    moved(stream, expected).map_err(|why| format!("{gone}; {why}"))
}

/// A peer whose executable is gone passes only when the kernel's signature
/// of it is Apple-anchored and signed by the team and identifier of
/// `expected` (`code_signature`'s module doc).
fn moved(stream: &UnixStream, expected: &Path) -> Result<(), String> {
    let running = crate::code_signature::running_peer(stream)?;
    let ours = crate::code_signature::of_file(expected)?;
    crate::code_signature::verify(&running, &ours)
}

struct Peer {
    pid: i32,
    uid: u32,
}

/// The pid of `stream`'s peer (the tools socket's caller, `turn_caller.rs`).
pub(crate) fn peer_pid(stream: &UnixStream) -> Result<i32, String> {
    peer(stream).map(|p| p.pid)
}

/// The executable of `pid`, symlinks resolved where the OS gives a path.
pub(crate) fn executable_of(pid: i32) -> Result<PathBuf, String> {
    executable(pid)
}

#[cfg(target_os = "macos")]
fn peer(stream: &UnixStream) -> Result<Peer, String> {
    const SOL_LOCAL: libc::c_int = 0;
    const LOCAL_PEERPID: libc::c_int = 0x002;
    let fd = stream.as_raw_fd();
    let mut pid: libc::pid_t = 0;
    let mut len = std::mem::size_of::<libc::pid_t>() as libc::socklen_t;
    // SAFETY: pid and len are valid for the sizes given.
    let got = unsafe {
        libc::getsockopt(
            fd,
            SOL_LOCAL,
            LOCAL_PEERPID,
            (&mut pid as *mut libc::pid_t).cast(),
            &mut len,
        )
    };
    if got != 0 || pid <= 0 {
        return Err(format!(
            "the peer's pid is unknown ({})",
            io::Error::last_os_error()
        ));
    }
    let (mut uid, mut gid) = (0, 0);
    // SAFETY: uid and gid are valid out-pointers.
    if unsafe { libc::getpeereid(fd, &mut uid, &mut gid) } != 0 {
        return Err(format!(
            "the peer's uid is unknown ({})",
            io::Error::last_os_error()
        ));
    }
    Ok(Peer { pid, uid })
}

#[cfg(target_os = "linux")]
fn peer(stream: &UnixStream) -> Result<Peer, String> {
    let mut cred = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: cred and len are valid for the sizes given.
    let got = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut cred as *mut libc::ucred).cast(),
            &mut len,
        )
    };
    if got != 0 || cred.pid <= 0 {
        return Err(format!(
            "the peer is unknown ({})",
            io::Error::last_os_error()
        ));
    }
    Ok(Peer {
        pid: cred.pid,
        uid: cred.uid,
    })
}

#[cfg(target_os = "macos")]
fn executable(pid: i32) -> Result<PathBuf, String> {
    let mut buffer = vec![0u8; 4 * libc::PATH_MAX as usize];
    // SAFETY: buffer is valid for its length.
    let len = unsafe { libc::proc_pidpath(pid, buffer.as_mut_ptr().cast(), buffer.len() as u32) };
    if len <= 0 {
        return Err(format!("pid {pid}'s executable is unknown"));
    }
    buffer.truncate(len as usize);
    let path = PathBuf::from(String::from_utf8_lossy(&buffer).into_owned());
    std::fs::canonicalize(&path).or(Ok(path))
}

#[cfg(target_os = "linux")]
fn executable(pid: i32) -> Result<PathBuf, String> {
    std::fs::read_link(format!("/proc/{pid}/exe"))
        .map_err(|e| format!("pid {pid}'s executable is unknown ({e})"))
}
