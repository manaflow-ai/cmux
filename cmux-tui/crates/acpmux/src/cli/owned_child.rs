//! A short child command owned by its caller (`cmux_process::Child`), bounded by a time limit:
//! its stdin written, its stdout and stderr read on threads scoped to the call, and its whole
//! process group ended when the limit passes or the call returns. The ssh fallback's logins
//! (`server/ssh_carry.rs`, `cli/ls_ssh.rs`) run through it.

use std::io::{Read, Write};

fn read_all(mut pipe: impl Read) -> std::io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    pipe.read_to_end(&mut bytes)?;
    Ok(bytes)
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
