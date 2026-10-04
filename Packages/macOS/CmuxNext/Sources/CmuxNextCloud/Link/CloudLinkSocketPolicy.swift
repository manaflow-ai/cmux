public import Darwin
import Foundation

/// The check a link socket path passes before the app connects to it. The
/// path comes from an app server's answer, so the app connects only to a Unix
/// socket of this user in a directory only this user can enter (the carrier's
/// `private_dir`, mode 0700). Nobody else can then replace the socket between
/// the check and the connect.
public enum CloudLinkSocketPolicy {
    /// `sun_path` holds 104 bytes with the terminating NUL.
    static let maxPathBytes = 103

    /// Throws ``CloudLinkError/unsafeSocket(_:)`` unless `path` is an
    /// absolute path, without `..`, of a socket owned by `uid` whose directory
    /// is a real directory owned by `uid` with no group or other access.
    public static func check(_ path: String, uid: uid_t = getuid()) throws {
        guard path.hasPrefix("/") else { throw CloudLinkError.unsafeSocket("not an absolute path") }
        guard !path.utf8.contains(0), path.utf8.count <= maxPathBytes else { throw CloudLinkError.unsafeSocket("path too long") }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(".."), !components.contains("."), components.last?.isEmpty == false else {
            throw CloudLinkError.unsafeSocket("not a plain path")
        }
        let directory = components.dropLast().joined(separator: "/")
        guard let dir = status(directory.isEmpty ? "/" : directory) else { throw CloudLinkError.unsafeSocket("no directory") }
        guard dir.st_mode & S_IFMT == S_IFDIR else { throw CloudLinkError.unsafeSocket("directory is not a directory") }
        guard dir.st_uid == uid else { throw CloudLinkError.unsafeSocket("directory has another owner") }
        guard dir.st_mode & 0o077 == 0 else { throw CloudLinkError.unsafeSocket("directory is open to others") }
        guard let socket = status(path) else { throw CloudLinkError.unsafeSocket("no socket") }
        guard socket.st_mode & S_IFMT == S_IFSOCK else { throw CloudLinkError.unsafeSocket("not a socket") }
        guard socket.st_uid == uid else { throw CloudLinkError.unsafeSocket("socket has another owner") }
    }

    /// `lstat`: a symbolic link is reported as itself, never followed.
    private static func status(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }
}
