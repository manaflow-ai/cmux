public import Darwin
public import Foundation

/// A diagnostic log file this user appends to, such as the debug logs under `/tmp`.
///
/// A log in a shared directory can already exist under another user's control,
/// so the path is opened without following a symlink and kept only when it is a
/// regular file ``owner`` owns with no other hard link. New files are 0600.
///
/// ```swift
/// guard let handle = OwnedLogFile(path: "/tmp/cmux-bg.log").openForAppending() else { return }
/// ```
public struct OwnedLogFile: Sendable {
    /// The log file's path.
    public let path: String
    /// The user that must own the file.
    public let owner: uid_t

    /// Describes the log at `path`, owned by `owner`, the effective user by default.
    public init(path: String, owner: uid_t = geteuid()) {
        self.path = path
        self.owner = owner
    }

    /// Returns an append-only handle to the file, creating it when missing, or
    /// nil when it cannot be opened or is not private to ``owner``.
    public func openForAppending() -> FileHandle? {
        OwnedFileAppendOpener(expectedOwnerID: owner).fileHandle(atPath: path)
    }
}
