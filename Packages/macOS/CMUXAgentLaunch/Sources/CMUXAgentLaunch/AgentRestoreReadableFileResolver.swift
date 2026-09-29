import Darwin

/// Resolves readable regular files for shell-free restore planning.
///
/// Restore plans replay captured file-valued options such as Claude's
/// `--settings <path>`. The file existed at capture time, but a launcher may
/// have deleted it since; this seam lets the planner check that at plan time
/// with a deterministic lookup that tests can inject.
public struct AgentRestoreReadableFileResolver: Sendable {
    private let predicate: @Sendable (String) -> Bool

    /// Creates the live POSIX readable-file resolver.
    public init() {
        self.init(isReadableFile: { path in
            var metadata = stat()
            let status = stat(path, &metadata)
            guard status == 0,
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                return false
            }
            return access(path, R_OK) == 0
        })
    }

    /// Creates a resolver with an injected readable-file predicate.
    ///
    /// - Parameter isReadableFile: The deterministic filesystem lookup.
    public init(isReadableFile: @escaping @Sendable (String) -> Bool) {
        predicate = isReadableFile
    }

    /// Returns whether the path resolves to a readable regular file.
    ///
    /// - Parameter path: The absolute or relative filesystem path to inspect.
    /// - Returns: `true` only for a readable regular file.
    public func isReadableFile(atPath path: String) -> Bool {
        predicate(path)
    }
}
