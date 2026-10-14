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
    // hq#1957: not implemented yet (the failing tests come first).
    let _ = (cmd, input, timeout);
    Err(RunError::Spawn("not implemented".into()))
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
    // hq#1957: not implemented yet (the failing tests come first).
    let _ = (path, cap);
    Vec::new()
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
        // hq#1957: not implemented yet (the failing tests come first).
        let _ = parent;
        Err(std::io::Error::other("not implemented"))
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
