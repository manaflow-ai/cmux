/// Represents an existing local path resolved under the pointer.
public struct TerminalCommandClickResolvedPath: Equatable, Sendable {
    /// The absolute path to open.
    public let path: String
    /// The terminal-text source that produced the path.
    public let source: TerminalCommandClickPathResolutionSource

    /// Creates a resolved local-path candidate.
    ///
    /// - Parameters:
    ///   - path: The absolute path to open.
    ///   - source: The terminal-text source that produced the path.
    public init(path: String, source: TerminalCommandClickPathResolutionSource) {
        self.path = path
        self.source = source
    }
}
