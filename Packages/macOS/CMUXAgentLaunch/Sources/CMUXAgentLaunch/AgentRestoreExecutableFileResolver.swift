import Darwin

/// Resolves executable regular files for shell-free restore planning.
public struct AgentRestoreExecutableFileResolver: Sendable {
    private let predicate: @Sendable (String) -> Bool

    /// Creates the live POSIX executable-file resolver.
    public init() {
        self.init(isExecutableFile: { path in
            var metadata = stat()
            let status = stat(path, &metadata)
            guard status == 0,
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                return false
            }
            return access(path, X_OK) == 0
        })
    }

    /// Creates a resolver with an injected executable-file predicate.
    ///
    /// - Parameter isExecutableFile: The deterministic filesystem lookup.
    public init(isExecutableFile: @escaping @Sendable (String) -> Bool) {
        predicate = isExecutableFile
    }

    /// Returns whether the path resolves to an executable regular file.
    ///
    /// - Parameter path: The absolute or relative filesystem path to inspect.
    /// - Returns: `true` only for an executable regular file.
    public func isExecutableFile(atPath path: String) -> Bool {
        predicate(path)
    }
}
