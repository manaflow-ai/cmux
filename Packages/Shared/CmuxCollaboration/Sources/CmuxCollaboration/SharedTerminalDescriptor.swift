public import Foundation

/// Describes one terminal surface shared in a collaboration session.
public struct SharedTerminalDescriptor: Codable, Equatable, Hashable, Sendable {
    /// The workspace that owns the terminal surface on the sharing peer.
    public let workspaceID: UUID
    /// The stable terminal surface identifier.
    public let surfaceID: UUID
    /// The user-visible terminal title.
    public let title: String

    /// Creates a shared terminal descriptor.
    /// - Parameters:
    ///   - workspaceID: The workspace that owns the terminal surface on the sharing peer.
    ///   - surfaceID: The stable terminal surface identifier.
    ///   - title: The user-visible terminal title.
    public init(workspaceID: UUID, surfaceID: UUID, title: String) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.title = title
    }

    /// The stable collaboration terminal identifier for a session.
    /// - Parameter sessionID: The current collaboration session identifier.
    /// - Returns: A terminal identifier scoped to the session.
    public func terminalID(sessionID: String) -> String {
        "\(sessionID):terminal:\(workspaceID.uuidString):\(surfaceID.uuidString)"
    }
}
