//! An acpmux that made itself not dumpable (cx-0q7o: before it holds a person
//! key) on Linux: the kernel then refuses this same-uid host its
//! `/proc/PID/exe`, so the peer check cannot read what it runs, and every
//! Linux Chief refused its own daemon ("pid N's executable is unknown
//! (Permission denied)"). Such a peer passes only when it is the daemon this
//! host started from the expected binary (its child, never reaped while it
//! runs, so its pid is not reused); any other unreadable peer is still refused.
#![cfg(target_os = "linux")]

use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use optchat_chief::acpmux_peer::check_with;

/// A child of this process that makes itself not dumpable, then listens on
/// `path` (SO_PEERCRED names the process that called listen).
struct NotDumpable {
    pid: libc::pid_t,
}

impl NotDumpable {
    fn start(path: &Path) -> Self {
        // Bound but not listening (UnixListener::bind would listen here, and
        // then this process would be the peer).
        let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
        assert!(fd >= 0, "socket failed");
        let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
        addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
        let bytes = path.as_os_str().as_encoded_bytes();
        assert!(bytes.len() < addr.sun_path.len());
        for (slot, b) in addr.sun_path.iter_mut().zip(bytes) {
            *slot = *b as libc::c_char;
        }
        let len = std::mem::size_of::<libc::sockaddr_un>() as libc::socklen_t;
        let bound = unsafe { libc::bind(fd, (&addr as *const libc::sockaddr_un).cast(), len) };
        assert_eq!(bound, 0, "bind failed");
        // SAFETY: the child only calls async-signal-safe libc functions, then _exit.
        let pid = unsafe { libc::fork() };
        assert!(pid >= 0, "fork failed");
        if pid == 0 {
            unsafe {
                libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0);
                libc::listen(fd, 8);
                loop {
                    let c = libc::accept(fd, std::ptr::null_mut(), std::ptr::null_mut());
                    if c < 0 {
                        libc::_exit(0);
                    }
                }
            }
        }
        unsafe { libc::close(fd) };
        NotDumpable { pid }
    }
}

impl Drop for NotDumpable {
    fn drop(&mut self) {
        unsafe {
            libc::kill(self.pid, libc::SIGKILL);
            libc::waitpid(self.pid, std::ptr::null_mut(), 0);
        }
    }
}

fn connect(path: &Path) -> UnixStream {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        match UnixStream::connect(path) {
            Ok(s) => return s,
            Err(_) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(e) => panic!("connect: {e}"),
        }
    }
}

fn this_exe() -> PathBuf {
    std::fs::canonicalize(std::env::current_exe().unwrap()).unwrap()
}

#[test]
fn a_not_dumpable_daemon_this_host_started_passes_and_no_other() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("acpmux.sock");
    let child = NotDumpable::start(&path);
    let stream = connect(&path);
    // Root, or a ptrace capability in this namespace, reads any
    // /proc/PID/exe: nothing to prove there.
    if std::fs::read_link(format!("/proc/{}/exe", child.pid)).is_ok() {
        eprintln!("skipped: this process may read a not-dumpable process's exe");
        return;
    }
    let exe = this_exe();
    let pid = child.pid as u32;

    // The bug: nothing names the daemon, so it is refused.
    let why = check_with(&stream, Some(&exe), None).unwrap_err();
    assert!(why.contains("executable is unknown"), "{why}");

    // The daemon this host started from the expected binary: passes.
    check_with(&stream, Some(&exe), Some((pid, exe.as_path()))).unwrap();

    // Started from another binary, or another pid: refused.
    let other = PathBuf::from("/bin/sh");
    assert!(check_with(&stream, Some(&exe), Some((pid, other.as_path()))).is_err());
    assert!(check_with(&stream, Some(&exe), Some((pid + 1, exe.as_path()))).is_err());
}
