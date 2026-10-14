//! One completion's child: the prompt on stdin, stdout read up to
//! [`OUTPUT_CAP`](super::OUTPUT_CAP) and stderr up to
//! [`STDERR_CAP`](super::STDERR_CAP), all under one deadline. On timeout the
//! child's whole process group is killed (the command starts its own group),
//! so nothing it started outlives the request.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::Command;

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
/// `timeout` passes.
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
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let work = async {
        let write = async move {
            if let (Some(mut pipe), Some(bytes)) = (stdin, input) {
                // A CLI that exits without reading closes the pipe: not an error here.
                let _ = pipe.write_all(bytes).await;
                let _ = pipe.shutdown().await;
            }
        };
        let (_, stdout, stderr) = tokio::join!(
            write,
            read_capped(stdout, super::OUTPUT_CAP),
            read_capped(stderr, super::STDERR_CAP)
        );
        let status = child.wait().await;
        (stdout, stderr, status)
    };
    // Bound first, so the finished future (and its borrow of `child`) is gone below.
    let outcome = tokio::time::timeout(timeout, work).await;
    match outcome {
        Ok((stdout, stderr, status)) => {
            let status = status.map_err(|e| RunError::Spawn(e.to_string()))?;
            Ok(Output { stdout, stderr, success: status.success(), code: status.code() })
        }
        Err(_) => {
            kill_group(group);
            let _ = child.kill().await;
            Err(RunError::Timeout)
        }
    }
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

/// A fresh, empty, private folder for one completion, removed when dropped:
/// the CLI's cwd, so no project `CLAUDE.md` or `AGENTS.md` loads.
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
        let path = parent.join(format!("acpmux-complete-{}-{n}-{nanos:08x}", std::process::id()));
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
