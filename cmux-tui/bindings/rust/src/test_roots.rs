//! Unique, short temporary roots for socket tests. A test keeps its runtime
//! directory layout below its own root, never at a shared `/tmp` path that a
//! leftover from another run or user can block (mode 000, another owner).

use std::path::{Path, PathBuf};

/// A fresh, short temporary directory, removed on drop.
pub(crate) struct TempRoot(PathBuf);

impl TempRoot {
    /// A fresh 0700 directory `/tmp/XXXXXX` (mkdtemp), for a test that lays
    /// out the product's full hashed socket path below it:
    /// `<root>/cmux-tui-hashed-<uid>/<64 hex>.sock`, 101 bytes for uid 501,
    /// inside the macOS `sun_path` (104 with its NUL). The product's own
    /// fallback, `/tmp/cmux-tui-hashed-<uid>/<64 hex>.sock`, is 94 bytes. A
    /// root below `TMPDIR`, or `/tmp/cs<pid>-<n>`, does not fit on macOS.
    pub(crate) fn short() -> Self {
        use std::ffi::{CString, OsString};
        use std::os::unix::ffi::OsStringExt;
        let template = CString::new("/tmp/XXXXXX").unwrap();
        let mut bytes = template.into_bytes_with_nul();
        // SAFETY: `bytes` is a writable NUL-terminated template that mkdtemp
        // fills in place; it outlives the call.
        let made = unsafe { libc::mkdtemp(bytes.as_mut_ptr().cast()) };
        assert!(!made.is_null(), "mkdtemp /tmp/XXXXXX: {}", std::io::Error::last_os_error());
        bytes.pop();
        Self(PathBuf::from(OsString::from_vec(bytes)))
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
