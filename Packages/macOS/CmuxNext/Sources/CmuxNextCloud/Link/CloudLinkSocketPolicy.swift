public import Darwin
import Foundation

/// The check a link socket path passes before the app connects to it. The
/// path comes from an app server's answer, so the app connects only to a
/// carrier socket (`cmux-link-<12 hex>.sock`, the Cloud server's
/// `LinkCommand::local_socket`) of this user, in a directory only this user
/// can enter (the carrier's `private_dir`, mode 0700), on a path no other
/// user can change: every ancestor is owned by root or this user, and one
/// that others can write keeps the sticky bit (`/private/tmp`). Nobody else
/// can then replace the socket between the check and the connect. The name
/// rule keeps a wrong answer off the local daemon's and other sockets.
public enum CloudLinkSocketPolicy {
    /// `sun_path` holds 104 bytes with the terminating NUL.
    static let maxPathBytes = 103

    /// Throws ``CloudLinkError/unsafeSocket(_:)`` unless `path` passes.
    public static func check(_ path: String, uid: uid_t = getuid()) throws {
        guard path.hasPrefix("/") else { throw CloudLinkError.unsafeSocket("not an absolute path") }
        guard !path.utf8.contains(0) else { throw CloudLinkError.unsafeSocket("path has a NUL byte") }
        guard path.utf8.count <= maxPathBytes else { throw CloudLinkError.unsafeSocket("path too long") }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              let name = components.last, isCarrierName(name) else {
            throw CloudLinkError.unsafeSocket("not a carrier socket path")
        }
        let directory = components.dropLast().joined(separator: "/")
        // Every ancestor as written (symbolic links included) and as resolved
        // is owned by root or this user and, when others can write it, sticky.
        guard let resolved = realpath(directory, nil) else { throw CloudLinkError.unsafeSocket("no directory") }
        let real = String(cString: resolved)
        free(resolved)
        try checkAncestors(of: directory, uid: uid)
        try checkAncestors(of: real, uid: uid)
        guard let dir = status(directory.isEmpty ? "/" : directory) else { throw CloudLinkError.unsafeSocket("no directory") }
        guard dir.st_mode & S_IFMT == S_IFDIR else { throw CloudLinkError.unsafeSocket("directory is not a directory") }
        guard dir.st_uid == uid else { throw CloudLinkError.unsafeSocket("directory has another owner") }
        guard dir.st_mode & 0o077 == 0 else { throw CloudLinkError.unsafeSocket("directory is open to others") }
        guard let socket = status(path) else { throw CloudLinkError.unsafeSocket("no socket") }
        guard socket.st_mode & S_IFMT == S_IFSOCK else { throw CloudLinkError.unsafeSocket("not a socket") }
        guard socket.st_uid == uid else { throw CloudLinkError.unsafeSocket("socket has another owner") }
    }

    /// Each proper ancestor of `directory` (from `/` down, without the
    /// directory itself).
    private static func checkAncestors(of directory: String, uid: uid_t) throws {
        var prefix = ""
        for component in directory.split(separator: "/").dropLast() {
            prefix += "/" + component
            guard let info = status(prefix) else { throw CloudLinkError.unsafeSocket("no directory") }
            guard info.st_uid == 0 || info.st_uid == uid else { throw CloudLinkError.unsafeSocket("a parent has another owner") }
            if info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o022 != 0, info.st_mode & S_ISVTX == 0 {
                throw CloudLinkError.unsafeSocket("a parent is open to others")
            }
        }
    }

    /// `cmux-link-` + 12 lowercase hex digits + `.sock`.
    static func isCarrierName(_ name: Substring) -> Bool {
        guard name.hasPrefix("cmux-link-"), name.hasSuffix(".sock") else { return false }
        let hex = name.dropFirst("cmux-link-".count).dropLast(".sock".count)
        return hex.count == 12 && hex.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// `lstat`: a symbolic link is reported as itself, never followed.
    private static func status(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }
}
