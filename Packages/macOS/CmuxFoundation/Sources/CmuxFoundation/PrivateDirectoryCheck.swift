import Foundation
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
        guard path.hasPrefix("/") else { return false }
        guard hasSafeAncestry(atPath: path) else { return false }
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

    /// Rejects a path whose ancestors could be renamed by an unrelated user.
    ///
    /// A private child under a non-sticky shared directory is still
    /// replaceable by renaming the child from that ancestor. The lexical and
    /// resolved chains are both checked so system links such as `/tmp` remain
    /// usable while their real target (`/private/tmp`) still has to be sticky.
    private func hasSafeAncestry(atPath path: String) -> Bool {
        let lexicalPath = path
        let lexicalParent = (lexicalPath as NSString).deletingLastPathComponent
        guard checkAncestorChain(lexicalParent) else { return false }
        guard let resolved = resolvedPath(lexicalPath) else { return false }
        if resolved == lexicalPath { return true }
        let resolvedParent = (resolved as NSString).deletingLastPathComponent
        return checkAncestorChain(resolvedParent)
    }

    private func checkAncestorChain(_ path: String) -> Bool {
        var current = path
        while true {
            var info = stat()
            guard lstat(current, &info) == 0 else { return false }
            let type = info.st_mode & S_IFMT
            if type == S_IFLNK {
                guard info.st_uid == 0 || info.st_uid == owner else { return false }
            } else if type == S_IFDIR {
                let writableByOthers = info.st_mode & (S_IWGRP | S_IWOTH) != 0
                let sticky = info.st_mode & S_ISVTX != 0
                guard info.st_uid == 0 || info.st_uid == owner else { return false }
                guard !writableByOthers || sticky else { return false }
            } else {
                return false
            }
            guard current != "/" else { return true }
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { current = "/" }
        }
    }

    private func resolvedPath(_ path: String) -> String? {
        path.withCString { pointer in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }
}
