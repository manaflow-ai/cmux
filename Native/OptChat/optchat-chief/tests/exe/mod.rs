//! Fake executables for tests that run them at once (cx-79km).
//!
//! `std::fs::write` holds a write fd on the file while it writes. When
//! another test thread forks in that window, its child keeps the fd until
//! it execs, and running the file then fails with ETXTBSY ("Text file
//! busy"). Renaming does not help: the fd names the inode, not the path. So
//! the script text goes to a side file, and a separate `cp` process writes
//! the executable: no fd of this process ever writes the inode that runs.

use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;

/// Writes `text` as an executable (0755) at `path`.
pub fn write_executable(path: &Path, text: &str) {
    let mut source = path.as_os_str().to_owned();
    source.push(".src");
    let source = std::path::PathBuf::from(source);
    std::fs::write(&source, text).unwrap();
    std::fs::set_permissions(&source, std::fs::Permissions::from_mode(0o755)).unwrap();
    let status = Command::new("cp").arg(&source).arg(path).status().unwrap();
    assert!(
        status.success(),
        "cp {} {}: {status}",
        source.display(),
        path.display()
    );
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}
