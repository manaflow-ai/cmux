//! One completion's child: the prompt on stdin, stdout read up to
//! [`OUTPUT_CAP`](super::OUTPUT_CAP) and stderr up to
//! [`STDERR_CAP`](super::STDERR_CAP), all under one deadline. When the
//! leader exits, and on timeout, the child's whole process group is killed
//! (the command starts its own group), so nothing it started outlives the
//! request.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::Command;

/// How long the pipes are read after the leader exited.
const DRAIN: Duration = Duration::from_millis(500);

/// What the child left.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Output {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub success: bool,
    /// The exit code; None when a signal ended it.
    pub code: Option<i32>,
}

#[derive(Debug)]
pub enum RunError {
    Spawn(String),
    Timeout,
}

/// Runs `cmd` with `input` on stdin (None: no stdin) until it exits or
/// `timeout` passes. Its process group is killed when the leader exits (or
/// on timeout), and the pipes are then drained for at most [`DRAIN`], so a
/// background process holding stdout never turns an answer into a timeout.
pub async fn run(
    mut cmd: Command,
    input: Option<&[u8]>,
    timeout: Duration,
) -> Result<Output, RunError> {
    cmd.stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    // Its own process group, so a timeout stops what it started too.
    #[cfg(unix)]
    cmd.process_group(0);
    let mut child = cmd.spawn().map_err(|e| RunError::Spawn(e.to_string()))?;
    // The group id, kept: once the leader is reaped `child.id()` is None.
    let group = child.id();
    let stdin = child.stdin.take();
    // The readers own the pipes: a process the CLI left behind that still
    // holds one does not hold the answer (see the drain below).
    let mut stdout = tokio::spawn(read_capped(child.stdout.take(), super::OUTPUT_CAP));
    let mut stderr = tokio::spawn(read_capped(child.stderr.take(), super::STDERR_CAP));
    let write = async move {
        if let (Some(mut pipe), Some(bytes)) = (stdin, input) {
            // A CLI that exits without reading closes the pipe: not an error here.
            let _ = pipe.write_all(bytes).await;
            let _ = pipe.shutdown().await;
        }
    };
    let waited = tokio::time::timeout(timeout, async {
        let ((), status) = tokio::join!(write, child.wait());
        status
    })
    .await;
    // On every path: nothing the CLI started outlives the request, and a
    // background process holding stdout lets go of it.
    kill_group(group);
    let status = match waited {
        Ok(status) => status,
        Err(_) => {
            let _ = child.kill().await;
            stdout.abort();
            stderr.abort();
            return Err(RunError::Timeout);
        }
    };
    let status = status.map_err(|e| RunError::Spawn(e.to_string()))?;
    // What the leader wrote is in the pipes; the drain is bounded in case a
    // process outside the group still holds one.
    let (stdout, stderr) = (drain(&mut stdout).await, drain(&mut stderr).await);
    Ok(Output { stdout, stderr, success: status.success(), code: status.code() })
}

/// A reader's bytes, waited for at most [`DRAIN`]; then it is stopped.
async fn drain(task: &mut tokio::task::JoinHandle<Vec<u8>>) -> Vec<u8> {
    let got = tokio::time::timeout(DRAIN, &mut *task).await;
    task.abort();
    got.ok().and_then(Result::ok).unwrap_or_default()
}

/// Up to `cap` bytes of `pipe`; then the pipe is closed, so a CLI that
/// writes more stops on a broken pipe instead of filling it.
async fn read_capped<R: AsyncRead + Unpin>(pipe: Option<R>, cap: usize) -> Vec<u8> {
    let Some(pipe) = pipe else { return Vec::new() };
    let mut buf = Vec::new();
    let _ = pipe.take(cap as u64).read_to_end(&mut buf).await;
    buf
}

#[cfg(unix)]
fn kill_group(group: Option<u32>) {
    if let Some(pid) = group.and_then(|p| i32::try_from(p).ok()) {
        // SAFETY: killpg only sends a signal; the group is this child's own.
        unsafe {
            libc::killpg(pid, libc::SIGKILL);
        }
    }
}

#[cfg(not(unix))]
fn kill_group(_group: Option<u32>) {}

/// Up to `cap` bytes of the file at `path` (empty when it is missing).
pub async fn read_file_capped(path: &Path, cap: usize) -> Vec<u8> {
    match tokio::fs::File::open(path).await {
        Ok(file) => read_capped(Some(file), cap).await,
        Err(_) => Vec::new(),
    }
}

/// A fresh, private folder for one completion's prompt and output files,
/// removed when dropped (never the CLI's cwd: `places.rs`).
pub struct RunDir {
    path: PathBuf,
}

impl RunDir {
    pub fn new() -> std::io::Result<Self> {
        Self::new_in(&std::env::temp_dir())
    }

    pub fn new_in(parent: &Path) -> std::io::Result<Self> {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0);
        let path = parent.join(format!(
            "{}{}-{n}-{nanos:08x}",
            super::places::RUN_PREFIX,
            std::process::id()
        ));
        let mut builder = std::fs::DirBuilder::new();
        #[cfg(unix)]
        std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
        // `create`, never `create_all`: a folder that exists is not fresh.
        builder.create(&path)?;
        Ok(Self { path })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Writes the prompt file (owner-only).
    pub fn write_private(&self, path: &Path, bytes: &[u8]) -> std::io::Result<()> {
        use std::io::Write;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let mut file = options.open(path)?;
        file.write_all(bytes)
    }
}

impl Drop for RunDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}
