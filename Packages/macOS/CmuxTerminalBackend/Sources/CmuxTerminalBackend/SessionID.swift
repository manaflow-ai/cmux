public import Foundation

/// Identifies one persisted logical terminal backend session.
public struct SessionID: BackendIdentifier {
    /// The UUID encoded on the wire.
    public let rawValue: UUID

    /// Creates a session identifier.
    ///
    /// - Parameter rawValue: The UUID assigned to the persisted session.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}
