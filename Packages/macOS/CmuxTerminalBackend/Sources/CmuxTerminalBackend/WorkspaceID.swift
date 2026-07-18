public import Foundation

/// Identifies a canonical backend workspace independently of its numeric ID.
public struct WorkspaceID: BackendIdentifier {
    /// The UUID encoded on the wire.
    public let rawValue: UUID

    /// Creates a workspace identifier.
    ///
    /// - Parameter rawValue: The stable UUID assigned to the workspace.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}
