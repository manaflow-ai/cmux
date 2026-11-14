//! A child command bounded by the caller's deadline (cmuxterm-hq#5120): its exit, the write of
//! its stdin and the reads of its piped output all end by the deadline. The caller spawns it in
//! its own process group (`process_group(0)`); on expiry that group, and only that group, is
//! killed.
//!
//! The child is not reaped until the end: while it is unreaped (running or a zombie) its pid,
//! and so its group id, cannot be taken by another process, so the kill can never reach an
//! unrelated group. If the unreaped wait fails (another reaper took the child, or `SIGCHLD` is
//! ignored) the group id is no longer proven ours and only the child itself is signalled. A
//! descendant that left the group and keeps a pipe open is not killed; its reader thread is left
//! behind, and the command exits soon after.

use std::io::{Read, Write};
use std::process::{Child, ExitStatus};
use std::sync::mpsc;
use tokio::time::Instant;

/// What a bounded child did. `written` is the stdin write's result when stdin was given.
#[derive(Debug)]
pub(crate) struct Finished {
    pub status: ExitStatus,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub written: Option<std::io::Result<()>>,
}

/// Wait for CHILD, writing STDIN to its piped stdin and reading its piped stdout and stderr
/// (whichever were piped), until DEADLINE. On expiry its process group is killed, it is reaped
/// and the error is `ErrorKind::TimedOut` with WHAT in its text. With no deadline it waits as
/// long as the child and its pipes take.
pub(crate) fn wait(
    mut child: Child,
    stdin: Option<Vec<u8>>,
    deadline: Option<Instant>,
    what: &str,
) -> std::io::Result<Finished> {
    let written = stdin.and_then(|body| {
        let mut pipe = child.stdin.take()?;
        Some(in_thread(move || pipe.write_all(&body)))
    });
    let stdout = child.stdout.take().map(|pipe| in_thread(move || read_all(pipe)));
    let stderr = child.stderr.take().map(|pipe| in_thread(move || read_all(pipe)));
    // Until the exit wait answers, the child is unreaped and its group id is ours.
    let mut group_ours = true;
    let mut finish = || -> Result<_, Expired> {
        group_ours = exit_within(&mut child, deadline)?;
        let written = written.as_ref().map(|rx| within(rx, deadline)).transpose()?;
        let stdout = stdout.as_ref().map(|rx| within(rx, deadline)).transpose()?;
        let stderr = stderr.as_ref().map(|rx| within(rx, deadline)).transpose()?;
        Ok((written, stdout, stderr))
    };
    match finish() {
        Ok((written, stdout, stderr)) => Ok(Finished {
            status: child.wait()?,
            stdout: stdout.transpose()?.unwrap_or_default(),
            stderr: stderr.transpose()?.unwrap_or_default(),
            written,
        }),
        Err(Expired) => {
            kill(&mut child, group_ours);
            let _ = child.wait();
            Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                format!("{what} timed out at the caller deadline"),
            ))
        }
    }
}

struct Expired;

fn within<T>(rx: &mpsc::Receiver<T>, deadline: Option<Instant>) -> Result<T, Expired> {
    match deadline {
        Some(deadline) => {
            rx.recv_timeout(deadline.saturating_duration_since(Instant::now())).map_err(|_| Expired)
        }
        // A sender drops only after sending, unless its thread panicked.
        None => rx.recv().map_err(|_| Expired),
    }
}

fn in_thread<T: Send + 'static>(work: impl FnOnce() -> T + Send + 'static) -> mpsc::Receiver<T> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(work());
    });
    rx
}

fn read_all(mut pipe: impl Read) -> std::io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    pipe.read_to_end(&mut bytes).map(|_| bytes)
}

/// Wait for CHILD to exit until DEADLINE, without reaping it. True when the wait proved it
/// exited unreaped; false when the wait failed, so its group id is not proven ours.
#[cfg(unix)]
fn exit_within(child: &mut Child, deadline: Option<Instant>) -> Result<bool, Expired> {
    let pid: libc::id_t = child.id();
    let exited = in_thread(move || {
        loop {
            // SAFETY: an all-zero siginfo_t is valid; waitid only writes it.
            let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
            // SAFETY: WNOWAIT leaves the child for `Child::wait` to reap.
            let done =
                unsafe { libc::waitid(libc::P_PID, pid, &mut info, libc::WEXITED | libc::WNOWAIT) };
            if done == 0 {
                return true;
            }
            if std::io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
                return false;
            }
        }
    });
    within(&exited, deadline)
}

/// Wait for CHILD to exit until DEADLINE. Elsewhere there is no process group to protect.
#[cfg(not(unix))]
fn exit_within(child: &mut Child, deadline: Option<Instant>) -> Result<bool, Expired> {
    use wait_timeout::ChildExt;
    let exited = match deadline {
        Some(deadline) => {
            child.wait_timeout(deadline.saturating_duration_since(Instant::now())).ok().flatten()
        }
        None => child.wait().ok(),
    };
    exited.map(|_| false).ok_or(Expired)
}

/// Kill CHILD, and its whole group when GROUP_OURS.
fn kill(child: &mut Child, group_ours: bool) {
    #[cfg(unix)]
    if group_ours && let Ok(pid) = i32::try_from(child.id()) {
        // SAFETY: CHILD is not reaped yet, so this group id is still its own (see the module
        // comment).
        unsafe { libc::kill(-pid, libc::SIGKILL) };
    }
    #[cfg(not(unix))]
    let _ = group_ours;
    let _ = child.kill();
}

#[cfg(all(test, unix))]
mod tests;
