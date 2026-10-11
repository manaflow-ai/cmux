//! The Windows daemon lock: an exclusive `LockFileEx` lock on the lock
//! file (std's `File::try_lock`), the twin of the Unix `flock` in daemon.rs.

use anyhow::{Context, Result, anyhow};
use std::path::PathBuf;
use std::time::Duration;

/// Windows: an exclusive `LockFileEx` lock (std's `File::try_lock`), held
/// while the file stays open; the system releases it when the daemon exits.
pub(super) fn acquire_lock(path: &PathBuf) -> Result<std::fs::File> {
    let file = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(path)
        .with_context(|| format!("open {}", path.display()))?;
    match file.try_lock() {
        Ok(()) => Ok(file),
        Err(std::fs::TryLockError::WouldBlock) => {
            Err(anyhow!("another acpmux daemon holds {}", path.display()))
        }
        Err(std::fs::TryLockError::Error(e)) => {
            Err(anyhow::Error::new(e).context(format!("lock {}", path.display())))
        }
    }
}

/// Windows: polls a non-blocking `LockFileEx` (std's `File::try_lock`), as
/// the Unix arm polls `flock`.
pub(super) async fn wait_for_lock_release(lock: PathBuf, budget: Duration) -> bool {
    let Ok(file) = std::fs::OpenOptions::new().read(true).write(true).open(&lock) else {
        return true;
    };
    let deadline = tokio::time::Instant::now() + budget;
    loop {
        match file.try_lock() {
            Ok(()) => return true,
            Err(std::fs::TryLockError::WouldBlock) => {}
            Err(std::fs::TryLockError::Error(_)) => return false,
        }
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}
