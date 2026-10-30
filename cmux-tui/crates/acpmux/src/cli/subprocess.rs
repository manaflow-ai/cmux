//! Child I/O and exit share the CLI caller's deadline. No helper threads outlive a timeout.
use super::errors::AppError;
use super::output::before_deadline;
use anyhow::Result;
use std::process::Output;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::{Child, Command};
use tokio::time::Instant;

struct OwnedChild {
    child: Child,
    armed: bool,
}

impl Drop for OwnedChild {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        // We create the group and keep its leader unreaped until all pipes close.
        // Thus the group id cannot have been reused when cancellation signals it.
        #[cfg(unix)]
        if let Some(pid) = self.child.id().and_then(|pid| i32::try_from(pid).ok()) {
            unsafe { libc::kill(-pid, libc::SIGKILL) };
        }
        // kill_on_drop also arranges reaping; no synchronous wait extends the budget.
        let _ = self.child.start_kill();
    }
}

async fn read(pipe: Option<impl AsyncRead + Unpin>) -> std::io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    if let Some(mut pipe) = pipe {
        pipe.read_to_end(&mut bytes).await?;
    }
    Ok(bytes)
}

pub(crate) async fn output(
    command: &mut Command,
    input: Option<&str>,
    deadline: Option<Instant>,
    session: &str,
) -> Result<(Output, std::io::Result<()>)> {
    // Do not start a side effect after setup has already consumed the budget.
    if deadline.is_some_and(|end| Instant::now() >= end) {
        return Err(AppError::timeout("prompt deadline passed").with_session(session).into());
    }
    command.kill_on_drop(true);
    #[cfg(unix)]
    command.process_group(0);
    let mut owned = OwnedChild { child: command.spawn()?, armed: true };
    let stdin = owned.child.stdin.take();
    let stdout = owned.child.stdout.take();
    let stderr = owned.child.stderr.take();
    let result = before_deadline(deadline, session, async {
        let write = async move {
            if let (Some(mut stdin), Some(input)) = (stdin, input) {
                stdin.write_all(input.as_bytes()).await?;
            }
            Ok::<(), std::io::Error>(())
        };
        // Keep a write error until we know the exit status: a relay's refusal wins
        // over an early stdin close, but a successful relay must consume all input.
        let (written, stdout, stderr) = tokio::join!(write, read(stdout), read(stderr));
        let stdout = stdout?;
        let stderr = stderr?;
        let status = owned.child.wait().await?;
        Ok((Output { status, stdout, stderr }, written))
    })
    .await;
    if result.is_ok() {
        owned.armed = false;
    }
    result
}
