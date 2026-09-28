public import Darwin

/// Makes a directory private to one user before cmux writes into it, such as
/// the per-surface agent command shim directories under a temporary directory.
///
/// A directory in a shared temporary directory can already exist under another
/// user's control, so the path is opened without following a symlink and kept
/// only when it is a real directory this user owns. It is then set to 0700.
///
/// ```swift
/// guard PrivateDirectoryCheck().makePrivate(atPath: directory.path) else { return nil }
/// ```
public struct PrivateDirectoryCheck: Sendable {
    /// The user that must own the directory.
    public let owner: uid_t

    /// Creates a check for directories owned by `owner`, the effective user by default.
    public init(owner: uid_t = geteuid()) {
        self.owner = owner
    }

    /// Sets the directory at `path` to mode 0700 when it is a real directory
    /// owned by ``owner``.
    ///
    /// - Returns: `true` when `path` is still that directory, not a symlink,
    ///   owned by ``owner`` and writable by no one else; otherwise `false`,
    ///   without changing anything the path does not own.
    public func makePrivate(atPath path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFDIR,
              opened.st_uid == owner,
              fchmod(fd, 0o700) == 0 else {
            return false
        }
        // The path must still name the directory that was opened and changed.
        var current = stat()
        guard lstat(path, &current) == 0 else { return false }
        return current.st_dev == opened.st_dev
            && current.st_ino == opened.st_ino
            && (current.st_mode & S_IFMT) == S_IFDIR
            && current.st_uid == owner
            && current.st_mode & (S_IWGRP | S_IWOTH) == 0
    }
}
