public import Foundation

/// Identifies connection-owned presentation state for one frontend view.
public struct PresentationID: BackendIdentifier {
    /// The UUID encoded on the wire.
    public let rawValue: UUID

    /// Creates a presentation identifier.
    ///
    /// - Parameter rawValue: The UUID assigned to the presentation.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}
