public import Foundation

/// Describes one repository-relative file shared in a collaboration session.
public struct SharedFileDescriptor: Codable, Equatable, Hashable, Sendable {
    /// A local label for the repository clone.
    public let repositoryID: String
    /// The file path relative to the repository root.
    public let relativePath: String
    /// The local absolute file URL for this peer.
    public let localURL: URL

    /// Creates a shared file descriptor.
    /// - Parameters:
    ///   - repositoryID: A local label for the repository clone.
    ///   - relativePath: The file path relative to the repository root.
    ///   - localURL: The local absolute file URL for this peer.
    public init(repositoryID: String, relativePath: String, localURL: URL) {
        self.repositoryID = repositoryID
        self.relativePath = relativePath
        self.localURL = localURL
    }

    /// The stable collaboration document identifier for a session.
    /// - Parameter sessionID: The current collaboration session identifier.
    /// - Returns: A document identifier scoped to the session.
    public func documentID(sessionID: String) -> String {
        "\(sessionID):\(repositoryID):\(relativePath)"
    }
}
