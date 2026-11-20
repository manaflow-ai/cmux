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

/// Start `cmd` as the leader of its own process group, write `stdin` to it, read its stdout and
/// stderr, and wait at most `limit` for it: its output, or `ErrorKind::TimedOut` with `what` in
/// the text, its group then ended. The child is a `cmux_process::Child`, so it and its group end
/// with this call in every case (its drop), and the pipe threads are scoped to it.
pub(crate) fn owned(
    cmd: &mut cmux_process::Command,
    stdin: Option<Vec<u8>>,
    limit: std::time::Duration,
    what: &str,
) -> std::io::Result<std::process::Output> {
    let piped = cmux_process::Stdio::piped;
    cmd.stdin(if stdin.is_some() { piped() } else { cmux_process::Stdio::null() })
        .stdout(piped())
        .stderr(piped())
        .process_group(0);
    let mut child = cmd.spawn()?;
    let pipe_in = child.stdin.take();
    let (out, err) = (child.stdout.take(), child.stderr.take());
    std::thread::scope(|s| {
        let writer = stdin.zip(pipe_in).map(|(body, mut pipe)| {
            s.spawn(move || {
                let _ = pipe.write_all(&body);
            })
        });
        let out = out.map(|pipe| s.spawn(move || read_all(pipe)));
        let err = err.map(|pipe| s.spawn(move || read_all(pipe)));
        let exited = child.exited_within(limit);
        if !matches!(exited, Ok(true)) {
            // Ends its group (SIGTERM, then SIGKILL) and reaps it; the pipes then close.
            drop(child);
            return Err(exited.err().unwrap_or_else(|| {
                std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    format!("{what} timed out after {} s", limit.as_secs()),
                )
            }));
        }
        // Exited and not reaped: its group id is still its own, so what it left running in the
        // group (a stray helper holding a pipe open) ends here, never someone else's group.
        #[cfg(unix)]
        if let Ok(pid) = i32::try_from(child.id()) {
            // SAFETY: the child is not reaped yet (see the module comment).
            unsafe { libc::kill(-pid, libc::SIGKILL) };
        }
        let status = child.wait()?;
        if let Some(w) = writer {
            let _ = w.join();
        }
        let join = |h: Option<std::thread::ScopedJoinHandle<'_, std::io::Result<Vec<u8>>>>| {
            h.map(|h| h.join().unwrap_or_else(|_| Ok(Vec::new())))
                .transpose()
                .map(Option::unwrap_or_default)
        };
        Ok(std::process::Output { status, stdout: join(out)?, stderr: join(err)? })
    })
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
mod tests {
    use super::*;
    use std::process::{Command, Stdio};
    use std::time::Duration;

    fn spawn(script: &str) -> Child {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", script]).stdin(Stdio::piped()).stdout(Stdio::piped());
        std::os::unix::process::CommandExt::process_group(&mut command, 0);
        command.spawn().unwrap()
    }

    #[test]
    fn a_child_that_finishes_gives_its_output_and_status() {
        let child = spawn("cat; exit 3");
        let done = wait(child, Some(b"hello".to_vec()), None, "cat").unwrap();
        assert_eq!(done.status.code(), Some(3));
        assert_eq!(done.stdout, b"hello");
        assert!(done.written.unwrap().is_ok());
    }

    #[test]
    fn a_stalled_child_and_its_group_end_at_the_deadline() {
        let child = spawn("sleep 30");
        let started = std::time::Instant::now();
        let deadline = Some(Instant::now() + Duration::from_millis(300));
        let error = wait(child, None, deadline, "the stall").unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
        assert!(error.to_string().contains("timed out"), "{error}");
        assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
    }

    /// A child someone else already reaped is not proven to hold its group id, so a timeout
    /// later signals only the child, never `-pid`.
    #[test]
    fn a_child_already_reaped_does_not_prove_its_group() {
        let mut child = spawn("exit 0");
        child.wait().unwrap();
        assert!(matches!(exit_within(&mut child, None), Ok(false)));
        let mut running = spawn("exit 0");
        assert!(matches!(exit_within(&mut running, None), Ok(true)));
        running.wait().unwrap();
    }

    /// The child exits at once, but a descendant keeps its stdout open: the read is bounded
    /// too. (tests/send_relay_cli.rs checks that such a descendant is killed with the group.)
    #[test]
    fn a_descendant_holding_the_output_open_ends_at_the_deadline() {
        let child = spawn("sleep 30 & exit 0");
        let started = std::time::Instant::now();
        let deadline = Some(Instant::now() + Duration::from_millis(300));
        let error = wait(child, None, deadline, "the open").unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
    }
}
