import Foundation

/// A requested path whose individual unified diff exceeds the response cap.
public struct WorkspaceGitTooLargePath: Equatable, Sendable {
    /// The repository-relative requested path.
    public let path: String
    /// The UTF-8 byte count of the generated unified diff.
    public let bytes: Int

    /// Creates an oversized-path record.
    /// - Parameters:
    ///   - path: The repository-relative requested path.
    ///   - bytes: The UTF-8 byte count of its diff.
    public init(path: String, bytes: Int) {
        self.path = path
        self.bytes = bytes
    }
}
