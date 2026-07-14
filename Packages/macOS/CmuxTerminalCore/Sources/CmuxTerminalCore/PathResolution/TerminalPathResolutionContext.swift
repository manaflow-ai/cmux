/// Ordered directories used to resolve a relative path emitted by a terminal.
public struct TerminalPathResolutionContext: Equatable, Sendable {
    /// The clicked surface's current working directory.
    public let workingDirectory: String?

    /// Lower-priority roots, such as the enclosing repository and workspace.
    public let fallbackDirectories: [String]

    /// Creates a path-resolution context.
    ///
    /// - Parameters:
    ///   - workingDirectory: The clicked surface's current working directory.
    ///   - fallbackDirectories: Roots to try after the working directory.
    public init(
        workingDirectory: String?,
        fallbackDirectories: [String] = []
    ) {
        self.workingDirectory = workingDirectory
        self.fallbackDirectories = fallbackDirectories
    }
}
