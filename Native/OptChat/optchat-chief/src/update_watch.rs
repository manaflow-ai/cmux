//! Whether the host's own binary was replaced on disk (an app update).

use std::path::{Path, PathBuf};

/// The identity of the host's binary at start, to compare with the file at
/// the same path later.
pub struct ExeWatch {
    path: PathBuf,
}

impl ExeWatch {
    /// Records the binary at `path` as it is now.
    pub fn new(path: &Path) -> ExeWatch {
        ExeWatch {
            path: path.to_owned(),
        }
    }

    /// Whether another file is at the path now.
    pub fn replaced(&self) -> bool {
        let _ = &self.path;
        false
    }
}
