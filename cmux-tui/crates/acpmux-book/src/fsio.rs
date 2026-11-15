//! The few file operations the book needs: reads and writes at an offset, a sync that does not
//! flush the drive's cache on every call, and the atomic whole-file write the checkpoint and the
//! blobs use.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

/// Reads into `buf` at `offset` until `buf` is full or the file ends; the bytes read.
pub(crate) fn read_at(file: &File, buf: &mut [u8], offset: u64) -> io::Result<usize> {
    let mut done = 0usize;
    while let Some(rest) = buf.get_mut(done..) {
        if rest.is_empty() {
            break;
        }
        match pread(file, rest, offset.saturating_add(done as u64)) {
            Ok(0) => break,
            Ok(read) => done = done.saturating_add(read),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(done)
}

#[cfg(unix)]
fn pread(file: &File, buf: &mut [u8], offset: u64) -> io::Result<usize> {
    std::os::unix::fs::FileExt::read_at(file, buf, offset)
}

#[cfg(windows)]
fn pread(file: &File, buf: &mut [u8], offset: u64) -> io::Result<usize> {
    std::os::windows::fs::FileExt::seek_read(file, buf, offset)
}

/// Writes all of `buf` at `offset`. Never on a file opened for append (there the offset is
/// ignored on Linux).
#[cfg(unix)]
pub(crate) fn write_all_at(file: &File, buf: &[u8], offset: u64) -> io::Result<()> {
    std::os::unix::fs::FileExt::write_all_at(file, buf, offset)
}

#[cfg(windows)]
pub(crate) fn write_all_at(file: &File, buf: &[u8], offset: u64) -> io::Result<()> {
    let mut done = 0usize;
    while let Some(rest) = buf.get(done..) {
        if rest.is_empty() {
            break;
        }
        let wrote = std::os::windows::fs::FileExt::seek_write(
            file,
            rest,
            offset.saturating_add(done as u64),
        )?;
        if wrote == 0 {
            return Err(io::ErrorKind::WriteZero.into());
        }
        done = done.saturating_add(wrote);
    }
    Ok(())
}

/// Pushes `file`'s data to the disk so it survives a crash of any process and a kernel panic:
/// `fdatasync` on Linux, `F_BARRIERFSYNC` on macOS (std's `sync_data` is `F_FULLFSYNC` there, tens
/// of milliseconds per call, which a checkpoint every second cannot pay), `FlushFileBuffers` on
/// Windows. On macOS a power loss can take back a suffix written since the drive last flushed;
/// the book is derived from the raw file, so that suffix is translated again.
#[cfg(not(target_os = "macos"))]
pub(crate) fn sync(file: &File) -> io::Result<()> {
    file.sync_data()
}

#[cfg(target_os = "macos")]
pub(crate) fn sync(file: &File) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    let fd = file.as_raw_fd();
    // SAFETY: fcntl on a descriptor that `file` owns for the whole call.
    let error = match retry_interrupted(|| unsafe { libc::fcntl(fd, libc::F_BARRIERFSYNC) }) {
        Ok(()) => return Ok(()),
        Err(error) => error,
    };
    // A volume without the call (network, FAT) has no stronger sync than fsync.
    let unsupported = matches!(
        error.raw_os_error(),
        Some(libc::ENOTSUP | libc::EOPNOTSUPP | libc::EINVAL | libc::ENOTTY)
    );
    if !unsupported {
        return Err(error);
    }
    // SAFETY: as above.
    retry_interrupted(|| unsafe { libc::fsync(fd) })
}

/// Makes a new or renamed name in `dir` durable. Nothing to do on Windows.
#[cfg(unix)]
pub(crate) fn sync_dir(dir: &Path) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    let handle = File::open(dir)?;
    let fd = handle.as_raw_fd();
    // SAFETY: fsync on a descriptor that `handle` owns for the whole call.
    retry_interrupted(|| unsafe { libc::fsync(fd) })
}

#[cfg(not(unix))]
pub(crate) fn sync_dir(_dir: &Path) -> io::Result<()> {
    Ok(())
}

/// Calls `call` until it returns something other than -1 with EINTR.
#[cfg(unix)]
fn retry_interrupted(call: impl Fn() -> libc::c_int) -> io::Result<()> {
    loop {
        if call() != -1 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

/// Numbers this process's temporary files, so two writes of one path never share a name.
static TEMPORARY: AtomicU64 = AtomicU64::new(0);

/// Writes `bytes` to `path` so a reader, or a restart after a kill at any moment, finds either
/// the old file or the new one, whole: a temporary file beside it, synced, then renamed over it.
pub(crate) fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let dir = path.parent().filter(|dir| !dir.as_os_str().is_empty()).unwrap_or(Path::new("."));
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let number = TEMPORARY.fetch_add(1, Ordering::Relaxed);
    let temporary = dir.join(format!(".{name}.{}.{number}.tmp", std::process::id()));
    let result = (|| {
        // `truncate`, not `create_new`: a process that died with this pid and number left a file
        // of this name, and it is this writer's to reuse.
        let mut file =
            OpenOptions::new().write(true).create(true).truncate(true).open(&temporary)?;
        file.write_all(bytes)?;
        sync(&file)?;
        drop(file);
        fs::rename(&temporary, path)?;
        sync_dir(dir)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}
