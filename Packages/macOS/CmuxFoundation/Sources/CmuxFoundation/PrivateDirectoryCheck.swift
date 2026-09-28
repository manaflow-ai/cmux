public import Darwin

/// Makes a directory private to one user before cmux writes into it, such as
/// the per-surface agent command shim directories under a temporary directory.
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

    /// Sets the directory at `path` to mode 0700.
    ///
    /// - Returns: `true` when the directory is now private.
    public func makePrivate(atPath path: String) -> Bool {
        chmod(path, 0o700) == 0
    }
}
