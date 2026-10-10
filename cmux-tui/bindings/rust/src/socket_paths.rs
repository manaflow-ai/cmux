//! Socket path rules that differ by platform: the runtime base, the short
//! fallback root, the AF_UNIX path limit and the per-user component. The
//! Windows rules follow the daemon (cmux-tui-core `platform`).

#[cfg(unix)]
use std::mem::{offset_of, size_of};
#[cfg(unix)]
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

#[cfg(windows)]
pub(crate) fn runtime_base() -> PathBuf {
    // The daemon's base on Windows (cmux-tui-core `platform::runtime_base_dir`).
    std::env::temp_dir()
}

#[cfg(unix)]
pub(crate) fn runtime_base() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR")
        .filter(|value| !value.is_empty())
        .or_else(|| std::env::var_os("TMPDIR").filter(|value| !value.is_empty()))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
}

/// Where short socket paths go when the runtime directory's are too long:
/// `/tmp` on Unix, the temp directory on Windows.
pub(crate) fn fallback_root() -> PathBuf {
    #[cfg(unix)]
    {
        PathBuf::from("/tmp")
    }
    #[cfg(windows)]
    {
        std::env::temp_dir()
    }
}

#[cfg(unix)]
pub(crate) fn unix_socket_path_fits(path: &Path) -> bool {
    const SUN_PATH_CAPACITY: usize =
        size_of::<libc::sockaddr_un>() - offset_of!(libc::sockaddr_un, sun_path);
    path.as_os_str().as_bytes().len() < SUN_PATH_CAPACITY
}

/// Windows AF_UNIX: `sockaddr_un.sun_path` is 108 bytes of UTF-8 with its
/// NUL.
#[cfg(windows)]
pub(crate) fn unix_socket_path_fits(path: &Path) -> bool {
    path.to_str().is_some_and(|p| p.len() < 108)
}

#[cfg(unix)]
pub(crate) fn current_uid_component() -> String {
    // SAFETY: getuid has no preconditions and does not dereference pointers.
    unsafe { libc::getuid() }.to_string()
}

/// Windows: the user name, as the daemon names its socket directory
/// (cmux-tui-core `platform::user_id_component`).
#[cfg(windows)]
pub(crate) fn current_uid_component() -> String {
    std::env::var("USERNAME").unwrap_or_else(|_| "user".to_string())
}
