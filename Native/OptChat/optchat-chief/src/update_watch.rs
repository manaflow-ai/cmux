//! Whether the host's own binary was replaced on disk: an app update swaps the
//! bundle while this process keeps running the old code, and the relaunched app
//! keeps a host that holds the home's lock. The host checks its binary now and
//! then (`host.rs`) and hands off once no turn runs (`Input::BinaryReplaced`),
//! so the app's watcher starts the new build.

use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

/// How often the host looks at its binary.
pub const CHECK_EVERY: std::time::Duration = std::time::Duration::from_secs(60);

/// The identity of the host's binary at start, to compare with the file at the
/// same path later.
pub struct ExeWatch {
    path: PathBuf,
    at_start: Option<Stamp>,
}

/// A file's identity: a replaced file differs in at least one field (a new
/// inode for a rename over it, a new size or time for a write in place).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Stamp {
    dev: u64,
    ino: u64,
    len: u64,
    mtime: i64,
    mtime_ns: i64,
}

fn stamp(path: &Path) -> Option<Stamp> {
    let m = std::fs::metadata(path).ok()?;
    Some(Stamp {
        dev: m.dev(),
        ino: m.ino(),
        len: m.len(),
        mtime: m.mtime(),
        mtime_ns: m.mtime_nsec(),
    })
}

impl ExeWatch {
    /// Records the binary at `path` as it is now.
    pub fn new(path: &Path) -> ExeWatch {
        ExeWatch {
            path: path.to_owned(),
            at_start: stamp(path),
        }
    }

    /// Whether another file is at the path now. A missing file is no change
    /// (mid-update the old bundle is gone and the new one not there yet), and
    /// neither is a path that had no file at start.
    pub fn replaced(&self) -> bool {
        match (self.at_start, stamp(&self.path)) {
            (Some(was), Some(now)) => was != now,
            _ => false,
        }
    }
}
