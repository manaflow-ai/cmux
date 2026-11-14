//! Where a module may come from. A module runs inside the daemon that holds every session, so the
//! rule is the one Live Code keeps until a signer check exists (docs/cmux-next/live-code.md,
//! cmux#13742): only a debug build loads one, and only from the person's own local checkout.
//!
//! The file must be a regular file under a git checkout (an ancestor holds `.git`), and the file
//! and every folder from it up to that checkout must belong to this process's user and be
//! writable by nobody else, so another account on the machine cannot swap code into the daemon.
//! A symlink is followed to its target first, and the target is what is checked. The guest gets
//! no capability either way (every import traps, `host.rs`).

use std::path::{Path, PathBuf};

/// `path`, canonical, when a module may be loaded from it; else why not.
#[cfg(unix)]
pub fn check(path: &Path) -> Result<PathBuf, String> {
    use std::os::unix::fs::MetadataExt as _;
    if !path.is_absolute() {
        return Err(format!("{} is not an absolute path", path.display()));
    }
    let real = path.canonicalize().map_err(|e| format!("{}: {e}", path.display()))?;
    let meta = std::fs::metadata(&real).map_err(|e| format!("{}: {e}", real.display()))?;
    if !meta.is_file() {
        return Err(format!("{} is not a regular file", real.display()));
    }
    // SAFETY: geteuid has no preconditions and cannot fail.
    let me = unsafe { libc::geteuid() };
    let private = |p: &Path, m: &std::fs::Metadata| -> Result<(), String> {
        if m.uid() != me {
            return Err(format!("{} belongs to uid {}, not {me}", p.display(), m.uid()));
        }
        if m.mode() & 0o022 != 0 {
            return Err(format!("{} is writable by group or others", p.display()));
        }
        Ok(())
    };
    private(&real, &meta)?;
    for dir in real.ancestors().skip(1) {
        let m = std::fs::metadata(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        private(dir, &m)?;
        if dir.join(".git").exists() {
            return Ok(real);
        }
    }
    Err(format!("{} is not inside a git checkout", real.display()))
}

#[cfg(not(unix))]
pub fn check(path: &Path) -> Result<PathBuf, String> {
    Err(format!("{}: hot modules load on unix hosts only", path.display()))
}

#[cfg(all(test, unix))]
mod tests;
