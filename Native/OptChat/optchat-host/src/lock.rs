//! One writer per chat (section 2): the process listens on a Unix socket
//! named `lock` in the chat directory for its whole life. A second process
//! that can connect knows the chat is taken. A socket that refuses
//! connections is stale (the OS closes it when its owner dies): it is
//! deleted and taken over. No PID files, no timeouts.
//!
//! Deviation (audit round 1): the takeover itself is serialized by an flock
//! on `takeover.flock`, held only while a process binds or takes over. Without
//! it, a takeover had to move the path aside and put a live socket back, and a
//! third process could bind in the gap, so two processes held the chat. Under
//! the flock a stale socket is deleted and rebound with no gap anyone else can
//! use. The socket stays the lifetime lock, as the spec says; the flock is
//! never held for the chat's life.

use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};

/// Why the lock was not taken.
#[derive(Debug)]
pub enum LockError {
    /// Another live process (or another `OptChat` in this one) holds the chat.
    Held,
    Io(io::Error),
}

/// The held lock. Dropping it closes the socket; the file is left for the
/// next owner to find stale and take over.
pub struct ChatLock {
    path: PathBuf,
    stop: Arc<AtomicBool>,
    acceptor: Option<JoinHandle<()>>,
}

/// An exclusive flock, released when dropped (the file closes).
struct Guard(#[allow(dead_code)] File);

impl Guard {
    fn take(path: &Path) -> io::Result<Guard> {
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .mode(0o600)
            .open(path)?;
        loop {
            // SAFETY: flock on a descriptor this function owns.
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0 {
                return Ok(Guard(file));
            }
            let e = io::Error::last_os_error();
            if e.kind() != io::ErrorKind::Interrupted {
                return Err(e);
            }
        }
    }
}

impl ChatLock {
    pub fn acquire(dir: &Path) -> Result<ChatLock, LockError> {
        let path = dir.join("lock");
        let _guard = Guard::take(&dir.join("takeover.flock")).map_err(LockError::Io)?;
        loop {
            // bind creates the socket file and fails if the path exists.
            match UnixListener::bind(&path) {
                Ok(listener) => return ChatLock::hold(path, listener),
                Err(e) if e.kind() == io::ErrorKind::AddrInUse => {}
                Err(e) => return Err(LockError::Io(e)),
            }
            match UnixStream::connect(&path) {
                Ok(_) => return Err(LockError::Held),
                Err(e) if e.kind() == io::ErrorKind::ConnectionRefused => {}
                Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
                Err(e) => return Err(LockError::Io(e)),
            }
            // Stale, and every other acquirer waits on the guard: deleting it
            // by name cannot delete a socket someone else just bound.
            match fs::remove_file(&path) {
                Ok(()) => {}
                Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                Err(e) => return Err(LockError::Io(e)),
            }
        }
    }

    fn hold(path: PathBuf, listener: UnixListener) -> Result<ChatLock, LockError> {
        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        // Accept and drop every probe: unaccepted connections fill the listen
        // backlog, and a full backlog refuses connections, which would make a
        // live lock look stale.
        let acceptor = thread::Builder::new()
            .name("optchat-lock".into())
            .spawn(move || {
                for conn in listener.incoming() {
                    drop(conn);
                    if flag.load(Ordering::SeqCst) {
                        break;
                    }
                }
            })
            // Without the acceptor the listener is gone with its closure, so
            // the chat would look stale to the next opener: fail instead.
            .map_err(LockError::Io)?;
        Ok(ChatLock {
            path,
            stop,
            acceptor: Some(acceptor),
        })
    }
}

impl Drop for ChatLock {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        // Wake the acceptor so it closes the listener now; join only when the
        // wake reached it (otherwise our path is gone and nothing can).
        if UnixStream::connect(&self.path).is_ok() {
            if let Some(t) = self.acceptor.take() {
                let _ = t.join();
            }
        }
    }
}
