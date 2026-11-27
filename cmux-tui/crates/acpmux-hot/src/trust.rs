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
mod tests {
    use super::check;
    use std::os::unix::fs::PermissionsExt as _;

    fn checkout() -> tempdir::Dir {
        tempdir::Dir::new()
    }

    /// A private temp folder made a "checkout" by an empty `.git` folder.
    mod tempdir {
        pub struct Dir(pub std::path::PathBuf);
        impl Dir {
            pub fn new() -> Self {
                use std::os::unix::fs::PermissionsExt as _;
                let base = std::env::temp_dir().canonicalize().unwrap();
                let n = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos();
                let dir = base.join(format!("acpmux-hot-trust-{}-{n}", std::process::id()));
                std::fs::create_dir_all(dir.join(".git")).unwrap();
                std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
                Dir(dir)
            }
        }
        impl Drop for Dir {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
    }

    #[test]
    fn a_private_file_in_a_checkout_loads() {
        let dir = checkout();
        let file = dir.0.join("m.wasm");
        std::fs::write(&file, b"x").unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(check(&file).unwrap(), file);
    }

    #[test]
    fn a_relative_path_a_shared_file_or_a_file_outside_a_checkout_is_refused() {
        assert!(check(std::path::Path::new("m.wasm")).is_err());
        let dir = checkout();
        let file = dir.0.join("m.wasm");
        std::fs::write(&file, b"x").unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o666)).unwrap();
        assert!(check(&file).unwrap_err().contains("writable by group or others"));
        std::fs::remove_dir(dir.0.join(".git")).unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
        // Above the temp folder, `/tmp`-like folders are writable by others or not a checkout.
        assert!(check(&file).is_err());
    }
}
