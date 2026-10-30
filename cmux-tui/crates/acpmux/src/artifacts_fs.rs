//! File access for the artifacts sync that never follows a symlink below a root's anchor (home).
//! A folder checked and then swapped for a symlink by another process cannot lead a read or a
//! write out of the root: on Unix every folder from the anchor down is opened relative to its
//! parent with `O_NOFOLLOW`, as `config::private_state_dir` opens state folders, and every read
//! and write goes through those descriptors. A write lands in a new file renamed over the old one,
//! so a reader never sees half of it.

use std::io;
use std::path::{Component, Path, PathBuf};

/// One synced folder, opened for one pass.
pub(crate) struct Dir {
    #[cfg(unix)]
    fd: std::os::fd::OwnedFd,
    #[cfg(not(unix))]
    path: PathBuf,
}

/// The names of `relative`, which must be plain names (no root, `.`, `..` or empty part).
fn names(relative: &Path) -> io::Result<Vec<&std::ffi::OsStr>> {
    relative
        .components()
        .map(|part| match part {
            Component::Normal(name) => Ok(name),
            _ => Err(io::Error::new(io::ErrorKind::InvalidInput, "not a plain relative path")),
        })
        .collect()
}

#[cfg(unix)]
mod unix {
    use std::ffi::{CStr, CString, OsStr};
    use std::io::{self, Read, Write};
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    use std::path::{Path, PathBuf};

    fn c_name(name: &OsStr) -> io::Result<CString> {
        CString::new(name.as_bytes()).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))
    }

    fn check(fd: libc::c_int) -> io::Result<OwnedFd> {
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: a descriptor the kernel just returned, owned by nothing else.
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }

    /// `name` in `dir`, never through a symlink.
    pub(super) fn open_at(dir: &OwnedFd, name: &OsStr, flags: libc::c_int) -> io::Result<OwnedFd> {
        let name = c_name(name)?;
        let flags = flags | libc::O_NOFOLLOW | libc::O_CLOEXEC;
        // SAFETY: a valid descriptor and a NUL-terminated name.
        check(unsafe { libc::openat(dir.as_raw_fd(), name.as_ptr(), flags, 0o600) })
    }

    pub(super) fn open_dir_at(dir: &OwnedFd, name: &OsStr) -> io::Result<OwnedFd> {
        open_at(dir, name, libc::O_RDONLY | libc::O_DIRECTORY)
    }

    /// The anchor itself is opened by path: a home folder may be a symlink (`/home -> /usr/home`).
    pub(super) fn open_anchor(path: &Path) -> io::Result<OwnedFd> {
        let path = CString::new(path.as_os_str().as_bytes())
            .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
        // SAFETY: a NUL-terminated path.
        check(unsafe {
            libc::open(path.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC)
        })
    }

    pub(super) fn mkdir_at(dir: &OwnedFd, name: &OsStr) -> io::Result<()> {
        let name = c_name(name)?;
        // SAFETY: a valid descriptor and a NUL-terminated name.
        if unsafe { libc::mkdirat(dir.as_raw_fd(), name.as_ptr(), 0o700) } < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::AlreadyExists {
                return Err(error);
            }
        }
        Ok(())
    }

    fn stat(fd: &OwnedFd) -> io::Result<libc::stat> {
        // SAFETY: a zeroed stat is a valid out-parameter; fd is valid.
        let mut stat: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe { libc::fstat(fd.as_raw_fd(), &mut stat) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(stat)
    }

    pub(super) fn is_dir(fd: &OwnedFd) -> io::Result<bool> {
        Ok(stat(fd)?.st_mode & libc::S_IFMT == libc::S_IFDIR)
    }

    /// A regular file's bytes; anything else (a FIFO, a device) is not one.
    pub(super) fn read_regular(fd: OwnedFd) -> io::Result<Option<Vec<u8>>> {
        if stat(&fd)?.st_mode & libc::S_IFMT != libc::S_IFREG {
            return Ok(None);
        }
        let mut bytes = Vec::new();
        std::fs::File::from(fd).read_to_end(&mut bytes)?;
        Ok(Some(bytes))
    }

    /// The names in `dir`, without `.` and `..`.
    pub(super) fn list(dir: &OwnedFd) -> io::Result<Vec<PathBuf>> {
        // fdopendir takes the descriptor it is given; it gets its own copy.
        // SAFETY: dup of a valid descriptor.
        let copy = check(unsafe { libc::fcntl(dir.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) })?;
        // SAFETY: a valid descriptor whose ownership passes to the stream.
        let stream = unsafe { libc::fdopendir(copy.as_raw_fd()) };
        if stream.is_null() {
            return Err(io::Error::last_os_error());
        }
        std::mem::forget(copy); // closedir closes it
        let mut names = Vec::new();
        loop {
            // SAFETY: a valid stream; the entry is read before the next readdir.
            let entry = unsafe { libc::readdir(stream) };
            if entry.is_null() {
                break;
            }
            // SAFETY: d_name is NUL-terminated.
            let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }.to_bytes();
            if name != b"." && name != b".." {
                names.push(PathBuf::from(OsStr::from_bytes(name)));
            }
        }
        // SAFETY: a stream fdopendir returned, closed once.
        unsafe { libc::closedir(stream) };
        Ok(names)
    }

    /// Write `bytes` as `name` in `dir`: a new file beside it, then renamed over it. The rename
    /// replaces whatever `name` is (a symlink too) and never writes through it.
    pub(super) fn replace_at(dir: &OwnedFd, name: &OsStr, bytes: &[u8]) -> io::Result<()> {
        let mut temporary = OsStr::new(".").to_os_string();
        temporary.push(name);
        temporary.push(format!(".artifacts-sync-{}", std::process::id()));
        let flags = libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL;
        let _ = unlink_at(dir, &temporary);
        let file = open_at(dir, &temporary, flags)?;
        let written = std::fs::File::from(file).write_all(bytes);
        let renamed = written.and_then(|()| {
            let (from, to) = (c_name(&temporary)?, c_name(name)?);
            // SAFETY: a valid descriptor and NUL-terminated names.
            let result = unsafe {
                libc::renameat(dir.as_raw_fd(), from.as_ptr(), dir.as_raw_fd(), to.as_ptr())
            };
            if result < 0 { Err(io::Error::last_os_error()) } else { Ok(()) }
        });
        if renamed.is_err() {
            let _ = unlink_at(dir, &temporary);
        }
        renamed
    }

    fn unlink_at(dir: &OwnedFd, name: &OsStr) -> io::Result<()> {
        let name = c_name(name)?;
        // SAFETY: a valid descriptor and a NUL-terminated name.
        if unsafe { libc::unlinkat(dir.as_raw_fd(), name.as_ptr(), 0) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
}

impl Dir {
    /// The folder `relative` below `anchor`, when every folder on the way is a real one. `None`
    /// when it is missing or reached through a symlink.
    pub(crate) fn open(anchor: &Path, relative: &Path) -> io::Result<Option<Self>> {
        let names = names(relative)?;
        #[cfg(unix)]
        {
            let mut fd = match unix::open_anchor(anchor) {
                Ok(fd) => fd,
                Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
                Err(error) => return Err(error),
            };
            for name in names {
                fd = match unix::open_dir_at(&fd, name) {
                    Ok(next) => next,
                    Err(error) if not_followed(&error) => return Ok(None),
                    Err(error) => return Err(error),
                };
            }
            Ok(Some(Self { fd }))
        }
        #[cfg(not(unix))]
        {
            let mut path = anchor.to_path_buf();
            for name in names {
                path.push(name);
                match std::fs::symlink_metadata(&path) {
                    Ok(meta) if meta.is_dir() => {}
                    Ok(_) => return Ok(None),
                    Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
                    Err(error) => return Err(error),
                }
            }
            Ok(Some(Self { path }))
        }
    }

    /// Every regular file below this folder, by its path relative to it. Symlinks are skipped.
    pub(crate) fn read_tree(&self) -> io::Result<Vec<(PathBuf, Vec<u8>)>> {
        let mut out = Vec::new();
        #[cfg(unix)]
        {
            fn walk(
                dir: &std::os::fd::OwnedFd,
                prefix: &Path,
                out: &mut Vec<(PathBuf, Vec<u8>)>,
            ) -> io::Result<()> {
                for name in unix::list(dir)? {
                    // O_NONBLOCK: a FIFO never holds the pass.
                    let fd = match unix::open_at(
                        dir,
                        name.as_os_str(),
                        libc::O_RDONLY | libc::O_NONBLOCK,
                    ) {
                        Ok(fd) => fd,
                        Err(error) if not_followed(&error) => continue,
                        Err(error) => return Err(error),
                    };
                    let path = prefix.join(&name);
                    if unix::is_dir(&fd)? {
                        walk(&fd, &path, out)?;
                    } else if let Some(bytes) = unix::read_regular(fd)? {
                        out.push((path, bytes));
                    }
                }
                Ok(())
            }
            walk(&self.fd, Path::new(""), &mut out)?;
        }
        #[cfg(not(unix))]
        {
            fn walk(
                root: &Path,
                current: &Path,
                out: &mut Vec<(PathBuf, Vec<u8>)>,
            ) -> io::Result<()> {
                for entry in std::fs::read_dir(current)? {
                    let entry = entry?;
                    let kind = entry.file_type()?;
                    let path = entry.path();
                    if kind.is_dir() {
                        walk(root, &path, out)?;
                    } else if kind.is_file() {
                        let relative = path.strip_prefix(root).unwrap_or(&path).to_path_buf();
                        out.push((relative, std::fs::read(&path)?));
                    }
                }
                Ok(())
            }
            walk(&self.path, &self.path, &mut out)?;
        }
        Ok(out)
    }

    /// A file's bytes, or `None` when it is missing, not a regular file or behind a symlink.
    pub(crate) fn read(&self, relative: &Path) -> io::Result<Option<Vec<u8>>> {
        let names = names(relative)?;
        let Some((file, folders)) = names.split_last() else { return Ok(None) };
        #[cfg(unix)]
        {
            let Some(dir) = self.descend(folders, false)? else { return Ok(None) };
            match unix::open_at(&dir, file, libc::O_RDONLY | libc::O_NONBLOCK) {
                Ok(fd) => unix::read_regular(fd),
                Err(error) if not_followed(&error) => Ok(None),
                Err(error) => Err(error),
            }
        }
        #[cfg(not(unix))]
        {
            let _ = folders;
            let path = self.path.join(relative);
            match std::fs::symlink_metadata(&path) {
                Ok(meta) if meta.is_file() => std::fs::read(&path).map(Some),
                Ok(_) => Ok(None),
                Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
                Err(error) => Err(error),
            }
        }
    }

    /// Whether nothing at all is at `relative` (a symlink or a folder in the way is something).
    pub(crate) fn missing(&self, relative: &Path) -> bool {
        let Ok(names) = names(relative) else { return false };
        let Some((file, folders)) = names.split_last() else { return false };
        #[cfg(unix)]
        {
            match self.descend(folders, false) {
                Ok(None) => self.descend_missing(folders),
                Ok(Some(dir)) => {
                    let Ok(name) =
                        std::ffi::CString::new(std::os::unix::ffi::OsStrExt::as_bytes(*file))
                    else {
                        return false;
                    };
                    // SAFETY: zeroed stat out-parameter, valid descriptor and name.
                    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
                    let result = unsafe {
                        libc::fstatat(
                            std::os::fd::AsRawFd::as_raw_fd(&dir),
                            name.as_ptr(),
                            &mut stat,
                            libc::AT_SYMLINK_NOFOLLOW,
                        )
                    };
                    result < 0 && io::Error::last_os_error().kind() == io::ErrorKind::NotFound
                }
                Err(_) => false,
            }
        }
        #[cfg(not(unix))]
        {
            let _ = (file, folders);
            std::fs::symlink_metadata(self.path.join(relative))
                .is_err_and(|error| error.kind() == io::ErrorKind::NotFound)
        }
    }

    /// Write `bytes` to `relative`, making its folders, never through a symlink.
    pub(crate) fn write(&self, relative: &Path, bytes: &[u8]) -> io::Result<()> {
        let names = names(relative)?;
        let Some((file, folders)) = names.split_last() else {
            return Err(io::Error::from(io::ErrorKind::InvalidInput));
        };
        #[cfg(unix)]
        {
            let Some(dir) = self.descend(folders, true)? else {
                return Err(io::Error::other("a folder on the way is a symlink"));
            };
            unix::replace_at(&dir, file, bytes)
        }
        #[cfg(not(unix))]
        {
            let _ = (file, folders);
            let path = self.path.join(relative);
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(path, bytes)
        }
    }

    /// The folder at `folders` below this one; `None` when one is missing (and not made) or a
    /// symlink.
    #[cfg(unix)]
    fn descend(
        &self,
        folders: &[&std::ffi::OsStr],
        make: bool,
    ) -> io::Result<Option<std::os::fd::OwnedFd>> {
        let mut dir = self.fd.try_clone()?;
        for name in folders {
            if make {
                unix::mkdir_at(&dir, name)?;
            }
            dir = match unix::open_dir_at(&dir, name) {
                Ok(next) => next,
                Err(error) if not_followed(&error) => return Ok(None),
                Err(error) => return Err(error),
            };
        }
        Ok(Some(dir))
    }

    /// Whether the first folder `descend` could not open is missing (not a symlink).
    #[cfg(unix)]
    fn descend_missing(&self, folders: &[&std::ffi::OsStr]) -> bool {
        let Ok(mut dir) = self.fd.try_clone() else { return false };
        for name in folders {
            match unix::open_dir_at(&dir, name) {
                Ok(next) => dir = next,
                Err(error) => return error.kind() == io::ErrorKind::NotFound,
            }
        }
        false
    }
}

/// An open refused because the name is missing, a symlink (`ELOOP`) or not a folder: the path
/// is not one to use, which is no error of the pass.
fn not_followed(error: &io::Error) -> bool {
    error.kind() == io::ErrorKind::NotFound
        || matches!(error.raw_os_error(), Some(code) if is_link_refusal(code))
}

#[cfg(unix)]
fn is_link_refusal(code: i32) -> bool {
    code == libc::ELOOP || code == libc::ENOTDIR || code == libc::EMLINK
}

#[cfg(not(unix))]
fn is_link_refusal(_: i32) -> bool {
    false
}
