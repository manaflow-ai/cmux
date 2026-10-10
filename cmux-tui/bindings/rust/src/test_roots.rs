//! Unique, short temporary roots for socket tests. A test keeps its runtime
//! directory layout below its own root, never at a shared `/tmp` path that a
//! leftover from another run or user can block (mode 000, another owner).

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

/// A fresh directory below `std::env::temp_dir()`, removed on drop. The name
/// stays short so a socket two levels below it fits `sun_path`.
pub(crate) struct TempRoot(PathBuf);

impl TempRoot {
    pub(crate) fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!("cs{}-{id}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        Self(root)
    }

    pub(crate) fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempRoot {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
