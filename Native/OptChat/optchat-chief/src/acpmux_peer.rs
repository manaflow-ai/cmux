//! Who answers on the acpmux socket (cx-ggai, the rule of the app's
//! `AcpmuxServerPeer`). Any same-uid process can stop the daemon and bind
//! its path; the Chief would then send it every turn, its prompts and its
//! subagents' traffic. So before the first byte, at every connect and
//! reconnect (the handoff wait included), the host checks the server peer of
//! its own connection:
//!
//! - its uid is this process's uid;
//! - its executable (symlinks resolved) is the acpmux this host runs:
//!   `ACPMUX_BIN`, else the `acpmux` beside this executable;
//! - when this host is Team-signed (macOS), the peer's code, named by its
//!   audit token, is Apple-anchored and signed by the same team.
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
    let exe = executable(peer.pid)?;
    if exe != expected {
        return Err(format!(
            "pid {} runs {}, not {}",
            peer.pid,
            exe.display(),
            expected.display()
        ));
    }
    signature(stream)
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

#[cfg(not(target_os = "macos"))]
fn signature(_stream: &UnixStream) -> Result<(), String> {
    Ok(())
}

#[cfg(target_os = "macos")]
fn signature(stream: &UnixStream) -> Result<(), String> {
    match codesign::own_team() {
        None => Ok(()),
        Some(team) => codesign::peer_signed_by(stream.as_raw_fd(), team),
    }
}

/// The Team signature check (Security.framework), as `AcpmuxServerPeer`.
#[cfg(target_os = "macos")]
mod codesign {
    use core_foundation_sys::base::{CFRelease, CFTypeRef, kCFAllocatorDefault};
    use core_foundation_sys::data::CFDataCreate;
    use core_foundation_sys::dictionary::{
        CFDictionaryCreate, CFDictionaryGetValue, CFDictionaryRef, kCFTypeDictionaryKeyCallBacks,
        kCFTypeDictionaryValueCallBacks,
    };
    use core_foundation_sys::string::{
        CFStringCreateWithBytes, CFStringGetCString, CFStringRef, kCFStringEncodingUTF8,
    };
    use std::ffi::c_void;
    use std::sync::OnceLock;

    type OSStatus = i32;
    type SecCodeRef = *const c_void;
    type SecStaticCodeRef = *const c_void;
    type SecRequirementRef = *const c_void;
    const SIGNING_INFORMATION: u32 = 1 << 1;

    #[link(name = "Security", kind = "framework")]
    unsafe extern "C" {
        static kSecCodeInfoTeamIdentifier: CFStringRef;
        static kSecGuestAttributeAudit: CFStringRef;
        fn SecCodeCopySelf(flags: u32, code: *mut SecCodeRef) -> OSStatus;
        fn SecCodeCopyStaticCode(
            code: SecCodeRef,
            flags: u32,
            out: *mut SecStaticCodeRef,
        ) -> OSStatus;
        fn SecCodeCopySigningInformation(
            code: SecStaticCodeRef,
            flags: u32,
            info: *mut CFDictionaryRef,
        ) -> OSStatus;
        fn SecCodeCopyGuestWithAttributes(
            host: SecCodeRef,
            attributes: CFDictionaryRef,
            flags: u32,
            guest: *mut SecCodeRef,
        ) -> OSStatus;
        fn SecRequirementCreateWithString(
            text: CFStringRef,
            flags: u32,
            requirement: *mut SecRequirementRef,
        ) -> OSStatus;
        fn SecCodeCheckValidity(
            code: SecCodeRef,
            flags: u32,
            requirement: SecRequirementRef,
        ) -> OSStatus;
    }

    /// Releases a CF object at the end of its scope.
    struct Owned(CFTypeRef);
    impl Drop for Owned {
        fn drop(&mut self) {
            if !self.0.is_null() {
                // SAFETY: the pointer came from a Create or Copy call.
                unsafe { CFRelease(self.0) }
            }
        }
    }

    /// This host's team when it is Team-signed; None for an ad-hoc build.
    pub fn own_team() -> Option<&'static str> {
        static TEAM: OnceLock<Option<String>> = OnceLock::new();
        TEAM.get_or_init(|| {
            // SAFETY: each out-pointer is checked, and each object released by Owned.
            unsafe {
                let mut code: SecCodeRef = std::ptr::null();
                if SecCodeCopySelf(0, &mut code) != 0 || code.is_null() {
                    return None;
                }
                let _code = Owned(code);
                let mut statik: SecStaticCodeRef = std::ptr::null();
                if SecCodeCopyStaticCode(code, 0, &mut statik) != 0 || statik.is_null() {
                    return None;
                }
                let _statik = Owned(statik);
                let mut info: CFDictionaryRef = std::ptr::null();
                if SecCodeCopySigningInformation(statik, SIGNING_INFORMATION, &mut info) != 0
                    || info.is_null()
                {
                    return None;
                }
                let _info = Owned(info.cast());
                let team =
                    CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier.cast()) as CFStringRef;
                if team.is_null() {
                    return None;
                }
                let mut buffer = [0 as std::ffi::c_char; 64];
                if CFStringGetCString(
                    team,
                    buffer.as_mut_ptr(),
                    buffer.len() as _,
                    kCFStringEncodingUTF8,
                ) == 0
                {
                    return None;
                }
                let text = std::ffi::CStr::from_ptr(buffer.as_ptr())
                    .to_string_lossy()
                    .into_owned();
                (!text.is_empty()).then_some(text)
            }
        })
        .as_deref()
    }

    /// The peer of `fd` (by its audit token) is Apple-anchored and signed by `team`.
    pub fn peer_signed_by(fd: i32, team: &str) -> Result<(), String> {
        const SOL_LOCAL: libc::c_int = 0;
        const LOCAL_PEERTOKEN: libc::c_int = 0x006;
        let refused = || Err(format!("the peer is not signed by this host's team {team}"));
        let mut token = [0u8; 32];
        let mut len = token.len() as libc::socklen_t;
        // SAFETY: token and len are valid for the sizes given; each CF object is released by Owned.
        unsafe {
            if libc::getsockopt(
                fd,
                SOL_LOCAL,
                LOCAL_PEERTOKEN,
                token.as_mut_ptr().cast(),
                &mut len,
            ) != 0
                || len as usize != token.len()
            {
                return refused();
            }
            let data =
                Owned(CFDataCreate(kCFAllocatorDefault, token.as_ptr(), token.len() as _).cast());
            if data.0.is_null() {
                return refused();
            }
            let keys = [kSecGuestAttributeAudit as *const c_void];
            let values = [data.0];
            let attributes = Owned(
                CFDictionaryCreate(
                    kCFAllocatorDefault,
                    keys.as_ptr(),
                    values.as_ptr(),
                    1,
                    &kCFTypeDictionaryKeyCallBacks,
                    &kCFTypeDictionaryValueCallBacks,
                )
                .cast(),
            );
            if attributes.0.is_null() {
                return refused();
            }
            let mut code: SecCodeRef = std::ptr::null();
            if SecCodeCopyGuestWithAttributes(std::ptr::null(), attributes.0.cast(), 0, &mut code)
                != 0
                || code.is_null()
            {
                return refused();
            }
            let _code = Owned(code);
            let text =
                format!("anchor apple generic and certificate leaf[subject.OU] = \"{team}\"");
            let string = Owned(
                CFStringCreateWithBytes(
                    kCFAllocatorDefault,
                    text.as_ptr(),
                    text.len() as _,
                    kCFStringEncodingUTF8,
                    0,
                )
                .cast(),
            );
            if string.0.is_null() {
                return refused();
            }
            let mut requirement: SecRequirementRef = std::ptr::null();
            if SecRequirementCreateWithString(string.0.cast(), 0, &mut requirement) != 0
                || requirement.is_null()
            {
                return refused();
            }
            let _requirement = Owned(requirement);
            if SecCodeCheckValidity(code, 0, requirement) != 0 {
                return refused();
            }
        }
        Ok(())
    }
}
